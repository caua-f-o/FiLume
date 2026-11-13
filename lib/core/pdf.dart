import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'editor.dart';
import 'ffmpeg.dart';
import 'format.dart';
import 'job.dart';
import 'ocr.dart';
import 'signature.dart';

/// Motores de PDF: qpdf (estrutura: dividir, unir, organizar, senha) e
/// Ghostscript (comprimir e desenhar páginas).
class PdfTools {
  PdfTools(this.qpdf, this.gs);
  final String qpdf;
  final String? gs;

  static Future<PdfTools?> locate() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final win = Platform.isWindows;
    final roots = <String>[
      if (Platform.environment['FILUME_PDF_DIR'] case final String custom) custom,
      p.join(exeDir, 'pdftools'),
      p.join(Directory.current.path, 'pdftools'),
      p.join(Directory.current.path, 'third_party', 'pdftools'),
    ];
    String? qpdf, gs;
    for (final r in roots) {
      final q = p.join(r, 'qpdf', 'bin', win ? 'qpdf.exe' : 'qpdf');
      final g = p.join(r, 'gs', 'bin', win ? 'gswin64c.exe' : 'gs');
      if (qpdf == null && File(q).existsSync()) qpdf = q;
      if (gs == null && File(g).existsSync()) gs = g;
    }
    Future<bool> works(String exe) async {
      try {
        return (await Process.run(exe, ['--version'])).exitCode == 0;
      } catch (_) {
        return false;
      }
    }

    if (qpdf == null && await works('qpdf')) qpdf = 'qpdf';
    if (gs == null) {
      for (final name in win ? const ['gswin64c', 'gs'] : const ['gs']) {
        if (await works(name)) {
          gs = name;
          break;
        }
      }
    }
    return qpdf == null ? null : PdfTools(qpdf, gs);
  }

  /// Lê número de páginas e se o PDF exige senha.
  Future<MediaInfo> probe(String path) async {
    path = p.absolute(path);
    final size = File(path).lengthSync();
    final r = await Process.run(qpdf, ['--show-npages', path]);
    if (r.exitCode == 0 || r.exitCode == 3) {
      final n = int.tryParse(r.stdout.toString().trim().split('\n').last.trim());
      if (n != null) {
        final info = MediaInfo.pdf(path: path, sizeBytes: size, pages: n);
        try {
          info.signatures = await readSignatures(qpdf, path);
        } catch (_) {}
        return info;
      }
    }
    final err = r.stderr.toString().toLowerCase();
    if (err.contains('password')) {
      return MediaInfo.pdf(path: path, sizeBytes: size, pages: 0, encrypted: true);
    }
    throw FfError('Este PDF está danificado ou não é um PDF válido.', r.stderr.toString());
  }
}

String _gsOrThrow(PdfTools t) =>
    t.gs ?? (throw FfError('O Ghostscript não foi encontrado; esta ferramenta precisa dele.'));

/// Roda o qpdf; o código 3 significa "terminou com avisos" e conta como sucesso.
Future<void> _qpdf(JobCtx ctx, PdfTools t, List<String> args) async {
  final code = await ctx.run.exec(t.qpdf, args);
  if (code != 0 && code != 3) {
    final tail = ctx.run.errorTail.join('\n');
    if (tail.toLowerCase().contains('invalid password')) {
      throw FfError('Senha incorreta ou PDF protegido por senha.');
    }
    throw FfError('Não foi possível processar o PDF (código $code).', tail);
  }
}

final _pageRe = RegExp(r'^Page (\d+)');

/// Roda o Ghostscript, reportando a página em andamento.
Future<void> _gs(JobCtx ctx, PdfTools t, List<String> args,
    {void Function(int page)? onPage}) async {
  final code = await ctx.run.exec(
    _gsOrThrow(t),
    ['-dNOPAUSE', '-dBATCH', '-dSAFER', ...args],
    onStdoutLine: (line) {
      final m = _pageRe.firstMatch(line);
      if (m != null) onPage?.call(int.parse(m[1]!));
    },
  );
  if (code != 0) {
    throw FfError('O Ghostscript terminou com erro (código $code).', ctx.run.errorTail.join('\n'));
  }
}

void _delete(String path) {
  try {
    if (File(path).existsSync()) File(path).deleteSync();
  } catch (_) {}
}

void _checkOpen(MediaInfo info) {
  if (info.encrypted) {
    throw FfError('Este PDF é protegido por senha. Remova a senha na ferramenta "Senha" primeiro.');
  }
  if (info.pages <= 0) throw FfError('Este PDF não tem páginas.');
}

Future<String> _outFile(String? outDir, MediaInfo info, String suffix, [String ext = 'pdf']) async {
  final dir = outDir ?? p.dirname(info.path);
  await Directory(dir).create(recursive: true);
  return uniquePath(p.join(dir, '${p.basenameWithoutExtension(info.path)}$suffix.$ext'));
}

Future<String> _outDirFor(String? outDir, MediaInfo info, String suffix) async {
  final dir = uniquePath(
      p.join(outDir ?? p.dirname(info.path), '${p.basenameWithoutExtension(info.path)}$suffix'),
      directory: true);
  await Directory(dir).create(recursive: true);
  return dir;
}

/// "1,2,3,7,9,10" → "1-3,7,9-10" (encurta a linha de comando).
String compactRanges(List<int> pages) {
  final out = <String>[];
  var i = 0;
  while (i < pages.length) {
    var j = i;
    while (j + 1 < pages.length && pages[j + 1] == pages[j] + 1) {
      j++;
    }
    out.add(j > i ? '${pages[i]}-${pages[j]}' : '${pages[i]}');
    i = j + 1;
  }
  return out.join(',');
}

// --------------------------------------------------------------- comprimir

enum PdfLevel {
  light('Leve', '/printer', 300, 'Quase sem perda visível; bom para imprimir.'),
  balanced('Equilibrado', '/ebook', 150, 'Bom para ler na tela e mandar por e-mail.'),
  strong('Forte', '/screen', 110, 'Bem menor; imagens visivelmente mais simples.'),
  max('Máximo', '/screen', 72, 'O menor possível; imagens perdem bastante detalhe.');

  const PdfLevel(this.label, this.preset, this.dpi, this.hint);
  final String label;
  final String preset;
  final int dpi;
  final String hint;
}

class PdfCompressSettings {
  PdfLevel level = PdfLevel.balanced;
  bool grayscale = false;

  // ---- avançado
  /// Tamanho máximo do resultado, em MB (null = sem alvo). Com alvo, o
  /// compressor procura sozinho a melhor qualidade que cabe nele.
  double? targetMb;

