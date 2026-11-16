import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'audio.dart';
import 'compress.dart';
import 'ffmpeg.dart';
import 'format.dart';
import 'heif.dart';
import 'image.dart';
import 'job.dart';
import 'office.dart';
import 'pdf.dart';
import 'streams.dart';

/// Conversor universal: descobre o tipo de cada arquivo, diz para quais
/// formatos ele pode ir neste computador e monta a tarefa de conversão.
/// Tudo roda localmente (FFmpeg, Ghostscript, qpdf e o pacote de escritório
/// que estiver instalado); nada é enviado para fora.

enum FileKind {
  image('Imagem'),
  video('Vídeo'),
  audio('Áudio'),
  pdf('PDF'),
  doc('Documento'),
  sheet('Planilha'),
  slides('Apresentação'),
  subtitle('Legenda');

  const FileKind(this.label);
  final String label;
}

const _kindExts = <FileKind, List<String>>{
  FileKind.image: [
    'jpg', 'jpeg', 'png', 'webp', 'avif', 'heic', 'heif', 'hif', 'bmp', 'tif', 'tiff', 'gif', 'ico', 'tga', 'jp2', 'jxl',
    'psd', 'ppm', 'pgm', 'svg', 'jfif',
  ],
  FileKind.video: [
    'mp4', 'mkv', 'mov', 'webm', 'avi', 'wmv', 'flv', 'm4v', 'mpg', 'mpeg', 'ts', 'm2ts', 'mts', '3gp', 'ogv', 'vob',
  ],
  FileKind.audio: [
    'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'oga', 'opus', 'wma', 'aiff', 'aif', 'ac3', 'amr', 'mka', 'm4b', 'caf',
  ],
  FileKind.pdf: ['pdf'],
  FileKind.doc: ['docx', 'doc', 'odt', 'rtf', 'txt', 'md', 'html', 'htm'],
  FileKind.sheet: ['xlsx', 'xls', 'ods', 'csv'],
  FileKind.slides: ['pptx', 'ppt', 'odp'],
  FileKind.subtitle: ['srt', 'vtt', 'ass', 'ssa'],
};

final Map<String, FileKind> _extKind = {
  for (final e in _kindExts.entries)
    for (final x in e.value) x: e.key,
};

/// Todas as extensões que o conversor aceita.
List<String> get universalExts => _extKind.keys.toList();

String extOf(String path) => p.extension(path).toLowerCase().replaceFirst('.', '');

FileKind? kindOf(String path) => _extKind[extOf(path)];

/// Um formato de saída.
class OutFormat {
  const OutFormat(this.ext, this.label, [this.group = '']);
  final String ext;
  final String label;

  /// Agrupa formatos de outra natureza (ex.: "Só o áudio" num vídeo).
  final String group;

  @override
  bool operator ==(Object other) => other is OutFormat && other.ext == ext;
  @override
  int get hashCode => ext.hashCode;
}

const _fJpg = OutFormat('jpg', 'JPG');
const _fPng = OutFormat('png', 'PNG');
const _fWebp = OutFormat('webp', 'WebP');
const _fAvif = OutFormat('avif', 'AVIF');
const _fHeic = OutFormat('heic', 'HEIC');
const _fJxl = OutFormat('jxl', 'JPEG XL');
const _fBmp = OutFormat('bmp', 'BMP');
const _fTif = OutFormat('tif', 'TIFF');
const _fGif = OutFormat('gif', 'GIF');
const _fIco = OutFormat('ico', 'ICO (ícone)');
const _fPdf = OutFormat('pdf', 'PDF');

const _audioOuts = [
  OutFormat('mp3', 'MP3'),
  OutFormat('m4a', 'M4A (AAC)'),
  OutFormat('opus', 'Opus'),
  OutFormat('ogg', 'OGG Vorbis'),
  OutFormat('flac', 'FLAC'),
  OutFormat('wav', 'WAV'),
  OutFormat('aiff', 'AIFF'),
  OutFormat('ac3', 'AC-3'),
  OutFormat('wma', 'WMA'),
];

/// O que este computador consegue fazer.
class ConvCaps {
  ConvCaps({
    this.encoders = const {},
    this.jxl = false,
    this.svg = false,
    this.heicEncode = false,
    this.pdf,
    OfficeTools? office,
  }) : office = office ?? OfficeTools();

  /// Encoders do FFmpeg que funcionam (ver [FfTools.detectEncoders]).
  final Set<String> encoders;
  final bool jxl, svg;

  /// O Windows desta máquina grava HEIC (tem o codificador HEVC).
  final bool heicEncode;
  final PdfTools? pdf;
  final OfficeTools office;

