import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'compress.dart';
import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';
import 'streams.dart';

enum CropMode { aspect, manual, auto }

enum CropAspect {
  r16x9('16:9', 16, 9),
  r9x16('9:16', 9, 16),
  r1x1('1:1', 1, 1),
  r4x5('4:5', 4, 5),
  r4x3('4:3', 4, 3),
  r21x9('21:9', 21, 9);

  const CropAspect(this.label, this.w, this.h);
  final String label;
  final int w;
  final int h;
}

typedef CropRect = ({int w, int h, int x, int y});

class CropSettings {
  CropMode mode = CropMode.aspect;
  CropAspect aspect = CropAspect.r9x16;

  /// Posição do recorte no eixo que sobra: 0 = esquerda/topo, 1 = direita/base.
  double anchor = 0.5;

  /// Pixels a remover de cada lado (modo manual).
  int left = 0, top = 0, right = 0, bottom = 0;

  CropSettings copy() => CropSettings()
    ..mode = mode
    ..aspect = aspect
    ..anchor = anchor
    ..left = left
    ..top = top
    ..right = right
    ..bottom = bottom;

  String describe() => switch (mode) {
        CropMode.aspect => 'proporção ${aspect.label}',
        CropMode.manual => 'margens E$left C$top D$right B$bottom',
        CropMode.auto => 'remover barras pretas',
      };

  /// Retângulo do recorte (dimensões pares). null no modo automático, se o
  /// recorte não muda nada ou se não sobra imagem.
  CropRect? rectFor(MediaInfo info) {
    final fw = info.width, fh = info.height;
    if (fw < 16 || fh < 16) return null;
    int w, h, x, y;
    switch (mode) {
      case CropMode.auto:
        return null;
      case CropMode.aspect:
        final ratio = aspect.w / aspect.h;
        if (fw / fh > ratio) {
          h = fh;
          w = (fh * ratio).floor();
        } else {
          w = fw;
          h = (fw / ratio).floor();
        }
        w -= w % 2;
        h -= h % 2;
        x = ((fw - w) * anchor).round();
        y = ((fh - h) * anchor).round();
      case CropMode.manual:
        w = fw - left - right;
        h = fh - top - bottom;
        w -= w % 2;
        h -= h % 2;
        x = left;
        y = top;
    }
    if (w < 16 || h < 16) return null;
    if (w >= fw - 1 && h >= fh - 1) return null;
    return (w: w, h: h, x: math.max(0, x), y: math.max(0, y));
  }
}

final _cropRe = RegExp(r'crop=(\d+):(\d+):(\d+):(\d+)');

/// Detecta barras pretas olhando alguns trechos curtos (não lê o vídeo todo).
Future<CropRect?> detectBlackBars(JobCtx ctx, MediaInfo info) async {
  int? x0, y0, x1, y1;
  const points = [0.12, 0.35, 0.6, 0.85];
  for (var n = 0; n < points.length; n++) {
    ctx.report(n / points.length * 0.05, stage: 'Procurando barras pretas');
    await ctx.run.exec(
      ctx.tools.ffmpeg,
      [
        '-hide_banner', '-nostdin', '-v', 'info',
        '-ss', (info.duration * points[n]).toStringAsFixed(2),
        '-i', info.path,
        '-map', '0:${info.videoIndex}',
        '-t', '2', '-vf', 'cropdetect=limit=24:round=2:reset=0',
        '-an', '-sn', '-f', 'null', '-',
      ],
      onStderrLine: (line) {
        final m = _cropRe.firstMatch(line);
        if (m == null) return;
        final w = int.parse(m[1]!), h = int.parse(m[2]!), x = int.parse(m[3]!), y = int.parse(m[4]!);
        if (w <= 0 || h <= 0) return;
        // União das áreas detectadas: nunca corta conteúdo de uma cena clara.
        x0 = x0 == null ? x : math.min(x0!, x);
        y0 = y0 == null ? y : math.min(y0!, y);
        x1 = x1 == null ? x + w : math.max(x1!, x + w);
        y1 = y1 == null ? y + h : math.max(y1!, y + h);
      },
    );
  }
  if (x0 == null) return null;
  var w = x1! - x0!, h = y1! - y0!;
  w -= w % 2;
  h -= h % 2;
  if (w < 16 || h < 16) return null;
  if (w >= info.width - 3 && h >= info.height - 3) return null;
  return (w: w, h: h, x: x0!, y: y0!);
}

Job buildCropJob(
  MediaInfo info,
  CropSettings settings,
  ReencodeSettings reencode,
  String? outDir,
  EncoderCaps caps,
) {
  final s = settings.copy();
  final r = reencode.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Recortar',
    detail: s.describe(),
    body: (ctx) async {
      if (info.duration <= 0) throw FfError('Não foi possível descobrir a duração do vídeo.');
      final CropRect? rect;
      if (s.mode == CropMode.auto) {
        rect = await detectBlackBars(ctx, info);
        if (rect == null) throw FfError('Não encontrei barras pretas neste vídeo.');
      } else {
        rect = s.rectFor(info);
        if (rect == null) {
          throw FfError(s.mode == CropMode.aspect
              ? 'O vídeo já está na proporção ${s.aspect.label}.'
              : 'As margens não deixam imagem suficiente (ou estão todas em zero).');
        }
        if (rect.x + rect.w > info.width || rect.y + rect.h > info.height) {
          throw FfError('O recorte sai para fora da imagem (${info.width}×${info.height}).');
        }
      }
      final ext = outExtFor(info.path);
      final dir = outDir ?? p.dirname(info.path);
      await Directory(dir).create(recursive: true);
      final out = uniquePath(p.join(dir, '${p.basenameWithoutExtension(info.path)}_recorte.$ext'));
      final args = <String>[
        '-i', info.path,
        '-map', '0:${info.videoIndex}',
        ...reencodeVideoArgs(r, caps, info, ext,
            preFilters: ['crop=${rect.w}:${rect.h}:${rect.x}:${rect.y}']),
        if (info.audioCount > 0) ...['-map', '0:a', ...audioArgsFor(info, ext, caps)],
        ...subtitleArgs(info, ext),
        '-dn', '-map_metadata', '0', '-map_chapters', '0',
        ...faststartArgs(ext, info.sizeBytes),
        out,
      ];
      try {
        await ctx.run.ffmpeg(ctx.tools, args,
            onProgress: (t, speed) => ctx.report(t / info.duration, stage: 'Recortando', speed: speed));
      } catch (_) {
        try {
          if (File(out).existsSync()) File(out).deleteSync();
        } catch (_) {}
        rethrow;
      }
      return JobResult(
        '${info.width}×${info.height} → ${rect.w}×${rect.h} · ${fmtBytes(File(out).lengthSync())}',
        out,
      );
    },
  );
}