  /// Resolução das imagens (null = a do nível).
  int? dpi;

  /// Qualidade JPEG das imagens, 1 a 100 (null = automática).
  int? quality;

  /// Preto e branco puro (1 bit): cada página vira uma imagem de fax.
  /// Encolhe muito documentos escaneados de texto; ruim para fotos.
  bool mono = false;

  bool get advanced => targetMb != null || dpi != null || quality != null || mono;

  PdfCompressSettings copy() => PdfCompressSettings()
    ..level = level
    ..grayscale = grayscale
    ..targetMb = targetMb
    ..dpi = dpi
    ..quality = quality
    ..mono = mono;

  String describe() => [
        if (targetMb != null) 'até ${fmtBytes((targetMb! * 1024 * 1024).round())}' else 'nível ${level.label.toLowerCase()}',
        if (mono) 'preto e branco' else if (grayscale) 'tons de cinza',
        if (dpi != null) '$dpi dpi',
        if (quality != null && !mono) 'qualidade $quality',
      ].join(' · ');
}

/// Degraus de (resolução, qualidade) que o tamanho-alvo percorre, do melhor ao menor.
const _ladder = [
  (300, 85), (200, 80), (150, 75), (150, 60), (120, 55), (100, 50), (100, 40), (72, 40), (72, 30), (50, 25), (40, 18),
];

/// Lê um TIFF de uma tira só (como o Ghostscript grava com MaxStripSize=0):
/// (largura, altura, dados comprimidos em CCITT G4).
(int, int, Uint8List) _readG4Tiff(String path) {
  final d = File(path).readAsBytesSync();
  final le = d[0] == 0x49;
  int u16(int o) => le ? d[o] | (d[o + 1] << 8) : (d[o] << 8) | d[o + 1];
  int u32(int o) => le ? u16(o) | (u16(o + 2) << 16) : (u16(o) << 16) | u16(o + 2);
  final ifd = u32(4);
  var w = 0, h = 0, off = 0, len = 0, strips = 1;
  for (var i = 0; i < u16(ifd); i++) {
    final e = ifd + 2 + i * 12;
    final v = u16(e + 2) == 3 ? u16(e + 8) : u32(e + 8);
    switch (u16(e)) {
      case 256:
        w = v;
      case 257:
        h = v;
      case 273:
        off = v;
        strips = u32(e + 4);
      case 279:
        len = v;
    }
  }
  if (strips != 1 || w == 0 || h == 0 || off == 0 || len == 0) {
    throw FfError('Não foi possível ler a página em preto e branco.');
  }
  return (w, h, Uint8List.sublistView(d, off, off + len));
}

/// PDF em que cada página é uma imagem de 1 bit (CCITT G4), em [dpi].
Future<void> _writeMonoPdf(List<String> tiffs, int dpi, String out) async {
  final sink = File(out).openWrite();
  var pos = 0;
  final offsets = <int>[];
  void raw(List<int> b) {
    sink.add(b);
    pos += b.length;
  }

  void obj(String head, [List<int>? stream]) {
    offsets.add(pos);
    raw(latin1.encode('${offsets.length} 0 obj\n$head\n'));
    if (stream != null) {
      raw(latin1.encode('stream\n'));
      raw(stream);
      raw(latin1.encode('\nendstream\n'));
    }
    raw(latin1.encode('endobj\n'));
  }

  raw(latin1.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'));
  final n = tiffs.length;
  obj('<< /Type /Catalog /Pages 2 0 R >>');
  obj('<< /Type /Pages /Count $n /Kids [${[for (var i = 0; i < n; i++) '${3 + i * 3} 0 R'].join(' ')}] >>');
  for (final t in tiffs) {
    final (w, h, data) = _readG4Tiff(t);
    final pw = (w * 72 / dpi).toStringAsFixed(2), ph = (h * 72 / dpi).toStringAsFixed(2);
    final id = offsets.length + 1;
    final content = 'q $pw 0 0 $ph 0 0 cm /I Do Q';
    obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pw $ph] '
        '/Resources << /XObject << /I ${id + 2} 0 R >> >> /Contents ${id + 1} 0 R >>');
    obj('<< /Length ${content.length} >>', latin1.encode(content));
    obj(
      '<< /Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /DeviceGray /BitsPerComponent 1 '
      '/Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns $w /Rows $h >> /Length ${data.length} >>',
      data,
    );
  }
  final xref = pos;
  final x = StringBuffer('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    x.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  x.write('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  raw(latin1.encode(x.toString()));
  await sink.close();
}