  EncoderCaps get enc => EncoderCaps(encoders);

  static Future<ConvCaps> detect(FfTools tools, PdfTools? pdf, {Set<String>? encoders}) async {
    final enc = encoders ?? await tools.detectEncoders();
    var jxl = false, svg = false;
    try {
      final r = await Process.run(tools.ffmpeg, ['-hide_banner', '-codecs'], stdoutEncoding: utf8, stderrEncoding: utf8);
      final text = r.stdout.toString();
      jxl = RegExp(r'encoders:[^)]*\blibjxl\b').hasMatch(text);
      svg = RegExp(r'\blibrsvg\b').hasMatch(text);
    } catch (_) {}
    final office = await OfficeTools.locate();
    final heic = await canEncodeHeic();
    return ConvCaps(encoders: enc, jxl: jxl, svg: svg, heicEncode: heic, pdf: pdf, office: office);
  }

  bool officeFor(FileKind kind) => switch (kind) {
        FileKind.doc || FileKind.pdf => office.soffice != null || office.msWord,
        FileKind.sheet => office.soffice != null || office.msExcel,
        FileKind.slides => office.soffice != null || office.msPowerPoint,
        _ => false,
      };
}

/// Formatos para os quais [path] pode ser convertido aqui. [info] é a leitura
/// do FFmpeg (vídeo, áudio e imagem), quando já existe.
List<OutFormat> targetsFor(String path, ConvCaps caps, {MediaInfo? info}) {
  final ext = extOf(path);
  final kind = _extKind[ext];
  if (kind == null) return const [];
  List<OutFormat> list;
  switch (kind) {
    case FileKind.image:
      list = [
        _fJpg, _fPng,
        if (caps.encoders.contains('libwebp')) _fWebp,
        if (caps.encoders.contains('libaom-av1') || caps.encoders.contains('libsvtav1')) _fAvif,
        if (caps.heicEncode) _fHeic,
        if (caps.jxl) _fJxl,
        _fTif, _fBmp, _fGif, _fIco, _fPdf,
        if (ext == 'gif') ...const [OutFormat('mp4', 'MP4', 'Vídeo'), OutFormat('webm', 'WebM', 'Vídeo')],
      ];
    case FileKind.video:
      final webm = caps.encoders.contains('libsvtav1') || caps.encoders.contains('libvpx-vp9');
      list = [
        const OutFormat('mp4', 'MP4'), const OutFormat('mkv', 'MKV'), const OutFormat('mov', 'MOV'),
        if (webm) const OutFormat('webm', 'WebM'),
        const OutFormat('avi', 'AVI'), const OutFormat('gif', 'GIF animado'),
        if (info == null || info.audioCount > 0)
          for (final a in _audioOuts.take(6))
            if (_audioAvailable(a.ext, caps)) OutFormat(a.ext, a.label, 'Só o áudio'),
      ];
    case FileKind.audio:
      list = [
        for (final a in _audioOuts)
          if (_audioAvailable(a.ext, caps)) a,
      ];
    case FileKind.pdf:
      list = [
        if (caps.pdf?.gs != null) ...[_fJpg, _fPng, const OutFormat('txt', 'Texto (TXT)')],
        if (caps.officeFor(FileKind.pdf)) ...const [OutFormat('docx', 'Word (DOCX)'), OutFormat('odt', 'OpenDocument (ODT)')],
      ];
    case FileKind.doc:
      list = caps.officeFor(kind)
          ? const [
              _fPdf, OutFormat('docx', 'Word (DOCX)'), OutFormat('odt', 'OpenDocument (ODT)'),
              OutFormat('rtf', 'RTF'), OutFormat('txt', 'Texto (TXT)'), OutFormat('html', 'HTML'),
            ]
          : [
              if (ext == 'txt' || ext == 'md') _fPdf,
              if (ext == 'docx' || ext == 'odt') const OutFormat('txt', 'Texto (TXT)'),
            ];
    case FileKind.sheet:
      list = caps.officeFor(kind)
          ? const [_fPdf, OutFormat('xlsx', 'Excel (XLSX)'), OutFormat('ods', 'OpenDocument (ODS)'), OutFormat('csv', 'CSV')]
          : const [];
    case FileKind.slides:
      list = caps.officeFor(kind)
          ? const [_fPdf, OutFormat('pptx', 'PowerPoint (PPTX)'), OutFormat('odp', 'OpenDocument (ODP)')]
          : const [];
    case FileKind.subtitle:
      list = const [OutFormat('srt', 'SRT'), OutFormat('vtt', 'WebVTT'), OutFormat('ass', 'ASS')];
  }
  // Converter para o mesmo formato só faz sentido em vídeo e áudio (recodificar).
  final same = _sameAs(ext);
  if (kind != FileKind.video && kind != FileKind.audio) list = [for (final f in list) if (f.ext != same) f];
  return list;
}

