import 'dart:io';

import 'package:path/path.dart' as p;

import 'compress.dart';
import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';
import 'streams.dart';

enum ConvFormat {
  mp4('MP4', 'mp4', 'Toca em tudo'),
  mkv('MKV', 'mkv', 'Aceita qualquer faixa'),
  mov('MOV', 'mov', 'Apple / edição'),
  webm('WebM', 'webm', 'Web');

  const ConvFormat(this.label, this.ext, this.hint);
  final String label;
  final String ext;
  final String hint;
}

class ConvertSettings {
  ConvFormat format = ConvFormat.mp4;

  /// Recodifica mesmo quando daria para só trocar o contêiner.
  bool forceReencode = false;

  ConvertSettings copy() => ConvertSettings()
    ..format = format
    ..forceReencode = forceReencode;
}

/// O que a conversão vai fazer com o vídeo e o áudio deste arquivo.
({bool copyVideo, bool copyAudio}) convertPlan(MediaInfo info, ConvertSettings s) => (
      copyVideo: !s.forceReencode && videoFits(info.vCodec, s.format.ext),
      copyAudio: !s.forceReencode && allAudioFits(info, s.format.ext),
    );

Job buildConvertJob(
  MediaInfo info,
  ConvertSettings settings,
  ReencodeSettings reencode,
  String? outDir,
  EncoderCaps caps,
) {
  final s = settings.copy();
  final r = reencode.copy();
  final plan = convertPlan(info, s);
  return Job(
    title: p.basename(info.path),
    kind: 'Converter',
    detail: '→ ${s.format.label}${plan.copyVideo ? ' · sem recodificar' : ' · qualidade ${r.level.label.toLowerCase()}'}',
    body: (ctx) async {
      if (info.duration <= 0) throw FfError('Não foi possível descobrir a duração do vídeo.');
      final ext = s.format.ext;
      final dir = outDir ?? p.dirname(info.path);
      await Directory(dir).create(recursive: true);
      final base = p.basenameWithoutExtension(info.path);
      final sameExt = p.extension(info.path).toLowerCase() == '.$ext';
      final out = uniquePath(p.join(dir, '$base${sameExt ? '_convertido' : ''}.$ext'));

      final args = <String>['-i', info.path, '-map', '0:${info.videoIndex}'];
      if (plan.copyVideo) {
        args.addAll(['-c:v', 'copy']);
        if (info.vCodec == 'hevc' && ext != 'mkv') args.addAll(['-tag:v', 'hvc1']);
      } else {
        args.addAll(reencodeVideoArgs(r, caps, info, ext));
      }
      if (info.audioCount > 0) {
        args.addAll(['-map', '0:a']);
        args.addAll(plan.copyAudio ? const ['-c:a', 'copy'] : audioEncodeArgs(ext, caps));
      }
      args.addAll(subtitleArgs(info, ext));
      args.addAll(['-dn', '-map_metadata', '0', '-map_chapters', '0']);
      args.addAll(faststartArgs(ext, info.sizeBytes));
      args.add(out);

      try {
        await ctx.run.ffmpeg(ctx.tools, args,
            onProgress: (t, speed) => ctx.report(t / info.duration,
                stage: plan.copyVideo ? 'Convertendo' : 'Recodificando', speed: speed));
      } catch (_) {
        _tryDelete(out);
        rethrow;
      }
      final lost = info.subs.length - subtitleCount(info, ext);
      return JobResult(
        '${fmtBytes(info.sizeBytes)} → ${fmtBytes(File(out).lengthSync())}',
        out,
        warning: lost > 0
            ? '$lost legenda(s) em imagem ficaram de fora: ${s.format.label} não comporta. Use MKV para manter.'
            : null,
      );
    },
  );
}

void _tryDelete(String path) {
  try {
    if (File(path).existsSync()) File(path).deleteSync();
  } catch (_) {}
}
