// Teste do editor de PDF: dart run tool/editor_test.dart
// Parte 1 (roda em qualquer lugar): a lógica do editor, com um arquivo de mentira.
// Parte 2 (precisa do PDFium): abre, edita, desenha e grava PDFs de verdade.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:filume/core/editor.dart';
import 'package:path/path.dart' as p;
import 'package:filume/core/pdf.dart';
import 'package:filume/core/pdfium.dart';

var bad = 0;
void check(String label, bool ok, [String extra = '']) {
  print('${ok ? 'OK' : 'FALHA'} $label $extra');
  if (!ok) bad++;
}

/// Arquivo de mentira: guarda os objetos em listas e mede texto a 0,5×tamanho por letra.
class FakeBackend implements EditBackend {
  FakeBackend(List<List<PdfObj>> pages) : pages = [for (final p in pages) List.of(p)];
  final List<List<PdfObj>> pages;
  bool closed = false;
  static int opened = 0;

  PdfObj _at(PdfObj o, int i, {double dx = 0, double dy = 0}) => PdfObj(
      index: i, kind: o.kind, l: o.l + dx, t: o.t + dy, r: o.r + dx, b: o.b + dy, text: o.text, size: o.size,
      baseX: o.baseX + dx, baseY: o.baseY + dy, upright: o.upright, font: o.font, bold: o.bold, italic: o.italic, embedded: o.embedded, color: o.color);

  @override
  int get pageCount => pages.length;
  @override
  (double, double) pageSize(int page) => (595, 842);
  @override
  List<PdfObj> objects(int page) => [for (var i = 0; i < pages[page].length; i++) _at(pages[page][i], i)];
  @override
  void move(int page, List<int> indices, double dx, double dy) {
    for (final i in indices) {
      pages[page][i] = _at(pages[page][i], i, dx: dx, dy: dy);
    }
  }

  @override
  void scale(int page, List<int> indices, double sx, double sy, double ax, double ay) {
    for (final i in indices) {
      final o = pages[page][i];
      pages[page][i] = PdfObj(index: i, kind: o.kind, l: ax + (o.l - ax) * sx, t: ay + (o.t - ay) * sy, r: ax + (o.r - ax) * sx, b: ay + (o.b - ay) * sy);
    }
  }

  @override
  void remove(int page, List<int> indices) {
    for (final i in indices.toList()..sort((a, b) => b.compareTo(a))) {
      pages[page].removeAt(i);
    }
  }

  @override
  bool addText(int page, List<TextLine> lines, FontSpec font, double size, int color) {
    final src = font.fromObject == null ? null : pages[page][font.fromObject!];
    if (src != null && lines.any((l) => l.text.contains('Ω'))) return false; // a fonte "do documento" não tem Ω
    for (final l in lines) {
      final w = textWidth(page, font, size, l.text);
      pages[page].add(PdfObj(
          index: 0, kind: ObjKind.text, l: l.x, t: l.baseline - size * 0.8, r: l.x + w, b: l.baseline + size * 0.2, text: l.text, size: size,
          baseX: l.x, baseY: l.baseline, font: src?.font ?? font.standard!, bold: src?.bold ?? font.standard!.contains('Bold'),
          embedded: src?.embedded ?? false, color: color));
    }
    return true;
  }

  @override
  double textWidth(int page, FontSpec font, double size, String text) => text.length * size * 0.5;
  @override
  void addPath(int page, PathSpec path) {
    final xs = [for (final s in path.segs) for (var i = 1; i + 1 < s.length; i += 2) s[i]];
    final ys = [for (final s in path.segs) for (var i = 2; i < s.length; i += 2) s[i]];
    pages[page].add(PdfObj(index: 0, kind: ObjKind.path, l: xs.reduce((a, b) => a < b ? a : b), t: ys.reduce((a, b) => a < b ? a : b),
        r: xs.reduce((a, b) => a > b ? a : b), b: ys.reduce((a, b) => a > b ? a : b)));
  }