/// Extensão "canônica" (jpeg → jpg, tiff → tif, htm → html…).
String _sameAs(String ext) => const {
      'jpeg': 'jpg', 'jfif': 'jpg', 'tiff': 'tif', 'heif': 'heic', 'hif': 'heic', 'htm': 'html', 'aif': 'aiff', 'ssa': 'ass',
    }[ext] ??
    ext;

bool _audioAvailable(String ext, ConvCaps caps) {
  final need = const {'mp3': 'libmp3lame', 'opus': 'libopus', 'ogg': 'libvorbis'}[ext];
  return need == null || caps.encoders.isEmpty || caps.encoders.contains(need);
}

/// Por que não há (ou há poucos) formatos para este arquivo, em português.
String? missingNote(String path, ConvCaps caps) {
  final kind = kindOf(path);
  if (kind == null) return 'Tipo de arquivo que o conversor ainda não conhece.';
  final office = kind == FileKind.doc || kind == FileKind.sheet || kind == FileKind.slides;
  if (office && !caps.officeFor(kind)) {
    return 'Para converter ${kind.label.toLowerCase()}s do Office é preciso ter o LibreOffice (gratuito) ou o Microsoft Office '
        'instalado. O FiLume usa o programa por baixo dos panos, sem abrir janela.';
  }
  if (kind == FileKind.pdf && !caps.officeFor(kind)) {
    return 'Para PDF → Word é preciso ter o LibreOffice (gratuito) ou o Microsoft Word instalado.';
  }
  return null;
}

class UniversalSettings {
  /// Pasta de saída; null = a mesma pasta de cada arquivo.
  String? outDir;

  int imageQuality = 90;

  /// Maior lado máximo, em pixels (0 = não mexe no tamanho).
  int imageMaxSide = 0;

  /// Várias imagens → um PDF só (em vez de um PDF por imagem).
  bool mergeImagesPdf = false;
  PageFit pdfFit = PageFit.image;

  ReLevel videoLevel = ReLevel.high;
  bool videoGpu = false;

  /// Altura máxima do vídeo (0 = original).
  int videoMaxHeight = 0;

  /// Recodifica mesmo quando daria para só trocar o contêiner.
  bool forceReencode = false;
  int gifFps = 12;
  int gifWidth = 480;

  int audioKbps = 192;
  bool audioMono = false;

  /// Resolução das páginas de PDF viradas imagem.
  int pdfDpi = 150;

  UniversalSettings copy() => UniversalSettings()
    ..outDir = outDir
    ..imageQuality = imageQuality
    ..imageMaxSide = imageMaxSide
    ..mergeImagesPdf = mergeImagesPdf
    ..pdfFit = pdfFit
    ..videoLevel = videoLevel
    ..videoGpu = videoGpu
    ..videoMaxHeight = videoMaxHeight
    ..forceReencode = forceReencode
    ..gifFps = gifFps
    ..gifWidth = gifWidth
    ..audioKbps = audioKbps
    ..audioMono = audioMono
    ..pdfDpi = pdfDpi;
}

