import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';

enum SplitMode { size, duration, parts }

class SplitSettings {
  SplitMode mode = SplitMode.size;
  double sizeMb = 100;
  double seconds = 600;
  int parts = 2;

  SplitSettings copy() => SplitSettings()
    ..mode = mode
    ..sizeMb = sizeMb
    ..seconds = seconds
    ..parts = parts;

  String describe() => switch (mode) {
        SplitMode.size => 'Partes de até ${fmtBytes(sizeMb * bytesPerMb)}',
        SplitMode.duration => 'Partes de ${fmtDuration(seconds)}',
        SplitMode.parts => '$parts partes iguais',
      };

  /// Estimativa de quantas partes vão sair (só para a interface).
  int estimateParts(MediaInfo info) => switch (mode) {
        SplitMode.size => sizeMb <= 0 ? 0 : (info.sizeBytes / (sizeMb * bytesPerMb)).ceil(),
        SplitMode.duration => seconds <= 0 ? 0 : (info.duration / seconds).ceil(),
        SplitMode.parts => parts,
      };
}

const _segmentExts = {
  'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'ts', 'm2ts', 'mts', 'flv', 'wmv', 'mpg', 'mpeg',
};

/// Calcula os pontos de corte (em keyframes) para que cada parte caiba no
/// limite. Recebe os pacotes um a um e guarda só uma tabela enxuta de
/// keyframes, então a memória usada não depende do tamanho do vídeo.
class SizeCutPlanner {
  SizeCutPlanner(this.videoIndex, this._minGapBytes);
  final int? videoIndex;

  /// Distância mínima (em bytes) entre keyframes guardados na tabela.
  final int _minGapBytes;

  final List<double> _kfTime = [];
  final List<int> _kfBytes = [];
  int totalBytes = 0;
  bool oversized = false;

  /// PTS do primeiro pacote do stream de referência: o muxer `segment` do
  /// FFmpeg mede os tempos de corte a partir dele.
  double? firstPts;
  int? _refStream;

  void addPacket(int stream, double? pts, int size, bool key) {
    _refStream ??= videoIndex ?? stream;
    final isRef = stream == _refStream;
    if (isRef && pts != null) firstPts ??= pts;
    final boundary = pts != null && key && isRef;
    if (boundary && totalBytes > 0 && (_kfBytes.isEmpty || totalBytes - _kfBytes.last >= _minGapBytes)) {
      _kfTime.add(pts);
      _kfBytes.add(totalBytes);
    }
    totalBytes += size;
  }

  /// Escolhe os cortes: cada parte leva o máximo de GOPs que cabem em
  /// [budgetBytes] (bytes de pacotes, já descontado o overhead do contêiner).
  List<double> plan(int budgetBytes) {
    final cuts = <double>[];
    var segStart = 0;
    var i = 0;
    while (i < _kfBytes.length) {
      // Último keyframe que ainda mantém a parte dentro do orçamento.
      var best = -1;
      while (i < _kfBytes.length && _kfBytes[i] - segStart <= budgetBytes) {
        best = i++;
      }
      final end = i < _kfBytes.length ? _kfBytes[i] : totalBytes;
      if (end - segStart <= budgetBytes) break; // o resto cabe na última parte
      if (best < 0) {
        // Um único trecho entre keyframes já estoura o limite.
        oversized = true;
        best = i++;
      }
      cuts.add(_kfTime[best]);
      segStart = _kfBytes[best];
    }
    if (totalBytes - segStart > budgetBytes) oversized = true;
    return cuts;
  }
}

Future<(List<double>, bool)> _planSizeCuts(JobCtx ctx, MediaInfo info, int limitBytes) async {
  final planner = SizeCutPlanner(info.videoIndex, limitBytes ~/ 400);
  final code = await ctx.run.exec(
    ctx.tools.ffprobe,
    [
      '-v', 'error',
      '-show_entries', 'packet=stream_index,pts_time,dts_time,size,flags',
      '-of', 'csv=p=0',
      info.path,
    ],
    onStdoutLine: (line) {
      final f = line.split(',');
      if (f.length < 5) return;
      final stream = int.tryParse(f[0]);
      final size = int.tryParse(f[3]);
      if (stream == null || size == null) return;
      final pts = double.tryParse(f[1]);
      planner.addPacket(stream, pts, size, f[4].startsWith('K'));
      final t = pts ?? double.tryParse(f[2]);
      if (t != null && info.duration > 0 && stream == (info.videoIndex ?? stream)) {
        ctx.report((t - info.startTime) / info.duration * 0.5, stage: 'Analisando pontos de corte');
      }
    },
  );
  if (code != 0 || planner.totalBytes <= 0) {
    throw FfError('Não foi possível analisar o vídeo.', ctx.run.errorTail.join('\n'));
  }
  // Overhead real do contêiner deste arquivo (MPEG-TS, por exemplo, passa de 8%),
  // mais 1,5% + 64 KB de folga para cabeçalhos e índice de cada parte.
  var overhead = info.sizeBytes / planner.totalBytes;
  if (overhead < 1) overhead = 1;
  var budget = (limitBytes / overhead * 0.985).floor() - 64 * 1024;
  if (budget < limitBytes ~/ 4) budget = limitBytes ~/ 4;
  // 1 ms de folga contra arredondamento: o corte acontece no primeiro keyframe
  // depois do tempo pedido.
  final origin = planner.firstPts ?? info.startTime;
  final cuts = [
    for (final t in planner.plan(budget)) (t - origin - 0.001).clamp(0.0, double.infinity).toDouble(),
  ];
  return (cuts, planner.oversized);
}

