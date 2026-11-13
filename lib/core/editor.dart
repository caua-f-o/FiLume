import 'dart:math' as math;
import 'dart:typed_data';

/// Editor de PDF: a parte que não depende de biblioteca nenhuma.
///
/// Tudo aqui trabalha em "coordenadas de tela": pontos (1/72 pol), origem no
/// canto de cima à esquerda da página como ela aparece (já girada), y para
/// baixo. Quem fala com o PDF de verdade é um [EditBackend] (ver pdfium.dart),
/// que converte para as coordenadas internas do arquivo.
///
/// O editor reconstrói linhas e parágrafos a partir dos pedaços de texto
/// soltos do PDF, refaz a quebra de linha quando o texto muda e guarda cada
/// alteração como uma operação, para desfazer e refazer.

// ------------------------------------------------------------------ geometria

/// Transformação afim, na convenção do PDF: x' = a·x + c·y + e, y' = b·x + d·y + f.
class Mat {
  const Mat(this.a, this.b, this.c, this.d, this.e, this.f);
  final double a, b, c, d, e, f;
  static const identity = Mat(1, 0, 0, 1, 0, 0);

  (double, double) apply(double x, double y) => (a * x + c * y + e, b * x + d * y + f);

  /// Só a parte linear (para direções e deslocamentos).
  (double, double) vec(double x, double y) => (a * x + c * y, b * x + d * y);

  /// Aplica esta e depois [o].
  Mat then(Mat o) => Mat(
        o.a * a + o.c * b,
        o.b * a + o.d * b,
        o.a * c + o.c * d,
        o.b * c + o.d * d,
        o.a * e + o.c * f + o.e,
        o.b * e + o.d * f + o.f,
      );

  Mat inverse() {
    final det = a * d - b * c;
    if (det.abs() < 1e-12) return identity;
    final ia = d / det, ib = -b / det, ic = -c / det, id = a / det;
    return Mat(ia, ib, ic, id, -(ia * e + ic * f), -(ib * e + id * f));
  }

  static Mat translate(double x, double y) => Mat(1, 0, 0, 1, x, y);

  /// Escala (sx, sy) mantendo o ponto (ax, ay) parado.
  static Mat scaleAbout(double sx, double sy, double ax, double ay) => Mat(sx, 0, 0, sy, ax - sx * ax, ay - sy * ay);
}

// -------------------------------------------------------------------- modelo

enum ObjKind { text, image, path, other }

/// Um objeto da página (pedaço de texto, imagem, desenho), em coordenadas de tela.
class PdfObj {
  PdfObj({
    required this.index,
    required this.kind,
    required this.l,
    required this.t,
    required this.r,
    required this.b,
    this.text = '',
    this.size = 0,
    this.baseX = 0,
    this.baseY = 0,
    this.upright = true,
    this.font = '',
    this.bold = false,
    this.italic = false,
    this.embedded = false,
    this.color = 0xFF000000,
  });

  /// Posição na lista de objetos da página (muda quando algo é removido).
  final int index;
  final ObjKind kind;
  final double l, t, r, b;

  // Só para texto:
  final String text;

  /// Tamanho da letra, em pontos de tela.
  final double size;

  /// Início da linha de base.
  final double baseX, baseY;

  /// Texto na horizontal, da esquerda para a direita.
  final bool upright;

  /// Nome da fonte no PDF (com o prefixo de subconjunto, se tiver).
  final String font;
  final bool bold, italic, embedded;

  /// Cor de preenchimento, 0xAARRGGBB.
  final int color;

  double get width => r - l;
  double get height => b - t;
}

enum FontFamily {
  sans('Sem serifa', 'Helvetica'),
  serif('Com serifa', 'Times'),
  mono('Monoespaçada', 'Courier');

  const FontFamily(this.label, this.base);
  final String label, base;
}

/// De onde vem a fonte de um texto novo: uma das 14 fontes padrão do PDF
/// (não pesam no arquivo) ou a fonte de um objeto que já está na página.
class FontSpec {
  const FontSpec.standard(String this.standard) : fromObject = null;
  const FontSpec.reuse(int this.fromObject) : standard = null;
  final String? standard;
  final int? fromObject;

