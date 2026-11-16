import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'modules.dart';

/// Conversão de documentos de escritório (Word, Excel, PowerPoint, OpenDocument).
///
/// Quem entende esses formatos de verdade é um pacote de escritório. O FiLume
/// usa, sem abrir janela e sem internet, o que já estiver instalado no
/// computador: o LibreOffice ou o Microsoft Office. Sem nenhum dos dois, sobram
/// as conversões simples feitas aqui mesmo (texto → PDF, Word → texto).
class OfficeTools {
  OfficeTools({
    this.soffice,
    this.sofficeIsModule = false,
    this.pdf2docx,
    this.msWord = false,
    this.msExcel = false,
    this.msPowerPoint = false,
    this.wordVersion,
  });

  /// Caminho do soffice (LibreOffice instalado ou o do módulo "Documentos").
  final String? soffice;
  final bool sofficeIsModule;

  /// Conversor dedicado de PDF → Word (módulo "PDF → Word"), se instalado.
  final String? pdf2docx;
  final bool msWord, msExcel, msPowerPoint;

  /// Versão do Word (12 = 2007, 14 = 2010, 15 = 2013…), quando deu para descobrir.
  final int? wordVersion;

  /// O Word só abre PDF a partir do 2013.
  bool get wordOpensPdf => msWord && (wordVersion == null || wordVersion! >= 15);

  /// Dá para fazer PDF → Word (DOCX) aqui?
  bool get pdfToDocx => pdf2docx != null || soffice != null || wordOpensPdf;

  /// Dá para fazer PDF → ODT aqui?
  bool get pdfToOdt => soffice != null || wordOpensPdf;

  bool get any => soffice != null || msWord || msExcel || msPowerPoint;

  String get label => [
        if (msWord || msExcel || msPowerPoint) 'Microsoft Office',
        if (soffice != null) sofficeIsModule ? 'módulo Documentos' : 'LibreOffice',
      ].join(' e ');