Job buildPdfCompressJob(MediaInfo info, PdfCompressSettings settings, String? outDir, PdfTools tools) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Comprimir',
    detail: s.describe(),
    body: (ctx) async {
      _checkOpen(info);
      final out = await _outFile(outDir, info, '_filume');
      final work = await Directory.systemTemp.createTemp('filume_comp_');
      final target = s.targetMb == null ? null : (s.targetMb! * 1024 * 1024).round();
      var tries = 0;

      /// Uma tentativa em tons contínuos; devolve o arquivo gerado.
      Future<String> tone(int dpi, int? q, double from, double to, String label) async {
        final f = p.join(work.path, 't${tries++}.pdf');
        // Qualidade JPEG → fator de quantização do Ghostscript.
        final qf = q == null ? null : ((q < 50 ? 5000 / q : 200 - 2 * q) / 100).clamp(0.02, 20).toStringAsFixed(2);
        final dict = '<< /QFactor $qf /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >>';
        await _gs(
          ctx,
          tools,
          [
            '-sDEVICE=pdfwrite', '-dCompatibilityLevel=1.6', '-dPDFSETTINGS=${s.level.preset}',
            '-dDetectDuplicateImages=true', '-dAutoRotatePages=/None',
            '-dSubsetFonts=true', '-dCompressFonts=true',
            '-dDownsampleColorImages=true', '-dColorImageDownsampleType=/Bicubic',
            '-dColorImageResolution=$dpi', '-dColorImageDownsampleThreshold=1.1',
            '-dDownsampleGrayImages=true', '-dGrayImageDownsampleType=/Bicubic',
            '-dGrayImageResolution=$dpi', '-dGrayImageDownsampleThreshold=1.1',
            '-dDownsampleMonoImages=true', '-dMonoImageResolution=${(dpi * 2).clamp(150, 600)}',
            if (s.grayscale) ...['-sColorConversionStrategy=Gray', '-dProcessColorModel=/DeviceGray'],
            // Nos níveis fortes (ou com qualidade escolhida), força JPEG nas imagens:
            // o modo automático às vezes escolhe compressão sem perda, que sai maior.
            if (q != null || s.level.index >= PdfLevel.strong.index) ...[
              '-dAutoFilterColorImages=false', '-dColorImageFilter=/DCTEncode',
              '-dAutoFilterGrayImages=false', '-dGrayImageFilter=/DCTEncode',
            ],
            '-sOutputFile=$f',
            if (q != null) ...['-c', '<< /ColorImageDict $dict /GrayImageDict $dict >> setdistillerparams', '-f'],
            info.path,
          ],
          onPage: (n) => ctx.report(from + (to - from) * (n - 1) / info.pages, stage: '$label · página $n de ${info.pages}'),
        );
        return f;
      }

      /// Uma tentativa em preto e branco puro.
      Future<String> mono(int dpi, double from, double to, String label) async {
        final dir = Directory(p.join(work.path, 'm${tries++}'))..createSync();
        await _gs(
          ctx,
          tools,
          [
            '-sDEVICE=tiffg4', '-r$dpi', '-dMaxStripSize=0', '-sOutputFile=${p.join(dir.path, 'p_%05d.tif')}',
            // Corte seco entre preto e branco (sem pontilhado): papel amarelado e
            // ruído de JPEG viram branco liso, que é o que comprime bem.
            '-c', '{ 0.62 lt { 0 } { 1 } ifelse } settransfer', '-f',
            info.path,
          ],
          onPage: (n) => ctx.report(from + (to - from) * (n - 1) / info.pages, stage: '$label · página $n de ${info.pages}'),
        );
        final tiffs = [for (final e in dir.listSync()) if (e.path.endsWith('.tif')) e.path]..sort();
        final f = p.join(work.path, 'mono_$dpi.pdf');
        await _writeMonoPdf(tiffs, dpi, f);
        return f;
      }

      String? warning;
      try {
        String best;
        if (target == null) {
          best = s.mono
              ? await mono(s.dpi ?? const [300, 300, 200, 150][s.level.index], 0, 0.92, 'Preto e branco')
              : await tone(s.dpi ?? s.level.dpi, s.quality, 0, 0.92, 'Comprimindo');
        } else {
          // Tamanho-alvo: busca o melhor degrau que cabe (poucas tentativas).
          final steps = s.mono
              ? [for (final d in const [300, 200, 150, 100]) (d, 0)]
              : [for (final st in _ladder) if (s.dpi == null || st.$1 <= s.dpi!) st];
          final sizes = <int, (String, int)>{};
          Future<int> at(int i) async {
            if (!sizes.containsKey(i)) {
              final k = sizes.length;
              final label = 'Tentativa ${k + 1}';
              final from = 0.92 * k / 4, to = 0.92 * (k + 1) / 4;
              final f = s.mono ? await mono(steps[i].$1, from, to, label) : await tone(steps[i].$1, steps[i].$2, from, to, label);
              sizes[i] = (f, File(f).lengthSync());
            }
            return sizes[i]!.$2;
          }

          var lo = 0, hi = steps.length - 1;
          if (await at(hi) > target) {
            lo = hi; // nem o menor degrau cabe
          } else {
            while (lo < hi) {
              final mid = (lo + hi) ~/ 2;
              if (await at(mid) <= target) {
                hi = mid;
              } else {
                lo = mid + 1;
              }
            }
          }
          best = sizes[lo]!.$1;
        }
        // Passada final sem perda: reempacota a estrutura do PDF.
        ctx.report(0.94, stage: 'Otimizando a estrutura');
        final packed = p.join(work.path, 'final.pdf');
        try {
          await _qpdf(ctx, tools, ['--object-streams=generate', '--recompress-flate', '--compression-level=9', best, packed]);
          if (File(packed).lengthSync() < File(best).lengthSync()) best = packed;
        } catch (_) {}
        final after = File(best).lengthSync();
        if (after >= info.sizeBytes) {
          throw FfError('Este PDF já está bem comprimido: o resultado ficaria maior '
              '(${fmtBytes(after)} contra ${fmtBytes(info.sizeBytes)}). '
              '${s.advanced ? 'Tente outras opções avançadas.' : 'Tente um nível mais forte ou as opções avançadas.'}');
        }
        if (target != null && after > target) {
          warning = 'Não deu para chegar a ${fmtBytes(target)}: este é o menor resultado possível'
              '${s.mono ? '' : ' sem preto e branco'}';
        }
        await File(best).copy(out);
      } catch (_) {
        _delete(out);
        rethrow;
      } finally {
        try {
          work.deleteSync(recursive: true);
        } catch (_) {}
      }
      final after = File(out).lengthSync();
      return JobResult(
        '${fmtBytes(info.sizeBytes)} → ${fmtBytes(after)} '
        '(−${((1 - after / info.sizeBytes) * 100).round()}%)',
        out,
        warning: warning,
      );
    },
  );
}

// ------------------------------------------------------------------ dividir

enum PdfSplitMode { everyN, size, ranges, single }

class PdfSplitSettings {
  PdfSplitMode mode = PdfSplitMode.everyN;
  int every = 10;
  double sizeMb = 10;
  String ranges = '';

  PdfSplitSettings copy() => PdfSplitSettings()
    ..mode = mode
    ..every = every
    ..sizeMb = sizeMb
    ..ranges = ranges;

  String describe() => switch (mode) {
        PdfSplitMode.everyN => 'a cada $every páginas',
        PdfSplitMode.size => 'partes de até ${fmtBytes(sizeMb * bytesPerMb)}',
        PdfSplitMode.ranges => 'intervalos $ranges',
        PdfSplitMode.single => 'uma página por arquivo',
      };

  /// Estimativa de partes para a interface (null se não dá para saber).
  int? estimateParts(MediaInfo info) => switch (mode) {
        PdfSplitMode.everyN => every <= 0 ? null : (info.pages / every).ceil(),
        PdfSplitMode.size => sizeMb <= 0 ? null : (info.sizeBytes / (sizeMb * bytesPerMb)).ceil(),
        PdfSplitMode.ranges => parsePageRanges(ranges, info.pages)?.length,
        PdfSplitMode.single => info.pages,
      };
}

/// "1-3, 5, 8-" → [(1,3),(5,5),(8,total)]. null se inválido.
List<(int, int)>? parsePageRanges(String text, int total) {
  final out = <(int, int)>[];
  for (final raw in text.split(RegExp(r'[,;]'))) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final m = RegExp(r'^(\d+)\s*(?:-\s*(\d*))?$').firstMatch(part);
    if (m == null) return null;
    final a = int.parse(m[1]!);
    final b = m[2] == null ? a : (m[2]!.isEmpty ? total : int.parse(m[2]!));
    if (a < 1 || b < a || b > total) return null;
    out.add((a, b));
  }
  return out.isEmpty ? null : out;
}