  static FontSpec of(FontFamily family, {bool bold = false, bool italic = false}) => FontSpec.standard(switch (family) {
        FontFamily.sans => 'Helvetica${bold || italic ? '-' : ''}${bold ? 'Bold' : ''}${italic ? 'Oblique' : ''}',
        FontFamily.mono => 'Courier${bold || italic ? '-' : ''}${bold ? 'Bold' : ''}${italic ? 'Oblique' : ''}',
        FontFamily.serif => bold || italic ? 'Times-${bold ? 'Bold' : ''}${italic ? 'Italic' : ''}' : 'Times-Roman',
      });

  String get key => standard ?? 'obj$fromObject';
}

/// Família padrão mais parecida com uma fonte do PDF, pelo nome.
FontFamily familyOf(String fontName) {
  final n = fontName.toLowerCase();
  if (RegExp(r'courier|mono|consol|menlo|typewriter|fixed').hasMatch(n)) return FontFamily.mono;
  if (RegExp(r'times|serif|georgia|garamond|cambria|roman|minion|palatino|book|bodoni|caslon|baskerville|century|libertine')
          .hasMatch(n) &&
      !n.contains('sans')) {
    return FontFamily.serif;
  }
  return FontFamily.sans;
}

/// Nome da fonte sem o prefixo de subconjunto ("ABCDEF+Arial" → "Arial").
String fontDisplayName(String font) {
  final plus = font.indexOf('+');
  final n = plus == 6 ? font.substring(7) : font;
  return n.replaceAll(RegExp(r'[-,]?(Regular|MT|PS)$'), '').replaceAll(RegExp(r'[-,]'), ' ').trim();
}

/// Caracteres que as fontes padrão do PDF sabem escrever (Windows-1252).
bool winAnsi(int rune) =>
    (rune >= 0x20 && rune <= 0x7E) ||
    (rune >= 0xA0 && rune <= 0xFF) ||
    const {
      0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x017D, //
      0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x017E, 0x0178,
    }.contains(rune);

enum HAlign { left, center, right }

/// Uma linha de texto pronta para ir à página.
class TextLine {
  const TextLine(this.text, this.x, this.baseline);
  final String text;
  final double x, baseline;
}

/// Caminho vetorial: [0,x,y] mover, [1,x,y] linha, [2,x1,y1,x2,y2,x,y] curva, [3] fechar.
class PathSpec {
  const PathSpec(this.segs, {this.stroke, this.width = 1, this.fill, this.multiply = false});
  final List<List<double>> segs;
  final int? stroke, fill;
  final double width;

  /// Mistura "multiplicar": a cor escurece o que está embaixo (marca-texto).
  final bool multiply;

  static PathSpec rect(double l, double t, double r, double b, {int? stroke, double width = 1, int? fill, bool multiply = false}) =>
      PathSpec([
        [0, l, t],
        [1, r, t],
        [1, r, b],
        [1, l, b],
        [3],
      ], stroke: stroke, width: width, fill: fill, multiply: multiply);

  static PathSpec ellipse(double l, double t, double r, double b, {int? stroke, double width = 1, int? fill}) {
    final cx = (l + r) / 2, cy = (t + b) / 2, rx = (r - l) / 2, ry = (b - t) / 2;
    const k = 0.5522847498;
    return PathSpec([
      [0, cx + rx, cy],
      [2, cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry],
      [2, cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy],
      [2, cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry],
      [2, cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy],
      [3],
    ], stroke: stroke, width: width, fill: fill);
  }

  static PathSpec line(double x1, double y1, double x2, double y2, {required int stroke, double width = 1, bool arrow = false}) {
    final segs = <List<double>>[
      [0, x1, y1],
      [1, x2, y2],
    ];
    if (arrow) {
      final len = math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
      if (len > 0.5) {
        final ux = (x2 - x1) / len, uy = (y2 - y1) / len;
        final h = math.max(6.0, width * 4), w = h * 0.45;
        final bx = x2 - ux * h, by = y2 - uy * h;
        segs.addAll([
          [0, x2, y2],
          [1, bx - uy * w, by + ux * w],
          [1, bx + uy * w, by - ux * w],
          [3],
        ]);
      }
    }
    return PathSpec(segs, stroke: stroke, width: width, fill: arrow ? stroke : null);
  }