  static Future<OfficeTools> locate() async {
    String? soffice;
    final env = Platform.environment;
    final moduleOffice = moduleEntry(officeModule);
    final candidates = <String>[
      if (env['FILUME_SOFFICE'] case final String custom) custom,
      if (Platform.isWindows) ...[
        for (final root in [env['ProgramFiles'], env['ProgramFiles(x86)'], env['ProgramW6432']].whereType<String>().toSet())
          p.join(root, 'LibreOffice', 'program', 'soffice.exe'),
      ] else ...[
        '/usr/bin/soffice',
        '/usr/local/bin/soffice',
        '/Applications/LibreOffice.app/Contents/MacOS/soffice',
      ],
      // O LibreOffice completo, se a pessoa tem, vem antes do módulo (que é enxuto).
      if (moduleOffice != null) moduleOffice,
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        soffice = c;
        break;
      }
    }
    final customP2d = env['FILUME_PDF2DOCX'];
    final pdf2docx = customP2d != null && File(customP2d).existsSync() ? customP2d : moduleEntry(pdfWordModule);
    var word = false, excel = false, ppt = false;
    int? wordVersion;
    if (Platform.isWindows && env['FILUME_NO_MSOFFICE'] == null) {
      Future<bool> com(String id) async {
        try {
          final r = await Process.run('reg', ['query', 'HKCR\\$id\\CLSID']).timeout(const Duration(seconds: 4));
          return r.exitCode == 0;
        } catch (_) {
          return false;
        }
      }

      final found = await Future.wait([com('Word.Application'), com('Excel.Application'), com('PowerPoint.Application')]);
      word = found[0];
      excel = found[1];
      ppt = found[2];
      if (word) {
        try {
          // HKCR\Word.Application\CurVer vale algo como "Word.Application.12".
          final r = await Process.run('reg', ['query', r'HKCR\Word.Application\CurVer', '/ve']).timeout(const Duration(seconds: 4));
          wordVersion = int.tryParse(RegExp(r'Word\.Application\.(\d+)').firstMatch(r.stdout.toString())?[1] ?? '');
        } catch (_) {}
      }
    }
    return OfficeTools(
      soffice: soffice,
      sofficeIsModule: soffice != null && soffice == moduleOffice,
      pdf2docx: pdf2docx,
      msWord: word,
      msExcel: excel,
      msPowerPoint: ppt,
      wordVersion: wordVersion,
    );
  }

  /// Converte [input] para [ext], gravando em [out]. [family] é "doc", "sheet",
  /// "slides" ou "pdf" (origem). Tenta cada programa disponível, na ordem em
  /// que costuma dar o melhor resultado, e só falha se todos falharem.
  Future<void> convert(FfRun run, String input, String out, String ext, String family,
      {void Function(double fraction, String stage)? onProgress}) async {
    final srcExt = p.extension(input).toLowerCase().replaceFirst('.', '');
    if (family == 'pdf') return _fromPdf(run, input, out, ext, onProgress);
    final ms = switch (family) {
      'doc' => msWord,
      'sheet' => msExcel,
      'slides' => msPowerPoint,
      _ => false,
    };
    // Formatos da Microsoft ficam mais fiéis no próprio Office; os abertos, no LibreOffice.
    const msNative = {'doc', 'docx', 'rtf', 'xls', 'xlsx', 'ppt', 'pptx'};
    final preferMs = msNative.contains(srcExt) || msNative.contains(ext);
    final engines = <Future<void> Function()>[
      if (ms && preferMs) () => _msOffice(run, input, out, ext, family),
      if (soffice != null) () => _libre(run, input, out, ext, family),
      if (ms && !preferMs) () => _msOffice(run, input, out, ext, family),
    ];
    if (engines.isEmpty) {
      throw FfError('Para converter este tipo de arquivo, baixe o módulo "Documentos do Office" (ou tenha o LibreOffice ou o Microsoft Office instalado).');
    }
    await _firstThatWorks(engines, out);
  }

  Future<void> _firstThatWorks(List<Future<void> Function()> engines, String out) async {
    final errors = <String>[];
    for (final e in engines) {
      try {
        await e();
        if (File(out).existsSync() && File(out).lengthSync() > 0) return;
        errors.add('o programa não gravou o arquivo');
      } on JobCanceled {
        rethrow;
      } catch (err) {
        errors.add(err is FfError ? '${err.message} ${err.details}'.trim() : err.toString());
      }
      try {
        if (File(out).existsSync()) File(out).deleteSync();
      } catch (_) {}
    }
    throw FfError('Não foi possível converter este arquivo.', errors.join('\n'));
  }

  // ----------------------------------------------------------------- PDF → Word

  /// PDF → DOCX/ODT. O conversor dedicado (módulo) remonta parágrafos e tabelas;
  /// o Word (2013 em diante) e o LibreOffice ficam como alternativas.
  Future<void> _fromPdf(FfRun run, String input, String out, String ext, void Function(double, String)? onProgress) async {
    final p2d = pdf2docx;
    final engines = <Future<void> Function()>[
      if (p2d != null && ext == 'docx') () => _pdf2docx(run, p2d, input, out, onProgress),
      if (p2d != null && ext != 'docx' && soffice != null)
        () async {
          // O conversor dedicado só grava DOCX; o LibreOffice passa para o formato pedido.
          final work = await Directory.systemTemp.createTemp('filume_p2d_');
          try {
            final docx = p.join(work.path, '${p.basenameWithoutExtension(input)}.docx');
            await _pdf2docx(run, p2d, input, docx, (f, s) => onProgress?.call(f * 0.8, s));
            onProgress?.call(0.85, 'Gravando');
            await _libre(run, docx, out, ext, 'doc');
          } finally {
            try {
              await work.delete(recursive: true);
            } catch (_) {}
          }
        },
      if (wordOpensPdf) () => _msOffice(run, input, out, ext, 'pdf'),
      if (soffice != null) () => _libre(run, input, out, ext, 'pdf'),
    ];
    if (engines.isEmpty) {
      throw FfError(msWord
          ? 'O Word deste computador${wordVersion == 12 ? ' (2007)' : wordVersion == 14 ? ' (2010)' : ''} não abre PDF: isso só existe a partir do Word 2013. '
              'Baixe o módulo "PDF → Word" para fazer esta conversão.'
          : 'Para PDF → Word é preciso baixar o módulo "PDF → Word".');
    }
    await _firstThatWorks(engines, out);
  }

  static final _p2dPage = RegExp(r'\((\d+)/(\d+)\) Page');

  Future<void> _pdf2docx(FfRun run, String exe, String input, String out, void Function(double, String)? onProgress) async {
    var creating = false;
    String? reason;
    final code = await run.exec(exe, [p.absolute(input), p.absolute(out)], onStdoutLine: (line) {
      if (line.startsWith('ERRO: ')) reason = line.substring(6).trim();
      if (line.contains('[4/4]')) creating = true;
      final m = _p2dPage.firstMatch(line);
      if (m == null) return;
      final page = int.parse(m[1]!), total = int.parse(m[2]!);
      if (total <= 0) return;
      // Ler as páginas é a parte demorada; montar o documento, a final.
      final f = creating ? 0.7 + 0.3 * (page - 1) / total : 0.05 + 0.65 * (page - 1) / total;
      onProgress?.call(f, '${creating ? 'Montando' : 'Lendo'} a página $page de $total');
    });
    if (code != 0 || !File(out).existsSync()) {
      throw FfError('O módulo PDF → Word não conseguiu converter este arquivo.', reason ?? run.errorTail.join('\n'));
    }
  }

  // ---------------------------------------------------------------- LibreOffice

  static const _libreFilters = {
    'txt': 'txt:Text (encoded):UTF8',
    'csv': 'csv:Text - txt - csv (StarCalc):44,34,76,1',
    'html': 'html:XHTML Writer File:UTF8',
  };

  Future<void> _libre(FfRun run, String input, String out, String ext, String family) async {
    final work = await Directory.systemTemp.createTemp('filume_lo_');
    try {
      // Perfil próprio: não mexe no LibreOffice do usuário nem trava se ele estiver aberto.
      final profile = Uri.directory(p.join(work.path, 'perfil')).toString();
      var filter = _libreFilters[ext] ?? ext;
      if (family == 'pdf') {
        filter = switch (ext) { 'docx' => 'docx:MS Word 2007 XML', 'odt' => 'odt:writer8', 'rtf' => 'rtf:Rich Text Format', _ => filter };
      }
      if (ext == 'html' && family != 'doc') filter = 'html';
      final code = await run.exec(soffice!, [
        '-env:UserInstallation=$profile',
        '--headless', '--norestore', '--nolockcheck', '--nodefault',
        if (family == 'pdf') '--infilter=writer_pdf_import',
        '--convert-to', filter,
        '--outdir', work.path,
        input,
      ]);
      final made = p.join(work.path, '${p.basenameWithoutExtension(input)}.$ext');
      if (code != 0 || !File(made).existsSync()) {
        throw FfError('O LibreOffice não conseguiu converter (código $code).', run.errorTail.join('\n'));
      }
      await _move(made, out);
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ----------------------------------------------------------- Microsoft Office

  /// Números dos formatos de gravação de cada programa do Office.
  static const _wordFmt = {'pdf': 17, 'docx': 16, 'doc': 0, 'rtf': 6, 'txt': 7, 'html': 10, 'odt': 23};
  static const _excelFmt = {'xlsx': 51, 'xls': 56, 'csv': 62, 'ods': 60, 'html': 44};
  static const _pptFmt = {'pdf': 32, 'pptx': 24, 'ppt': 1, 'odp': 35};

  Future<void> _msOffice(FfRun run, String input, String out, String ext, String family) async {
    final (String script, int? fmt) = switch (family) {
      'sheet' => (_excelScript, ext == 'pdf' ? -1 : _excelFmt[ext]),
      'slides' => (_pptScript, _pptFmt[ext]),
      _ => (_wordScript, _wordFmt[ext]),
    };
    if (fmt == null) throw FfError('O Microsoft Office não grava em .$ext.');
    final work = await Directory.systemTemp.createTemp('filume_mso_');
    try {
      final ps = File(p.join(work.path, 'office.ps1'))..writeAsStringSync(script);
      final code = await run.exec('powershell.exe', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps.path, p.absolute(input), p.absolute(out), '$fmt',
      ]);
      if (code != 0) throw FfError('O Microsoft Office não conseguiu converter (código $code).', run.errorTail.join('\n'));
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  static const _wordScript = r'''
$ErrorActionPreference = 'Stop'
$app = New-Object -ComObject Word.Application
try {
  $app.Visible = $false
  $app.DisplayAlerts = 0
  $major = 0
  try { $major = [int](([string]$app.Version).Split('.')[0]) } catch {}
  if ($args[0].ToLower().EndsWith('.pdf') -and $major -gt 0 -and $major -lt 15) { throw 'Este Word nao abre PDF (so a partir do Word 2013).' }
  $doc = $app.Documents.Open($args[0], $false, $true, $false)
  try {
    $fmt = [int]$args[2]
    # O Word 2007 não tem SaveAs2 (e só grava PDF com o SP2 ou o suplemento da Microsoft).
    if ($major -gt 0 -and $major -lt 14) {
      $path = [string]$args[1]; $no = $false; $empty = ''; $utf8 = 65001
      if ($fmt -eq 7) { $doc.SaveAs([ref]$path, [ref]$fmt, [ref]$no, [ref]$empty, [ref]$no, [ref]$empty, [ref]$no, [ref]$no, [ref]$no, [ref]$no, [ref]$no, [ref]$utf8) }
      else { $doc.SaveAs([ref]$path, [ref]$fmt) }
    }
    elseif ($fmt -eq 7) { $doc.SaveAs2($args[1], $fmt, $false, '', $false, '', $false, $false, $false, $false, $false, 65001) }
    else { $doc.SaveAs2($args[1], $fmt) }
  } finally { $doc.Close(0) }
} finally {
  $app.Quit(0)
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
}
''';

  static const _excelScript = r'''
$ErrorActionPreference = 'Stop'
$app = New-Object -ComObject Excel.Application
try {
  $app.Visible = $false
  $app.DisplayAlerts = $false
  $book = $app.Workbooks.Open($args[0], 0, $true)
  try {
    $fmt = [int]$args[2]
    if ($fmt -lt 0) { $book.ExportAsFixedFormat(0, $args[1]) }
    else { $book.SaveAs($args[1], $fmt) }
  } finally { $book.Close($false) }
} finally {
  $app.Quit()
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
}
''';

  static const _pptScript = r'''
$ErrorActionPreference = 'Stop'
$app = New-Object -ComObject PowerPoint.Application
try {
  $deck = $app.Presentations.Open($args[0], -1, 0, 0)
  try { $deck.SaveAs($args[1], [int]$args[2]) } finally { $deck.Close() }
} finally {
  $app.Quit()
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
}
''';
}

Future<void> _move(String src, String dst) async {
  try {
    await File(src).rename(dst);
  } on FileSystemException {
    await File(src).copy(dst);
    await File(src).delete();
  }
}

// ------------------------------------------------------- conversões embutidas

/// Lê um arquivo de dentro de um ZIP (docx e odt são ZIPs). Null se não achar.
Uint8List? zipEntry(Uint8List zip, String name) {
  final d = ByteData.sublistView(zip);
  // Fim do diretório central: procura a assinatura de trás para frente.
  var eocd = -1;
  for (var i = zip.length - 22; i >= 0 && i >= zip.length - 22 - 65535; i--) {
    if (d.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return null;
  final count = d.getUint16(eocd + 10, Endian.little);
  var o = d.getUint32(eocd + 16, Endian.little);
  for (var i = 0; i < count; i++) {
    if (o + 46 > zip.length || d.getUint32(o, Endian.little) != 0x02014b50) return null;
    final method = d.getUint16(o + 10, Endian.little);
    final csize = d.getUint32(o + 20, Endian.little);
    final nameLen = d.getUint16(o + 28, Endian.little);
    final extraLen = d.getUint16(o + 30, Endian.little);
    final commentLen = d.getUint16(o + 32, Endian.little);
    final local = d.getUint32(o + 42, Endian.little);
    final entry = utf8.decode(zip.sublist(o + 46, o + 46 + nameLen), allowMalformed: true);
    if (entry == name) {
      if (local + 30 > zip.length) return null;
      final start = local + 30 + d.getUint16(local + 26, Endian.little) + d.getUint16(local + 28, Endian.little);
      if (start + csize > zip.length) return null;
      final raw = Uint8List.sublistView(zip, start, start + csize);
      if (method == 0) return raw;
      if (method == 8) return Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
      return null;
    }
    o += 46 + nameLen + extraLen + commentLen;
  }
  return null;
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m[2]!, radix: m[1] == 'x' ? 16 : 10)))
    .replaceAll('&amp;', '&');

/// Texto de um .docx (parágrafos, quebras e tabulações; sem formatação).
String? docxText(Uint8List file) {
  final xml = zipEntry(file, 'word/document.xml');
  if (xml == null) return null;
  final s = utf8.decode(xml, allowMalformed: true);
  final out = StringBuffer();
  final token = RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>|<w:tab\s*/>|<w:(?:br|cr)(?:\s[^>]*)?/>|</w:p>|</w:tc>');
  for (final m in token.allMatches(s)) {
    final t = m[0]!;
    if (m[1] != null) {
      out.write(_unescape(m[1]!));
    } else if (t.startsWith('<w:tab')) {
      out.write('\t');
    } else if (t == '</w:tc>') {
      out.write('\t');
    } else {
      out.write('\n');
    }
  }
  return out.toString().replaceAll(RegExp(r'\t\n'), '\n');
}

/// Texto de um .odt.
String? odtText(Uint8List file) {
  final xml = zipEntry(file, 'content.xml');
  if (xml == null) return null;
  var s = utf8.decode(xml, allowMalformed: true);
  final body = s.indexOf('<office:body');
  if (body > 0) s = s.substring(body);
  s = s
      .replaceAll(RegExp(r'<text:tab\s*/>'), '\t')
      .replaceAll(RegExp(r'<text:line-break\s*/>'), '\n')
      .replaceAllMapped(RegExp(r'<text:s(?:\s+text:c="(\d+)")?\s*/>'), (m) => ' ' * (int.tryParse(m[1] ?? '1') ?? 1))
      .replaceAll(RegExp(r'</text:(p|h)>'), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  return _unescape(s);
}

int? _winAnsi(int rune) {
  if (rune >= 0x20 && rune <= 0x7E) return rune;
  if (rune >= 0xA0 && rune <= 0xFF) return rune;
  const extra = {
    0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
    0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
    0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
    0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
  };
  return extra[rune];
}

/// Grava [text] num PDF A4 simples (Courier 10, margens de 2 cm), quebrando as
/// linhas longas nas palavras. Devolve quantos caracteres não existem na fonte
/// (saem como "?").
Future<int> writeTextPdf(String text, String out) async {
  const cols = 86, rows = 62, size = 10.0, lead = 12.0, left = 56.7, top = 785.0;
  final lines = <String>[];
  for (var line in text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    line = line.replaceAll('\t', '    ').replaceAll('\f', '');
    if (line.isEmpty) {
      lines.add('');
      continue;
    }
    while (line.runes.length > cols) {
      final chars = line.runes.toList();
      var cut = cols;
      for (var i = cols; i > cols ~/ 3; i--) {
        if (chars[i] == 0x20) {
          cut = i;
          break;
        }
      }
      lines.add(String.fromCharCodes(chars.take(cut)));
      line = String.fromCharCodes(chars.skip(cut)).trimLeft();
    }
    lines.add(line);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) lines.add('');
  var missing = 0;
  final pages = <List<int>>[];
  for (var i = 0; i < lines.length; i += rows) {
    final b = BytesBuilder();
    b.add(latin1.encode('BT /F1 $size Tf $lead TL $left $top Td\n'));
    for (final line in lines.skip(i).take(rows)) {
      b.addByte(0x28);
      for (final r in line.runes) {
        var c = _winAnsi(r);
        if (c == null) {
          missing++;
          c = 0x3F;
        }
        if (c == 0x28 || c == 0x29 || c == 0x5C) b.addByte(0x5C);
        b.addByte(c);
      }
      b.add(latin1.encode(") '\n"));
    }
    b.add(latin1.encode('ET\n'));
    pages.add(b.toBytes());
  }
  final file = BytesBuilder();
  final offsets = <int>[];
  void obj(List<int> body) {
    offsets.add(file.length);
    file.add(latin1.encode('${offsets.length} 0 obj\n'));
    file.add(body);
    file.add(latin1.encode('\nendobj\n'));
  }

  file.add(latin1.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'));
  // 1 catálogo, 2 árvore de páginas, 3 fonte, depois (página, conteúdo) por página.
  obj(latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  obj(latin1.encode('<< /Type /Pages /Count ${pages.length} /Kids [${[for (var i = 0; i < pages.length; i++) '${4 + i * 2} 0 R'].join(' ')}] >>'));
  obj(latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>'));
  for (var i = 0; i < pages.length; i++) {
    obj(latin1.encode('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + i * 2} 0 R >>'));
    obj([...latin1.encode('<< /Length ${pages[i].length} >>\nstream\n'), ...pages[i], ...latin1.encode('endstream')]);
  }
  final xref = file.length;
  file.add(latin1.encode('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n'));
  for (final o in offsets) {
    file.add(latin1.encode('${o.toString().padLeft(10, '0')} 00000 n \n'));
  }
  file.add(latin1.encode('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n'));
  await File(out).writeAsBytes(file.toBytes());
  return missing;
}

/// Lê um arquivo de texto: UTF-8 (com ou sem marca), UTF-16 ou, se não for
/// nenhum dos dois, o padrão antigo do Windows (Latin-1).
String readTextFile(String path) {
  final b = File(path).readAsBytesSync();
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return utf8.decode(b.sublist(3), allowMalformed: true);
  if (b.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
    final le = b[0] == 0xFF;
    final d = ByteData.sublistView(b);
    return String.fromCharCodes([for (var i = 2; i + 1 < b.length; i += 2) d.getUint16(i, le ? Endian.little : Endian.big)]);
  }
  try {
    return utf8.decode(b);
  } on FormatException {
    return latin1.decode(b);
  }
}
