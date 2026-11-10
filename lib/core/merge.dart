import 'dart:io';

import 'package:path/path.dart' as p;

import 'compress.dart';
import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';
import 'streams.dart';

class MergeSettings {
  /// Recodifica mesmo quando os vídeos são compatíveis entre si.
  bool forceReencode = false;

  MergeSettings copy() => MergeSettings()..forceReencode = forceReencode;
}

/// Dá para juntar sem recodificar? Só se todos tiverem o mesmo formato de
/// vídeo e áudio (típico de partes do mesmo vídeo ou clipes da mesma câmera).
bool mergeCompatible(List<MediaInfo> items) {
  if (items.length < 2) return false;
  final a = items.first;
  final extA = p.extension(a.path).toLowerCase();
  for (final b in items.skip(1)) {
    if (p.extension(b.path).toLowerCase() != extA ||
        b.vCodec != a.vCodec ||
        b.width != a.width ||
        b.height != a.height ||
        b.pixFmt != a.pixFmt ||
        (b.fps - a.fps).abs() > 0.02 ||
        b.audioCount != a.audioCount ||
        b.aCodec != a.aCodec ||
        b.sampleRate != a.sampleRate ||
        b.channels != a.channels) {
      return false;
    }
  }
  return true;
}

const _concatCopyExts = {'mp4', 'm4v', 'mov', 'mkv', 'webm', 'ts', 'm2ts', 'mts', 'flv', 'avi'};
const _maxReencodeInputs = 60;

Job buildMergeJob(
  List<MediaInfo> items,
  MergeSettings settings,
  ReencodeSettings reencode,
  String? outDir,
  EncoderCaps caps,
) {
  final s = settings.copy();
  final r = reencode.copy();
  final inputs = List<MediaInfo>.of(items);
  final first = inputs.first;
  final srcExt = p.extension(first.path).replaceFirst('.', '').toLowerCase();
  final copy = !s.forceReencode && mergeCompatible(inputs) && _concatCopyExts.contains(srcExt);
  final total = inputs.fold<double>(0, (sum, i) => sum + i.duration);
  return Job(
    title: '${inputs.length} vídeos → ${p.basenameWithoutExtension(first.path)}_unido',
    kind: 'Unir',
    detail: copy ? 'sem recodificar' : 'recodificando · qualidade ${r.level.label.toLowerCase()}',
    body: (ctx) async {
      if (inputs.length < 2) throw FfError('Adicione pelo menos 2 vídeos para unir.');
      if (total <= 0) throw FfError('Não foi possível descobrir a duração dos vídeos.');
      final ext = copy ? srcExt : outExtFor(first.path);
      final dir = outDir ?? p.dirname(first.path);
      await Directory(dir).create(recursive: true);
      final out = uniquePath(p.join(dir, '${p.basenameWithoutExtension(first.path)}_unido.$ext'));
      final work = await Directory.systemTemp.createTemp('filume_');

      try {
        final List<String> args;
        if (copy) {
          // Lista para o "concat demuxer": lê um arquivo de cada vez.
          final list = File(p.join(work.path, 'lista.txt'));
          await list.writeAsString([
            for (final i in inputs) "file '${i.path.replaceAll("'", r"'\''")}'",
          ].join('\n'));
          args = [
            '-f', 'concat', '-safe', '0', '-i', list.path,
            '-map', '0:v:0', '-map', '0:a?',
            '-c', 'copy',
            if (first.vCodec == 'hevc' && ext != 'mkv') ...['-tag:v', 'hvc1'],
            ...faststartArgs(ext, inputs.fold<int>(0, (n, i) => n + i.sizeBytes)),
            out,
          ];
        } else {
          if (inputs.length > _maxReencodeInputs) {
            throw FfError('Para unir vídeos diferentes entre si, o limite é de $_maxReencodeInputs por vez.');
          }
          // Tudo é ajustado ao formato do primeiro vídeo (com barras, sem distorcer).
          final w = first.width - first.width % 2, h = first.height - first.height % 2;
          final fps = first.fps > 0 ? first.fps.toStringAsFixed(3) : '30';
          final anyAudio = inputs.any((i) => i.audioCount > 0);
          final graph = StringBuffer();
          final pads = StringBuffer();
          for (var n = 0; n < inputs.length; n++) {
            final i = inputs[n];
            graph.write('[$n:${i.videoIndex}]scale=$w:$h:force_original_aspect_ratio=decrease,'
                'pad=$w:$h:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=$fps,format=yuv420p[v$n];');
            pads.write('[v$n]');
            if (anyAudio) {
              graph.write(i.audioCount > 0
                  ? '[$n:a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a$n];'
                  : 'anullsrc=r=48000:cl=stereo,atrim=duration=${i.duration.toStringAsFixed(3)}[a$n];');
              pads.write('[a$n]');
            }
          }
          graph.write('${pads}concat=n=${inputs.length}:v=1:a=${anyAudio ? 1 : 0}[v]${anyAudio ? '[a]' : ''}');
          args = [
            for (final i in inputs) ...['-i', i.path],
            '-filter_complex', graph.toString(),
            '-map', '[v]',
            ...reencodeVideoArgs(r, caps, first, ext, noVf: true),
            if (anyAudio) ...['-map', '[a]', ...audioEncodeArgs(ext, caps)],
            ...faststartArgs(ext, inputs.fold<int>(0, (n, i) => n + i.sizeBytes)),
            out,
          ];
        }
        await ctx.run.ffmpeg(ctx.tools, args,
            onProgress: (t, speed) =>
                ctx.report(t / total, stage: copy ? 'Unindo' : 'Unindo e recodificando', speed: speed));
      } catch (_) {
        try {
          if (File(out).existsSync()) File(out).deleteSync();
        } catch (_) {}
        rethrow;
      } finally {
        try {
          work.deleteSync(recursive: true);
        } catch (_) {}
      }
      return JobResult('${fmtDuration(total)} · ${fmtBytes(File(out).lengthSync())}', out);
    },
  );
}
