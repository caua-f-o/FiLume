import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart' show FfError;
import 'pdf.dart';
import 'pdfium.dart';

// Verificação de um PDF: acessibilidade (leitores de tela) e arquivamento de
// longo prazo (os requisitos principais do PDF/A).
//
// A lista de verificações foi levantada a partir dos módulos de acessibilidade
// e de preflight do PdfCraft (https://github.com/storytold/pdfcraft, MIT OU
// Apache-2.0, © 2026 ArtCraft Team e colaboradores do PdfCraft). O código é
// novo e lê a estrutura do arquivo pelo qpdf. É uma verificação dos pontos
// principais, não uma certificação de conformidade.

enum CheckLevel { ok, warn, fail, info }

enum CheckGroup {
  access('Acessibilidade'),
  archive('Arquivamento (PDF/A)');

  const CheckGroup(this.label);
  final String label;
}

class PdfCheck {
  PdfCheck(this.group, this.id, this.title, this.level, this.detail, [this.tip]);
  final CheckGroup group;
  final String id, title, detail;
  final CheckLevel level;

  /// Como resolver, quando há o que fazer.
  final String? tip;
}

class PdfInspection {
  PdfInspection(this.file, this.pages, this.pdfVersion, this.checks, this.declaredPdfA);
  final String file;
  final int pages;
  final String pdfVersion;
  final List<PdfCheck> checks;

  /// "PDF/A-2b" etc., se o arquivo se declara assim.
  final String? declaredPdfA;

  int count(CheckGroup g, CheckLevel l) => checks.where((c) => c.group == g && c.level == l).length;
}

bool _ok(int code) => code == 0 || code == 3;

