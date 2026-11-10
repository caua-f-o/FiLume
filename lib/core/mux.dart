import 'dart:io';

import 'package:path/path.dart' as p;

import 'compress.dart';
import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';
import 'streams.dart';

enum MuxAudioMode {
  keep('Manter o áudio do vídeo'),
  replace('Substituir pelo arquivo'),
  add('Adicionar como faixa extra'),
  remove('Remover o áudio');

  const MuxAudioMode(this.label);
  final String label;

  bool get needsFile => this == replace || this == add;
}

class MuxSettings {
  MuxAudioMode audioMode = MuxAudioMode.keep;

  /// Arquivo de áudio externo (já lido pelo ffprobe).
  MediaInfo? audio;
  String? subtitlePath;

  /// Termina quando a faixa mais curta acabar.
  bool shortest = false;

  bool get changesSomething =>
      audioMode == MuxAudioMode.remove ||
      (audioMode.needsFile && audio != null) ||
      subtitlePath != null;

  MuxSettings copy() => MuxSettings()
    ..audioMode = audioMode
    ..audio = audio
    ..subtitlePath = subtitlePath
    ..shortest = shortest;

  String describe() => [
        switch (audioMode) {
          MuxAudioMode.keep => null,
          MuxAudioMode.replace => 'áudio trocado',
          MuxAudioMode.add => 'áudio extra',
          MuxAudioMode.remove => 'sem áudio',
        },
        if (subtitlePath != null) 'legenda',
      ].whereType<String>().join(' + ');
}

Job buildMuxJob(MediaInfo info, MuxSettings settings, String? outDir, EncoderCaps caps) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Mux',
    detail: s.describe(),
    body: (ctx) async {
      if (info.duration <= 0) throw FfError('Não foi possível descobrir a duração do vídeo.');
      final ext = outExtFor(info.path, fallback: 'mkv');
      final useAudio = s.audioMode.needsFile ? s.audio : null;
      if (s.audioMode.needsFile && useAudio == null) throw FfError('Escolha o arquivo de áudio.');
      if (useAudio != null && useAudio.audioCount == 0) {
        throw FfError('O arquivo escolhido não tem faixa de áudio.');
      }

      final args = <String>['-i', info.path];
      var nextInput = 1;
      int? audioInput, subInput;
      if (useAudio != null) {
        args.addAll(['-i', useAudio.path]);
        audioInput = nextInput++;
      }
      if (s.subtitlePath != null) {
        args.addAll(['-i', s.subtitlePath!]);
        subInput = nextInput++;
      }

      args.addAll(['-map', '0:${info.videoIndex}', '-c:v', 'copy']);
      if (info.vCodec == 'hevc' && ext != 'mkv') args.addAll(['-tag:v', 'hvc1']);

      // Áudio: copia tudo; só converte a faixa nova se o contêiner não aceitar.
      var audioOut = 0;
      final keepOriginal = s.audioMode == MuxAudioMode.keep || s.audioMode == MuxAudioMode.add;
      args.addAll(['-c:a', 'copy']);
      if (keepOriginal && info.audioCount > 0) {
        if (allAudioFits(info, ext)) {
          args.addAll(['-map', '0:a']);
        } else {
          args.addAll(['-map', '0:a', ...audioEncodeArgs(ext, caps)]);
        }
        audioOut = info.audioCount;
      }
      if (audioInput != null) {
        args.addAll(['-map', '$audioInput:a:0']);
        if (!audioFits(useAudio!.aCodec, ext)) {
          final enc = audioEncodeArgs(ext, caps);
          args.addAll(['-c:a:$audioOut', enc[1], '${enc[2]}:$audioOut', enc[3]]);
        }
      }

      // Legendas: as que já existem, mais a nova.
      args.addAll(subtitleArgs(info, ext));
      if (subInput != null) {
        final n = subtitleCount(info, ext);
        final subExt = p.extension(s.subtitlePath!).toLowerCase();
        final codec = switch (ext) {
          'mkv' => subExt == '.vtt' ? 'srt' : 'copy',
          'webm' => 'webvtt',
          _ => 'mov_text',
        };
        args.addAll(['-map', '$subInput:s:0', '-c:s:$n', codec, '-disposition:s:$n', 'default']);
      }

      args.addAll(['-dn', '-map_metadata', '0', '-map_chapters', '0']);
      // -shortest é impreciso copiando faixas; como as durações são conhecidas,
      // um -t exato resolve.
      var length = info.duration;
      if (s.shortest && useAudio != null && useAudio.duration > 0 && useAudio.duration < length) {
        length = useAudio.duration;
        args.addAll(['-t', length.toStringAsFixed(3)]);
      }
      args.addAll(faststartArgs(ext, info.sizeBytes));

      final dir = outDir ?? p.dirname(info.path);
      await Directory(dir).create(recursive: true);
      final out = uniquePath(p.join(dir, '${p.basenameWithoutExtension(info.path)}_mux.$ext'));
      args.add(out);
      try {
        await ctx.run.ffmpeg(ctx.tools, args,
            onProgress: (t, speed) => ctx.report(t / length, stage: 'Montando faixas', speed: speed));
      } catch (_) {
        try {
          if (File(out).existsSync()) File(out).deleteSync();
        } catch (_) {}
        rethrow;
      }
      return JobResult(fmtBytes(File(out).lengthSync()), out);
    },
  );
}
