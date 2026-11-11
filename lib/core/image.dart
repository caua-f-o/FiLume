import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';

// ------------------------------------------------------------------ formatos

enum ImgFormat {
  jpg('JPG', 'jpg', lossy: true),
  png('PNG', 'png', alpha: true),
  webp('WebP', 'webp', lossy: true, alpha: true),
  avif('AVIF', 'avif', lossy: true),
  bmp('BMP', 'bmp'),
  tiff('TIFF', 'tif', alpha: true);

  const ImgFormat(this.label, this.ext, {this.lossy = false, this.alpha = false});
  final String label;
  final String ext;

  /// Tem ajuste de qualidade (e, com isso, dá para mirar num tamanho).
  final bool lossy;

  /// Guarda transparência.
  final bool alpha;

  bool available(Set<String> encoders) => switch (this) {
        ImgFormat.webp => encoders.contains('libwebp'),
        ImgFormat.avif => encoders.contains('libaom-av1') || encoders.contains('libsvtav1'),
        _ => true,
      };

  static ImgFormat? ofPath(String path) => switch (p.extension(path).toLowerCase()) {
        '.jpg' || '.jpeg' => ImgFormat.jpg,
        '.png' => ImgFormat.png,
        '.webp' => ImgFormat.webp,
        '.avif' => ImgFormat.avif,
        '.bmp' => ImgFormat.bmp,
        '.tif' || '.tiff' => ImgFormat.tiff,
        _ => null,
      };
}

final _alphaFmt = RegExp(r'^(rgba|bgra|argb|abgr|ya\d|yuva|gbrap|pal8)');

bool imageHasAlpha(MediaInfo info) => _alphaFmt.hasMatch(info.pixFmt ?? '');

/// Formato de saída "igual ao de entrada" (PNG quando a entrada não é gravável).
ImgFormat sameFormat(MediaInfo info, Set<String> encoders) {
  final f = ImgFormat.ofPath(info.path);
  return f != null && f.available(encoders) ? f : ImgFormat.png;
}

List<String> _codecArgs(ImgFormat f, int quality, Set<String> encoders, bool alpha) {
  final q = quality.clamp(1, 100);
  switch (f) {
    case ImgFormat.jpg:
      // Escala do MJPEG: 2 (melhor) a 31 (pior).
      final qs = (2 + (100 - q) * 29 / 99).round().clamp(2, 31);
      return ['-c:v', 'mjpeg', '-q:v', '$qs', '-pix_fmt', q >= 90 ? 'yuvj444p' : 'yuvj420p'];
    case ImgFormat.png:
      return ['-c:v', 'png', '-compression_level', '9', '-pred', 'mixed'];
    case ImgFormat.webp:
      return ['-c:v', 'libwebp', '-quality', '$q', '-compression_level', '6'];
    case ImgFormat.avif:
      final crf = (63 - q * 0.58).round().clamp(0, 63);
      return encoders.contains('libaom-av1')
          ? ['-c:v', 'libaom-av1', '-still-picture', '1', '-crf', '$crf', '-b:v', '0', '-cpu-used', '6', '-pix_fmt', 'yuv420p']
          : ['-c:v', 'libsvtav1', '-crf', '$crf', '-preset', '6', '-pix_fmt', 'yuv420p'];
    case ImgFormat.bmp:
      return ['-c:v', 'bmp', '-pix_fmt', 'bgr24'];
    case ImgFormat.tiff:
      return ['-c:v', 'tiff', '-compression_algo', 'deflate', '-pix_fmt', alpha ? 'rgba' : 'rgb24'];
  }
}

/// Monta os argumentos do FFmpeg para gravar uma imagem: filtros em cadeia,
/// fundo branco quando o formato não guarda transparência, e o codificador.
List<String> imageArgs({
  required String input,
  required String output,
  required ImgFormat format,
  required int quality,
  required Set<String> encoders,
  required bool hasAlpha,
  List<String> filters = const [],
  bool palette = false,
}) {
  final chain = [...filters];
  var graph = chain.isEmpty ? 'null' : chain.join(',');
  if (hasAlpha && !format.alpha) {
    graph = '$graph,split[fa][fb];[fa]drawbox=c=white:t=fill:replace=1[fbg];[fbg][fb]overlay=format=auto';
  }
  if (palette) {
    graph = '$graph,split[pa][pb];[pa]palettegen=max_colors=256:reserve_transparent=1[pp];'
        '[pb][pp]paletteuse=dither=sierra2_4a';
  }
  return [
    '-i', input,
    '-filter_complex', '[0:v:0]$graph[out]',
    '-map', '[out]',
    '-an', '-sn', '-dn',
    '-frames:v', '1',
    ...(palette ? ['-c:v', 'png', '-compression_level', '9'] : _codecArgs(format, quality, encoders, hasAlpha)),
    if (format != ImgFormat.webp && format != ImgFormat.avif) ...['-update', '1'],
    output,
  ];
}

