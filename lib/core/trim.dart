import 'dart:io';

import 'package:path/path.dart' as p;

import 'compress.dart';
import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';
import 'streams.dart';

class TrimSettings {
  double start = 0;

  /// null = até o fim do vídeo.
  double? end;

  /// Corte exato no quadro (recodifica) em vez de no keyframe (cópia).
  bool precise = false;

  TrimSettings copy() => TrimSettings()
    ..start = start
    ..end = end
    ..precise = precise;

  /// Trecho efetivo para um vídeo, ou null se não sobra nada para cortar.
  (double, double)? rangeFor(MediaInfo info) {
    final e = end == null || end! > info.duration ? info.duration : end!;
    if (start >= e || (start <= 0 && e >= info.duration)) return null;
    return (start, e);
  }

  String describe() =>
      '${fmtDuration(start)} → ${end == null ? 'fim' : fmtDuration(end!)}${precise ? ' · exato' : ''}';
}

const _copyExts = {
  'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'ts', 'm2ts', 'mts', 'flv', 'wmv', 'mpg', 'mpeg',
};

Job buildTrimJob(
  MediaInfo info,
  TrimSettings settings,
  ReencodeSettings reencode,
  String? outDir,
  EncoderCaps caps,
) {
  final s = settings.copy();
  final r = reencode.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Cortar',
    detail: s.describe(),
    body: (ctx) async {
      final range = s.rangeFor(info);
      if (range == null) {
        throw FfError(s.start >= info.duration
            ? 'O início (${fmtDuration(s.start)}) fica depois do fim do vídeo (${fmtDuration(info.duration)}).'
            : 'O trecho escolhido é o vídeo inteiro ou está vazio — confira início e fim.');
      }
      final (start, end) = range;
      final length = end - start;
      final srcExt = p.extension(info.path).replaceFirst('.', '').toLowerCase();
      final ext = s.precise
          ? outExtFor(info.path)
          : (_copyExts.contains(srcExt) ? srcExt : 'mkv');
      final dir = outDir ?? p.dirname(info.path);
      await Directory(dir).create(recursive: true);
      final out = uniquePath(p.join(dir, '${p.basenameWithoutExtension(info.path)}_corte.$ext'));

      // -ss antes do -i: o FFmpeg pula direto para o ponto, sem ler o começo.
      final args = <String>[
        '-ss', start.toStringAsFixed(3),
        '-i', info.path,
        '-t', length.toStringAsFixed(3),
      ];
      if (s.precise) {
        args.addAll(['-map', '0:${info.videoIndex}', ...reencodeVideoArgs(r, caps, info, ext)]);
        if (info.audioCount > 0) {
          args.addAll(['-map', '0:a', ...audioEncodeArgs(ext, caps)]);
        }
        args.addAll(subtitleArgs(info, ext));
        args.addAll(['-dn', '-map_metadata', '0', ...faststartArgs(ext, info.sizeBytes)]);
      } else {
        args.addAll([
          '-map', '0:v?', '-map', '0:a?', '-map', '0:s?',
          '-c', 'copy', '-ignore_unknown',
          '-avoid_negative_ts', 'make_zero',
          '-map_metadata', '0',
        ]);
      }
      args.addAll(['-map_chapters', '-1', out]);

      try {
        await ctx.run.ffmpeg(ctx.tools, args,
            onProgress: (t, speed) =>
                ctx.report(t / length, stage: s.precise ? 'Recodificando trecho' : 'Cortando', speed: speed));
      } catch (_) {
        try {
          if (File(out).existsSync()) File(out).deleteSync();
        } catch (_) {}
        rethrow;
      }
      return JobResult('${fmtDuration(length)} · ${fmtBytes(File(out).lengthSync())}', out);
    },
  );
}