  @override
  void addImage(int page, Uint8List rgba, int width, int height, double l, double t, double w, double h) =>
      pages[page].add(PdfObj(index: 0, kind: ObjKind.image, l: l, t: t, r: l + w, b: t + h));
  @override
  RenderedPage render(int page, double scale) => RenderedPage(Uint8List(4), 1, 1);
  @override
  void save(String path) {}
  @override
  void close() => closed = true;
}

/// Uma linha de texto partida em palavras soltas, como os PDFs costumam guardar.
List<PdfObj> words(String line, double x, double baseline, {double size = 12, String font = 'ABCDEF+Arial', bool embedded = true, bool bold = false, int color = 0xFF000000}) {
  final out = <PdfObj>[];
  var cx = x;
  for (final w in line.split(' ')) {
    final width = w.length * size * 0.5;
    out.add(PdfObj(index: 0, kind: ObjKind.text, l: cx, t: baseline - size * 0.8, r: cx + width, b: baseline + size * 0.2, text: w, size: size,
        baseX: cx, baseY: baseline, font: font, embedded: embedded, bold: bold, color: color));
    cx += width + size * 0.5;
  }
  return out;
}

void logic() {
  // Geometria
  const m = Mat(0, -1, 1, 0, 10, 20);
  final (x, y) = m.then(m.inverse()).apply(3, 7);
  check('matriz: ida e volta', (x - 3).abs() < 1e-9 && (y - 7).abs() < 1e-9);
  final (sx, sy) = Mat.scaleAbout(2, 3, 10, 10).apply(10, 10);
  check('matriz: escala mantém a âncora', sx == 10 && sy == 10);

  // Fontes
  check('nomes das fontes padrão', FontSpec.of(FontFamily.sans).standard == 'Helvetica' && FontSpec.of(FontFamily.sans, bold: true, italic: true).standard == 'Helvetica-BoldOblique' &&
      FontSpec.of(FontFamily.serif).standard == 'Times-Roman' && FontSpec.of(FontFamily.serif, italic: true).standard == 'Times-Italic' && FontSpec.of(FontFamily.mono, bold: true).standard == 'Courier-Bold');
  check('família pelo nome', familyOf('ABCDEF+TimesNewRomanPSMT') == FontFamily.serif && familyOf('Calibri') == FontFamily.sans && familyOf('CourierNew') == FontFamily.mono && familyOf('OpenSans-Regular') == FontFamily.sans);
  check('nome de fonte legível', fontDisplayName('ABCDEF+Arial-BoldMT') == 'Arial Bold', fontDisplayName('ABCDEF+Arial-BoldMT'));
  check('caracteres suportados', Editor.unsupported('ação — “ok” 你好 Ω') == '你好Ω', Editor.unsupported('ação — “ok” 你好 Ω'));

  // Parágrafos: título, parágrafo de 3 linhas (a última curta), outro parágrafo, e uma segunda coluna.
  final objs = <PdfObj>[
    ...words('Contrato de locacao', 72, 100, size: 18, bold: true),
    ...words('Este contrato estabelece as condicoes gerais', 72, 140),
    ...words('para a locacao do imovel descrito abaixo e', 72, 154.4),
    ...words('seus anexos.', 72, 168.8),
    ...words('O prazo sera de doze meses contados da data', 72, 197.6),
    ...words('de assinatura deste documento pelas partes.', 72, 212),
    ...words('Coluna da direita', 400, 140),
    PdfObj(index: 0, kind: ObjKind.image, l: 72, t: 300, r: 272, b: 400),
    PdfObj(index: 0, kind: ObjKind.path, l: 0, t: 0, r: 595, b: 842),
  ];
  final blocks = buildBlocks([for (var i = 0; i < objs.length; i++) FakeBackend([objs])._at(objs[i], i)]);
  check('parágrafos reconstruídos', blocks.length == 4 && blocks[0].text == 'Contrato de locacao' && blocks[1].lines.length == 3 &&
      blocks[1].text == 'Este contrato estabelece as condicoes gerais para a locacao do imovel descrito abaixo e seus anexos.' &&
      blocks.any((b) => b.text == 'Coluna da direita') && blocks.any((b) => b.lines.length == 2 && b.text.startsWith('O prazo')),
      blocks.map((b) => '[${b.lines.length}] ${b.text}').join(' | '));
  final para = blocks.firstWhere((b) => b.lines.length == 3);
  check('entrelinha e alinhamento', (para.leading - 14.4).abs() < 0.01 && para.align == HAlign.left);

  // Quebra de linha
  final lines = layoutText((s) => s.length * 6.0, 'um dois tres quatro cinco\nseis', x: 10, firstBaseline: 100, width: 60, leading: 14);
  check('quebra de linha', lines.map((l) => l.text).join('|') == 'um dois|tres|quatro|cinco|seis' && lines[1].baseline == 114 && lines.last.baseline == 156,
      lines.map((l) => '${l.text}@${l.baseline}').join(' '));
  final right = layoutText((s) => s.length * 6.0, 'abc', x: 10, firstBaseline: 0, width: 60, leading: 14, align: HAlign.right);
  final center = layoutText((s) => s.length * 6.0, 'abc', x: 10, firstBaseline: 0, width: 60, leading: 14, align: HAlign.center);
  check('alinhamento à direita e ao centro', right.single.x == 52 && center.single.x == 31);

  // Editor: editar, fonte original × substituta, desfazer e refazer
  FakeBackend.opened = 0;
  final ed = Editor(() {
    FakeBackend.opened++;
    return FakeBackend([objs]);
  });
  final count0 = ed.page(0).objs.length;
  final blk = ed.page(0).blocks.firstWhere((b) => b.lines.length == 3);
  final hit = ed.page(0).hit(0, 100, 150);
  check('clique acha o parágrafo', hit != null && hit.isText && hit.block!.lines.length == 3);
  check('clique acha a imagem, mas não o fundo da página', ed.page(0).hit(0, 100, 350)?.kind == ObjKind.image && ed.page(0).hit(0, 500, 700) == null);

  // Mesmo vocabulário: reaproveita a fonte do documento
  var op = ed.editBlock(0, blk, 'Este contrato estabelece as condicoes para a locacao do imovel.', TextStyleSpec.of(blk));
  check('texto com letras que a fonte já tem: mantém a fonte original', op.font.fromObject != null && op.fallback != null);
  ed.apply(op);
  var now = ed.page(0).blocks.firstWhere((b) => b.text.startsWith('Este contrato'));
  check('parágrafo refeito dentro da mesma largura', now.text == 'Este contrato estabelece as condicoes para a locacao do imovel.' && now.lines.length == 2 &&
      now.r <= blk.r + 0.01 && (now.lines.first.baseline - 140).abs() < 0.01 && now.first.font == 'ABCDEF+Arial' && !op.substituted,
      '${now.lines.length} linhas, fonte ${now.first.font}');
  check('objetos antigos saíram', ed.page(0).objs.length == count0 - blk.indices.length + 2);

  // Letra que a fonte embutida não tem: troca por uma padrão
  op = ed.editBlock(0, now, 'Novo texto com Zebra e Xadrez.', TextStyleSpec.of(now));
  check('letra nova (Z, X): usa fonte padrão parecida', op.font.standard == 'Helvetica' && op.fallback == null, op.font.key);
  ed.apply(op);
  // Fonte "tem" a letra pelo vocabulário, mas não consegue escrever: cai na reserva ao aplicar
  final other = ed.page(0).blocks.firstWhere((b) => b.text.startsWith('O prazo'));
  final cheat = TextOp(0, lines: [const TextLine('Ω', 72, 197.6)], font: FontSpec.reuse(other.first.index), size: 12, color: 0xFF000000,
      remove: other.indices, fallback: FontSpec.of(FontFamily.sans), fallbackLines: [const TextLine('?', 72, 197.6)]);
  ed.apply(cheat);
  check('fonte original falha ao escrever: entra a reserva', cheat.substituted && ed.page(0).blocks.any((b) => b.text == '?'));

  // Desfazer / refazer
  final before = ed.page(0).objs.length;
  check('desfazer volta um passo', ed.undo() == 0 && ed.page(0).blocks.any((b) => b.text.startsWith('O prazo')) && ed.canRedo);
  ed.undo();
  ed.undo();
  check('desfazer tudo: página como era', ed.page(0).objs.length == count0 && !ed.canUndo && ed.page(0).blocks.firstWhere((b) => b.lines.length == 3).text.startsWith('Este contrato estabelece as condicoes gerais'));
  ed.redo();
  ed.redo();
  ed.redo();
  check('refazer tudo: mesmo resultado', ed.page(0).objs.length == before && ed.page(0).blocks.any((b) => b.text == '?') && !ed.canRedo);
  check('cada desfazer reabriu o arquivo', FakeBackend.opened == 4, '${FakeBackend.opened}');

  // Mover, excluir, inserir
  final img = ed.page(0).hit(0, 100, 350)!;
  ed.apply(MoveOp(0, img.indices, 50, -20));
  final moved = ed.page(0).hit(0, 150, 330)!;
  check('mover', moved.kind == ObjKind.image && moved.l == 122 && moved.t == 280);
  ed.apply(ScaleOp(0, moved.indices, 0.5, 0.5, moved.l, moved.t));
  final small = ed.page(0).hit(0, 130, 290)!;
  check('redimensionar pela âncora', small.l == 122 && small.r == 222 && small.b == 330);
  ed.apply(DeleteOp(0, small.indices));
  check('excluir', ed.page(0).hit(0, 130, 290) == null);
  final t = ed.newText(0, 'Observação: válido até 2027 — “urgente”', TextStyleSpec(size: 10, color: 0xFFCC0000), 72, 500, 200);
  ed.apply(t);
  final added = ed.page(0).hit(0, 80, 505)!;
  check('texto novo quebra na largura da caixa', added.isText && added.block!.lines.length == 2 && added.block!.first.color == 0xFFCC0000 && t.font.standard == 'Helvetica',
      '${added.block!.lines.length} linhas');
  ed.apply(PathOp(0, PathSpec.rect(300, 500, 400, 540, fill: 0x66FFEB3B, multiply: true), 'Marca-texto'));
  ed.apply(PathOp(0, PathSpec.line(300, 600, 400, 650, stroke: 0xFF000000, width: 2, arrow: true), 'Seta'));
  ed.apply(ImageOp(0, Uint8List(16), 2, 2, 300, 700, 50, 50));
  check('formas e imagem entram como objetos', ed.page(0).hit(0, 350, 520)?.kind == ObjKind.path && ed.page(0).hit(0, 320, 720)?.kind == ObjKind.image);
  check('seta tem a ponta', PathSpec.line(0, 0, 100, 0, stroke: 1, arrow: true).segs.length == 6 && PathSpec.ellipse(0, 0, 10, 10).segs.length == 6);
  ed.close();
}