Future<String> _outPath(String? outDir, MediaInfo info, String suffix, String ext) async {
  final dir = p.absolute(outDir ?? p.dirname(info.path));
  await Directory(dir).create(recursive: true);
  return uniquePath(p.join(dir, '${p.basenameWithoutExtension(info.path)}$suffix.$ext'));
}

void _delete(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

void _check(MediaInfo info) {
  if (info.width <= 0 || info.height <= 0) throw FfError('Não foi possível ler esta imagem.');
}

Future<void> _encode(JobCtx ctx, List<String> args) => ctx.run.ffmpeg(ctx.tools, args);

String _sizes(MediaInfo info, String out) => '${fmtBytes(info.sizeBytes)} → ${fmtBytes(File(out).lengthSync())}';

// ----------------------------------------------------------------- converter

class ImageConvertSettings {
  ImgFormat format = ImgFormat.jpg;
  int quality = 90;

  ImageConvertSettings copy() => ImageConvertSettings()
    ..format = format
    ..quality = quality;
}

Job buildImageConvertJob(MediaInfo info, ImageConvertSettings settings, String? outDir, Set<String> encoders) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Converter',
    detail: '→ ${s.format.label}${s.format.lossy ? ' · qualidade ${s.quality}' : ''}',
    body: (ctx) async {
      _check(info);
      final same = ImgFormat.ofPath(info.path) == s.format;
      final out = await _outPath(outDir, info, same ? '_convertido' : '', s.format.ext);
      try {
        ctx.report(0.1, stage: 'Convertendo');
        await _encode(
          ctx,
          imageArgs(
            input: info.path,
            output: out,
            format: s.format,
            quality: s.quality,
            encoders: encoders,
            hasAlpha: imageHasAlpha(info),
          ),
        );
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult(_sizes(info, out), out);
    },
  );
}

// ---------------------------------------------------------------- compressor

enum ImageCompressMode { quality, targetSize, percent }

class ImageCompressSettings {
  ImageCompressMode mode = ImageCompressMode.quality;

  /// null = manter o formato de entrada.
  ImgFormat? format;
  int quality = 75;
  double targetKb = 500;
  double percent = 50;

  ImageCompressSettings copy() => ImageCompressSettings()
    ..mode = mode
    ..format = format
    ..quality = quality
    ..targetKb = targetKb
    ..percent = percent;

  ImgFormat outFormat(MediaInfo info, Set<String> encoders) {
    if (format != null) return format!;
    final same = sameFormat(info, encoders);
    // BMP e TIFF não comprimem de verdade: viram JPG.
    return same == ImgFormat.bmp || same == ImgFormat.tiff ? ImgFormat.jpg : same;
  }

  int? targetBytes(MediaInfo info) => switch (mode) {
        ImageCompressMode.quality => null,
        ImageCompressMode.targetSize => (targetKb * 1024).round(),
        ImageCompressMode.percent => (info.sizeBytes * percent / 100).round(),
      };
}