void _delete(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

Future<String> _outPath(String path, OutFormat to, UniversalSettings s) async {
  final dir = p.absolute(s.outDir ?? p.dirname(path));
  await Directory(dir).create(recursive: true);
  final same = _sameAs(extOf(path)) == to.ext;
  return uniquePath(p.join(dir, '${p.basenameWithoutExtension(path)}${same ? '_convertido' : ''}.${to.ext}'));
}

String _sizes(String src, String out) => '${fmtBytes(File(src).lengthSync())} → ${fmtBytes(File(out).lengthSync())}';

List<String> _scaleDown(int maxSide) => maxSide > 0
    ? ["scale=w='min(iw,$maxSide)':h='min(ih,$maxSide)':force_original_aspect_ratio=decrease:flags=lanczos"]
    : const [];

/// Monta a tarefa que converte [path] para [to].
Job buildUniversalJob({
  required String path,
  required OutFormat to,
  required UniversalSettings settings,
  required ConvCaps caps,
  MediaInfo? info,
}) {
  final s = settings.copy();
  final kind = kindOf(path);
  final src = extOf(path);
  final title = p.basename(path);
  Job job(String detail, JobBody body) => Job(title: title, kind: 'Converter', detail: detail, body: body);
  FfError unsupported() => FfError('Não sei converter .$src para .${to.ext}.');

  switch (kind) {
    case null:
      return job('→ ${to.label}', (_) async => throw unsupported());

    case FileKind.image:
      if (to.group == 'Vídeo') return _videoJob(path, info, to, s, caps, job);
      return job('→ ${to.label}', (ctx) => _convertImage(ctx, path, info, to, s, caps));

    case FileKind.video:
      if (to.group == 'Só o áudio') return _audioJob(path, info, to, s, job);
      return _videoJob(path, info, to, s, caps, job);

    case FileKind.audio:
      return _audioJob(path, info, to, s, job);

    case FileKind.pdf:
      return job('→ ${to.label}', (ctx) => _convertPdf(ctx, path, info, to, s, caps));

    case FileKind.doc || FileKind.sheet || FileKind.slides:
      return job('→ ${to.label}', (ctx) async {
        final out = await _outPath(path, to, s);
        final family = switch (kind) { FileKind.sheet => 'sheet', FileKind.slides => 'slides', _ => 'doc' };
        try {
          ctx.report(0.15, stage: 'Convertendo');
          String? warning;
          if (caps.officeFor(kind)) {
            await caps.office.convert(ctx.run, path, out, to.ext, family);
          } else if (to.ext == 'pdf' && (src == 'txt' || src == 'md')) {
            final missing = await writeTextPdf(readTextFile(path), out);
            if (missing > 0) warning = '$missing caractere(s) fora do alfabeto ocidental saíram como "?".';
          } else if (to.ext == 'txt' && (src == 'docx' || src == 'odt')) {
            final bytes = await File(path).readAsBytes();
            final text = src == 'docx' ? docxText(bytes) : odtText(bytes);
            if (text == null) throw FfError('Este arquivo não parece ser um .$src válido.');
            await File(out).writeAsString(text.replaceAll('\n', Platform.isWindows ? '\r\n' : '\n'));
            warning = 'Saiu só o texto, sem formatação, imagens ou notas.';
          } else {
            throw FfError(missingNote(path, caps) ?? unsupported().message);
          }
          return JobResult(_sizes(path, out), out, warning: warning);
        } catch (_) {
          _delete(out);
          rethrow;
        }
      });

    case FileKind.subtitle:
      return job('→ ${to.label}', (ctx) async {
        final out = await _outPath(path, to, s);
        try {
          // O FFmpeg espera UTF-8; legendas antigas costumam vir no padrão do Windows.
          var utf = true;
          try {
            utf8.decode(await File(path).readAsBytes());
          } on FormatException {
            utf = false;
          }
          ctx.report(0.3, stage: 'Convertendo');
          await ctx.run.ffmpeg(ctx.tools, [
            if (!utf) ...['-sub_charenc', 'WINDOWS-1252'],
            '-i', path,
            '-c:s', const {'srt': 'srt', 'vtt': 'webvtt', 'ass': 'ass'}[to.ext]!,
            out,
          ]);
          return JobResult(_sizes(path, out), out);
        } catch (_) {
          _delete(out);
          rethrow;
        }
      });
  }
}

// ------------------------------------------------------------------- imagens

/// Deixa a imagem pronta para o FFmpeg ler: fotos HEIC viram um PNG temporário.
Future<(String, bool)> _imageSource(JobCtx ctx, String path, MediaInfo? info, Directory Function() work) async {
  if (!isHeifPath(path)) return (path, info != null && imageHasAlpha(info));
  final tmp = p.join(work().path, 'foto.png');
  ctx.report(0.05, stage: 'Abrindo a foto');
  await decodeHeif(ctx.tools, ctx.run, path, tmp);
  return (tmp, false);
}

Future<JobResult> _convertImage(JobCtx ctx, String path, MediaInfo? info, OutFormat to, UniversalSettings s, ConvCaps caps) async {
  final out = await _outPath(path, to, s);
  Directory? work;
  Directory dir() => work ??= Directory.systemTemp.createTempSync('filume_conv_');
  try {
    final (input, alpha) = await _imageSource(ctx, path, info, dir);
    final filters = _scaleDown(s.imageMaxSide);
    ctx.report(0.3, stage: 'Convertendo');
    final fmt = const {
      'jpg': ImgFormat.jpg, 'png': ImgFormat.png, 'webp': ImgFormat.webp, 'avif': ImgFormat.avif,
      'bmp': ImgFormat.bmp, 'tif': ImgFormat.tiff,
    }[to.ext];
    String graph([String extra = '']) => '[0:v:0]${[...filters, if (extra.isNotEmpty) extra].join(',').ifEmpty('null')}';
    if (fmt != null) {
      await ctx.run.ffmpeg(
        ctx.tools,
        imageArgs(input: input, output: out, format: fmt, quality: s.imageQuality, encoders: caps.encoders, hasAlpha: alpha, filters: filters),
      );
    } else if (to.ext == 'gif') {
      await ctx.run.ffmpeg(ctx.tools, [
        '-i', input,
        '-filter_complex',
        '${graph()},split[ga][gb];[ga]palettegen=reserve_transparent=1[gp];[gb][gp]paletteuse=dither=sierra2_4a[out]',
        '-map', '[out]', '-frames:v', '1', out,
      ]);
    } else if (to.ext == 'ico') {
      await ctx.run.ffmpeg(ctx.tools, [
        '-i', input,
        '-filter_complex',
        "${graph("scale=w='min(iw,256)':h='min(ih,256)':force_original_aspect_ratio=decrease:flags=lanczos,format=rgba")}[out]",
        '-map', '[out]', '-frames:v', '1', '-c:v', 'png', '-f', 'ico', out,
      ]);
    } else if (to.ext == 'jxl') {
      final distance = s.imageQuality >= 100 ? 0.0 : ((100 - s.imageQuality) / 10).clamp(0.1, 15.0);
      await ctx.run.ffmpeg(ctx.tools, [
        '-i', input,
        '-filter_complex', '${graph()}[out]',
        '-map', '[out]', '-frames:v', '1', '-c:v', 'libjxl', '-distance', distance.toStringAsFixed(1), out,
      ]);
    } else if (to.ext == 'heic') {
      // O Windows grava o HEIC; o FFmpeg entrega um PNG já no tamanho pedido.
      var png = input;
      if (filters.isNotEmpty || !input.toLowerCase().endsWith('.png')) {
        png = p.join(dir().path, 'entrada.png');
        await ctx.run.ffmpeg(ctx.tools, [
          '-i', input, '-filter_complex', '${graph()}[out]', '-map', '[out]', '-frames:v', '1', '-c:v', 'png', '-update', '1', png,
        ]);
      }
      await encodeHeic(ctx.run, png, out, s.imageQuality);
    } else if (to.ext == 'pdf') {
      final probe = await ctx.tools.probe(input);
      final image = MediaInfo.image(probe, size: await ctx.tools.imageDisplaySize(input));
      await writeImagesPdf(ctx, [image], s.pdfFit, out);
    } else {
      throw FfError('Não sei gravar imagens em .${to.ext}.');
    }
    if (!File(out).existsSync() || File(out).lengthSync() == 0) throw FfError('A imagem convertida não foi gravada.');
    return JobResult(_sizes(path, out), out);
  } catch (_) {
    _delete(out);
    rethrow;
  } finally {
    try {
      work?.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Várias imagens num PDF só, na ordem dada.
Job buildImagesPdfJob(List<(String, MediaInfo?)> images, UniversalSettings settings) {
  final s = settings.copy();
  final first = images.first.$1;
  return Job(
    title: '${images.length} imagens → ${p.basenameWithoutExtension(first)}.pdf',
    kind: 'Converter',
    detail: 'um PDF só · página ${s.pdfFit.label.toLowerCase()}',
    body: (ctx) async {
      final out = await _outPath(first, _fPdf, s);
      final work = await Directory.systemTemp.createTemp('filume_conv_');
      try {
        final infos = <MediaInfo>[];
        for (var i = 0; i < images.length; i++) {
          ctx.report(0.4 * i / images.length, stage: 'Abrindo imagem ${i + 1} de ${images.length}');
          var input = images[i].$1;
          if (isHeifPath(input)) {
            final tmp = p.join(work.path, 'foto_$i.png');
            await decodeHeif(ctx.tools, ctx.run, input, tmp);
            input = tmp;
          }
          infos.add(MediaInfo.image(await ctx.tools.probe(input), size: await ctx.tools.imageDisplaySize(input)));
        }
        await writeImagesPdf(ctx, infos, s.pdfFit, out,
            onImage: (k) => ctx.report(0.4 + 0.6 * k / infos.length, stage: 'Página ${k + 1} de ${infos.length}'));
        return JobResult('${infos.length} páginas · ${fmtBytes(File(out).lengthSync())}', out);
      } catch (_) {
        _delete(out);
        rethrow;
      } finally {
        try {
          await work.delete(recursive: true);
        } catch (_) {}
      }
    },
  );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ---------------------------------------------------------------- HEIC (gravar)

const _heicScript = r'''
$ErrorActionPreference = 'Stop'
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Storage.StorageFolder, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapEncoder, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
  $methods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
  $asTask = ($methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  $asAction = ($methods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
  function Await($op, [Type]$type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    $task.Result
  }
  function AwaitAction($op) { $asAction.Invoke($null, @($op)).Wait(-1) | Out-Null }
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($args[0])) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $folder = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync([IO.Path]::GetDirectoryName($args[1]))) ([Windows.Storage.StorageFolder])
  $target = Await ($folder.CreateFileAsync([IO.Path]::GetFileName($args[1]), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
  $outStream = Await ($target.OpenAsync([Windows.Storage.FileAccessMode]::ReadWrite)) ([Windows.Storage.Streams.IRandomAccessStream])
  $props = New-Object Windows.Graphics.Imaging.BitmapPropertySet
  $quality = New-Object Windows.Graphics.Imaging.BitmapTypedValue ([single]([int]$args[2] / 100.0)), ([Windows.Foundation.PropertyType]::Single)
  $props.Add('ImageQuality', $quality)
  $encoder = Await ([Windows.Graphics.Imaging.BitmapEncoder]::CreateAsync([Windows.Graphics.Imaging.BitmapEncoder]::HeifEncoderId, $outStream, $props)) ([Windows.Graphics.Imaging.BitmapEncoder])
  $encoder.SetSoftwareBitmap($bitmap)
  AwaitAction ($encoder.FlushAsync())
  $outStream.Dispose()
  $stream.Dispose()
  exit 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
''';

/// Grava [png] como HEIC usando o codificador do Windows.
Future<void> encodeHeic(FfRun run, String png, String out, int quality) async {
  if (!Platform.isWindows) throw FfError('Gravar HEIC depende do codificador do Windows.');
  final dir = await Directory.systemTemp.createTemp('filume_heic_');
  try {
    final ps = File(p.join(dir.path, 'heic.ps1'))..writeAsStringSync(_heicScript);
    final code = await run.exec('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps.path,
      p.absolute(png), p.absolute(out), '${quality.clamp(1, 100)}',
    ]);
    final ok = code == 0 && File(out).existsSync() && parseHeif(await File(out).readAsBytes()) != null;
    if (!ok) {
      _delete(out);
      throw FfError(
        'O Windows não conseguiu gravar em HEIC.',
        'É preciso ter as "Extensões de Vídeo HEVC" da Microsoft Store.\n${run.errorTail.join('\n')}',
      );
    }
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// Testa, com uma imagem minúscula, se este Windows grava HEIC de verdade.
Future<bool> canEncodeHeic() async {
  if (!Platform.isWindows) return false;
  Directory? dir;
  try {
    dir = await Directory.systemTemp.createTemp('filume_heicteste_');
    final png = p.join(dir.path, 'a.png'), out = p.join(dir.path, 'a.heic');
    // PNG 16x16 cinza, gerado aqui mesmo (sem depender de outro programa).
    await File(png).writeAsBytes(_tinyPng());
    await encodeHeic(FfRun(), png, out, 80).timeout(const Duration(seconds: 25));
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      await dir?.delete(recursive: true);
    } catch (_) {}
  }
}

List<int> _tinyPng() {
  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    var crc = 0xFFFFFFFF;
    for (final b in body) {
      crc ^= b;
      for (var k = 0; k < 8; k++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    crc ^= 0xFFFFFFFF;
    List<int> u32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];
    return [...u32(data.length), ...body, ...u32(crc)];
  }

  const side = 16;
  final raw = <int>[
    for (var y = 0; y < side; y++) ...[0, for (var x = 0; x < side * 3; x++) 128],
  ];
  return [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ...chunk('IHDR', [0, 0, 0, side, 0, 0, 0, side, 8, 2, 0, 0, 0]),
    ...chunk('IDAT', ZLibEncoder().convert(raw)),
    ...chunk('IEND', const []),
  ];
}

// --------------------------------------------------------------------- vídeo

Job _videoJob(String path, MediaInfo? info, OutFormat to, UniversalSettings s, ConvCaps caps, Job Function(String, JobBody) job) {
  final ext = to.ext;
  final short = info == null ? 0 : (info.width < info.height ? info.width : info.height);
  final scale = info != null && s.videoMaxHeight > 0 && short > s.videoMaxHeight
      ? [info.width >= info.height ? 'scale=-2:${s.videoMaxHeight}' : 'scale=${s.videoMaxHeight}:-2']
      : const <String>[];
  final container = const {'mp4', 'mkv', 'mov', 'webm'}.contains(ext);
  final fromGif = extOf(path) == 'gif';
  final copyVideo = container && !fromGif && info != null && !s.forceReencode && scale.isEmpty && videoFits(info.vCodec, ext);
  final copyAudio = container && info != null && !s.forceReencode && allAudioFits(info, ext);
  final detail = ext == 'gif'
      ? '→ GIF · ${s.gifFps} qps · ${s.gifWidth} px'
      : '→ ${to.label}${copyVideo ? ' · sem recodificar' : ' · qualidade ${s.videoLevel.label.toLowerCase()}'}'
          '${scale.isEmpty ? '' : ' · ${s.videoMaxHeight}p'}';
  return job(detail, (ctx) async {
    if (info == null || info.videoIndex == null) throw FfError('Este arquivo não tem imagem de vídeo.');
    final out = await _outPath(path, to, s);
    final v = info.videoIndex!;
    final args = <String>['-i', path];
    if (ext == 'gif') {
      final w = info.width > 0 && info.width < s.gifWidth ? info.width : s.gifWidth;
      args.addAll([
        '-filter_complex',
        '[0:$v]fps=${s.gifFps},scale=$w:-1:flags=lanczos,split[ga][gb];[ga]palettegen=stats_mode=diff[gp];'
            '[gb][gp]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle[out]',
        '-map', '[out]', '-an', '-sn', '-dn', out,
      ]);
    } else if (ext == 'avi') {
      args.addAll([
        '-map', '0:$v',
        '-c:v', 'mpeg4', '-vtag', 'xvid', '-q:v', '${(s.videoLevel.crf / 5).round()}',
        '-vf', [...scale, 'format=yuv420p'].join(','),
        if (info.audioCount > 0) ...['-map', '0:a:0', '-c:a', caps.encoders.contains('libmp3lame') ? 'libmp3lame' : 'ac3', '-b:a', '192k'],
        '-sn', '-dn', out,
      ]);
    } else {
      args.addAll(['-map', '0:$v']);
      if (copyVideo) {
        args.addAll(['-c:v', 'copy']);
        if (info.vCodec == 'hevc' && ext != 'mkv') args.addAll(['-tag:v', 'hvc1']);
      } else {
        final r = ReencodeSettings()
          ..level = s.videoLevel
          ..useGpu = s.videoGpu;
        // GIF pode ter lados ímpares, que o H.264 não aceita.
        final pre = fromGif ? [...scale, 'scale=trunc(iw/2)*2:trunc(ih/2)*2'] : scale;
        args.addAll(reencodeVideoArgs(r, caps.enc, info, ext, preFilters: pre));
      }
      if (info.audioCount > 0) {
        args.addAll(['-map', '0:a']);
        args.addAll(copyAudio ? const ['-c:a', 'copy'] : audioEncodeArgs(ext, caps.enc));
      }
      args.addAll(subtitleArgs(info, ext));
      args.addAll(['-dn', '-map_metadata', '0', '-map_chapters', '0']);
      args.addAll(faststartArgs(ext, info.sizeBytes));
      args.add(out);
    }
    try {
      await ctx.run.ffmpeg(ctx.tools, args,
          onProgress: (t, speed) => ctx.report(info.duration > 0 ? t / info.duration : 0.5,
              stage: copyVideo ? 'Convertendo' : 'Recodificando', speed: speed));
    } catch (_) {
      _delete(out);
      rethrow;
    }
    final lost = container ? info.subs.length - subtitleCount(info, ext) : info.subs.length;
    return JobResult(
      _sizes(path, out),
      out,
      warning: lost > 0 && ext != 'gif'
          ? '$lost legenda(s) ficaram de fora: ${to.label} não comporta. Use MKV para manter.'
          : null,
    );
  });
}

// --------------------------------------------------------------------- áudio

List<String> _audioArgs(String ext, UniversalSettings s, int channels) {
  final fmt = const {
    'mp3': AudioFormat.mp3, 'm4a': AudioFormat.m4a, 'opus': AudioFormat.opus,
    'ogg': AudioFormat.ogg, 'flac': AudioFormat.flac, 'wav': AudioFormat.wav,
  }[ext];
  if (fmt != null) return audioOutArgs(fmt, s.audioKbps, s.audioMono, sourceChannels: channels);
  final mono = s.audioMono ? const ['-ac', '1'] : const <String>[];
  return switch (ext) {
    'aiff' => ['-c:a', 'pcm_s16be', ...mono],
    // AC-3 e WMA não passam de 5.1/estéreo nem aceitam bitrates muito baixos.
    'ac3' => ['-c:a', 'ac3', '-b:a', '${s.audioKbps.clamp(96, 640)}k', ...(s.audioMono ? mono : (channels > 6 ? const ['-ac', '6'] : const <String>[]))],
    'wma' => ['-c:a', 'wmav2', '-b:a', '${s.audioKbps.clamp(64, 320)}k', ...(s.audioMono ? mono : (channels > 2 ? const ['-ac', '2'] : const <String>[]))],
    _ => throw FfError('Não sei gravar áudio em .$ext.'),
  };
}

Job _audioJob(String path, MediaInfo? info, OutFormat to, UniversalSettings s, Job Function(String, JobBody) job) {
  const lossless = {'flac', 'wav', 'aiff'};
  final detail = '→ ${to.label}${lossless.contains(to.ext) ? '' : ' ${s.audioKbps} kb/s'}${s.audioMono ? ' · mono' : ''}';
  return job(detail, (ctx) async {
    if (info == null || info.audioCount == 0) throw FfError('Este arquivo não tem faixa de áudio.');
    final out = await _outPath(path, to, s);
    try {
      await ctx.run.ffmpeg(
        ctx.tools,
        ['-i', path, '-map', '0:a:0', '-vn', '-sn', '-dn', ..._audioArgs(to.ext, s, info.channels), '-map_metadata', '0', out],
        onProgress: (t, speed) => ctx.report(info.duration > 0 ? t / info.duration : 0.5, stage: 'Convertendo', speed: speed),
      );
    } catch (_) {
      _delete(out);
      rethrow;
    }
    return JobResult('${fmtBytes(info.hasVideo ? audioBytes(info) : info.sizeBytes)} → ${fmtBytes(File(out).lengthSync())}', out);
  });
}

// ----------------------------------------------------------------------- PDF

final _gsPage = RegExp(r'^Page (\d+)');

Future<JobResult> _convertPdf(JobCtx ctx, String path, MediaInfo? info, OutFormat to, UniversalSettings s, ConvCaps caps) async {
  if (info != null && info.encrypted) {
    throw FfError('Este PDF é protegido por senha. Remova a senha no FiLume PDF (ferramenta "Senha") primeiro.');
  }
  final pages = info?.pages ?? 0;
  if (to.ext == 'docx' || to.ext == 'odt') {
    final out = await _outPath(path, to, s);
    try {
      ctx.report(0.15, stage: 'Convertendo');
      await caps.office.convert(ctx.run, path, out, to.ext, 'pdf');
      return JobResult(_sizes(path, out), out,
          warning: 'PDF não guarda parágrafos nem tabelas de verdade: confira a formatação do documento gerado.');
    } catch (_) {
      _delete(out);
      rethrow;
    }
  }
  final gs = caps.pdf?.gs;
  if (gs == null) throw FfError('O Ghostscript não foi encontrado na pasta do FiLume.');
  Future<void> run(List<String> args) async {
    final code = await ctx.run.exec(gs, ['-dNOPAUSE', '-dBATCH', '-dSAFER', ...args, path], onStdoutLine: (line) {
      final m = _gsPage.firstMatch(line);
      if (m != null && pages > 0) ctx.report((int.parse(m[1]!) - 1) / pages, stage: 'Página ${m[1]} de $pages');
    });
    if (code != 0) throw FfError('O Ghostscript terminou com erro (código $code).', ctx.run.errorTail.join('\n'));
  }

  if (to.ext == 'txt') {
    final out = await _outPath(path, to, s);
    try {
      await run(['-sDEVICE=txtwrite', '-sOutputFile=${out.replaceAll('%', '%%')}']);
      final empty = (await File(out).readAsString()).trim().isEmpty;
      return JobResult(_sizes(path, out), out,
          warning: empty ? 'Este PDF não tem texto (deve ser digitalização). Passe o OCR nele no FiLume PDF e converta de novo.' : null);
    } catch (_) {
      _delete(out);
      rethrow;
    }
  }
  // Imagens: uma página só vira um arquivo; várias vão para uma pasta.
  final device = ['-sDEVICE=${to.ext == 'png' ? 'png16m' : 'jpeg'}', if (to.ext != 'png') '-dJPEGQ=${s.imageQuality.clamp(40, 100)}',
      '-r${s.pdfDpi}', '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4'];
  if (pages == 1) {
    final out = await _outPath(path, to, s);
    try {
      await run([...device, '-sOutputFile=${out.replaceAll('%', '%%')}']);
      return JobResult(_sizes(path, out), out);
    } catch (_) {
      _delete(out);
      rethrow;
    }
  }
  final base = p.basenameWithoutExtension(path);
  final dir = uniquePath(p.join(p.absolute(s.outDir ?? p.dirname(path)), '${base}_imagens'), directory: true);
  await Directory(dir).create(recursive: true);
  try {
    await run([...device, '-sOutputFile=${p.join(dir, '${base}_%03d.${to.ext}').replaceAll('%', '%%').replaceAll('%%03d', '%03d')}']);
  } catch (_) {
    try {
      Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
    rethrow;
  }
  final n = Directory(dir).listSync().length;
  return JobResult('$n ${n == 1 ? 'imagem' : 'imagens'}', dir);
}