Job buildPdfSplitJob(MediaInfo info, PdfSplitSettings settings, String? outDir, PdfTools tools) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Dividir',
    detail: s.describe(),
    body: (ctx) async {
      _checkOpen(info);
      final n = info.pages;
      final base = p.basenameWithoutExtension(info.path);
      final limit = (s.sizeMb * bytesPerMb).floor();
      if (s.mode == PdfSplitMode.everyN && (s.every < 1 || s.every >= n)) {
        throw FfError('O PDF tem $n página(s): com ${s.every} por parte não há o que dividir.');
      }
      if (s.mode == PdfSplitMode.single && n < 2) throw FfError('O PDF só tem uma página.');
      if (s.mode == PdfSplitMode.size) {
        if (limit < 20 * 1024) throw FfError('O tamanho por parte precisa ser de pelo menos 20 KB.');
        if (info.sizeBytes <= limit) {
          throw FfError('O PDF já cabe em ${fmtBytes(limit)} — não há o que dividir.');
        }
      }
      final ranges = s.mode == PdfSplitMode.ranges ? parsePageRanges(s.ranges, n) : null;
      if (s.mode == PdfSplitMode.ranges && ranges == null) {
        throw FfError('Intervalos inválidos para um PDF de $n páginas. Exemplo: 1-3, 5, 8-12');
      }

      final dir = await _outDirFor(outDir, info, '_partes');
      String partPath(int a, int b) =>
          p.join(dir, '${base}_p${a.toString().padLeft(3, '0')}${b > a ? '-${b.toString().padLeft(3, '0')}' : ''}.pdf');
      Future<int> build(int a, int b, String out) async {
        await _qpdf(ctx, tools, [info.path, '--pages', '.', a == b ? '$a' : '$a-$b', '--', out]);
        return File(out).lengthSync();
      }

      var oversized = false;
      Directory? work;
      try {
        switch (s.mode) {
          case PdfSplitMode.everyN:
          case PdfSplitMode.single:
            final per = s.mode == PdfSplitMode.single ? 1 : s.every;
            ctx.report(0, stage: 'Dividindo');
            // Um único processo lê o PDF uma vez e grava todas as partes.
            await _qpdf(ctx, tools,
                [info.path, '--split-pages=$per', p.join(dir, '${base.replaceAll('%', '_')}_p%d.pdf')]);
          case PdfSplitMode.ranges:
            for (var i = 0; i < ranges!.length; i++) {
              ctx.report(i / ranges.length, stage: 'Parte ${i + 1} de ${ranges.length}');
              final (a, b) = ranges[i];
              await build(a, b, uniquePath(partPath(a, b)));
            }
          case PdfSplitMode.size:
            // 1) Mede cada página isolada. A soma superestima (fontes repetidas
            //    em cada página), então serve de ponto de partida seguro.
            work = await Directory.systemTemp.createTemp('filume_pdf_');
            ctx.report(0, stage: 'Medindo páginas');
            await _qpdf(ctx, tools, [info.path, '--split-pages=1', p.join(work.path, 'p-%d.pdf')]);
            final files = work.listSync().whereType<File>().toList()
              ..sort((x, y) => x.path.compareTo(y.path));
            final sizes = [for (final f in files) f.lengthSync()];
            if (sizes.length != n) throw FfError('Não foi possível medir as páginas deste PDF.');
            work.deleteSync(recursive: true);
            work = null;

            int greedy(int a, num budget) {
              var sum = 0, b = a;
              for (var i = a; i <= n; i++) {
                sum += sizes[i - 1];
                if (sum > budget && i > a) break;
                b = i;
              }
              return b;
            }

            var a = 1;
            while (a <= n) {
              ctx.report(0.3 + 0.7 * (a - 1) / n, stage: 'Gravando partes');
              var b = greedy(a, limit * 0.97);
              var out = partPath(a, b);
              var size = await build(a, b, out);
              // 2) Se sobrou bastante espaço (recursos compartilhados), tenta
              //    encaixar mais páginas na mesma parte.
              for (var tries = 0; tries < 4 && b < n && size < limit * 0.8; tries++) {
                final sum = sizes.sublist(a - 1, b).fold<int>(0, (x, y) => x + y);
                final nb = greedy(a, sum * (limit * 0.95 / size));
                if (nb <= b) break;
                final out2 = partPath(a, nb);
                final size2 = await build(a, nb, out2);
                if (size2 > limit) {
                  _delete(out2);
                  break;
                }
                _delete(out);
                out = out2;
                size = size2;
                b = nb;
              }
              if (size > limit) oversized = true;
              a = b + 1;
            }
        }
      } catch (_) {
        try {
          Directory(dir).deleteSync(recursive: true);
        } catch (_) {}
        rethrow;
      } finally {
        try {
          work?.deleteSync(recursive: true);
        } catch (_) {}
      }

      var count = 0, largest = 0;
      await for (final e in Directory(dir).list()) {
        if (e is File) {
          count++;
          final len = await e.length();
          if (len > largest) largest = len;
        }
      }
      return JobResult(
        '$count ${count == 1 ? 'parte' : 'partes'} · maior com ${fmtBytes(largest)}',
        dir,
        warning: oversized
            ? 'Alguma página sozinha passa do limite (maior parte: ${fmtBytes(largest)}). Comprima o PDF antes.'
            : null,
      );
    },
  );
}

// --------------------------------------------------------- unir e organizar

/// Uma página na bandeja do organizador: uma página de PDF ou uma imagem
/// (arquivo ou digitalização).
class PageRef {
  PageRef(this.doc, this.page, [this.rotation = 0, this.skew = 0]);
  final MediaInfo doc;

  /// Número da página no arquivo de origem (começa em 1).
  final int page;

  /// Giro extra em graus: 0, 90, 180 ou 270.
  int rotation;

  /// Correção de inclinação ("endireitar"), em graus; só para imagens.
  double skew;

  /// Endireitamento em andamento (mostra um indicador na miniatura).
  bool busy = false;

  bool get isImage => doc.isImage;
}

/// Monta o PDF final com o qpdf: [parts] são (arquivo, página, giro).
Future<void> _assemble(JobCtx ctx, PdfTools tools, List<(String, int, int)> parts, String out) async {
  final args = <String>['--empty', '--pages'];
  var i = 0;
  while (i < parts.length) {
    var j = i;
    while (j + 1 < parts.length && parts[j + 1].$1 == parts[i].$1) {
      j++;
    }
    args.addAll([
      parts[i].$1,
      // Sequências crescentes viram "a-b"; o resto vai página a página.
      _orderedRanges([for (var k = i; k <= j; k++) parts[k].$2]),
    ]);
    i = j + 1;
  }
  args.add('--');
  for (final angle in const [90, 180, 270]) {
    final idx = [
      for (var k = 0; k < parts.length; k++)
        if (parts[k].$3 % 360 == angle) k + 1,
    ];
    if (idx.isNotEmpty) args.add('--rotate=+$angle:${compactRanges(idx)}');
  }
  args.add(out);
  await _qpdf(ctx, tools, args);
}