  /// Traço à mão livre passando por [pts] (x, y alternados).
  static PathSpec ink(List<double> pts, {required int stroke, double width = 1.5}) => PathSpec([
        [0, pts[0], pts[1]],
        for (var i = 2; i + 1 < pts.length; i += 2) [1, pts[i], pts[i + 1]],
        if (pts.length == 2) [1, pts[0] + 0.1, pts[1] + 0.1],
      ], stroke: stroke, width: width);

  /// Vários traços (uma assinatura) num objeto só.
  static PathSpec strokes(List<List<double>> strokes, {required int stroke, double width = 1.5}) => PathSpec([
        for (final s in strokes)
          if (s.length >= 2) ...ink(s, stroke: stroke).segs,
      ], stroke: stroke, width: width);
}

class RenderedPage {
  RenderedPage(this.bgra, this.width, this.height);

  /// Pixels em BGRA, 4 bytes cada.
  final Uint8List bgra;
  final int width, height;
}

/// O que o editor precisa do arquivo. Índices são posições na lista de
/// objetos da página; objetos novos entram sempre no fim (por cima).
abstract class EditBackend {
  int get pageCount;

  /// Largura e altura da página como ela aparece, em pontos.
  (double, double) pageSize(int page);
  List<PdfObj> objects(int page);
  void move(int page, List<int> indices, double dx, double dy);
  void scale(int page, List<int> indices, double sx, double sy, double anchorX, double anchorY);
  void remove(int page, List<int> indices);

  /// Escreve as linhas. Devolve false (sem mudar nada) se a fonte
  /// reaproveitada não consegue escrever esse texto.
  bool addText(int page, List<TextLine> lines, FontSpec font, double size, int color);

  /// Largura que [text] ocupa (avanço), em pontos.
  double textWidth(int page, FontSpec font, double size, String text);
  void addPath(int page, PathSpec path);
  void addImage(int page, Uint8List rgba, int width, int height, double l, double t, double w, double h);
  RenderedPage render(int page, double scale);
  void save(String path);
  void close();
}

// ---------------------------------------------------- linhas e parágrafos

class BlockLine {
  BlockLine(this.indices, this.text, this.l, this.r, this.t, this.b, this.baseline);
  final List<int> indices;
  final String text;
  final double l, r, t, b, baseline;
}

/// Um parágrafo reconstruído: linhas vizinhas com a mesma letra.
class TextBlock {
  TextBlock(this.lines, this.first);
  final List<BlockLine> lines;

  /// Primeiro pedaço de texto (dá a fonte, a cor e o tamanho).
  final PdfObj first;

  List<int> get indices => [for (final l in lines) ...l.indices];
  String get text => lines.map((l) => l.text).join(' ');
  double get l => lines.map((x) => x.l).reduce(math.min);
  double get r => lines.map((x) => x.r).reduce(math.max);
  double get t => lines.first.t;
  double get b => lines.last.b;
  double get size => first.size;

  /// Distância entre as linhas de base.
  double get leading {
    if (lines.length < 2) return size * 1.2;
    final d = [for (var i = 1; i < lines.length; i++) lines[i].baseline - lines[i - 1].baseline]..sort();
    return d[d.length ~/ 2];
  }

  HAlign get align {
    if (lines.length < 2) return HAlign.left;
    bool same(Iterable<double> v, double tol) => v.reduce(math.max) - v.reduce(math.min) <= tol;
    if (same(lines.map((x) => x.l), 1.5)) return HAlign.left;
    if (same(lines.map((x) => x.r), 1.5)) return HAlign.right;
    if (same(lines.map((x) => (x.l + x.r) / 2), 2)) return HAlign.center;
    return HAlign.left;
  }
}