Job buildSplitJob(MediaInfo info, SplitSettings settings, String? outDir) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Dividir',
    detail: s.describe(),
    body: (ctx) async {
      if (info.duration <= 0) throw FfError('Não foi possível descobrir a duração do vídeo.');
      final limitBytes = (s.sizeMb * bytesPerMb).floor();
      final segmentArgs = <String>[];
      var scanShare = 0.0;
      var oversized = false;

      switch (s.mode) {
        case SplitMode.size:
          if (limitBytes < bytesPerMb ~/ 2) throw FfError('O tamanho por parte precisa ser de pelo menos 0,5 MB.');
          if (info.sizeBytes <= limitBytes) {
            throw FfError('O vídeo já cabe em ${fmtBytes(limitBytes)} — não há o que dividir.');
          }
          final (cuts, over) = await _planSizeCuts(ctx, info, limitBytes);
          if (cuts.isEmpty) {
            throw FfError('Não há keyframes suficientes para dividir este vídeo sem recodificar.');
          }
          oversized = over;
          scanShare = 0.5;
          final times = cuts.map((t) => t.toStringAsFixed(6)).join(',');
          segmentArgs.addAll(['-segment_times', times]);
        case SplitMode.duration:
          if (s.seconds < 1) throw FfError('A duração por parte precisa ser de pelo menos 1 segundo.');
          if (s.seconds >= info.duration) {
            throw FfError('O vídeo é mais curto que a duração escolhida — não há o que dividir.');
          }
          segmentArgs.addAll(['-segment_time', s.seconds.toStringAsFixed(3)]);
        case SplitMode.parts:
          if (s.parts < 2) throw FfError('Escolha pelo menos 2 partes.');
          segmentArgs.addAll(['-segment_time', (info.duration / s.parts).toStringAsFixed(3)]);
      }

      final base = p.basenameWithoutExtension(info.path);
      var ext = p.extension(info.path).replaceFirst('.', '').toLowerCase();
      if (!_segmentExts.contains(ext)) ext = 'mkv';
      final dir = uniquePath(p.join(outDir ?? p.dirname(info.path), '${base}_partes'), directory: true);
      await Directory(dir).create(recursive: true);
      final pattern = '${p.join(dir, base).replaceAll('%', '%%')}_%03d.$ext';

      try {
        await ctx.run.ffmpeg(
          ctx.tools,
          [
            '-i', info.path,
            '-map', '0:v?', '-map', '0:a?', '-map', '0:s?',
            '-c', 'copy', '-ignore_unknown',
            '-f', 'segment', ...segmentArgs,
            '-reset_timestamps', '1',
            '-segment_start_number', '1',
            if (const {'mp4', 'm4v', 'mov'}.contains(ext)) ...[
              '-segment_format_options', 'movflags=+faststart',
            ],
            pattern,
          ],
          onProgress: (t, speed) => ctx.report(scanShare + t / info.duration * (1 - scanShare),
              stage: 'Dividindo', speed: speed),
        );
      } catch (_) {
        try {
          Directory(dir).deleteSync(recursive: true);
        } catch (_) {}
        rethrow;
      }

      var count = 0, largest = 0;
      await for (final e in Directory(dir).list()) {
        if (e is File) {
          count++;
          final len = await e.length();
          if (len > largest) largest = len;
        }
      }
      String? warning;
      if (s.mode == SplitMode.size && (oversized || largest > limitBytes)) {
        warning = 'Alguma parte passou do limite (maior: ${fmtBytes(largest)}): o vídeo tem trechos '
            'longos sem keyframe. Comprima antes para conseguir partes menores.';
      }
      return JobResult(
        '$count ${count == 1 ? 'parte' : 'partes'} · maior com ${fmtBytes(largest)}',
        dir,
        warning: warning,
      );
    },
  );
}
