import 'compress.dart';
import 'ffmpeg.dart';

/// Regras de compatibilidade entre codecs e contêineres, usadas por todas as
/// ferramentas para copiar faixas sempre que possível (rápido e sem perda).

const _textSubs = {'subrip', 'srt', 'ass', 'ssa', 'mov_text', 'webvtt', 'text'};

const _videoOk = {
  'mp4': {'h264', 'hevc', 'av1', 'mpeg4'},
  'm4v': {'h264', 'hevc', 'mpeg4'},
  'mov': {'h264', 'hevc', 'mpeg4', 'prores', 'mjpeg'},
  'webm': {'vp8', 'vp9', 'av1'},
};

const _audioOk = {
  'mp4': {'aac', 'mp3', 'ac3', 'eac3'},
  'm4v': {'aac', 'ac3'},
  'mov': {'aac', 'mp3', 'ac3', 'alac', 'pcm_s16le', 'pcm_s24le'},
  'webm': {'opus', 'vorbis'},
};

/// Contêineres em que o FiLume grava resultados recodificados.
const outputExts = {'mp4', 'mkv', 'mov', 'm4v', 'webm'};

bool videoFits(String? codec, String ext) => _videoOk[ext]?.contains(codec) ?? true;

bool audioFits(String? codec, String ext) => _audioOk[ext]?.contains(codec) ?? true;

bool allAudioFits(MediaInfo info, String ext) => info.aCodecs.every((c) => audioFits(c, ext));

/// Mapeia as legendas do arquivo 0 que o contêiner [ext] aceita, convertendo
/// legendas de texto para o formato nativo dele. [firstOut] é o índice da
/// primeira legenda na saída.
List<String> subtitleArgs(MediaInfo info, String ext, {int firstOut = 0}) {
  final args = <String>[];
  var n = firstOut;
  for (final (index, codec) in info.subs) {
    final codecOut = subtitleCodecFor(codec, ext);
    if (codecOut == null) continue;
    args.addAll(['-map', '0:$index', '-c:s:$n', codecOut]);
    n++;
  }
  return args;
}

/// Quantas legendas [subtitleArgs] vai mapear.
int subtitleCount(MediaInfo info, String ext) =>
    info.subs.where((s) => subtitleCodecFor(s.$2, ext) != null).length;

/// Codec de saída para uma legenda, ou null se o contêiner não comporta.
String? subtitleCodecFor(String codec, String ext) {
  final isText = _textSubs.contains(codec);
  switch (ext) {
    case 'mkv':
      return codec == 'mov_text' || codec == 'text' ? 'srt' : 'copy';
    case 'mp4' || 'm4v' || 'mov':
      return isText ? 'mov_text' : null;
    case 'webm':
      return isText ? 'webvtt' : null;
    default:
      return null;
  }
}

/// Áudio de saída: copia se couber no contêiner, senão converte.
List<String> audioArgsFor(MediaInfo info, String ext, EncoderCaps caps) {
  if (info.audioCount == 0) return const ['-an'];
  if (allAudioFits(info, ext)) return const ['-c:a', 'copy'];
  return audioEncodeArgs(ext, caps);
}

List<String> audioEncodeArgs(String ext, EncoderCaps caps) {
  if (ext == 'webm') {
    return caps.usable.contains('libopus')
        ? const ['-c:a', 'libopus', '-b:a', '128k']
        : const ['-c:a', 'libvorbis', '-q:a', '5'];
  }
  return const ['-c:a', 'aac', '-b:a', '160k'];
}

/// Qualidade usada quando uma ferramenta precisa recodificar o vídeo.
enum ReLevel {
  high('Alta', 18),
  balanced('Equilibrada', 22),
  compact('Compacta', 27);

  const ReLevel(this.label, this.crf);
  final String label;
  final int crf;
}

class ReencodeSettings {
  ReLevel level = ReLevel.high;
  bool useGpu = false;

  ReencodeSettings copy() => ReencodeSettings()
    ..level = level
    ..useGpu = useGpu;
}

/// Argumentos de vídeo para recodificar em [ext] (H.264; em WebM, AV1 ou VP9).
List<String> reencodeVideoArgs(
  ReencodeSettings r,
  EncoderCaps caps,
  MediaInfo info,
  String ext, {
  List<String> preFilters = const [],
  bool noVf = false,
}) {
  if (ext == 'webm') {
    final vf = preFilters.isNotEmpty && !noVf ? ['-vf', preFilters.join(',')] : const <String>[];
    if (caps.usable.contains('libsvtav1')) {
      return ['-c:v', 'libsvtav1', '-preset', '8', '-crf', '${r.level.crf + 12}', ...vf];
    }
    if (caps.usable.contains('libvpx-vp9')) {
      return [
        '-c:v', 'libvpx-vp9', '-crf', '${r.level.crf + 12}', '-b:v', '0',
        '-row-mt', '1', '-cpu-used', '4', ...vf,
      ];
    }
    throw FfError('Este FFmpeg não tem encoder para WebM (AV1 ou VP9).');
  }
  var codec = VCodec.h264;
  if (!caps.supports(codec)) {
    codec = VCodec.values.firstWhere(caps.supports,
        orElse: () => throw FfError('Nenhum encoder de vídeo disponível neste FFmpeg.'));
  }
  final s = CompressSettings()
    ..codec = codec
    ..mode = CompressMode.quality
    ..crf = r.level.crf + (codec.defaultCrf - VCodec.h264.defaultCrf)
    ..container = ext == 'mkv' ? OutContainer.mkv : OutContainer.mp4;
  final gpu = caps.gpuFor(codec), cpu = caps.cpuFor(codec);
  final enc = (r.useGpu ? gpu : cpu) ?? cpu ?? gpu!;
  return videoEncodeArgs(s, info, enc, 0, preFilters: preFilters, noVf: noVf);
}

/// Extensão de saída: mantém a do original quando o FiLume sabe gravar nela.
String outExtFor(String path, {String fallback = 'mp4'}) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return outputExts.contains(ext) ? ext : fallback;
}

List<String> faststartArgs(String ext, int sizeBytes) =>
    // faststart regrava o arquivo no final; em vídeos gigantes não compensa.
    ext != 'mkv' && ext != 'webm' && sizeBytes < 8 * 1024 * 1024 * 1024
        ? const ['-movflags', '+faststart']
        : const [];
