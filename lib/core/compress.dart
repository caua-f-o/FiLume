import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';
import 'streams.dart';

enum VCodec {
  h264('H.264', 'Mais compatível', 23),
  hevc('H.265 (HEVC)', 'Arquivos menores', 26),
  av1('AV1', 'Menor ainda, mais lento', 32);

  const VCodec(this.label, this.hint, this.defaultCrf);
  final String label;
  final String hint;
  final int defaultCrf;
}

enum CompressMode { quality, targetSize, percent }

enum Speed {
  fast('Rápido'),
  balanced('Equilibrado'),
  small('Menor arquivo');

  const Speed(this.label);
  final String label;
}

enum AudioMode {
  copy('Manter original', 0),
  aac192('AAC 192 kb/s', 192),
  aac128('AAC 128 kb/s', 128),
  aac96('AAC 96 kb/s', 96),
  none('Remover áudio', 0);

  const AudioMode(this.label, this.kbps);
  final String label;
  final int kbps;
}

enum OutContainer {
  mp4('MP4', 'mp4'),
  mkv('MKV', 'mkv'),
  mov('MOV', 'mov');

  const OutContainer(this.label, this.ext);
  final String label;
  final String ext;
}

/// Encoders disponíveis (detectados em tempo de execução).
class EncoderCaps {
  const EncoderCaps(this.usable);
  final Set<String> usable;

  static const _cpu = {VCodec.h264: 'libx264', VCodec.hevc: 'libx265', VCodec.av1: 'libsvtav1'};

  String? cpuFor(VCodec c) => usable.contains(_cpu[c]) ? _cpu[c] : null;

  String? gpuFor(VCodec c) {
    for (final suffix in const ['nvenc', 'qsv', 'amf']) {
      final name = '${c.name}_$suffix';
      if (usable.contains(name)) return name;
    }
    return null;
  }

  bool supports(VCodec c) => cpuFor(c) != null || gpuFor(c) != null;

  static String gpuLabel(String encoder) {
    if (encoder.endsWith('nvenc')) return 'NVIDIA';
    if (encoder.endsWith('qsv')) return 'Intel';
    return 'AMD';
  }
}

class CompressSettings {
  VCodec codec = VCodec.h264;
  bool useGpu = false;
  CompressMode mode = CompressMode.quality;
  int crf = VCodec.h264.defaultCrf;
  double targetMb = 100;
  double percent = 50;
  bool twoPass = true;
  Speed speed = Speed.balanced;

  /// Altura máxima (lado menor) em pixels; 0 = manter.
  int maxHeight = 0;

  /// FPS máximo; 0 = manter.
  int maxFps = 0;
  AudioMode audio = AudioMode.aac128;
  OutContainer container = OutContainer.mp4;

  /// Usa metade dos núcleos e menos lookahead: menos RAM e PC mais livre.
  bool eco = false;

  CompressSettings copy() => CompressSettings()
    ..codec = codec
    ..useGpu = useGpu
    ..mode = mode
    ..crf = crf
    ..targetMb = targetMb
    ..percent = percent
    ..twoPass = twoPass
    ..speed = speed
    ..maxHeight = maxHeight
    ..maxFps = maxFps
    ..audio = audio
    ..container = container
    ..eco = eco;

  String describe() {
    final q = switch (mode) {
      CompressMode.quality => 'qualidade $crf',
      CompressMode.targetSize => 'alvo ${fmtBytes(targetMb * bytesPerMb)}',
      CompressMode.percent => '${percent.round()}% do original',
    };
    return '${codec.label} · $q${useGpu ? ' · GPU' : ''}';
  }
}

/// Tamanho-alvo em bytes para os modos por tamanho (null no modo qualidade).
double? targetBytesFor(CompressSettings s, MediaInfo info) => switch (s.mode) {
      CompressMode.quality => null,
      CompressMode.targetSize => s.targetMb * bytesPerMb,
      CompressMode.percent => info.sizeBytes * s.percent / 100,
    };

int _audioBps(CompressSettings s, MediaInfo info) {
  if (s.audio == AudioMode.none || info.audioCount == 0) return 0;
  if (s.audio == AudioMode.copy) {
    return info.audioBitrate > 0 ? info.audioBitrate : 160000 * info.audioCount;
  }
  return s.audio.kbps * 1000 * info.audioCount;
}