/// Monta linhas e parágrafos a partir dos pedaços de texto da página.
List<TextBlock> buildBlocks(List<PdfObj> objs) {
  final texts = [
    for (final o in objs)
      if (o.kind == ObjKind.text && o.upright && o.size > 0.5 && o.text.trim().isNotEmpty) o,
  ]..sort((a, b) => a.baseY.compareTo(b.baseY));
  final byIndex = {for (final o in texts) o.index: o};

  // 1. Fileiras: pedaços na mesma linha de base.
  final rows = <List<PdfObj>>[];
  for (final o in texts) {
    if (rows.isNotEmpty && (o.baseY - rows.last.first.baseY).abs() <= 0.35 * math.max(o.size, rows.last.first.size)) {
      rows.last.add(o);
    } else {
      rows.add([o]);
    }
  }
  // 2. Linhas: uma fileira se divide onde há um vão grande (colunas) ou a letra muda de tamanho.
  final lines = <BlockLine>[];
  for (final row in rows) {
    row.sort((a, b) => a.l.compareTo(b.l));
    var cur = <PdfObj>[];
    void flush() {
      if (cur.isEmpty) return;
      final sb = StringBuffer();
      for (var i = 0; i < cur.length; i++) {
        if (i > 0) {
          final gap = cur[i].l - cur[i - 1].r;
          final s = sb.toString();
          if (gap > 0.15 * cur[i].size && !s.endsWith(' ') && !cur[i].text.startsWith(' ')) sb.write(' ');
        }
        sb.write(cur[i].text);
      }
      lines.add(BlockLine(
        [for (final o in cur) o.index],
        sb.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
        cur.map((o) => o.l).reduce(math.min),
        cur.map((o) => o.r).reduce(math.max),
        cur.map((o) => o.t).reduce(math.min),
        cur.map((o) => o.b).reduce(math.max),
        cur.first.baseY,
      ));
      cur = [];
    }

    for (final o in row) {
      if (cur.isNotEmpty) {
        final prev = cur.last;
        final gap = o.l - prev.r;
        if (gap > 1.5 * o.size || (o.size - prev.size).abs() > 0.15 * prev.size) flush();
      }
      cur.add(o);
    }
    flush();
  }
  // 3. Parágrafos: linhas seguidas, com a mesma letra, alinhadas e sem "linha curta" no meio.
  lines.sort((a, b) => a.baseline != b.baseline ? a.baseline.compareTo(b.baseline) : a.l.compareTo(b.l));
  final blocks = <TextBlock>[];
  for (final line in lines) {
    final head = byIndex[line.indices.first]!;
    TextBlock? home;
    for (final blk in blocks.reversed) {
      final last = blk.lines.last;
      final gap = line.baseline - last.baseline;
      if (gap <= 0.2 * head.size || gap > 1.9 * head.size) continue;
      final f = blk.first;
      if ((f.size - head.size).abs() > 0.08 * f.size || f.bold != head.bold || f.color != head.color) continue;
      final overlap = math.min(line.r, blk.r) - math.max(line.l, blk.l);
      final aligned = (line.l - blk.l).abs() <= 2.2 * head.size || overlap >= 0.5 * math.min(line.r - line.l, blk.r - blk.l);
      if (!aligned) continue;
      // A linha anterior terminou cedo: o parágrafo acabou ali.
      if (last.r < math.max(blk.r, line.r) - 3.0 * head.size) continue;
      home = blk;
      break;
    }
    if (home != null) {
      home.lines.add(line);
    } else {
      blocks.add(TextBlock([line], head));
    }
  }
  return blocks;
}

// ------------------------------------------------------------ quebra de linha