String _text(dynamic v) {
  if (v is! String) return '';
  if (v.startsWith('u:')) return v.substring(2);
  if (v.startsWith('b:')) {
    final hex = v.substring(2);
    return String.fromCharCodes([for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
  }
  return v;
}

/// Examina [file]. Com [pdfium], também conta as páginas sem texto (digitalizações).
Future<PdfInspection> inspectPdf(PdfTools tools, String file, {Pdfium? pdfium}) async {
  final r = await Process.run(
    tools.qpdf,
    ['--json=2', '--json-stream-data=none', '--json-key=qpdf', '--json-key=encrypt', '--json-key=pages', file],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (!_ok(r.exitCode)) {
    final err = r.stderr.toString();
    throw FfError(
      err.contains('password') ? '"${p.basename(file)}" é protegido por senha. Remova a senha antes (ferramenta Senha).' : 'Não foi possível ler "${p.basename(file)}".',
      err,
    );
  }
  final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  final q = j['qpdf'] as List;
  final version = '${(q[0] as Map)['pdfversion'] ?? ''}';
  final objects = (q[1] as Map).cast<String, dynamic>();
  final pages = (j['pages'] as List?)?.length ?? 0;

  Map<String, dynamic>? dictOf(dynamic v) {
    if (v is String && v.endsWith(' R')) {
      final o = objects['obj:$v'];
      if (o is! Map) return null;
      final d = o['value'] ?? (o['stream'] is Map ? (o['stream'] as Map)['dict'] : null);
      return d is Map ? d.cast<String, dynamic>() : null;
    }
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  dynamic deref(dynamic v) {
    if (v is String && v.endsWith(' R')) {
      final o = objects['obj:$v'];
      return o is Map ? o['value'] : null;
    }
    return v;
  }

  final trailer = dictOf((objects['trailer'] as Map?)?['value']) ?? const {};
  final root = dictOf(trailer['/Root']) ?? const {};
  final info = dictOf(trailer['/Info']) ?? const {};

  // Todos os dicionários do arquivo (inclusive os dos fluxos).
  final dicts = <Map<String, dynamic>>[];
  for (final e in objects.entries) {
    if (!e.key.startsWith('obj:')) continue;
    final o = e.value;
    if (o is! Map) continue;
    final d = o['value'] is Map ? o['value'] : (o['stream'] is Map ? (o['stream'] as Map)['dict'] : null);
    if (d is Map) dicts.add(d.cast<String, dynamic>());
  }
  void walk(dynamic v, void Function(Map<String, dynamic>) f) {
    if (v is Map) {
      f(v.cast<String, dynamic>());
      for (final x in v.values) {
        walk(x, f);
      }
    } else if (v is List) {
      for (final x in v) {
        walk(x, f);
      }
    }
  }

  // ---- metadados XMP
  var xmp = '';
  final metaRef = root['/Metadata'];
  if (metaRef is String) {
    final m = RegExp(r'^(\d+) (\d+) R$').firstMatch(metaRef);
    if (m != null) {
      final x = await Process.run(tools.qpdf, ['--json=2', '--json-stream-data=inline', '--json-object=${m[1]},${m[2]}', '--json-key=qpdf', file],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      if (_ok(x.exitCode)) {
        try {
          final objs = ((jsonDecode(x.stdout as String) as Map)['qpdf'] as List)[1] as Map;
          final data = ((objs['obj:$metaRef'] as Map?)?['stream'] as Map?)?['data'];
          if (data is String) xmp = utf8.decode(base64.decode(data), allowMalformed: true);
        } catch (_) {}
      }
    }
  }
  String? declared;
  final part = RegExp(r'pdfaid:part(?:>|=")\s*(\d)').firstMatch(xmp)?[1];
  if (part != null) {
    final conf = RegExp(r'pdfaid:conformance(?:>|=")\s*([A-Za-z])').firstMatch(xmp)?[1] ?? '';
    declared = 'PDF/A-$part${conf.toLowerCase()}';
  }

  // ---- fontes
  final notEmbedded = <String>{};
  var fonts = 0;
  bool embedded(Map<String, dynamic>? desc) => desc != null && (desc.containsKey('/FontFile') || desc.containsKey('/FontFile2') || desc.containsKey('/FontFile3'));
  for (final d in dicts) {
    if (d['/Type'] != '/Font') continue;
    final sub = d['/Subtype'];
    if (sub == '/Type3' || sub == '/CIDFontType0' || sub == '/CIDFontType2') continue;
    fonts++;
    var ok = false;
    if (sub == '/Type0') {
      final kids = deref(d['/DescendantFonts']);
      final kid = kids is List && kids.isNotEmpty ? dictOf(kids.first) : null;
      ok = embedded(dictOf(kid?['/FontDescriptor']));
    } else {
      ok = embedded(dictOf(d['/FontDescriptor']));
    }
    if (!ok) notEmbedded.add('${d['/BaseFont'] ?? '/?'}'.substring(1).replaceFirst(RegExp(r'^[A-Z]{6}\+'), ''));
  }

  // ---- o resto da varredura
  var images = 0, figures = 0, figuresNoAlt = 0, scripts = 0, media = 0, lzw = 0, widgets = 0, widgetsNoLabel = 0;
  for (final d in dicts) {
    if (d['/Subtype'] == '/Image') images++;
    final filter = d['/Filter'];
    if (filter == '/LZWDecode' || (filter is List && filter.contains('/LZWDecode'))) lzw++;
    walk(d, (m) {
      if (m['/S'] == '/JavaScript' || m.containsKey('/JS')) scripts++;
      if (m['/S'] == '/Figure') {
        figures++;
        if (_text(m['/Alt']).trim().isEmpty && _text(m['/ActualText']).trim().isEmpty) figuresNoAlt++;
      }
      final st = m['/Subtype'];
      if (m['/Type'] == '/Annot' || m.containsKey('/Rect')) {
        if (st == '/Movie' || st == '/Sound' || st == '/Screen' || st == '/3D' || st == '/RichMedia') media++;
        if (st == '/Widget') {
          widgets++;
          var label = _text(m['/TU']);
          final parent = dictOf(m['/Parent']);
          if (label.isEmpty && parent != null) label = _text(parent['/TU']);
          if (label.trim().isEmpty) widgetsNoLabel++;
        }
      }
    });
  }
  final names = dictOf(root['/Names']) ?? const {};
  if (names.containsKey('/JavaScript')) scripts++;
  final attachments = names.containsKey('/EmbeddedFiles');
  final encrypt = (j['encrypt'] as Map?) ?? const {};
  final encrypted = encrypt['encrypted'] == true;
  final canRead = (encrypt['capabilities'] as Map?)?['accessibility'] != false;

  // ---- páginas sem texto
  int? noText;
  if (pdfium != null && !encrypted) {
    try {
      final b = PdfiumBackend.open(file, pdfium);
      try {
        noText = 0;
        final n = b.pageCount;
        // Em documentos enormes, uma amostra espalhada já responde.
        final step = n > 60 ? (n / 60).ceil() : 1;
        for (var i = 0; i < n; i += step) {
          if (!b.chars(i).any((c) => c.code > 32)) noText = noText! + 1;
        }
        if (step > 1) noText = (noText! * step).clamp(0, n);
      } finally {
        b.close();
      }
    } catch (_) {
      noText = null;
    }
  }

  final checks = <PdfCheck>[];
  void add(CheckGroup g, String id, String title, CheckLevel level, String detail, [String? tip]) => checks.add(PdfCheck(g, id, title, level, detail, tip));
  const a = CheckGroup.access, v = CheckGroup.archive;
  String plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

  // ============================================================ acessibilidade
  final marked = (dictOf(root['/MarkInfo']) ?? const {})['/Marked'] == true;
  final tagged = marked && root.containsKey('/StructTreeRoot');
  add(a, 'tags', 'Estrutura marcada (tags)', tagged ? CheckLevel.ok : CheckLevel.fail,
      tagged ? 'O documento diz o que é título, parágrafo, lista e tabela.' : 'O documento não tem tags: o leitor de tela não sabe o que é título, parágrafo ou tabela, nem a ordem de leitura.',
      tagged ? null : 'Exporte de novo pelo programa de origem com a opção "PDF marcado" (no Word: Opções → Marcas de estrutura; no LibreOffice: PDF marcado).');
  final lang = _text(root['/Lang']).trim();
  add(a, 'lang', 'Idioma do documento', lang.isNotEmpty ? CheckLevel.ok : CheckLevel.fail,
      lang.isNotEmpty ? 'Idioma declarado: $lang.' : 'O idioma não está declarado; o leitor de tela pode ler com a pronúncia errada.',
      lang.isNotEmpty ? null : 'Defina o idioma no programa de origem antes de exportar.');
  final title = _text(info['/Title']).trim().isNotEmpty ? _text(info['/Title']).trim() : (RegExp(r'<dc:title>[\s\S]*?<rdf:li[^>]*>([^<]+)<').firstMatch(xmp)?[1]?.trim() ?? '');
  final showTitle = (dictOf(root['/ViewerPreferences']) ?? const {})['/DisplayDocTitle'] == true;
  add(a, 'title', 'Título', title.isEmpty ? CheckLevel.fail : (showTitle ? CheckLevel.ok : CheckLevel.warn),
      title.isEmpty ? 'O documento não tem título; quem usa leitor de tela ouve só o nome do arquivo.' : (showTitle ? 'Título: "$title".' : 'Título: "$title", mas a janela mostra o nome do arquivo em vez dele.'),
      title.isEmpty ? 'Preencha o título nas propriedades do documento.' : null);
  if (noText != null) {
    add(a, 'text', 'Texto de verdade nas páginas', noText == 0 ? CheckLevel.ok : CheckLevel.fail,
        noText == 0 ? 'Todas as páginas têm texto que pode ser lido e pesquisado.' : '${plural(noText, 'página não tem', 'páginas não têm')} texto (digitalização ou imagem).',
        noText == 0 ? null : 'Passe o OCR no FiPDF (bandeja → OCR) para as páginas ganharem texto.');
  }
  if (figures > 0 || images > 0) {
    if (!tagged) {
      add(a, 'alt', 'Descrição das imagens', images > 0 ? CheckLevel.warn : CheckLevel.info,
          '${plural(images, 'imagem', 'imagens')} no arquivo; sem tags, nenhuma tem descrição para quem não enxerga.');
    } else {
      add(a, 'alt', 'Descrição das imagens', figuresNoAlt == 0 ? CheckLevel.ok : CheckLevel.fail,
          figuresNoAlt == 0 ? (figures == 0 ? 'As imagens estão marcadas como decoração.' : 'Todas as ${plural(figures, 'figura tem', 'figuras têm')} descrição.') : '$figuresNoAlt de ${plural(figures, 'figura', 'figuras')} sem texto alternativo.',
          figuresNoAlt == 0 ? null : 'Adicione o texto alternativo a cada imagem no programa de origem.');
    }
  }
  final outlines = dictOf(root['/Outlines']);
  final hasOutline = outlines != null && outlines.containsKey('/First');
  if (pages >= 10 || hasOutline) {
    add(a, 'outline', 'Marcadores (sumário)', hasOutline ? CheckLevel.ok : CheckLevel.warn,
        hasOutline ? 'O documento tem marcadores para navegar.' : 'Documento de $pages páginas sem marcadores: fica difícil navegar.');
  }
  if (widgets > 0) {
    add(a, 'fields', 'Rótulo dos campos de formulário', widgetsNoLabel == 0 ? CheckLevel.ok : CheckLevel.warn,
        widgetsNoLabel == 0 ? 'Todos os campos têm descrição.' : '$widgetsNoLabel de ${plural(widgets, 'campo', 'campos')} sem descrição para o leitor de tela.');
  }
  if (encrypted) {
    add(a, 'perm', 'Permissão para leitores de tela', canRead ? CheckLevel.ok : CheckLevel.fail,
        canRead ? 'A proteção do arquivo deixa leitores de tela lerem o texto.' : 'A proteção do arquivo bloqueia leitores de tela.');
  }

  // =============================================================== arquivamento
  add(v, 'declared', 'Declaração de PDF/A', declared != null ? CheckLevel.ok : CheckLevel.info,
      declared != null ? 'O arquivo se declara $declared.' : 'O arquivo não se declara PDF/A. Os itens abaixo mostram o que faltaria.');
  add(v, 'fonts', 'Fontes dentro do arquivo', notEmbedded.isEmpty ? CheckLevel.ok : CheckLevel.fail,
      notEmbedded.isEmpty
          ? (fonts == 0 ? 'O arquivo não usa fontes.' : 'Todas as ${plural(fonts, 'fonte está embutida', 'fontes estão embutidas')}.')
          : '${plural(notEmbedded.length, 'fonte não está embutida', 'fontes não estão embutidas')}: ${notEmbedded.take(6).join(', ')}${notEmbedded.length > 6 ? '…' : ''}. Em outro computador o texto pode mudar de cara.',
      notEmbedded.isEmpty ? null : 'Exporte de novo com a opção de embutir as fontes.');
  add(v, 'encrypt', 'Sem senha nem restrições', encrypted ? CheckLevel.fail : CheckLevel.ok,
      encrypted ? 'O arquivo é protegido; PDF/A não permite criptografia.' : 'O arquivo não é protegido.', encrypted ? 'Remova a senha no FiPDF (ferramenta Senha).' : null);
  add(v, 'xmp', 'Metadados XMP', xmp.isNotEmpty ? CheckLevel.ok : CheckLevel.fail,
      xmp.isNotEmpty ? 'O arquivo traz os metadados no formato XMP.' : 'Faltam os metadados no formato XMP, exigidos pelo PDF/A.');
  final intents = deref(root['/OutputIntents']);
  add(v, 'color', 'Perfil de cor', intents is List && intents.isNotEmpty ? CheckLevel.ok : CheckLevel.warn,
      intents is List && intents.isNotEmpty ? 'O arquivo declara o perfil de cor de saída.' : 'Sem perfil de cor de saída: as cores podem variar de uma tela ou impressora para outra.');
  add(v, 'script', 'Sem scripts', scripts == 0 ? CheckLevel.ok : CheckLevel.fail,
      scripts == 0 ? 'O arquivo não tem JavaScript.' : 'O arquivo tem JavaScript (${plural(scripts, 'trecho', 'trechos')}), o que o PDF/A proíbe.');
  add(v, 'media', 'Sem áudio, vídeo ou 3D', media == 0 ? CheckLevel.ok : CheckLevel.fail,
      media == 0 ? 'Nada de mídia embutida.' : '${plural(media, 'elemento', 'elementos')} de áudio, vídeo ou 3D, que o PDF/A proíbe.');
  if (attachments) {
    add(v, 'attach', 'Arquivos anexados', part == '3' ? CheckLevel.ok : CheckLevel.warn,
        part == '3' ? 'Há anexos, permitidos no PDF/A-3.' : 'O arquivo tem anexos; só o PDF/A-3 aceita qualquer tipo de anexo.');
  }
  if (lzw > 0) add(v, 'lzw', 'Compressão LZW', CheckLevel.fail, '${plural(lzw, 'trecho usa', 'trechos usam')} a compressão LZW, que o PDF/A proíbe.');

  return PdfInspection(file, pages, version, checks, declared);
}

/// Relatório em texto simples.
String inspectionAsText(PdfInspection r) {
  const mark = {CheckLevel.ok: '[ok]', CheckLevel.warn: '[atenção]', CheckLevel.fail: '[falta]', CheckLevel.info: '[info]'};
  final sb = StringBuffer('Verificação de ${p.basename(r.file)}\r\n${r.pages} ${r.pages == 1 ? 'página' : 'páginas'} · PDF ${r.pdfVersion}\r\n');
  for (final g in CheckGroup.values) {
    sb.write('\r\n${g.label}\r\n');
    for (final c in r.checks.where((c) => c.group == g)) {
      sb.write('${mark[c.level]} ${c.title}: ${c.detail}\r\n');
      if (c.tip != null) sb.write('    Como resolver: ${c.tip}\r\n');
    }
  }
  sb.write('\r\nEsta é uma verificação dos pontos principais, não uma certificação de conformidade.\r\n');
  return sb.toString();
}