Job buildImageCompressJob(MediaInfo info, ImageCompressSettings settings, String? outDir, Set<String> encoders) {
  final s = settings.copy();
  final format = s.outFormat(info, encoders);
  final target = s.targetBytes(info);
  return Job(
    title: p.basename(info.path),
    kind: 'Comprimir',
    detail: target == null ? '${format.label} · qualidade ${s.quality}' : '${format.label} · alvo ${fmtBytes(target)}',
    body: (ctx) async {
      _check(info);
      if (target != null && !format.lossy) {
        throw FfError('${format.label} não tem ajuste de qualidade. '
            'Para chegar a um tamanho, escolha JPG, WebP ou AVIF como formato de saída.');
      }
      if (target != null && target >= info.sizeBytes) {
        throw FfError('A imagem já é menor que o alvo (${fmtBytes(target)}).');
      }
      final alpha = imageHasAlpha(info);
      final out = await _outPath(outDir, info, '_comprimido', format.ext);
      Future<int> encode(int quality, String path) async {
        await _encode(
          ctx,
          imageArgs(
            input: info.path,
            output: path,
            format: format,
            quality: quality,
            encoders: encoders,
            hasAlpha: alpha,
            // PNG não tem "qualidade": reduz para 256 cores, que é onde ele encolhe.
            palette: format == ImgFormat.png,
          ),
        );
        return File(path).lengthSync();
      }

      try {
        if (target == null) {
          ctx.report(0.1, stage: 'Comprimindo');
          await encode(s.quality, out);
        } else {
          // Busca binária da maior qualidade que cabe no alvo.
          final tmp = '$out.tmp.${format.ext}';
          var lo = 5, hi = 95, best = -1;
          try {
            for (var step = 0; step < 7 && lo <= hi; step++) {
              final q = (lo + hi) ~/ 2;
              ctx.report(step / 7, stage: 'Testando qualidade $q');
              final size = await encode(q, tmp);
              if (size <= target) {
                best = q;
                File(tmp).copySync(out);
                lo = q + 1;
              } else {
                hi = q - 1;
              }
            }
          } finally {
            _delete(tmp);
          }
          if (best < 0) {
            throw FfError('Não dá para chegar a ${fmtBytes(target)} só baixando a qualidade. '
                'Reduza as dimensões em "Redimensionar" e tente de novo.');
          }
        }
        if (File(out).lengthSync() >= info.sizeBytes) {
          throw FfError('O resultado ficaria maior que o original; a imagem já está bem comprimida. '
              'Tente uma qualidade menor ou outro formato.');
        }
      } catch (_) {
        _delete(out);
        rethrow;
      }
      final saved = 100 - File(out).lengthSync() * 100 / info.sizeBytes;
      return JobResult('${_sizes(info, out)} (−${saved.round()}%)', out);
    },
  );
}

// ------------------------------------------------------------ redimensionar

enum ResizeMode { percent, width, height, longSide }

class ImageResizeSettings {
  ResizeMode mode = ResizeMode.longSide;
  double percent = 50;
  double pixels = 1920;

  ImageResizeSettings copy() => ImageResizeSettings()
    ..mode = mode
    ..percent = percent
    ..pixels = pixels;

  /// Dimensões finais, mantendo a proporção.
  (int, int) outSize(MediaInfo info) {
    final w = info.width, h = info.height;
    if (w <= 0 || h <= 0) return (0, 0);
    final double k = switch (mode) {
      ResizeMode.percent => percent / 100,
      ResizeMode.width => pixels / w,
      ResizeMode.height => pixels / h,
      ResizeMode.longSide => pixels / math.max(w, h),
    };
    return (math.max(1, (w * k).round()), math.max(1, (h * k).round()));
  }
}

const maxImageSide = 16384;