/// Quebra [text] em linhas de até [width] pontos e posiciona cada uma.
/// "\n" no texto força linha nova. [x] é a borda esquerda da caixa.
List<TextLine> layoutText(
  double Function(String) measure,
  String text, {
  required double x,
  required double firstBaseline,
  required double width,
  required double leading,
  HAlign align = HAlign.left,
}) {
  final space = measure(' ');
  final out = <TextLine>[];
  var baseline = firstBaseline;
  void emit(String s, double w) {
    final dx = switch (align) {
      HAlign.left => 0.0,
      HAlign.center => (width - w) / 2,
      HAlign.right => width - w,
    };
    if (s.isNotEmpty) out.add(TextLine(s, x + dx, baseline));
    baseline += leading;
  }

  for (final para in text.split('\n')) {
    final words = para.split(RegExp(r'[ \t]+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      emit('', 0);
      continue;
    }
    var cur = '';
    var curW = 0.0;
    for (final word in words) {
      final w = measure(word);
      if (cur.isEmpty) {
        cur = word;
        curW = w;
      } else if (curW + space + w <= width + 0.01) {
        cur = '$cur $word';
        curW += space + w;
      } else {
        emit(cur, curW);
        cur = word;
        curW = w;
      }
    }
    emit(cur, curW);
  }
  return out;
}

// ----------------------------------------------------------------- operações

/// Uma alteração na página, que sabe se refazer do zero (para o desfazer).
abstract class EditOp {
  EditOp(this.page);
  final int page;
  String get label;
  void apply(EditBackend b);
}

class MoveOp extends EditOp {
  MoveOp(super.page, this.indices, this.dx, this.dy);
  final List<int> indices;
  final double dx, dy;
  @override
  String get label => 'Mover';
  @override
  void apply(EditBackend b) => b.move(page, indices, dx, dy);
}

class ScaleOp extends EditOp {
  ScaleOp(super.page, this.indices, this.sx, this.sy, this.ax, this.ay);
  final List<int> indices;
  final double sx, sy, ax, ay;
  @override
  String get label => 'Redimensionar';
  @override
  void apply(EditBackend b) => b.scale(page, indices, sx, sy, ax, ay);
}

class DeleteOp extends EditOp {
  DeleteOp(super.page, this.indices);
  final List<int> indices;
  @override
  String get label => 'Excluir';
  @override
  void apply(EditBackend b) => b.remove(page, indices);
}

/// Escreve texto (novo ou no lugar de um parágrafo que sai).
class TextOp extends EditOp {
  TextOp(super.page, {required this.lines, required this.font, required this.size, required this.color, this.remove = const [], this.fallback, this.fallbackLines});
  final List<TextLine> lines;
  final FontSpec font;
  final double size;
  final int color;

  /// Objetos que saem (o parágrafo antigo).
  final List<int> remove;

  /// Se a fonte original não conseguir escrever o texto, usa esta.
  final FontSpec? fallback;
  final List<TextLine>? fallbackLines;

  /// Preenchido ao aplicar: a fonte original foi trocada.
  bool substituted = false;

  @override
  String get label => remove.isEmpty ? 'Inserir texto' : 'Editar texto';
  @override
  void apply(EditBackend b) {
    substituted = false;
    if (lines.isNotEmpty && !b.addText(page, lines, font, size, color)) {
      final fb = fallback;
      if (fb != null) {
        substituted = b.addText(page, fallbackLines ?? lines, fb, size, color);
      }
    }
    if (remove.isNotEmpty) b.remove(page, remove);
  }
}

class PathOp extends EditOp {
  PathOp(super.page, this.path, this.label);
  final PathSpec path;
  @override
  final String label;
  @override
  void apply(EditBackend b) => b.addPath(page, path);
}

class ImageOp extends EditOp {
  ImageOp(super.page, this.rgba, this.width, this.height, this.l, this.t, this.w, this.h);
  final Uint8List rgba;
  final int width, height;
  final double l, t, w, h;
  @override
  String get label => 'Inserir imagem';
  @override
  void apply(EditBackend b) => b.addImage(page, rgba, width, height, l, t, w, h);
}

// -------------------------------------------------------------------- editor

/// O que está selecionado: um parágrafo ou um objeto solto.
class Selection {
  Selection(this.page, this.indices, this.l, this.t, this.r, this.b, {this.block, this.kind = ObjKind.text});
  final int page;
  final List<int> indices;
  final double l, t, r, b;
  final TextBlock? block;
  final ObjKind kind;
  bool get isText => block != null;
}

class PageModel {
  PageModel(this.width, this.height, this.objs) : blocks = buildBlocks(objs);
  final double width, height;
  final List<PdfObj> objs;
  final List<TextBlock> blocks;

  /// Borda direita mais distante do texto da página (a "margem").
  double get textRight => blocks.isEmpty ? width - 36 : blocks.map((b) => b.r).reduce(math.max);

  /// O que está em (x, y): o parágrafo, senão o menor objeto sob o ponto.
  Selection? hit(int page, double x, double y) {
    TextBlock? blk;
    for (final b in blocks) {
      if (x >= b.l - 3 && x <= b.r + 3 && y >= b.t - 3 && y <= b.b + 3) {
        if (blk == null || (b.r - b.l) * (b.b - b.t) < (blk.r - blk.l) * (blk.b - blk.t)) blk = b;
      }
    }
    if (blk != null) return Selection(page, blk.indices, blk.l, blk.t, blk.r, blk.b, block: blk);
    final inBlocks = {for (final b in blocks) ...b.indices};
    PdfObj? best;
    for (final o in objs.reversed) {
      if (inBlocks.contains(o.index)) continue;
      if (x < o.l - 2 || x > o.r + 2 || y < o.t - 2 || y > o.b + 2) continue;
      // Fundo da página (digitalização, moldura): não se seleciona com um clique.
      if (o.width * o.height > 0.8 * width * height) continue;
      if (best == null || o.width * o.height < best.width * best.height) best = o;
    }
    return best == null ? null : Selection(page, [best.index], best.l, best.t, best.r, best.b, kind: best.kind);
  }
}

/// Estilo de um texto no editor.
class TextStyleSpec {
  TextStyleSpec({this.family, this.bold = false, this.italic = false, this.size = 12, this.color = 0xFF000000, this.align = HAlign.left});

  /// null = manter a fonte original do PDF (quando possível).
  FontFamily? family;
  bool bold, italic;
  double size;
  int color;
  HAlign align;

  TextStyleSpec copy() => TextStyleSpec(family: family, bold: bold, italic: italic, size: size, color: color, align: align);

  static TextStyleSpec of(TextBlock b) =>
      TextStyleSpec(bold: b.first.bold, italic: b.first.italic, size: (b.size * 2).round() / 2, color: b.first.color, align: b.align);
}

class Editor {
  Editor(this._open) : backend = _open();
  final EditBackend Function() _open;
  EditBackend backend;
  final List<EditOp> _done = [];
  final List<EditOp> _undone = [];
  final Map<int, PageModel> _pages = {};
  Map<String, Set<int>>? _fontChars;

  bool get dirty => _done.isNotEmpty;
  bool get canUndo => _done.isNotEmpty;
  bool get canRedo => _undone.isNotEmpty;
  String? get undoLabel => _done.isEmpty ? null : _done.last.label;
  String? get redoLabel => _undone.isEmpty ? null : _undone.last.label;
  int get pageCount => backend.pageCount;

  PageModel page(int i) => _pages[i] ??= () {
        final (w, h) = backend.pageSize(i);
        return PageModel(w, h, backend.objects(i));
      }();

  void apply(EditOp op) {
    op.apply(backend);
    _done.add(op);
    _undone.clear();
    _pages.remove(op.page);
    _fontChars = null;
  }

  /// Desfaz reabrindo o arquivo e refazendo tudo menos a última operação.
  /// Devolve a página afetada.
  int? undo() {
    if (_done.isEmpty) return null;
    final op = _done.removeLast();
    _undone.add(op);
    _replay();
    return op.page;
  }

  int? redo() {
    if (_undone.isEmpty) return null;
    final op = _undone.removeLast();
    op.apply(backend);
    _done.add(op);
    _pages.remove(op.page);
    _fontChars = null;
    return op.page;
  }

  void _replay() {
    backend.close();
    backend = _open();
    for (final op in _done) {
      op.apply(backend);
    }
    _pages.clear();
    _fontChars = null;
  }

  /// Marca o estado atual como salvo (o histórico de desfazer continua).
  void close() => backend.close();

  /// Caracteres que cada fonte do documento já escreve em algum lugar. Uma
  /// fonte embutida costuma trazer só esses (subconjunto).
  Set<int> _charsOf(String font, int near) {
    final map = _fontChars ??= {};
    if (!map.containsKey('\u0000scanned')) {
      map['\u0000scanned'] = {};
      final n = backend.pageCount;
      final pages = n <= 80 ? List.generate(n, (i) => i) : [for (var i = math.max(0, near - 20); i < math.min(n, near + 20); i++) i];
      for (final p in pages) {
        for (final o in page(p).objs) {
          if (o.kind == ObjKind.text) (map[o.font] ??= {}).addAll(o.text.runes);
        }
      }
    }
    return map[font] ?? const {};
  }

  /// A fonte original de [first] consegue escrever [text]?
  bool canReuse(PdfObj first, String text, int page) {
    final runes = text.runes.where((r) => r != 0x0A && r != 0x20);
    if (!first.embedded) return runes.every(winAnsi);
    final have = _charsOf(first.font, page);
    return runes.every(have.contains);
  }

  /// Caracteres de [text] que as fontes padrão não escrevem.
  static String unsupported(String text) =>
      String.fromCharCodes({for (final r in text.runes) if (r != 0x0A && !winAnsi(r)) r});

  static String _clean(String text) => String.fromCharCodes([for (final r in text.runes) r == 0x0A || winAnsi(r) ? r : 0x3F]);

  /// Troca o texto (e/ou o estilo) de um parágrafo: refaz as linhas dentro
  /// da largura do parágrafo, com a fonte original se ela der conta.
  TextOp editBlock(int pageIndex, TextBlock block, String text, TextStyleSpec style) {
    final model = page(pageIndex);
    final first = block.first;
    // Parágrafo de uma linha só pode crescer até a margem do texto da página.
    final align = style.align;
    var width = block.r - block.l;
    var x = block.l;
    if (block.lines.length == 1) {
      switch (align) {
        case HAlign.left:
          width = math.max(width, model.textRight - block.l);
        case HAlign.right:
          width = math.max(width, block.r - 36);
          x = block.r - width;
        case HAlign.center:
          final c = (block.l + block.r) / 2;
          width = 2 * math.min(c - 24, model.width - 24 - c);
          x = c - width / 2;
      }
    }
    final leading = block.lines.length > 1 ? block.leading * style.size / block.size : style.size * 1.2;
    final std = FontSpec.of(style.family ?? familyOf(first.font), bold: style.bold, italic: style.italic);
    List<TextLine> lay(FontSpec f, String t) => layoutText(
          (s) => backend.textWidth(pageIndex, f, style.size, s),
          t,
          x: x,
          firstBaseline: block.lines.first.baseline,
          width: width,
          leading: leading,
          align: align,
        );
    final sameLook = style.family == null && style.bold == first.bold && style.italic == first.italic;
    if (sameLook && canReuse(first, text, pageIndex)) {
      final reuse = FontSpec.reuse(first.index);
      return TextOp(pageIndex,
          lines: lay(reuse, text), font: reuse, size: style.size, color: style.color, remove: block.indices, fallback: std, fallbackLines: lay(std, _clean(text)));
    }
    return TextOp(pageIndex, lines: lay(std, _clean(text)), font: std, size: style.size, color: style.color, remove: block.indices);
  }

  /// Texto novo numa caixa que começa em (x, top) e vai até [right].
  TextOp newText(int pageIndex, String text, TextStyleSpec style, double x, double top, double right) {
    final font = FontSpec.of(style.family ?? FontFamily.sans, bold: style.bold, italic: style.italic);
    return TextOp(
      pageIndex,
      lines: layoutText(
        (s) => backend.textWidth(pageIndex, font, style.size, s),
        _clean(text),
        x: x,
        firstBaseline: top + style.size * 0.95,
        width: math.max(style.size * 2, right - x),
        leading: style.size * 1.2,
        align: style.align,
      ),
      font: font,
      size: style.size,
      color: style.color,
    );
  }
}