Future<void> real(Pdfium pdfium) async {
  final tools = (await PdfTools.locate())!;
  final dir = await Directory.systemTemp.createTemp('filume_edtest_');
  final d = dir.path;
  // Documento de teste: título, um parágrafo de 3 linhas e um retângulo.
  File('$d/a.ps').writeAsStringSync('''
/Helvetica-Bold findfont 18 scalefont setfont 72 760 moveto (Contrato de teste) show
/Helvetica findfont 12 scalefont setfont
72 720 moveto (Este contrato estabelece as condicoes gerais para a) show
72 705.6 moveto (locacao do imovel descrito abaixo, incluindo todos os) show
72 691.2 moveto (seus anexos.) show
0.2 0.4 0.8 setrgbcolor 72 500 200 100 rectfill
showpage
/Helvetica findfont 12 scalefont setfont 72 720 moveto (Segunda pagina) show showpage
''');
  final gs = await Process.run(tools.gs!, ['-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=pdfwrite', '-sOutputFile=$d/a.pdf', '$d/a.ps']);
  if (gs.exitCode != 0) throw 'gs: ${gs.stderr}';

  final ed = Editor(() => PdfiumBackend.open('$d/a.pdf', pdfium));
  check('abre: 2 páginas A4', ed.pageCount == 2 && (ed.page(0).width - 612).abs() < 1 && (ed.page(0).height - 792).abs() < 1, '${ed.page(0).width}x${ed.page(0).height}');
  final blocks = ed.page(0).blocks;
  print('  objetos: ${ed.page(0).objs.map((o) => '${o.kind.name}${o.kind == ObjKind.text ? '(${o.text}|${o.font}|${o.size.toStringAsFixed(1)}|emb=${o.embedded})' : ''}').join(' ')}');
  final para = blocks.where((b) => b.lines.length == 3).firstOrNull;
  check('lê título e parágrafo de 3 linhas', blocks.length == 2 && para != null && blocks.any((b) => b.text == 'Contrato de teste' && b.first.bold && (b.size - 18).abs() < 0.2) &&
      para.text.startsWith('Este contrato estabelece') && (para.size - 12).abs() < 0.2,
      blocks.map((b) => '[${b.lines.length}|${b.size.toStringAsFixed(1)}|${b.first.bold}] ${b.text}').join(' | '));
  if (para == null) return;
  // Posição na tela: a 1ª linha está a 792-720 = 72 pt do topo.
  check('posições em coordenadas de tela', (para.lines.first.baseline - 72).abs() < 0.5 && (para.l - 72).abs() < 1.5, 'base ${para.lines.first.baseline} l ${para.l}');
  final rect = ed.page(0).hit(0, 150, 792 - 550);
  check('retângulo selecionável', rect?.kind == ObjKind.path && (rect!.l - 72).abs() < 1 && (rect.t - 192).abs() < 1, '${rect?.l},${rect?.t}');
  final w = ed.backend.textWidth(0, FontSpec.of(FontFamily.sans), 12, 'Este contrato');
  check('mede a largura do texto', (w - (para.lines.first.r - para.l) * 13 / 51).abs() < 8 && w > 50 && w < 90, w.toStringAsFixed(2));
  check('espaço tem largura', (ed.backend.textWidth(0, FontSpec.of(FontFamily.sans), 12, ' ') - 3.34).abs() < 0.4);

  int ink(RenderedPage r, int x0, int y0, int x1, int y1) {
    var n = 0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * r.width + x) * 4;
        if (r.bgra[i] < 200 || r.bgra[i + 1] < 200 || r.bgra[i + 2] < 200) n++;
      }
    }
    return n;
  }

  final r0 = ed.backend.render(0, 1);
  check('desenha a página', r0.width == 612 && r0.height == 792 && ink(r0, 60, 55, 400, 110) > 300 && ink(r0, 300, 300, 500, 500) == 0, '${ink(r0, 60, 55, 400, 110)} pontos de tinta');

  // Editar o parágrafo: texto com acentos, mais curto
  final op = ed.editBlock(0, para, 'Este contrato define as condições da locação, com início em março de 2027.', TextStyleSpec.of(para));
  ed.apply(op);
  final edited = ed.page(0).blocks.where((b) => b.text.contains('março')).firstOrNull;
  check('parágrafo editado, com acentos', edited != null && edited.text == 'Este contrato define as condições da locação, com início em março de 2027.' && edited.lines.length == 2 &&
      (edited.lines.first.baseline - 72).abs() < 0.5 && edited.r <= para.r + 2,
      '${edited?.lines.length} linhas · "${edited?.text}" · fonte ${edited?.first.font} · substituída=${op.substituted}');
  check('texto antigo saiu da página', !ed.page(0).blocks.any((b) => b.text.contains('anexos')));

  // Mudar estilo: negrito vermelho maior
  if (edited != null) {
    final st = TextStyleSpec.of(edited)
      ..bold = true
      ..color = 0xFFCC0000
      ..size = 14;
    ed.apply(ed.editBlock(0, edited, edited.text, st));
    final styled = ed.page(0).blocks.where((b) => b.text.contains('março')).firstOrNull;
    check('estilo: negrito, vermelho, 14 pt', styled != null && styled.first.bold && styled.first.color == 0xFFCC0000 && (styled.size - 14).abs() < 0.2,
        'bold=${styled?.first.bold} cor=${styled?.first.color.toRadixString(16)} tam=${styled?.size} fonte=${styled?.first.font}');
  }

  // Inserir texto, formas e imagem
  ed.apply(ed.newText(0, 'Observação: válido até 2027 — “urgente”', TextStyleSpec(size: 11), 72, 400, 540));
  check('texto novo', ed.page(0).blocks.any((b) => b.text.contains('Observação') && b.text.contains('“urgente”')), ed.page(0).blocks.map((b) => b.text).join(' | '));
  ed.apply(PathOp(0, PathSpec.rect(300, 100, 400, 130, fill: 0x80FFEB3B, multiply: true), 'Marca-texto'));
  ed.apply(PathOp(0, PathSpec.ellipse(320, 420, 420, 480, stroke: 0xFF00AA00, width: 2), 'Elipse'));
  ed.apply(PathOp(0, PathSpec.line(320, 520, 500, 560, stroke: 0xFF000000, width: 2, arrow: true), 'Seta'));
  ed.apply(PathOp(0, PathSpec.ink([100, 600, 120, 620, 140, 600, 160, 620], stroke: 0xFF0000AA), 'Caneta'));
  final px = Uint8List(40 * 20 * 4);
  for (var i = 0; i < px.length; i += 4) {
    px[i] = 255; // vermelho
    px[i + 3] = 255;
  }
  ed.apply(ImageOp(0, px, 40, 20, 450, 650, 80, 40));
  final img = ed.page(0).hit(0, 490, 670);
  check('imagem inserida no lugar', img?.kind == ObjKind.image && (img!.l - 450).abs() < 1 && (img.t - 650).abs() < 1 && (img.r - 530).abs() < 1 && (img.b - 690).abs() < 1,
      '${img?.l},${img?.t},${img?.r},${img?.b}');
  final r1 = ed.backend.render(0, 1);
  int red(RenderedPage r, int x, int y) => r.bgra[(y * r.width + x) * 4 + 2];
  int blue(RenderedPage r, int x, int y) => r.bgra[(y * r.width + x) * 4];
  check('imagem aparece vermelha, em pé', red(r1, 490, 670) > 200 && blue(r1, 490, 670) < 60);
  check('formas aparecem', ink(r1, 315, 415, 425, 485) > 100 && ink(r1, 315, 515, 505, 565) > 100 && ink(r1, 95, 595, 165, 625) > 30);

  // Mover e redimensionar a imagem; excluir o retângulo azul
  ed.apply(MoveOp(0, img!.indices, -100, 20));
  final moved = ed.page(0).hit(0, 390, 690);
  check('mover', moved?.kind == ObjKind.image && (moved!.l - 350).abs() < 1 && (moved.t - 670).abs() < 1, '${moved?.l},${moved?.t}');
  ed.apply(ScaleOp(0, moved!.indices, 2, 2, moved.l, moved.t));
  final big = ed.page(0).hit(0, 450, 720);
  check('redimensionar', big?.kind == ObjKind.image && (big!.r - 510).abs() < 1 && (big.b - 750).abs() < 1 && (big.l - 350).abs() < 1, '${big?.l},${big?.t},${big?.r},${big?.b}');
  final blueRect = ed.page(0).hit(0, 150, 242);
  ed.apply(DeleteOp(0, blueRect!.indices));
  check('excluir', ed.page(0).hit(0, 150, 242) == null && ink(ed.backend.render(0, 1), 80, 200, 260, 280) == 0);

  // Desfazer e refazer de verdade
  final n = ed.page(0).objs.length;
  ed.undo();
  check('desfazer: retângulo volta', ed.page(0).hit(0, 150, 242)?.kind == ObjKind.path);
  ed.redo();
  check('refazer', ed.page(0).objs.length == n && ed.page(0).hit(0, 150, 242) == null);

  // Página 2 intocada; gravar e conferir com qpdf e Ghostscript
  ed.apply(ed.newText(1, 'Rodapé da segunda página', TextStyleSpec(size: 9, family: FontFamily.serif, italic: true), 72, 760, 540));
  ed.backend.save('$d/out.pdf');
  ed.close();
  final chk = await Process.run(tools.qpdf, ['--check', '$d/out.pdf']);
  check('arquivo gravado é um PDF válido (qpdf)', chk.exitCode == 0, '${chk.stdout}${chk.stderr}'.trim().split('\n').last);
  await Process.run(tools.gs!, ['-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=txtwrite', '-sOutputFile=$d/out.txt', '$d/out.pdf']);
  final flat = (File('$d/out.txt').existsSync() ? utf8.decode(File('$d/out.txt').readAsBytesSync(), allowMalformed: true) : '')
      .replaceAll(RegExp(r'\s+'), ' ');
  check('Ghostscript lê o texto novo e não acha o antigo', flat.contains('condições da locação') && flat.contains('Observação') && flat.contains('Rodapé') &&
      flat.contains('Segunda pagina') && !flat.contains('anexos'), flat.replaceAll(RegExp(r'\s+'), ' ').trim());
  if (!flat.contains('condições da locação')) {
    // Diagnóstico: dicionários de fonte e trechos de texto do arquivo gravado.
    await Process.run(tools.qpdf, ['--qdf', '--object-streams=disable', '$d/out.pdf', '$d/out.qdf']);
    final q = latin1.decode(File('$d/out.qdf').readAsBytesSync());
    for (final m in RegExp(r'<<[^<>]*/Type /Font[^<>]*>>').allMatches(q)) {
      print('  fonte: ${m[0]!.replaceAll(RegExp(r'\s+'), ' ')}');
    }
    for (final m in RegExp(r'/F\w+ [\d.]+ Tf[^\n]*\n?[^\n]*\(.{0,40}').allMatches(q).take(12)) {
      print('  texto: ${m[0]!.replaceAll(RegExp(r'\s+'), ' ')}');
    }
  }
  final again = PdfiumBackend.open('$d/out.pdf', pdfium);
  final reopened = buildBlocks(again.objects(0));
  check('reabrir o arquivo gravado: edições estão lá', reopened.any((b) => b.text.contains('março de 2027')) && again.objects(0).any((o) => o.kind == ObjKind.image));
  again.close();

  // Página girada (90°): texto novo tem de sair em pé na tela
  await Process.run(tools.qpdf, ['$d/a.pdf', '--rotate=+90:1', '--', '$d/rot.pdf']);
  final rot = Editor(() => PdfiumBackend.open('$d/rot.pdf', pdfium));
  final pg = rot.page(0);
  check('página girada: tamanho de tela trocado', (pg.width - 792).abs() < 1 && (pg.height - 612).abs() < 1, '${pg.width}x${pg.height}');
  rot.apply(rot.newText(0, 'Texto em pé na página girada', TextStyleSpec(size: 14), 100, 300, 700));
  final up = rot.page(0).blocks.where((b) => b.text.contains('Texto em pé')).firstOrNull;
  check('página girada: texto novo sai na horizontal e no lugar', up != null && (up.r - up.l) > 5 * (up.b - up.t) && (up.l - 100).abs() < 2 && (up.t - 300).abs() < 4,
      up == null ? 'não achou (${rot.page(0).objs.where((o) => o.kind == ObjKind.text).map((o) => '${o.text}:${o.upright}').join(',')})' : '${up.l},${up.t} ${up.r - up.l}x${up.b - up.t}');
  rot.apply(PathOp(0, PathSpec.rect(100, 400, 300, 450, fill: 0xFF00AA00), 'Retângulo'));
  final rr = rot.backend.render(0, 1);
  check('página girada: retângulo desenhado onde foi pedido', rr.width == 792 && ink(rr, 110, 410, 290, 440) > 4000 && ink(rr, 110, 460, 290, 500) == 0, '${ink(rr, 110, 410, 290, 440)}');
  rot.close();

  // Página com o desenho cortado em três fluxos no meio de traços (como faz
  // o "Microsoft Print to PDF"): o 1º abre o estado (q, cm) e começa o quadrado
  // azul; o 2º termina o azul e desenha o verde, ainda deslocado; o 3º fecha o
  // estado e desenha o vermelho. Mover o verde e o vermelho obriga o PDFium a
  // reescrever o 2º e o 3º fluxo sem mexer no 1º.
  String obj(int n, String body) => '$n 0 obj << /Length ${body.length} >> stream\n$body\nendstream endobj\n';
  final split = '%PDF-1.4\n'
      '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n'
      '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n'
      '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents [4 0 R 5 0 R 6 0 R] >> endobj\n'
      '${obj(4, 'q 0.5 0 0 0.5 0 0 cm q 2 0 0 2 0 0 cm q 1 0 0 1 300 0 cm 0 0 1 rg 10 400 m 110 400 l')}'
      '${obj(5, '110 500 l 10 500 l h f 0 0.6 0 rg 10 200 50 50 re f Q')}'
      '${obj(6, '1 0 0 1 0 0 cm 1 0 0 rg 20 20 100 100 re f Q Q')}'
      'trailer << /Root 1 0 R >>\n%%EOF\n';
  File('$d/split_raw.pdf').writeAsStringSync(split);
  await Process.run(tools.qpdf, ['$d/split_raw.pdf', '$d/split.pdf']);
  Future<List<int>> splitEdit(String src, String out) async {
    final e = Editor(() => PdfiumBackend.open(src, pdfium));
    final green = e.page(0).hit(0, 335, 567), red = e.page(0).hit(0, 70, 722);
    if (green != null) e.apply(MoveOp(0, green.indices, 100, 0));
    final red2 = e.page(0).hit(0, 70, 722) ?? red;
    if (red2 != null) e.apply(MoveOp(0, red2.indices, 200, 0));
    e.apply(e.newText(0, 'Texto novo no topo', TextStyleSpec(size: 14), 72, 60, 540));
    e.backend.save(out);
    e.close();
    final back = PdfiumBackend.open(out, pdfium);
    final r = back.render(0, 1);
    back.close();
    return [
      green == null ? -1 : 1, red == null ? -1 : 1,
      ink(r, 320, 300, 400, 380), // azul no lugar
      ink(r, 20, 300, 100, 380), // azul sem o deslocamento (errado)
      ink(r, 415, 547, 455, 587), // verde movido
      ink(r, 230, 680, 310, 760), // vermelho movido
      ink(r, 30, 680, 110, 760), // vermelho no lugar antigo (errado)
    ];
  }
  bool good(List<int> v) => v[0] == 1 && v[1] == 1 && v[2] > 5000 && v[3] == 0 && v[4] > 1200 && v[5] > 5000 && v[6] == 0;
  final raw = await splitEdit('$d/split.pdf', '$d/split_raw_out.pdf');
  print('  sem preparar: ${good(raw) ? 'certo' : 'quebrado'} $raw');
  final prepared = await prepareForEdit(tools, '$d/split.pdf');
  check('preparo junta os fluxos da página', prepared != '$d/split.pdf');
  final fixed = await splitEdit(prepared, '$d/split_out.pdf');
  check('desenho cortado em fluxos continua no lugar depois de mover objetos', good(fixed), '$fixed');
  Directory(p.dirname(prepared)).deleteSync(recursive: true);
  dir.deleteSync(recursive: true);
}

Future<void> main() async {
  logic();
  print(bad == 0 ? 'Lógica do editor: tudo certo.' : 'Lógica do editor: $bad problemas');
  final pdfium = Pdfium.load();
  if (pdfium == null) {
    final must = Platform.environment['FILUME_REQUIRE_PDFIUM'] == '1';
    print('${must ? 'FALHA' : 'AVISO'}: PDFium ausente; a parte com arquivos de verdade não rodou. ${Pdfium.loadError}');
    exit(bad == 0 && !must ? 0 : 1);
  }
  await real(pdfium);
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