/// Bitrate de vídeo necessário para caber no alvo (pode ser inviável: <= 0).
int videoBitrateFor(CompressSettings s, MediaInfo info) {
  final target = targetBytesFor(s, info);
  if (target == null || info.duration <= 0) return 0;
  // 3% de folga para o contêiner e variação do encoder.
  return (target * 8 / info.duration * 0.97 - _audioBps(s, info)).floor();
}

const _minVideoBps = 60000;

String _preset(String enc, Speed s) {
  final i = s.index;
  if (enc == 'libx264' || enc == 'libx265') return const ['veryfast', 'medium', 'slow'][i];
  if (enc == 'libsvtav1') return const ['10', '8', '5'][i];
  if (enc.endsWith('nvenc')) return const ['p2', 'p5', 'p7'][i];
  if (enc.endsWith('qsv')) return const ['veryfast', 'medium', 'slow'][i];
  return const ['speed', 'balanced', 'quality'][i]; // amf
}

/// Argumentos de codificação de vídeo. [preFilters] entram antes de
/// escala/FPS; com [noVf] nenhum `-vf` é emitido (para quem usa filter_complex).
List<String> videoEncodeArgs(
  CompressSettings s,
  MediaInfo info,
  String enc,
  int videoBps, {
  int pass = 0,
  List<String> preFilters = const [],
  bool noVf = false,
}) {
  final a = <String>['-c:v', enc];
  final threads = math.max(1, Platform.numberOfProcessors ~/ 2);
  final x265 = <String>[];
  final svt = <String>[];

  if (enc.endsWith('amf')) {
    a.addAll(['-quality', _preset(enc, s.speed)]);
  } else {
    a.addAll(['-preset', _preset(enc, s.speed)]);
  }

  if (s.mode == CompressMode.quality) {
    final q = '${s.crf}';
    if (enc.startsWith('lib')) {
      a.addAll(['-crf', q]);
    } else if (enc.endsWith('nvenc')) {
      a.addAll(['-rc', 'vbr', '-cq', q, '-b:v', '0']);
    } else if (enc.endsWith('qsv')) {
      a.addAll(['-global_quality', q]);
    } else {
      a.addAll(['-rc', 'cqp', '-qp_i', q, '-qp_p', q, '-qp_b', q]);
    }
  } else {
    a.addAll(['-b:v', '$videoBps']);
    if (enc != 'libsvtav1') {
      a.addAll(['-maxrate', '${videoBps * 2}', '-bufsize', '${videoBps * 4}']);
    }
    if (pass > 0) {
      if (enc == 'libx265') {
        x265.add('pass=$pass');
      } else {
        a.addAll(['-pass', '$pass', '-passlogfile', 'ffpass']);
      }
    }
  }

  if (s.eco) {
    if (enc == 'libx264') a.addAll(['-threads', '$threads', '-rc-lookahead', '20']);
    if (enc == 'libx265') x265.addAll(['pools=$threads', 'rc-lookahead=15']);
    if (enc == 'libsvtav1') svt.add('lp=$threads');
    a.addAll(['-filter_threads', '1']);
  }
  if (enc == 'libx265') x265.add('log-level=error');
  if (x265.isNotEmpty) a.addAll(['-x265-params', x265.join(':')]);
  if (svt.isNotEmpty) a.addAll(['-svtav1-params', svt.join(':')]);

  final filters = <String>[...preFilters];
  final shortSide = math.min(info.width, info.height);
  if (s.maxHeight > 0 && shortSide > s.maxHeight) {
    filters.add(info.width >= info.height
        ? 'scale=-2:${s.maxHeight}'
        : 'scale=${s.maxHeight}:-2');
  }
  if (s.maxFps > 0 && info.fps > s.maxFps + 0.5) filters.add('fps=${s.maxFps}');
  if (filters.isNotEmpty && !noVf) a.addAll(['-vf', filters.join(',')]);

  // H.264 em 8 bits toca em qualquer lugar; HEVC/AV1 preservam a profundidade.
  if (s.codec == VCodec.h264) a.addAll(['-pix_fmt', 'yuv420p']);
  if (s.codec == VCodec.hevc && s.container != OutContainer.mkv) a.addAll(['-tag:v', 'hvc1']);
  return a;
}