String _orderedRanges(List<int> pages) => compactRanges(pages);

Job buildPdfMergeJob(List<MediaInfo> items, String? outDir, PdfTools tools) {
  final docs = List<MediaInfo>.of(items);
  final first = docs.first;
  final total = docs.fold<int>(0, (n, d) => n + d.pages);
  return Job(
    title: '${docs.length} PDFs → ${p.basenameWithoutExtension(first.path)}_unido',
    kind: 'Unir',
    detail: '$total páginas',
    body: (ctx) async {
      if (docs.length < 2) throw FfError('Adicione pelo menos 2 PDFs para unir.');
      docs.forEach(_checkOpen);
      final out = await _outFile(outDir, first, '_unido');
      ctx.report(0, stage: 'Unindo');
      try {
        await _qpdf(ctx, tools, [
          '--empty', '--pages',
          for (final d in docs) ...[d.path, '1-z'],
          '--', out,
        ]);
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult('$total páginas · ${fmtBytes(File(out).lengthSync())}', out);
    },
  );
}

/// Junta as páginas da bandeja em um PDF só. Imagens e digitalizações viram,
/// cada uma, um PDF de uma página (em [work]); o progresso ocupa 0..[span].
Future<void> _buildTray(JobCtx ctx, PdfTools tools, List<PageRef> pages, PageFit fit, String out, String work,
    {double span = 1, int jpegQ = 2}) async {
  final images = pages.where((r) => r.isImage).length;
  final parts = <(String, int, int)>[];
  var done = 0;
  for (final r in pages) {
    if (!r.isImage) {
      parts.add((r.doc.path, r.page, r.rotation));
      continue;
    }
    ctx.report(span * 0.9 * done / images, stage: 'Imagem ${done + 1} de $images');
    final pdf = p.join(work, 'img_$done.pdf');
    await writeImagesPdf(ctx, [r.doc], fit, pdf, skew: [r.skew], jpegQ: jpegQ);
    parts.add((pdf, 1, r.rotation));
    done++;
  }
  ctx.report(span * 0.92, stage: 'Montando páginas');
  await _assemble(ctx, tools, parts, out);
}

Job buildPdfOrganizeJob(List<PageRef> pages, String? outDir, PdfTools tools, [PageFit fit = PageFit.a4]) {
  final snapshot = [for (final r in pages) PageRef(r.doc, r.page, r.rotation, r.skew)];
  final first = snapshot.first.doc;
  return Job(
    title: '${p.basenameWithoutExtension(first.path)}_organizado.pdf',
    kind: 'Organizar',
    detail: '${snapshot.length} páginas',
    body: (ctx) async {
      final out = await _outFile(outDir, first, '_organizado');
      final work = await Directory.systemTemp.createTemp('filume_mesa_');
      try {
        await _buildTray(ctx, tools, snapshot, fit, out, work.path);
      } catch (_) {
        _delete(out);
        rethrow;
      } finally {
        try {
          work.deleteSync(recursive: true);
        } catch (_) {}
      }
      return JobResult('${snapshot.length} páginas · ${fmtBytes(File(out).lengthSync())}', out);
    },
  );
}

// ------------------------------------------------- bandeja (FiLume PDF)

/// Resolução em que as páginas são desenhadas para o OCR ler.
const _ocrDpi = 200;

/// OCR: acrescenta uma camada de texto invisível às páginas de [pdf] que
/// ainda não têm texto (digitalizações, fotos). Devolve quantas ganharam
/// texto; o progresso ocupa [from]..[to].
Future<int> _ocrLayer(JobCtx ctx, PdfTools tools, String pdf, String work, OcrFn ocr, double from, double to) async {
  final dir = Directory(p.join(work, 'ocr'))..createSync();
  final total = (await tools.probe(pdf)).pages;
  ctx.report(from, stage: 'OCR: procurando páginas sem texto');
  await _gs(ctx, tools, ['-q', '-sDEVICE=txtwrite', '-sOutputFile=${p.join(dir.path, 't_%d.txt')}', pdf]);
  final need = <int>[];
  for (var i = 1; i <= total; i++) {
    final f = File(p.join(dir.path, 't_$i.txt'));
    if (!f.existsSync() || latin1.decode(f.readAsBytesSync()).trim().isEmpty) need.add(i);
  }
  if (need.isEmpty) return 0;
  final span = to - from;
  final images = <String>[];
  for (var k = 0; k < need.length; k++) {
    ctx.report(from + span * 0.5 * k / need.length, stage: 'OCR: preparando página ${k + 1} de ${need.length}');
    final img = p.join(dir.path, 'p_${need[k]}.jpg');
    await _gs(ctx, tools, [
      '-q', '-sDEVICE=jpeg', '-dJPEGQ=88', '-r$_ocrDpi', '-dFirstPage=${need[k]}', '-dLastPage=${need[k]}',
      '-sOutputFile=$img', pdf,
    ]);
    images.add(img);
  }
  ctx.report(from + span * 0.5, stage: 'OCR: lendo o texto');
  final read = await ocr(
    images,
    (done) => ctx.report(from + span * (0.5 + 0.45 * done / need.length), stage: 'OCR: lendo página $done de ${need.length}'),
  );
  var withText = 0;
  final layers = <(double, double, String)>[for (var i = 0; i < total; i++) (612, 792, '')];
  for (var k = 0; k < need.length; k++) {
    final page = read[k];
    if (page.words.isEmpty || page.width <= 0) continue;
    final w = page.width * 72 / _ocrDpi, h = page.height * 72 / _ocrDpi;
    layers[need[k] - 1] = (w, h, textLayerContent(page, w, h));
    withText++;
  }
  if (withText == 0) return 0;
  final layer = p.join(dir.path, 'texto.pdf'), merged = p.join(dir.path, 'com_texto.pdf');
  await writeTextLayerPdf(layers, layer);
  await _qpdf(ctx, tools, [pdf, '--overlay', layer, '--', merged]);
  await File(merged).copy(pdf);
  return withText;
}

/// O que fazer com as páginas da bandeja ao salvar.
enum TrayOp {
  save('Salvar PDF', 'Salvar'),
  compress('Comprimir e salvar', 'Comprimir'),
  split('Dividir e salvar', 'Dividir'),
  images('Exportar imagens', 'Exportar'),
  protect('Proteger e salvar', 'Proteger');

  const TrayOp(this.label, this.kind);
  final String label;
  final String kind;

  /// Dividir e exportar geram uma pasta; o resto, um arquivo PDF.
  bool get folder => this == split || this == images;
}

/// Leva [src] (arquivo ou pasta) para [dst], sem sobrescrever nada.
Future<String> _moveOut(String src, String dst) async {
  final isDir = FileSystemEntity.isDirectorySync(src);
  final target = uniquePath(dst, directory: isDir);
  await Directory(p.dirname(target)).create(recursive: true);
  try {
    isDir ? await Directory(src).rename(target) : await File(src).rename(target);
  } on FileSystemException {
    // Outro disco: copia e apaga a origem.
    if (isDir) {
      await Directory(target).create(recursive: true);
      await for (final e in Directory(src).list()) {
        if (e is File) await e.copy(p.join(target, p.basename(e.path)));
      }
    } else {
      await File(src).copy(target);
    }
  }
  return target;
}

/// A bandeja é exatamente um PDF inteiro, na ordem e sem giros?
MediaInfo? _untouchedDoc(List<PageRef> pages) {
  final doc = pages.first.doc;
  if (doc.isImage || pages.length != doc.pages) return null;
  for (var i = 0; i < pages.length; i++) {
    final r = pages[i];
    if (!identical(r.doc, doc) || r.page != i + 1 || r.rotation % 360 != 0) return null;
  }
  return doc;
}

/// PDFs assinados digitalmente entre as páginas da bandeja.
List<MediaInfo> signedDocsIn(List<PageRef> pages) {
  final out = <MediaInfo>[];
  for (final r in pages) {
    if (r.doc.signatures.isNotEmpty && !out.any((d) => identical(d, r.doc))) out.add(r.doc);
  }
  return out;
}

/// Salvar sem mexer em nada num PDF assinado: o arquivo é copiado byte a
/// byte e a assinatura continua valendo.
bool trayKeepsSignature(List<PageRef> pages, TrayOp op) =>
    op == TrayOp.save && pages.isNotEmpty && (_untouchedDoc(pages)?.signatures.isNotEmpty ?? false);

/// Anexa os [originals] (PDFs assinados) dentro de [pdf], para a assinatura
/// poder ser conferida mesmo que a cópia tenha sido alterada.
Future<void> _attachOriginals(JobCtx ctx, PdfTools tools, String pdf, List<MediaInfo> originals, String work,
    {String password = ''}) async {
  final tmp = p.join(work, 'com_anexo.pdf');
  final used = <String>{};
  await _qpdf(ctx, tools, [
    if (password.isNotEmpty) '--password=$password',
    pdf,
    for (final o in originals) ...[
      '--add-attachment', o.path,
      '--key=${uniqueName(used, 'original assinado - ${p.basename(o.path)}')}',
      '--filename=${p.basename(o.path)}',
      '--description=Original com assinatura digital, sem alteracoes',
      '--',
    ],
    tmp,
  ]);
  await File(tmp).copy(pdf);
  _delete(tmp);
}

/// Nome que ainda não está em [used] (acrescenta " (2)", " (3)"…).
String uniqueName(Set<String> used, String name) {
  var n = name;
  for (var i = 2; !used.add(n); i++) {
    n = '$name ($i)';
  }
  return n;
}

/// Trabalho do FiLume PDF: monta as páginas da bandeja e aplica [op].
/// O resultado vai para [outDir] com o nome [name] (sem extensão).
Job buildTrayJob({
  required List<PageRef> pages,
  required TrayOp op,
  required String outDir,
  required String name,
  required PdfTools tools,
  PageFit fit = PageFit.a4,
  int jpegQ = 2,
  PdfCompressSettings? compress,
  PdfSplitSettings? split,
  PdfConvertSettings? convert,
  String password = '',
  OcrFn? ocr,
  bool attachSigned = false,
}) {
  final snapshot = [for (final r in pages) PageRef(r.doc, r.page, r.rotation, r.skew)];
  final cs = compress?.copy(), ss = split?.copy(), vs = convert?.copy();
  return Job(
    title: op.folder ? name : '$name.pdf',
    kind: op.kind,
    detail: '${snapshot.length} ${snapshot.length == 1 ? 'página' : 'páginas'}',
    body: (ctx) async {
      if (snapshot.isEmpty) throw FfError('A bandeja está vazia.');
      if (op == TrayOp.protect && password.isEmpty) throw FfError('Digite a senha.');
      final work = await Directory.systemTemp.createTemp('filume_bandeja_');
      try {
        final target = p.join(outDir, op.folder ? name : '$name.pdf');
        // OCR não se aplica ao exportar imagens.
        final read = op == TrayOp.images ? null : ocr;
        String? note;

        /// Aplica o OCR em [pdf]; se o OCR falhar, o PDF sai sem texto e com um aviso.
        Future<void> addText(String pdf, double from, double to) async {
          if (read == null) return;
          try {
            final n = await _ocrLayer(ctx, tools, pdf, work.path, read, from, to);
            if (n > 0) note = 'OCR: texto pesquisável em $n ${n == 1 ? 'página' : 'páginas'}';
          } on OcrError catch (e) {
            note = 'Salvo sem OCR. ${e.message}';
          }
        }

        String? both(String? a, String? b) => a == null ? b : (b == null ? a : '$a · $b');

        final signed = signedDocsIn(snapshot);
        if (trayKeepsSignature(snapshot, op)) {
          // Nada mudou num PDF assinado: cópia idêntica, a assinatura continua valendo.
          final tmp = p.join(work.path, 'saida.pdf');
          await File(signed.first.path).copy(tmp);
          final out = await _moveOut(tmp, target);
          return JobResult('${snapshot.length} páginas · ${fmtBytes(File(out).lengthSync())}', out,
              warning: 'Assinatura digital preservada: cópia idêntica ao original');
        }
        final attach = attachSigned && signed.isNotEmpty && !op.folder;
        final signNote = signed.isEmpty
            ? null
            : 'A assinatura digital não vale nesta cópia${attach ? '; o original assinado foi anexado ao PDF' : ''}';

        if (op == TrayOp.save) {
          final tmp = p.join(work.path, 'saida.pdf');
          await _buildTray(ctx, tools, snapshot, fit, tmp, work.path, span: read == null ? 1 : 0.5, jpegQ: jpegQ);
          await addText(tmp, 0.5, 0.98);
          if (attach) await _attachOriginals(ctx, tools, tmp, signed, work.path);
          final out = await _moveOut(tmp, target);
          return JobResult('${snapshot.length} páginas · ${fmtBytes(File(out).lengthSync())}', out,
              warning: both(note, signNote));
        }
        // Um PDF intocado dispensa a montagem (comprimir e proteger usam o original).
        // Em preto e branco as páginas viram imagem: o OCR entra depois da compressão.
        final lateOcr = op == TrayOp.compress && (cs?.mono ?? false);
        final single = op.folder || (read != null && !lateOcr) ? null : _untouchedDoc(snapshot);
        final MediaInfo info;
        var from = 0.0;
        if (single != null) {
          info = single;
        } else {
          final src = Directory(p.join(work.path, 'origem'))..createSync();
          final tmp = p.join(src.path, '$name.pdf');
          await _buildTray(ctx, tools, snapshot, fit, tmp, work.path, span: 0.3, jpegQ: jpegQ);
          from = 0.3;
          if (read != null && !lateOcr) {
            await addText(tmp, 0.3, 0.6);
            from = 0.6;
          }
          info = await tools.probe(tmp);
        }
        final outTmp = Directory(p.join(work.path, 'saida'))..createSync();
        final inner = switch (op) {
          TrayOp.compress => buildPdfCompressJob(info, cs ?? PdfCompressSettings(), outTmp.path, tools),
          TrayOp.split => buildPdfSplitJob(info, ss ?? PdfSplitSettings(), outTmp.path, tools),
          TrayOp.images => buildPdfToImagesJob(info, vs ?? PdfConvertSettings(), outTmp.path, tools),
          _ => buildPdfPasswordJob(
              info,
              PdfPasswordSettings()
                ..protect = true
                ..password = password,
              outTmp.path,
              tools),
        };
        final sub = JobCtx(ctx.tools, ctx.run,
            (pr, stage, speed) => ctx.report(from + (1 - from) * pr, stage: stage, speed: speed));
        final r = await inner.body(sub);
        if (lateOcr) await addText(r.revealPath, 0.97, 0.99);
        if (attach) await _attachOriginals(ctx, tools, r.revealPath, signed, work.path, password: password);
        final out = await _moveOut(r.revealPath, target);
        return JobResult(r.summary, out, warning: both(both(r.warning, note), signNote));
      } finally {
        try {
          work.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
  );
}

// ---------------------------------------------------------------- converter

enum PdfConvertMode { toImages, fromImages }

enum PageFit {
  a4('A4'),
  image('Do tamanho da imagem');

  const PageFit(this.label);
  final String label;
}

class PdfConvertSettings {
  PdfConvertMode mode = PdfConvertMode.toImages;
  bool png = false;
  int dpi = 150;
  PageFit fit = PageFit.a4;

  PdfConvertSettings copy() => PdfConvertSettings()
    ..mode = mode
    ..png = png
    ..dpi = dpi
    ..fit = fit;
}

Job buildPdfToImagesJob(MediaInfo info, PdfConvertSettings settings, String? outDir, PdfTools tools) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Converter',
    detail: '→ ${s.png ? 'PNG' : 'JPG'} · ${s.dpi} dpi',
    body: (ctx) async {
      _checkOpen(info);
      final dir = await _outDirFor(outDir, info, '_imagens');
      final base = p.basenameWithoutExtension(info.path).replaceAll('%', '_');
      try {
        await _gs(
          ctx,
          tools,
          [
            '-sDEVICE=${s.png ? 'png16m' : 'jpeg'}', if (!s.png) '-dJPEGQ=90',
            '-r${s.dpi}', '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
            '-sOutputFile=${p.join(dir, '${base}_%03d.${s.png ? 'png' : 'jpg'}')}',
            info.path,
          ],
          onPage: (n) => ctx.report((n - 1) / info.pages, stage: 'Página $n de ${info.pages}'),
        );
      } catch (_) {
        try {
          Directory(dir).deleteSync(recursive: true);
        } catch (_) {}
        rethrow;
      }
      return JobResult('${info.pages} ${info.pages == 1 ? 'imagem' : 'imagens'}', dir);
    },
  );
}

/// Largura, altura e nº de componentes de um JPEG (lidos do marcador SOF).
(int, int, int)? jpegSize(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    final isSof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
    if (isSof) {
      final h = (b[i + 5] << 8) | b[i + 6], w = (b[i + 7] << 8) | b[i + 8];
      return (w, h, b[i + 9]);
    }
    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
      i += 2;
      continue;
    }
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  return null;
}

String _num(double v) => v.toStringAsFixed(2);

/// Grava um PDF com uma imagem por página (JPEG embutido, sem dependências).
/// [skew] traz, por imagem, o ângulo de correção de inclinação em graus.
Future<void> writeImagesPdf(
  JobCtx ctx,
  List<MediaInfo> images,
  PageFit fit,
  String out, {
  List<double> skew = const [],
  void Function(int index)? onImage,
  int jpegQ = 2,
}) async {
  final work = await Directory.systemTemp.createTemp('filume_pdf_');
  RandomAccessFile? raf;
  try {
      raf = await File(out).open(mode: FileMode.write);
      var offset = 0;
      final offsets = <int>[];
      Future<void> write(List<int> bytes) async {
        await raf!.writeFrom(bytes);
        offset += bytes.length;
      }

      Future<void> obj(String body) async {
        offsets.add(offset);
        await write('${offsets.length} 0 obj\n$body\nendobj\n'.codeUnits);
      }

      // Objetos: 1 catálogo, 2 árvore de páginas; para a imagem k (0..):
      // 3+3k página, 4+3k conteúdo, 5+3k imagem.
      await write('%PDF-1.4\n%âãÏÓ\n'.codeUnits);
      await obj('<< /Type /Catalog /Pages 2 0 R >>');
      await obj('<< /Type /Pages /Count ${images.length} '
          '/Kids [${[for (var k = 0; k < images.length; k++) '${3 + 3 * k} 0 R'].join(' ')}] >>');

      for (var k = 0; k < images.length; k++) {
        onImage?.call(k);
        final jpg = p.join(work.path, 'i$k.jpg');
        // Tudo vira JPEG padrão (uma imagem por vez na memória). Transparência
        // é achatada sobre branco; se o filtro não existir, vai sem ele.
        final alpha =
            RegExp(r'^(rgba|bgra|argb|abgr|ya|yuva|gbrap|pal8)').hasMatch(images[k].pixFmt ?? '');
        // "Endireitar": gira pelo ângulo medido, preenchendo os cantos de branco.
        final angle = k < skew.length ? skew[k] : 0.0;
        final rotate = angle == 0 ? null : 'rotate=a=${(angle * 3.141592653589793 / 180).toStringAsFixed(6)}:c=white:bilinear=1';
        Future<void> convert(bool flatten) => ctx.run.ffmpeg(ctx.tools, [
              '-i', images[k].path,
              if (flatten) ...[
                '-filter_complex',
                'color=white:s=16x16,format=rgb24[c];[c][0:v]scale2ref[c][i];[c][i]overlay=shortest=1'
                    '${rotate == null ? '' : ',$rotate'}',
              ] else if (rotate != null) ...['-vf', rotate],
              '-frames:v', '1', '-q:v', '$jpegQ', '-pix_fmt', 'yuvj420p', jpg,
            ]);
        if (alpha) {
          try {
            await convert(true);
          } on FfError {
            await convert(false);
          }
        } else {
          await convert(false);
        }
        final bytes = await File(jpg).readAsBytes();
        final dim = jpegSize(bytes);
        if (dim == null) throw FfError('Não foi possível ler "${p.basename(images[k].path)}".');
        final (w, h, comps) = dim;

        // Página: A4 (em pé ou deitada conforme a imagem) ou proporcional à imagem.
        double pw, ph, dw, dh;
        if (fit == PageFit.a4) {
          final landscape = w > h;
          pw = landscape ? 841.89 : 595.28;
          ph = landscape ? 595.28 : 841.89;
          final scale = (pw / w) < (ph / h) ? pw / w : ph / h;
          dw = w * scale;
          dh = h * scale;
        } else {
          pw = dw = 595.28;
          ph = dh = 595.28 * h / w;
        }
        final content = 'q ${_num(dw)} 0 0 ${_num(dh)} ${_num((pw - dw) / 2)} ${_num((ph - dh) / 2)} cm /Im0 Do Q';
        await obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${_num(pw)} ${_num(ph)}] '
            '/Resources << /XObject << /Im0 ${5 + 3 * k} 0 R >> >> /Contents ${4 + 3 * k} 0 R >>');
        await obj('<< /Length ${content.length} >>\nstream\n$content\nendstream');
        offsets.add(offset);
        await write('${offsets.length} 0 obj\n<< /Type /XObject /Subtype /Image /Width $w /Height $h '
                '/ColorSpace ${comps == 1 ? '/DeviceGray' : '/DeviceRGB'} /BitsPerComponent 8 '
                '/Filter /DCTDecode /Length ${bytes.length} >>\nstream\n'
            .codeUnits);
        await write(bytes);
        await write('\nendstream\nendobj\n'.codeUnits);
        _delete(jpg);
      }

      final xref = offset;
      final table = StringBuffer('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
      for (final o in offsets) {
        table.write('${o.toString().padLeft(10, '0')} 00000 n \n');
      }
      table.write('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
      await write(table.toString().codeUnits);
      await raf.close();
      raf = null;
  } catch (_) {
    await raf?.close();
    rethrow;
  } finally {
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Job buildImagesToPdfJob(List<MediaInfo> items, PdfConvertSettings settings, String? outDir) {
  final s = settings.copy();
  final images = List<MediaInfo>.of(items);
  final first = images.first;
  return Job(
    title: '${images.length} ${images.length == 1 ? 'imagem' : 'imagens'} → ${p.basenameWithoutExtension(first.path)}.pdf',
    kind: 'Converter',
    detail: 'página ${s.fit.label.toLowerCase()}',
    body: (ctx) async {
      final out = await _outFile(outDir, first, '');
      try {
        await writeImagesPdf(
          ctx,
          images,
          s.fit,
          out,
          onImage: (k) => ctx.report(k / images.length, stage: 'Imagem ${k + 1} de ${images.length}'),
        );
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult(
        '${images.length} ${images.length == 1 ? 'página' : 'páginas'} · ${fmtBytes(File(out).lengthSync())}',
        out,
      );
    },
  );
}

// -------------------------------------------------------------------- senha

class PdfPasswordSettings {
  /// true = proteger com senha; false = remover a senha.
  bool protect = true;
  String password = '';

  PdfPasswordSettings copy() => PdfPasswordSettings()
    ..protect = protect
    ..password = password;
}

Job buildPdfPasswordJob(MediaInfo info, PdfPasswordSettings settings, String? outDir, PdfTools tools) {
  final s = settings.copy();
  return Job(
    title: p.basename(info.path),
    kind: 'Senha',
    detail: s.protect ? 'proteger com senha' : 'remover senha',
    body: (ctx) async {
      if (s.password.isEmpty) throw FfError('Digite a senha.');
      if (s.protect && info.encrypted) {
        throw FfError('Este PDF já tem senha. Remova a senha atual antes de definir outra.');
      }
      final out = await _outFile(outDir, info, s.protect ? '_protegido' : '_sem_senha');
      ctx.report(0, stage: s.protect ? 'Protegendo' : 'Removendo senha');
      try {
        await _qpdf(
          ctx,
          tools,
          s.protect
              ? ['--encrypt', s.password, s.password, '256', '--', info.path, out]
              : ['--password=${s.password}', '--decrypt', info.path, out],
        );
      } catch (_) {
        _delete(out);
        rethrow;
      }
      return JobResult(fmtBytes(File(out).lengthSync()), out);
    },
  );
}

// ------------------------------------------------------------------- editor

/// Grava o PDF que está aberto no editor: o PDFium escreve o arquivo e o
/// qpdf reempacota a estrutura (sem perda) para ele não sair maior à toa.
Job buildEditorSaveJob(Editor editor, String outDir, String name, PdfTools tools) {
  return Job(
    title: '$name.pdf',
    kind: 'Editar',
    detail: '${editor.pageCount} ${editor.pageCount == 1 ? 'página' : 'páginas'}',
    body: (ctx) async {
      final work = await Directory.systemTemp.createTemp('filume_edit_');
      try {
        ctx.report(0.1, stage: 'Gravando as alterações');
        final raw = p.join(work.path, 'editado.pdf');
        editor.backend.save(raw);
        ctx.report(0.6, stage: 'Otimizando a estrutura');
        var best = raw;
        final packed = p.join(work.path, 'final.pdf');
        try {
          await _qpdf(ctx, tools, ['--object-streams=generate', '--compress-streams=y', raw, packed]);
          if (File(packed).lengthSync() < File(raw).lengthSync()) best = packed;
        } catch (_) {}
        final pages = (await tools.probe(best)).pages;
        final out = await _moveOut(best, p.join(outDir, '$name.pdf'));
        return JobResult('$pages ${pages == 1 ? 'página' : 'páginas'} · ${fmtBytes(File(out).lengthSync())}', out);
      } finally {
        try {
          work.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
  );
}
