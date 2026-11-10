import 'dart:io';

import 'package:path/path.dart' as p;

import 'compress.dart';
import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';

enum AudioFormat {
  mp3('MP3', 'mp3', 'libmp3lame', true, 32, 320),
  m4a('M4A (AAC)', 'm4a', 'aac', true, 32, 320),
  opus('Opus', 'opus', 'libopus', true, 16, 256),
  ogg('OGG Vorbis', 'ogg', 'libvorbis', true, 48, 320),
  flac('FLAC', 'flac', 'flac', false, 0, 0),
  wav('WAV', 'wav', 'pcm_s16le', false, 0, 0);

  const AudioFormat(this.label, this.ext, this.encoder, this.lossy, this.minKbps, this.maxKbps);
  final String label;
  final String ext;
  final String encoder;
  final bool lossy;
  final int minKbps;
  final int maxKbps;

  /// Encoders nativos do FFmpeg existem sempre; os "lib*" dependem do build.
  bool available(EncoderCaps caps) =>
      !encoder.startsWith('lib') || caps.usable.isEmpty || caps.usable.contains(encoder);
}

const audioBitrates = [64, 96, 128, 192, 256, 320];

/// Formato de saída compartilhado pelas ferramentas de áudio.
class AudioOutSettings {
  AudioFormat format = AudioFormat.mp3;
  int kbps = 192;
  bool mono = false;

  AudioOutSettings copy() => AudioOutSettings()
    ..format = format
    ..kbps = kbps
    ..mono = mono;

  String describe() =>
      '${format.label}${format.lossy ? ' $kbps kb/s' : ''}${mono ? ' · mono' : ''}';
}

/// Tamanho (em bytes) só do áudio — em arquivos de vídeo, estimado pelo bitrate.
int audioBytes(MediaInfo info) {
  if (!info.hasVideo) return info.sizeBytes;
  return info.audioBitrate > 0 ? (info.audioBitrate * info.duration / 8).round() : 0;
}

List<String> audioOutArgs(AudioFormat format, int kbps, bool mono, {int sourceChannels = 2}) {
  final k = format.lossy ? kbps.clamp(format.minKbps, format.maxKbps) : 0;
  return [
    '-c:a', format.encoder,
    if (format.lossy) ...['-b:a', '${k}k'],
    if (mono) ...['-ac', '1'] else if (format == AudioFormat.opus && sourceChannels > 2) ...['-ac', '2'],
    if (format == AudioFormat.m4a) ...['-movflags', '+faststart'],
  ];
}

void _delete(String path) {
  try {
    if (File(path).existsSync()) File(path).deleteSync();
  } catch (_) {}
}

Future<String> _outPath(String? outDir, MediaInfo info, String suffix, String ext) async {
  final dir = outDir ?? p.dirname(info.path);
  await Directory(dir).create(recursive: true);
  return uniquePath(p.join(dir, '${p.basenameWithoutExtension(info.path)}$suffix.$ext'));
}

void _checkAudio(MediaInfo info) {
  if (info.audioCount == 0) throw FfError('Este arquivo não tem faixa de áudio.');
  if (info.duration <= 0) throw FfError('Não foi possível descobrir a duração do áudio.');
}

// ---------------------------------------------------------------- converter

Job buildAudioConvertJob(MediaInfo info, AudioOutSettings settings, String? outDir) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Converter',
    detail: '→ ${s.describe()}',
    body: (ctx) async {
      _checkAudio(info);
      final sameExt = p.extension(info.path).toLowerCase() == '.${s.format.ext}';
      final out = await _outPath(outDir, info, sameExt ? '_convertido' : '', s.format.ext);
      try {
        await ctx.run.ffmpeg(
          ctx.tools,
          [
            '-i', info.path, '-map', '0:a:0', '-vn', '-sn', '-dn',
            ...audioOutArgs(s.format, s.kbps, s.mono, sourceChannels: info.channels),
            '-map_metadata', '0', out,
          ],
          onProgress: (t, speed) => ctx.report(t / info.duration, stage: 'Convertendo', speed: speed),
        );
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult('${fmtBytes(audioBytes(info))} → ${fmtBytes(File(out).lengthSync())}', out);
    },
  );
}

// --------------------------------------------------------------- compressor

const _mp3Steps = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];

enum AudioCompressMode { bitrate, targetSize, percent }

class AudioCompressSettings {
  AudioCompressMode mode = AudioCompressMode.bitrate;
  AudioFormat format = AudioFormat.mp3;
  int kbps = 96;
  double targetMb = 10;
  double percent = 50;
  bool mono = false;

  AudioCompressSettings copy() => AudioCompressSettings()
    ..mode = mode
    ..format = format
    ..kbps = kbps
    ..targetMb = targetMb
    ..percent = percent
    ..mono = mono;