Job buildCompressJob(MediaInfo info, CompressSettings settings, String? outDir, EncoderCaps caps) {
  final s = settings.copy();
  final name = p.basename(info.path);
  return Job(
    title: name,
    kind: 'Comprimir',
    detail: s.describe(),
    body: (ctx) async {
      if (!info.hasVideo) throw FfError('Este arquivo não tem faixa de vídeo.');
      if (info.duration <= 0) throw FfError('Não foi possível descobrir a duração do vídeo.');
      final gpu = caps.gpuFor(s.codec), cpu = caps.cpuFor(s.codec);
      final enc = (s.useGpu ? gpu : cpu) ?? cpu ?? gpu;
      if (enc == null) throw FfError('Nenhum encoder ${s.codec.label} disponível neste FFmpeg.');

      var videoBps = 0;
      if (s.mode != CompressMode.quality) {
        videoBps = videoBitrateFor(s, info);
        if (videoBps < _minVideoBps) {
          throw FfError(
              'O tamanho-alvo (${fmtBytes(targetBytesFor(s, info)!)}) é pequeno demais para '
              '${fmtDuration(info.duration)} de vídeo. Aumente o alvo, reduza a resolução ou divida o vídeo.');
        }
      }

      final dir = outDir ?? p.dirname(info.path);
      await Directory(dir).create(recursive: true);
      final out = uniquePath(
          p.join(dir, '${p.basenameWithoutExtension(info.path)}_filume.${s.container.ext}'));

      final twoPass = s.mode != CompressMode.quality &&
          s.twoPass &&
          (enc == 'libx264' || enc == 'libx265');
      final input = ['-i', info.path];
      final work = twoPass ? await Directory.systemTemp.createTemp('filume_') : null;

      try {
        if (twoPass) {
          await ctx.run.ffmpeg(
            ctx.tools,
            [
              ...input,
              '-map', '0:${info.videoIndex}',
              ...videoEncodeArgs(s, info, enc, videoBps, pass: 1),
              '-an', '-sn', '-dn', '-f', 'null', Platform.isWindows ? 'NUL' : '/dev/null',
            ],
            workingDirectory: work!.path,
            onProgress: (t, speed) => ctx.report(t / info.duration * 0.5,
                stage: 'Analisando (1/2)', speed: speed),
          );
        }

        final args = <String>[
          ...input,
          '-map', '0:${info.videoIndex}',
          ...videoEncodeArgs(s, info, enc, videoBps, pass: twoPass ? 2 : 0),
        ];
        if (s.audio == AudioMode.none) {
          args.add('-an');
        } else {
          args.addAll(['-map', '0:a?']);
          args.addAll(s.audio == AudioMode.copy
              ? ['-c:a', 'copy']
              : ['-c:a', 'aac', '-b:a', '${s.audio.kbps}k']);
        }
        args.addAll(subtitleArgs(info, s.container.ext));
        args.addAll(['-dn', '-map_metadata', '0', '-map_chapters', '0']);
        // faststart regrava o arquivo no final; em vídeos gigantes não compensa.
        if (s.container != OutContainer.mkv && info.sizeBytes < 8 * 1024 * 1024 * 1024) {
          args.addAll(['-movflags', '+faststart']);
        }
        args.add(out);

        await ctx.run.ffmpeg(
          ctx.tools,
          args,
          workingDirectory: work?.path,
          onProgress: (t, speed) {
            final f = t / info.duration;
            ctx.report(twoPass ? 0.5 + f * 0.5 : f,
                stage: twoPass ? 'Comprimindo (2/2)' : 'Comprimindo', speed: speed);
          },
        );
      } catch (_) {
        try {
          if (File(out).existsSync()) File(out).deleteSync();
        } catch (_) {}
        rethrow;
      } finally {
        try {
          work?.deleteSync(recursive: true);
        } catch (_) {}
      }

      final outSize = File(out).lengthSync();
      final delta = info.sizeBytes > 0 ? (outSize / info.sizeBytes - 1) * 100 : 0.0;
      final sign = delta > 0 ? '+' : '−';
      final target = targetBytesFor(s, info);
      String? warning;
      if (outSize >= info.sizeBytes) {
        warning = 'Ficou maior que o original — tente qualidade menor ou outro codec.';
      } else if (target != null && outSize > target) {
        warning = 'Passou do alvo de ${fmtBytes(target)}.';
      }
      return JobResult(
        '${fmtBytes(info.sizeBytes)} → ${fmtBytes(outSize)} ($sign${delta.abs().round()}%)',
        out,
        warning: warning,
      );
    },
  );
}
