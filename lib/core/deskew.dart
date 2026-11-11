import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ffmpeg.dart';

/// Mede a inclinação de uma página digitalizada ou fotografada.
///
/// Devolve o ângulo (em graus, sentido horário) que endireita a imagem;
/// 0 quando ela já está reta ou quando não há linhas de texto para se guiar.
Future<double> detectSkew(FfTools tools, MediaInfo info) async {
  if (info.width <= 0 || info.height <= 0) return 0;
  // Uma cópia pequena em tons de cinza basta e mantém a análise rápida.
  final w = math.min(720, info.width);
  final h = math.max(1, (info.height * w / info.width).round());
  final proc = await Process.start(tools.ffmpeg, [
    '-v', 'error', '-nostdin', '-i', info.path,
    '-frames:v', '1', '-vf', 'scale=$w:$h:flags=area,format=gray',
    '-f', 'rawvideo', '-pix_fmt', 'gray', '-',
  ]);
  proc.stderr.drain<void>().ignore();
  final bytes = BytesBuilder(copy: false);
  await proc.stdout.forEach(bytes.add);
  if (await proc.exitCode != 0) return 0;
  final px = bytes.takeBytes();
  if (px.length < w * h) return 0;
  return skewOfGray(px, w, h);
}

/// Núcleo da medição (perfil de projeção): o texto fica alinhado no ângulo em
/// que as linhas escuras e os espaços claros entre elas ficam mais marcados.
double skewOfGray(Uint8List px, int w, int h) {
  // Limiar: o que for bem mais escuro que a média conta como tinta.
  var sum = 0;
  for (var i = 0; i < w * h; i++) {
    sum += px[i];
  }
  final threshold = (sum / (w * h)) * 0.78;
  final xs = <int>[], ys = <int>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (px[y * w + x] < threshold) {
        xs.add(x - w ~/ 2);
        ys.add(y);
      }
    }
  }
  // Página em branco ou quase toda escura: nada para medir.
  if (xs.length < w * h * 0.004 || xs.length > w * h * 0.6) return 0;

  final rows = Int32List(h + w);
  double score(double degrees) {
    final t = math.tan(degrees * math.pi / 180);
    rows.fillRange(0, rows.length, 0);
    for (var i = 0; i < xs.length; i++) {
      final r = (ys[i] - xs[i] * t).round() + w ~/ 2;
      if (r >= 0 && r < rows.length) rows[r]++;
    }
    var s = 0.0;
    for (var r = 1; r < rows.length; r++) {
      final d = rows[r] - rows[r - 1];
      s += d * d;
    }
    return s;
  }

  var best = 0.0, bestScore = score(0);
  final flat = bestScore;
  for (var a = -15.0; a <= 15.0; a += 0.5) {
    final s = score(a);
    if (s > bestScore) {
      bestScore = s;
      best = a;
    }
  }
  final center = best;
  for (var a = center - 0.5; a <= center + 0.5; a += 0.05) {
    final s = score(a);
    if (s > bestScore) {
      bestScore = s;
      best = a;
    }
  }
  // Só corrige quando o ganho é claro (evita "endireitar" fotos sem texto).
  if (best.abs() < 0.1 || bestScore < flat * 1.08) return 0;
  // O ângulo medido é o da inclinação; a correção é girar o mesmo tanto no sentido oposto.
  return -double.parse(best.toStringAsFixed(2));
}