Job buildImageResizeJob(MediaInfo info, ImageResizeSettings settings, String? outDir, Set<String> encoders) {
  final s = settings.copy();
  final (w, h) = s.outSize(info);
  return Job(
    title: p.basename(info.path),
    kind: 'Redimensionar',
    detail: '→ $w×$h',
    body: (ctx) async {
      _check(info);
      if (w > maxImageSide || h > maxImageSide) {
        throw FfError('O resultado teria $w×$h, acima do limite de $maxImageSide px por lado.');
      }
      final format = sameFormat(info, encoders);
      final out = await _outPath(outDir, info, '_${w}x$h', format.ext);
      try {
        ctx.report(0.1, stage: 'Redimensionando');
        await _encode(
          ctx,
          imageArgs(
            input: info.path,
            output: out,
            format: format,
            quality: 92,
            encoders: encoders,
            hasAlpha: imageHasAlpha(info),
            filters: ['scale=$w:$h:flags=lanczos+accurate_rnd+full_chroma_int'],
          ),
        );
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult('${info.width}×${info.height} → $w×$h · ${fmtBytes(File(out).lengthSync())}', out);
    },
  );
}

// ---------------------------------------------------------------------- girar

enum RotateOp {
  right('90° à direita', 'transpose=1', '_dir'),
  left('90° à esquerda', 'transpose=2', '_esq'),
  half('180°', 'hflip,vflip', '_180'),
  flipH('Espelhar na horizontal', 'hflip', '_espelho'),
  flipV('Espelhar na vertical', 'vflip', '_invertido');

  const RotateOp(this.label, this.filter, this.suffix);
  final String label, filter, suffix;
}

class ImageRotateSettings {
  RotateOp op = RotateOp.right;
}

Job buildImageRotateJob(MediaInfo info, RotateOp op, String? outDir, Set<String> encoders) {
  return Job(
    title: p.basename(info.path),
    kind: 'Girar',
    detail: op.label,
    body: (ctx) async {
      _check(info);
      final format = sameFormat(info, encoders);
      final out = await _outPath(outDir, info, op.suffix, format.ext);
      try {
        ctx.report(0.1, stage: 'Girando');
        await _encode(
          ctx,
          imageArgs(
            input: info.path,
            output: out,
            format: format,
            quality: 95,
            encoders: encoders,
            hasAlpha: imageHasAlpha(info),
            filters: [op.filter],
          ),
        );
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult(op.label, out);
    },
  );
}

// ------------------------------------------------------------ hiperescalador

/// Programa de ampliação por IA (Real-ESRGAN, roda na placa de vídeo via Vulkan).
class UpscalerTools {
  UpscalerTools(this.exe, this.models);
  final String exe;
  final String models;

  static UpscalerTools? locate() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? 'realesrgan-ncnn-vulkan.exe' : 'realesrgan-ncnn-vulkan';
    final roots = <String>[
      if (Platform.environment['FILUME_UPSCALER_DIR'] case final String custom) custom,
      p.join(exeDir, 'upscaler'),
      p.join(Directory.current.path, 'upscaler'),
      p.join(Directory.current.path, 'third_party', 'upscaler'),
    ];
    for (final r in roots) {
      final exe = p.join(r, name), models = p.join(r, 'models');
      if (File(exe).existsSync() && Directory(models).existsSync()) return UpscalerTools(exe, models);
    }
    return null;
  }

  bool hasModel(String name) => File(p.join(models, '$name.param')).existsSync();
}

enum UpscaleEngine { ai, classic, pixel }

enum UpscaleModel {
  photo('Fotos e imagens reais', 'realesrgan-x4plus', 4),
  anime('Anime e ilustração', 'realesrgan-x4plus-anime', 4),
  animeFast('Anime (rápido)', 'realesr-animevideov3', 0);

  const UpscaleModel(this.label, this.file, this.native);
  final String label, file;

  /// Fator em que o modelo trabalha (0 = tem uma versão para cada fator).
  final int native;

  String fileFor(int factor) => native == 0 ? '$file-x$factor' : file;
  int nativeFor(int factor) => native == 0 ? factor : native;
}

class UpscaleSettings {
  UpscaleEngine engine = UpscaleEngine.ai;
  UpscaleModel model = UpscaleModel.photo;
  int factor = 2;
  ImgFormat format = ImgFormat.png;

  UpscaleSettings copy() => UpscaleSettings()
    ..engine = engine
    ..model = model
    ..factor = factor
    ..format = format;

  (int, int) outSize(MediaInfo info) => (info.width * factor, info.height * factor);
}

/// Limite de pixels que a IA produz de uma vez (a imagem intermediária fica
/// inteira na memória): 120 megapixels.
const maxAiPixels = 120 * 1000 * 1000;

final _percent = RegExp(r'^\s*(\d+(?:[.,]\d+)?)%');

Job buildUpscaleJob(
  MediaInfo info,
  UpscaleSettings settings,
  String? outDir,
  Set<String> encoders,
  UpscalerTools? upscaler,
) {
  final s = settings.copy();
  final (w, h) = s.outSize(info);
  final how = switch (s.engine) {
    UpscaleEngine.ai => 'IA · ${s.model.label}',
    UpscaleEngine.classic => 'clássico',
    UpscaleEngine.pixel => 'pixel art',
  };
  return Job(
    title: p.basename(info.path),
    kind: 'Ampliar',
    detail: '${s.factor}× · $how → $w×$h',
    body: (ctx) async {
      _check(info);
      if (w > maxImageSide || h > maxImageSide) {
        throw FfError('O resultado teria $w×$h, acima do limite de $maxImageSide px por lado. '
            'Use um fator menor.');
      }
      final alpha = imageHasAlpha(info);
      final out = await _outPath(outDir, info, '_${s.factor}x', s.format.ext);
      const lanczos = 'flags=lanczos+accurate_rnd+full_chroma_int';
      try {
        if (s.engine != UpscaleEngine.ai) {
          ctx.report(0.1, stage: 'Ampliando');
          await _encode(
            ctx,
            imageArgs(
              input: info.path,
              output: out,
              format: s.format,
              quality: 95,
              encoders: encoders,
              hasAlpha: alpha,
              filters: s.engine == UpscaleEngine.pixel
                  // xBR preserva as bordas duras de pixel art. Ele ignora a transparência,
                  // então ela é ampliada à parte (sem suavizar) e juntada de volta.
                  ? [
                      if (alpha)
                        'format=rgba,split[xc][xa];[xa]alphaextract,scale=$w:$h:flags=neighbor[xm];'
                            '[xc]xbr=n=${s.factor}[xx];[xx][xm]alphamerge'
                      else
                        'xbr=n=${s.factor}',
                    ]
                  // Lanczos + nitidez adaptativa leve, para não ficar "lavado".
                  : ['scale=$w:$h:$lanczos', 'cas=strength=0.35'],
            ),
          );
          return JobResult('${info.width}×${info.height} → $w×$h · $how', out);
        }

        if (upscaler == null) {
          throw FfError('O ampliador por IA não foi encontrado. A pasta "upscaler" deveria estar ao lado '
              'do FiLume.exe. Enquanto isso, use o modo Clássico.');
        }
        final native = s.model.nativeFor(s.factor);
        final model = s.model.fileFor(s.factor);
        if (!upscaler.hasModel(model)) {
          throw FfError('O modelo "$model" não está na pasta do ampliador.');
        }
        if (info.width * native * info.height * native > maxAiPixels) {
          throw FfError('Imagem grande demais para a IA neste modo '
              '(${info.width}×${info.height} viraria ${info.width * native}×${info.height * native} por dentro). '
              'Use o modelo "${UpscaleModel.animeFast.label}" em 2×, reduza a imagem antes ou use o modo Clássico.');
        }
        final tmp = await Directory.systemTemp.createTemp('filume_up_');
        try {
          final src = p.join(tmp.path, 'in.png'), up = p.join(tmp.path, 'up.png');
          // 1) Entrada em PNG (o ampliador só lê PNG/JPG/WebP; isso também aplica a rotação da câmera).
          ctx.report(0.02, stage: 'Preparando');
          await _encode(
            ctx,
            imageArgs(
              input: info.path,
              output: src,
              format: ImgFormat.png,
              quality: 100,
              encoders: encoders,
              hasAlpha: alpha,
            ).map((a) => a == '9' ? '1' : a).toList(), // PNG temporário: compressão rápida
          );
          // 2) IA. O programa imprime o progresso como "12.50%".
          final log = <String>[];
          await ctx.run.exec(
            upscaler.exe,
            ['-i', src, '-o', up, '-n', model, '-s', '$native', '-m', upscaler.models, '-f', 'png'],
            workingDirectory: p.dirname(upscaler.exe),
            onStderrLine: (line) {
              final m = _percent.firstMatch(line);
              if (m != null) {
                final v = double.tryParse(m.group(1)!.replaceAll(',', '.')) ?? 0;
                ctx.report(0.05 + 0.85 * v / 100, stage: 'Ampliando com IA');
              } else {
                log.add(line);
              }
            },
          );
          // O programa devolve código 0 mesmo quando falha: o que vale é o arquivo.
          if (!File(up).existsSync() || File(up).lengthSync() == 0) {
            final text = log.join('\n');
            if (text.contains('vkCreateInstance') || text.contains('invalid gpu') || text.contains('vkEnumerate')) {
              throw FfError(
                'A ampliação por IA precisa de uma placa de vídeo compatível com Vulkan (e drivers em dia), '
                'e nenhuma foi encontrada. Use o modo Clássico.',
                text,
              );
            }
            if (text.contains('vkAllocateMemory') || text.contains('out of memory')) {
              throw FfError('Faltou memória de vídeo para esta imagem. Tente um fator menor ou o modelo rápido.', text);
            }
            throw FfError('O ampliador por IA não gerou a imagem.', text);
          }
          // 3) Ajusta ao fator pedido (quando o modelo trabalha em 4×) e grava no formato escolhido.
          ctx.report(0.92, stage: 'Finalizando');
          await _encode(
            ctx,
            imageArgs(
              input: up,
              output: out,
              format: s.format,
              quality: 95,
              encoders: encoders,
              hasAlpha: alpha,
              filters: native == s.factor ? const [] : ['scale=$w:$h:$lanczos'],
            ),
          );
        } finally {
          try {
            tmp.deleteSync(recursive: true);
          } catch (_) {}
        }
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult('${info.width}×${info.height} → $w×$h · $how', out);
    },
  );
}