  String describe() {
    final q = switch (mode) {
      AudioCompressMode.bitrate => '$kbps kb/s',
      AudioCompressMode.targetSize => 'alvo ${fmtBytes(targetMb * bytesPerMb)}',
      AudioCompressMode.percent => '${percent.round()}% do original',
    };
    return '${format.label} · $q${mono ? ' · mono' : ''}';
  }

  /// Tamanho-alvo em bytes (null no modo por bitrate ou se não dá para saber).
  double? targetBytes(MediaInfo info) => switch (mode) {
        AudioCompressMode.bitrate => null,
        AudioCompressMode.targetSize => targetMb * bytesPerMb,
        AudioCompressMode.percent => audioBytes(info) > 0 ? audioBytes(info) * percent / 100 : null,
      };

  /// Bitrate (kb/s) que será usado; null se não dá para calcular.
  int? kbpsFor(MediaInfo info) {
    if (mode == AudioCompressMode.bitrate) return kbps;
    final target = targetBytes(info);
    if (target == null || info.duration <= 0) return null;
    // 6% de folga: contêiner + variação do encoder em modo VBR.
    return (target * 8 / info.duration * 0.94 / 1000).floor();
  }

  /// Estimativa do tamanho final.
  double? estimateBytes(MediaInfo info) {
    final k = kbpsFor(info);
    if (k == null) return null;
    return k.clamp(format.minKbps, format.maxKbps) * 1000 * info.duration / 8;
  }
}

Job buildAudioCompressJob(MediaInfo info, AudioCompressSettings settings, String? outDir) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Comprimir',
    detail: s.describe(),
    body: (ctx) async {
      _checkAudio(info);
      final k = s.kbpsFor(info);
      if (k == null) {
        throw FfError('Não dá para calcular a porcentagem deste arquivo. Use o modo por bitrate ou por tamanho.');
      }
      final floor = s.format.minKbps;
      if (k < floor) {
        throw FfError('O tamanho-alvo é pequeno demais para ${fmtDuration(info.duration)} de áudio '
            '(daria $k kb/s; o mínimo em ${s.format.label} é $floor). Aumente o alvo ou divida o áudio.');
      }
      final out = await _outPath(outDir, info, '_filume', s.format.ext);
      var kb = k;
      if (s.format == AudioFormat.mp3) {
        // MP3 só existe em degraus fixos; usa o maior que não passa do alvo.
        kb = _mp3Steps.lastWhere((step) => step <= k, orElse: () => _mp3Steps.first);
      }
      final args = audioOutArgs(s.format, kb, s.mono, sourceChannels: info.channels);
      if (s.format == AudioFormat.opus && s.mode != AudioCompressMode.bitrate) {
        args.addAll(['-vbr', 'constrained']);
      }
      try {
        await ctx.run.ffmpeg(
          ctx.tools,
          ['-i', info.path, '-map', '0:a:0', '-vn', '-sn', '-dn', ...args, '-map_metadata', '0', out],
          onProgress: (t, speed) => ctx.report(t / info.duration, stage: 'Comprimindo', speed: speed),
        );
      } catch (_) {
        _delete(out);
        rethrow;
      }
      final before = audioBytes(info), after = File(out).lengthSync();
      String? warning;
      final target = s.targetBytes(info);
      if (before > 0 && after >= before) {
        warning = 'Ficou maior que o original — escolha um bitrate menor.';
      } else if (target != null && after > target) {
        warning = 'Passou do alvo de ${fmtBytes(target)}.';
      }
      final pct = before > 0 ? ' (−${((1 - after / before) * 100).round().abs()}%)' : '';
      return JobResult(
        before > 0 ? '${fmtBytes(before)} → ${fmtBytes(after)}${after < before ? pct : ''}' : fmtBytes(after),
        out,
        warning: warning,
      );
    },
  );
}

// ------------------------------------------------------------------- merger

class AudioMergeSettings {
  bool forceReencode = false;

  AudioMergeSettings copy() => AudioMergeSettings()..forceReencode = forceReencode;
}

/// Dá para juntar sem recodificar? Só arquivos de áudio no mesmo formato.
bool audioMergeCompatible(List<MediaInfo> items) {
  if (items.length < 2) return false;
  final a = items.first;
  final extA = p.extension(a.path).toLowerCase();
  if (a.hasVideo || !const {'.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.mka'}.contains(extA)) {
    return false;
  }
  return items.skip(1).every((b) =>
      !b.hasVideo &&
      p.extension(b.path).toLowerCase() == extA &&
      b.aCodec == a.aCodec &&
      b.sampleRate == a.sampleRate &&
      b.channels == a.channels);
}

const _maxFilterInputs = 60;

String _norm(int n, {String extra = ''}) =>
    '[$n:a:0]${extra}aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a$n];';

Job buildAudioMergeJob(
  List<MediaInfo> items,
  AudioMergeSettings settings,
  AudioOutSettings output,
  String? outDir,
) {
  final s = settings.copy();
  final o = output.copy();
  final inputs = List<MediaInfo>.of(items);
  final first = inputs.first;
  final copy = !s.forceReencode && audioMergeCompatible(inputs);
  final total = inputs.fold<double>(0, (sum, i) => sum + i.duration);
  return Job(
    title: '${inputs.length} áudios → ${p.basenameWithoutExtension(first.path)}_unido',
    kind: 'Unir',
    detail: copy ? 'sem recodificar' : '→ ${o.describe()}',
    body: (ctx) async {
      if (inputs.length < 2) throw FfError('Adicione pelo menos 2 áudios para unir.');
      inputs.forEach(_checkAudio);
      final ext = copy ? p.extension(first.path).replaceFirst('.', '').toLowerCase() : o.format.ext;
      final out = await _outPath(outDir, first, '_unido', ext);
      final work = await Directory.systemTemp.createTemp('filume_');
      try {
        final List<String> args;
        if (copy) {
          final list = File(p.join(work.path, 'lista.txt'));
          await list.writeAsString([
            for (final i in inputs) "file '${i.path.replaceAll("'", r"'\''")}'",
          ].join('\n'));
          args = ['-f', 'concat', '-safe', '0', '-i', list.path, '-map', '0:a:0', '-c', 'copy', out];
        } else {
          if (inputs.length > _maxFilterInputs) {
            throw FfError('Para unir áudios de formatos diferentes, o limite é de $_maxFilterInputs por vez.');
          }
          final graph = StringBuffer();
          for (var n = 0; n < inputs.length; n++) {
            graph.write(_norm(n));
          }
          graph.write('${[for (var n = 0; n < inputs.length; n++) '[a$n]'].join()}'
              'concat=n=${inputs.length}:v=0:a=1[out]');
          args = [
            for (final i in inputs) ...['-i', i.path],
            '-filter_complex', graph.toString(), '-map', '[out]',
            ...audioOutArgs(o.format, o.kbps, o.mono),
            out,
          ];
        }
        await ctx.run.ffmpeg(ctx.tools, args,
            onProgress: (t, speed) => ctx.report(t / total, stage: 'Unindo', speed: speed));
      } catch (_) {
        _delete(out);
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

// -------------------------------------------------------------------- mixer

enum MixLength {
  longest('Até o áudio mais longo'),
  shortest('Até o mais curto'),
  first('Duração do primeiro');

  const MixLength(this.label);
  final String label;
}

class MixSettings {
  MixLength length = MixLength.longest;

  /// Volume de cada arquivo (1.0 = 100%), pela chave do caminho.
  final Map<String, double> gains = {};

  double gainOf(String path) => gains[path] ?? 1.0;

  MixSettings copy() => MixSettings()
    ..length = length
    ..gains.addAll(gains);
}

Job buildAudioMixJob(List<MediaInfo> items, MixSettings settings, AudioOutSettings output, String? outDir) {
  final s = settings.copy();
  final o = output.copy();
  final inputs = List<MediaInfo>.of(items);
  final first = inputs.first;
  return Job(
    title: '${inputs.length} áudios → ${p.basenameWithoutExtension(first.path)}_mix',
    kind: 'Mixar',
    detail: '${s.length.label.toLowerCase()} · ${o.describe()}',
    body: (ctx) async {
      if (inputs.length < 2) throw FfError('Adicione pelo menos 2 áudios para mixar.');
      if (inputs.length > 32) throw FfError('O mixer aceita até 32 áudios por vez.');
      inputs.forEach(_checkAudio);
      final durations = inputs.map((i) => i.duration).toList()..sort();
      final total = switch (s.length) {
        MixLength.longest => durations.last,
        MixLength.shortest => durations.first,
        MixLength.first => first.duration,
      };
      final graph = StringBuffer();
      for (var n = 0; n < inputs.length; n++) {
        final g = s.gainOf(inputs[n].path);
        graph.write(_norm(n, extra: g == 1.0 ? '' : 'volume=${g.toStringAsFixed(2)},'));
      }
      // normalize=0 mantém o volume de cada faixa; o limitador evita estouro na soma.
      graph.write('${[for (var n = 0; n < inputs.length; n++) '[a$n]'].join()}'
          'amix=inputs=${inputs.length}:duration=${s.length.name}:dropout_transition=0:normalize=0,'
          'alimiter=limit=0.97[out]');
      final out = await _outPath(outDir, first, '_mix', o.format.ext);
      try {
        await ctx.run.ffmpeg(
          ctx.tools,
          [
            for (final i in inputs) ...['-i', i.path],
            '-filter_complex', graph.toString(), '-map', '[out]',
            ...audioOutArgs(o.format, o.kbps, o.mono),
            out,
          ],
          onProgress: (t, speed) => ctx.report(t / total, stage: 'Mixando', speed: speed),
        );
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult('${fmtDuration(total)} · ${fmtBytes(File(out).lengthSync())}', out);
    },
  );
}
