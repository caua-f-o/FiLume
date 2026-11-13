import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'job.dart';
import 'ocr.dart';
import 'pdf.dart';

/// Comparador de PDFs. Trabalha em três frentes:
///  1. emparelha as páginas dos dois arquivos (acha páginas inseridas e removidas);
///  2. compara o desenho de cada par de páginas e marca onde mudou, com
///     tolerância a ruído e deslocamento quando a página é foto ou digitalização;
///  3. compara o texto (o do PDF ou, em páginas sem texto, o lido por OCR)
///     e lista as palavras que saíram e as que entraram.

enum CompareTolerance {
  auto('Automática'),
  exact('Exata'),
  tolerant('Tolerante');

  const CompareTolerance(this.label);
  final String label;
}

enum PairStatus { equal, changed, added, removed }

/// Retângulo de diferença, em frações da página do original (0..1).
class DiffRegion {
  const DiffRegion(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
}

/// Um trecho de texto alterado, com um pouco do que vem antes e depois.
class TextChange {
  const TextChange(this.before, this.removed, this.added, this.after);
  final String before, removed, added, after;
}

class PagePair {
  PagePair(this.a, this.b);

  /// Página no original e no novo (1 = primeira); null = não existe ali.
  final int? a, b;
  PairStatus status = PairStatus.equal;

  /// Fração da página que mudou (0..1).
  double changed = 0;
  List<DiffRegion> regions = const [];
  List<TextChange> text = const [];

  /// As alterações de texto vieram de OCR (podem ter pequenos erros de leitura).
  bool ocrText = false;

  /// A comparação visual usou o modo tolerante.
  bool tolerant = false;

  /// Imagens das páginas, para mostrar.
  String? imageA, imageB;

  /// Largura ÷ altura de cada página.
  double aspectA = 0.707, aspectB = 0.707;

  /// Deslocamento do novo em relação ao original (frações da página).
  double shiftX = 0, shiftY = 0;
}

class CompareResult {
  CompareResult(this.dir, this.nameA, this.nameB, this.pagesA, this.pagesB, this.pairs, {this.note});

  /// Pasta temporária com as imagens das páginas (apagar ao descartar).
  final String dir;
  final String nameA, nameB;
  final int pagesA, pagesB;
  final List<PagePair> pairs;

  /// Aviso sobre limites desta comparação (OCR indisponível, por exemplo).
  final String? note;

  int count(PairStatus s) => pairs.where((x) => x.status == s).length;
  bool get identical => pairs.every((x) => x.status == PairStatus.equal);

  String get summary {
    if (identical) return 'Nenhuma diferença encontrada';
    String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
    return [
      if (count(PairStatus.changed) > 0) n(count(PairStatus.changed), 'página alterada', 'páginas alteradas'),
      if (count(PairStatus.added) > 0) n(count(PairStatus.added), 'adicionada', 'adicionadas'),
      if (count(PairStatus.removed) > 0) n(count(PairStatus.removed), 'removida', 'removidas'),
    ].join(' · ');
  }

  void dispose() {
    try {
      Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
  }
}

// ------------------------------------------------------------------- imagens

/// Página renderizada em tons de cinza (um byte por pixel).
class Gray {
  Gray(this.bytes, this.w, this.h, this.start);
  final Uint8List bytes;
  final int w, h, start;
}

/// Página reduzida a uma grade de células (média dos pixels de cada célula).
class Grid {
  Grid(this.w, this.h)
      : d = Uint8List(w * h),
        valid = Uint8List(w * h);
  final int w, h;
  final Uint8List d;

  /// 0 nas células sem nenhum pixel (fora da página, depois de um deslocamento).
  final Uint8List valid;
}

/// Lê um PGM binário (P5), como o Ghostscript grava.
Gray readPgm(String path) {
  final b = File(path).readAsBytesSync();
  var pos = 2;
  final nums = <int>[];
  while (nums.length < 3 && pos < b.length) {
    final c = b[pos];
    if (c == 0x23) {
      while (pos < b.length && b[pos] != 0x0A) {
        pos++;
      }
    } else if (c >= 0x30 && c <= 0x39) {
      var v = 0;
      while (pos < b.length && b[pos] >= 0x30 && b[pos] <= 0x39) {
        v = v * 10 + b[pos] - 0x30;
        pos++;
      }
      nums.add(v);
      continue;
    }
    pos++;
  }
  if (nums.length < 3 || b[0] != 0x50 || b[1] != 0x35 || pos + 1 + nums[0] * nums[1] > b.length) {
    throw FfError('Não foi possível ler a página renderizada.');
  }
  return Gray(b, nums[0], nums[1], pos + 1);
}

/// Colunas e linhas da grade de uma página (células de ~0,5 mm).
(int, int) gridSize(Gray g) {
  final cols = (g.w ~/ 3).clamp(24, 460);
  return (cols, (cols * g.h / g.w).round().clamp(8, 1200));
}

/// Reduz [g] a uma grade de [cols]×[rows]. Com ([ox], [oy]), a página é
/// lida deslocada desses pixels (para encaixar sobre outra).
Grid makeGrid(Gray g, int cols, int rows, {int ox = 0, int oy = 0}) {
  final out = Grid(cols, rows);
  final sum = Int32List(cols * rows), cnt = Int32List(cols * rows);
  final xmap = Int32List(g.w);
  for (var x = 0; x < g.w; x++) {
    final c = ((x - ox) * cols / g.w).floor();
    xmap[x] = c >= 0 && c < cols ? c : -1;
  }
  for (var y = 0; y < g.h; y++) {
    final r = ((y - oy) * rows / g.h).floor();
    if (r < 0 || r >= rows) continue;
    final row = r * cols;
    var o = g.start + y * g.w;
    for (var x = 0; x < g.w; x++, o++) {
      final c = xmap[x];
      if (c < 0) continue;
      sum[row + c] += g.bytes[o];
      cnt[row + c]++;
    }
  }
  for (var i = 0; i < sum.length; i++) {
    if (cnt[i] == 0) {
      out.d[i] = 255;
    } else {
      out.d[i] = sum[i] ~/ cnt[i];
      out.valid[i] = 1;
    }
  }
  return out;
}

/// Miniatura fixa (24×32) para medir a semelhança geral entre páginas.
Uint8List _thumb(Grid g) {
  const tw = 24, th = 32;
  final sum = Int32List(tw * th), cnt = Int32List(tw * th);
  for (var y = 0; y < g.h; y++) {
    final row = (y * th ~/ g.h) * tw;
    for (var x = 0; x < g.w; x++) {
      final i = row + x * tw ~/ g.w;
      sum[i] += g.d[y * g.w + x];
      cnt[i]++;
    }
  }
  return Uint8List.fromList([for (var i = 0; i < sum.length; i++) cnt[i] == 0 ? 255 : sum[i] ~/ cnt[i]]);
}

/// Iguala o branco do papel: compensa a diferença de exposição entre duas
/// fotos ou digitalizações da mesma folha.
void _normalize(Grid g) {
  final hist = Int32List(256);
  for (final v in g.d) {
    hist[v]++;
  }
  final goal = (g.d.length * 0.80).round();
  var acc = 0, hi = 255;
  for (var i = 0; i < 256; i++) {
    acc += hist[i];
    if (acc >= goal) {
      hi = i;
      break;
    }
  }
  if (hi < 90 || hi >= 250) return;
  for (var i = 0; i < g.d.length; i++) {
    final v = g.d[i] * 250 ~/ hi;
    g.d[i] = v > 255 ? 255 : v;
  }
}

/// Suaviza a grade (média 3×3): tira o grão do papel e o serrilhado das
/// bordas das letras, que mudam de uma digitalização para outra.
void _soften(Grid g) {
  final src = Uint8List.fromList(g.d);
  final w = g.w, h = g.h;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      g.d[i] = (src[i - w - 1] + src[i - w] + src[i - w + 1] + src[i - 1] + src[i] + src[i + 1] + src[i + w - 1] + src[i + w] + src[i + w + 1]) ~/ 9;
    }
  }
}

/// Diferença média entre [a] e [b] deslocado de (dx, dy), na área em comum.
double _sad(Grid a, Grid b, int dx, int dy, int step) {
  var sum = 0, n = 0;
  for (var y = 0; y < a.h; y += step) {
    final by = y + dy;
    if (by < 0 || by >= b.h) continue;
    for (var x = 0; x < a.w; x += step) {
      final bx = x + dx;
      if (bx < 0 || bx >= b.w) continue;
      final v = a.d[y * a.w + x] - b.d[by * b.w + bx];
      sum += v < 0 ? -v : v;
      n++;
    }
  }
  return n == 0 ? 1e9 : sum / n;
}

Grid _shrink(Grid g, int f) {
  final o = Grid((g.w / f).ceil(), (g.h / f).ceil());
  final sum = Int32List(o.w * o.h), cnt = Int32List(o.w * o.h);
  for (var y = 0; y < g.h; y++) {
    for (var x = 0; x < g.w; x++) {
      final i = (y ~/ f) * o.w + x ~/ f;
      sum[i] += g.d[y * g.w + x];
      cnt[i]++;
    }
  }
  for (var i = 0; i < sum.length; i++) {
    o.d[i] = cnt[i] == 0 ? 255 : sum[i] ~/ cnt[i];
  }
  return o;
}

/// Acha quanto o novo está deslocado em relação ao original (em células,
/// até ~1 cm). Entre encaixes parecidos, vence o menor deslocamento: linhas
/// de texto se repetem e enganariam a busca.
(int, int) _findShift(Grid a, Grid b) {
  (int, int) search(Grid p, Grid q, int cx, int cy, int reach, int step) {
    var best = double.infinity, bx = cx, by = cy;
    for (var dy = cy - reach; dy <= cy + reach; dy++) {
      for (var dx = cx - reach; dx <= cx + reach; dx++) {
        final s = _sad(p, q, dx, dy, step) * (1 + 0.012 * (dx.abs() + dy.abs()));
        if (s < best) {
          best = s;
          bx = dx;
          by = dy;
        }
      }
    }
    return (bx, by);
  }

  final (hx, hy) = search(_shrink(a, 2), _shrink(b, 2), 0, 0, 10, 2);
  return search(a, b, hx * 2, hy * 2, 2, 2);
}

/// Ajuste fino, em pixels do novo: parte do deslocamento em células e
/// procura o melhor encaixe pixel a pixel.
(int, int) _refineShift(Gray a, Gray b, int ox, int oy) {
  final fx = b.w / a.w, fy = b.h / a.h;
  final reach = (b.w / (a.w / 3)).ceil() + 1;
  double sad(int dx, int dy) {
    var sum = 0, n = 0;
    for (var y = 4; y < a.h - 4; y += 3) {
      final by = (y * fy).round() + dy;
      if (by < 0 || by >= b.h) continue;
      final ra = a.start + y * a.w, rb = b.start + by * b.w;
      for (var x = 4; x < a.w - 4; x += 3) {
        final bx = (x * fx).round() + dx;
        if (bx < 0 || bx >= b.w) continue;
        final v = a.bytes[ra + x] - b.bytes[rb + bx];
        sum += v < 0 ? -v : v;
        n++;
      }
    }
    return n == 0 ? 1e9 : sum / n;
  }

  var best = sad(ox, oy), bx = ox, by = oy;
  for (var dy = oy - reach; dy <= oy + reach; dy++) {
    for (var dx = ox - reach; dx <= ox + reach; dx++) {
      final s = sad(dx, dy);
      if (s < best) {
        best = s;
        bx = dx;
        by = dy;
      }
    }
  }
  return (bx, by);
}

class VisualDiff {
  VisualDiff(this.regions, this.changed, this.shiftX, this.shiftY);
  final List<DiffRegion> regions;
  final double changed;

  /// Deslocamento do novo em relação ao original, em frações da página.
  final double shiftX, shiftY;
}

/// Compara duas páginas. No modo [tolerant] (fotos e digitalizações),
/// compensa exposição, deslocamento e ruído antes de comparar.
VisualDiff diffPages(Gray pa, Gray pb, {required bool tolerant}) {
  final (w, h) = gridSize(pa);
  final a = makeGrid(pa, w, h);
  var b = makeGrid(pb, w, h);
  var shiftX = 0.0, shiftY = 0.0;
  if (tolerant) {
    _normalize(a);
    _normalize(b);
    final (cx, cy) = _findShift(a, b);
    final (ox, oy) = _refineShift(pa, pb, (cx * pb.w / w).round(), (cy * pb.h / h).round());
    if (ox != 0 || oy != 0) {
      b = makeGrid(pb, w, h, ox: ox, oy: oy);
      _normalize(b);
      shiftX = ox / pb.w;
      shiftY = oy / pb.h;
    }
  }
  if (tolerant) {
    _soften(a);
    _soften(b);
  }
  final thr = tolerant ? 34 : 14;
  // Em digitalizações, a beirada da folha (sombra, borda preta) não conta.
  final edge = tolerant ? 5 : 0;
  final marks = Uint8List(w * h);

  /// Menor diferença entre a célula (x, y) de [p] e a vizinhança dela em [q].
  int near(Grid p, Grid q, int x, int y) {
    final v = p.d[y * w + x];
    var best = 255;
    for (var j = -1; j <= 1; j++) {
      final yy = y + j;
      if (yy < 0 || yy >= h) continue;
      for (var i = -1; i <= 1; i++) {
        final xx = x + i;
        if (xx < 0 || xx >= w) continue;
        final d = v - q.d[yy * w + xx];
        final ad = d < 0 ? -d : d;
        if (ad < best) best = ad;
      }
    }
    return best;
  }

  final diff = Uint8List(w * h);
  for (var y = edge; y < h - edge; y++) {
    for (var x = edge; x < w - edge; x++) {
      final i = y * w + x;
      if (b.valid[i] == 0) continue; // fora da área em comum
      if (tolerant) {
        final d1 = near(a, b, x, y), d2 = near(b, a, x, y);
        diff[i] = d1 > d2 ? d1 : d2;
      } else {
        final v = a.d[i] - b.d[i];
        diff[i] = v < 0 ? -v : v;
      }
    }
  }
  var cut = thr;
  if (tolerant) {
    // O limite acompanha o ruído desta dupla de páginas: fica um pouco acima
    // do que quase todas as células diferem entre si (encaixe imperfeito,
    // grão do papel, JPEG), sem passar de um teto que esconderia mudanças.
    final hist = Int32List(256);
    for (final d in diff) {
      hist[d]++;
    }
    final goal = (diff.length * 0.97).round();
    var acc = 0, p = 255;
    for (var i = 0; i < 256; i++) {
      acc += hist[i];
      if (acc >= goal) {
        p = i;
        break;
      }
    }
    cut = (p * 2.4).round().clamp(thr, 80);
  }
  for (var i = 0; i < diff.length; i++) {
    if (diff[i] > cut) marks[i] = 1;
  }
  if (tolerant) {
    // Ruído: uma célula marcada precisa de pelo menos duas outras por perto.
    final keep = Uint8List(w * h);
    for (var y = 2; y < h - 2; y++) {
      for (var x = 2; x < w - 2; x++) {
        if (marks[y * w + x] == 0) continue;
        var n = 0;
        for (var j = -2; j <= 2; j++) {
          for (var i = -2; i <= 2; i++) {
            n += marks[(y + j) * w + x + i];
          }
        }
        if (n >= 3) keep[y * w + x] = 1;
      }
    }
    marks.setAll(0, keep);
  }
  var count = 0;
  for (final m in marks) {
    count += m;
  }
  if (count == 0) return VisualDiff(const [], 0, shiftX, shiftY);

  // Junta marcas próximas (dilatação) e tira a caixa de cada grupo.
  const r = 5;
  final wide = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (marks[y * w + x] == 0) continue;
      for (var j = -r; j <= r; j++) {
        final yy = y + j;
        if (yy < 0 || yy >= h) continue;
        for (var i = -r; i <= r; i++) {
          final xx = x + i;
          if (xx >= 0 && xx < w) wide[yy * w + xx] = 1;
        }
      }
    }
  }
  final regions = <DiffRegion>[];
  final stack = <int>[];
  for (var start = 0; start < wide.length; start++) {
    if (wide[start] != 1) continue;
    var x0 = w, y0 = h, x1 = 0, y1 = 0, real = 0;
    stack.add(start);
    wide[start] = 2;
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      final x = i % w, y = i ~/ w;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      real += marks[i];
      if (x > 0 && wide[i - 1] == 1) {
        wide[i - 1] = 2;
        stack.add(i - 1);
      }
      if (x < w - 1 && wide[i + 1] == 1) {
        wide[i + 1] = 2;
        stack.add(i + 1);
      }
      if (y > 0 && wide[i - w] == 1) {
        wide[i - w] = 2;
        stack.add(i - w);
      }
      if (y < h - 1 && wide[i + w] == 1) {
        wide[i + w] = 2;
        stack.add(i + w);
      }
    }
    if (tolerant && real < 4) {
      count -= real;
      continue; // pequeno demais para não ser ruído
    }
    regions.add(DiffRegion(x0 / w, y0 / h, (x1 - x0 + 1) / w, (y1 - y0 + 1) / h));
  }
  if (regions.length > 250) return VisualDiff(const [DiffRegion(0, 0, 1, 1)], count / (w * h), shiftX, shiftY);
  return VisualDiff(regions, regions.isEmpty ? 0 : count / (w * h), shiftX, shiftY);
}

// --------------------------------------------------------------------- texto

List<String> _words(String text) => [
      for (final t in text.split(RegExp(r'\s+')))
        if (t.isNotEmpty) t,
    ];

/// Forma usada para comparar palavras. No modo [loose] (texto de OCR),
/// ignora maiúsculas e pontuação, que o OCR erra com frequência.
String _key(String word, bool loose) =>
    loose ? word.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '') : word;

/// Diferenças entre duas listas de palavras, agrupadas em trechos.
List<TextChange> diffWords(List<String> a, List<String> b, {bool loose = false}) {
  var ka = [for (final w in a) _key(w, loose)], kb = [for (final w in b) _key(w, loose)];
  if (loose) {
    // Palavras que viraram vazio (só pontuação) saem da comparação.
    final fa = <String>[], fka = <String>[], fb = <String>[], fkb = <String>[];
    for (var i = 0; i < a.length; i++) {
      if (ka[i].isNotEmpty) {
        fa.add(a[i]);
        fka.add(ka[i]);
      }
    }
    for (var i = 0; i < b.length; i++) {
      if (kb[i].isNotEmpty) {
        fb.add(b[i]);
        fkb.add(kb[i]);
      }
    }
    a = fa;
    ka = fka;
    b = fb;
    kb = fkb;
  }
  var pre = 0;
  while (pre < a.length && pre < b.length && ka[pre] == kb[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && ka[a.length - 1 - suf] == kb[b.length - 1 - suf]) {
    suf++;
  }
  final n = a.length - pre - suf, m = b.length - pre - suf;
  // ops: 0 = igual, 1 = removida (índice em a), 2 = adicionada (índice em b)
  final ops = <(int, int)>[];
  for (var i = 0; i < pre; i++) {
    ops.add((0, i));
  }
  if (n * m > 9000000) {
    // Grande demais para comparar palavra a palavra: trata o miolo como trocado.
    for (var i = 0; i < n; i++) {
      ops.add((1, pre + i));
    }
    for (var j = 0; j < m; j++) {
      ops.add((2, pre + j));
    }
  } else if (n > 0 || m > 0) {
    final t = Uint16List((n + 1) * (m + 1));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        t[i * (m + 1) + j] = ka[pre + i] == kb[pre + j]
            ? t[(i + 1) * (m + 1) + j + 1] + 1
            : (t[(i + 1) * (m + 1) + j] >= t[i * (m + 1) + j + 1] ? t[(i + 1) * (m + 1) + j] : t[i * (m + 1) + j + 1]);
      }
    }
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (ka[pre + i] == kb[pre + j]) {
        ops.add((0, pre + i));
        i++;
        j++;
      } else if (t[(i + 1) * (m + 1) + j] >= t[i * (m + 1) + j + 1]) {
        ops.add((1, pre + i++));
      } else {
        ops.add((2, pre + j++));
      }
    }
    while (i < n) {
      ops.add((1, pre + i++));
    }
    while (j < m) {
      ops.add((2, pre + j++));
    }
  }
  for (var i = 0; i < suf; i++) {
    ops.add((0, a.length - suf + i));
  }
  // Agrupa em trechos; uma palavra igual isolada entre duas mudanças não separa.
  final out = <TextChange>[];
  var k = 0;
  while (k < ops.length) {
    if (ops[k].$1 == 0) {
      k++;
      continue;
    }
    final start = k;
    var end = k;
    while (end < ops.length) {
      if (ops[end].$1 != 0) {
        end++;
      } else if (end + 1 < ops.length && ops[end + 1].$1 != 0) {
        end++;
      } else {
        break;
      }
    }
    final rem = <String>[], add = <String>[];
    for (var q = start; q < end; q++) {
      final (op, idx) = ops[q];
      if (op == 0) {
        rem.add(a[idx]);
        add.add(a[idx]);
      } else if (op == 1) {
        rem.add(a[idx]);
      } else {
        add.add(b[idx]);
      }
    }
    final before = [for (var q = start - 1; q >= 0 && q >= start - 5; q--) if (ops[q].$1 == 0) a[ops[q].$2]].reversed;
    final after = [for (var q = end; q < ops.length && q < end + 5; q++) if (ops[q].$1 == 0) a[ops[q].$2]];
    out.add(TextChange(before.join(' '), rem.join(' '), add.join(' '), after.join(' ')));
    if (out.length >= 300) break;
    k = end;
  }
  return out;
}

double _textSim(Map<String, int> a, int na, Map<String, int> b, int nb) {
  if (na == 0 || nb == 0) return 0;
  var common = 0;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o != null) common += e.value < o ? e.value : o;
  }
  return 2 * common / (na + nb);
}

Map<String, int> _bag(List<String> words) {
  final m = <String, int>{};
  // Palavras e pares de palavras vizinhas: os pares distinguem páginas que
  // usam o mesmo vocabulário (cláusulas parecidas, tabelas).
  String? last;
  for (final w in words) {
    final k = _key(w, true);
    if (k.isEmpty) continue;
    m[k] = (m[k] ?? 0) + 1;
    if (last != null) {
      final pair = '$last $k';
      m[pair] = (m[pair] ?? 0) + 1;
    }
    last = k;
  }
  return m;
}

// ------------------------------------------------------------ emparelhamento

/// Emparelha as páginas pela semelhança [sim] (0..1), mantendo a ordem.
List<(int?, int?)> alignPages(int n, int m, double Function(int i, int j) sim) {
  if (n == 1 && m == 1) return [(0, 0)]; // uma página contra uma: compara direto
  // Abaixo de 0,45 não é a mesma página. Acima, quanto mais parecidas, muito
  // mais vale o par: assim uma página inserida não "rouba" o par da seguinte.
  double score(double v) => v < 0.45 ? -1 : v * v * v * v * v * v + 0.02;
  final s = List.generate(n, (i) => List.generate(m, (j) => score(sim(i, j))));
  final t = List.generate(n + 1, (_) => Float64List(m + 1));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      var best = t[i + 1][j] > t[i][j + 1] ? t[i + 1][j] : t[i][j + 1];
      if (s[i][j] > 0 && t[i + 1][j + 1] + s[i][j] >= best) best = t[i + 1][j + 1] + s[i][j];
      t[i][j] = best;
    }
  }
  final out = <(int?, int?)>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (s[i][j] > 0 && t[i][j] == t[i + 1][j + 1] + s[i][j]) {
      out.add((i++, j++));
    } else if (t[i + 1][j] >= t[i][j + 1]) {
      out.add((i++, null));
    } else {
      out.add((null, j++));
    }
  }
  while (i < n) {
    out.add((i++, null));
  }
  while (j < m) {
    out.add((null, j++));
  }
  return out;
}

// ----------------------------------------------------------------- comparação

final _pageLine = RegExp(r'^Page (\d+)');

Future<void> _gs(JobCtx ctx, PdfTools tools, List<String> args, {void Function(int page)? onPage}) async {
  final gs = tools.gs ?? (throw FfError('O Ghostscript não foi encontrado; o comparador precisa dele.'));
  final code = await ctx.run.exec(gs, ['-dNOPAUSE', '-dBATCH', '-dSAFER', ...args], onStdoutLine: (line) {
    final m = _pageLine.firstMatch(line);
    if (m != null) onPage?.call(int.parse(m[1]!));
  });
  if (code != 0) throw FfError('Não foi possível ler um dos arquivos (código $code).', ctx.run.errorTail.join('\n'));
}

String _n(String dir, String prefix, int page, String ext) => p.join(dir, '$prefix${page.toString().padLeft(4, '0')}.$ext');

/// Compara [a] (original) com [b] (novo). Aceita PDFs e imagens.
Future<CompareResult> comparePdfs(
  JobCtx ctx,
  PdfTools tools,
  MediaInfo a,
  MediaInfo b, {
  CompareTolerance tolerance = CompareTolerance.auto,
  OcrFn? ocr,
}) async {
  final dir = (await Directory.systemTemp.createTemp('filume_cmp_')).path;
  try {
    // Imagens entram como PDFs de uma página.
    Future<(String, int)> source(MediaInfo m, String tag) async {
      if (!m.isImage) {
        if (m.encrypted) throw FfError('"${p.basename(m.path)}" é protegido por senha. Remova a senha antes de comparar.');
        return (m.path, m.pages);
      }
      final out = p.join(dir, '$tag.pdf');
      await writeImagesPdf(ctx, [m], PageFit.image, out);
      return (out, 1);
    }

    ctx.report(0, stage: 'Abrindo os arquivos');
    final (pa, na) = await source(a, 'a');
    final (pb, nb) = await source(b, 'b');
    if (na == 0 || nb == 0) throw FfError('Um dos arquivos não tem páginas.');
    final docs = [(pa, na, 'a'), (pb, nb, 'b')];
    final total = na + nb;

    // 1. Texto de cada página.
    var done = 0;
    for (final (path, _, tag) in docs) {
      await _gs(ctx, tools, ['-sDEVICE=txtwrite', '-sOutputFile=${p.join(dir, 't$tag%04d.txt')}', path],
          onPage: (n) => ctx.report(0.10 * (done + n) / total, stage: 'Lendo o texto'));
      done += tag == 'a' ? na : 0;
    }
    List<List<String>> readText(String tag, int n) => [
          for (var i = 1; i <= n; i++)
            () {
              final f = File(_n(dir, 't$tag', i, 'txt'));
              return f.existsSync() ? _words(utf8.decode(f.readAsBytesSync(), allowMalformed: true)) : <String>[];
            }(),
        ];
    final words = [readText('a', na), readText('b', nb)];
    final native = [
      [for (final w in words[0]) w.length >= 3],
      [for (final w in words[1]) w.length >= 3],
    ];

    // 2. Páginas em cinza (para comparar) e em cores (para mostrar e para o OCR).
    done = 0;
    for (final (path, n, tag) in docs) {
      await _gs(ctx, tools, ['-sDEVICE=pgmraw', '-r150', '-sOutputFile=${p.join(dir, 'g$tag%04d.pgm')}', path],
          onPage: (pg) => ctx.report(0.10 + 0.30 * (done + pg) / total, stage: 'Preparando página ${done + pg} de $total'));
      done += n;
    }
    done = 0;
    for (final (path, n, tag) in docs) {
      await _gs(ctx, tools, [
        '-sDEVICE=jpeg', '-dJPEGQ=85', '-r130', '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
        '-sOutputFile=${p.join(dir, 'v$tag%04d.jpg')}', path,
      ], onPage: (pg) => ctx.report(0.40 + 0.25 * (done + pg) / total, stage: 'Gerando visualização ${done + pg} de $total'));
      done += n;
    }

    // 3. OCR nas páginas sem texto (fotos e digitalizações).
    String? note;
    final ocrPage = [List.filled(na, false), List.filled(nb, false)];
    final need = <(int, int)>[
      for (var d = 0; d < 2; d++)
        for (var i = 0; i < words[d].length; i++)
          if (!native[d][i]) (d, i),
    ];
    if (need.isNotEmpty) {
      if (ocr == null) {
        note = 'Há páginas sem texto (fotos ou digitalizações). Nelas a comparação é só visual; '
            'a lista de palavras alteradas precisa do OCR do Windows.';
      } else {
        ctx.report(0.65, stage: 'OCR das páginas sem texto');
        try {
          final read = await ocr(
            [for (final (d, i) in need) _n(dir, 'v${d == 0 ? 'a' : 'b'}', i + 1, 'jpg')],
            (k) => ctx.report(0.65 + 0.15 * k / need.length, stage: 'OCR: página $k de ${need.length}'),
          );
          for (var k = 0; k < need.length; k++) {
            final (d, i) = need[k];
            final byLine = <int, List<String>>{};
            for (final w in read[k].words) {
              (byLine[w.line] ??= []).add(w.text);
            }
            words[d][i] = [for (final l in byLine.values) ...l];
            ocrPage[d][i] = words[d][i].isNotEmpty;
          }
        } on OcrError catch (e) {
          note = 'O OCR não funcionou (${e.message}). Nas páginas sem texto, a comparação é só visual.';
        }
      }
    }
    if (ctx.run.canceled) throw const JobCanceled();

    // 4. Emparelha as páginas.
    ctx.report(0.80, stage: 'Emparelhando as páginas');
    final bags = [
      [for (final w in words[0]) _bag(w)],
      [for (final w in words[1]) _bag(w)],
    ];
    final sizes = [
      [for (final m in bags[0]) m.values.fold(0, (x, y) => x + y)],
      [for (final m in bags[1]) m.values.fold(0, (x, y) => x + y)],
    ];
    Uint8List thumbOf(String tag, int i) {
      final g = readPgm(_n(dir, 'g$tag', i, 'pgm'));
      final (c, r) = gridSize(g);
      return _thumb(makeGrid(g, c, r));
    }

    final thumbs = [
      [for (var i = 1; i <= na; i++) thumbOf('a', i)],
      [for (var i = 1; i <= nb; i++) thumbOf('b', i)],
    ];
    double sim(int i, int j) {
      if (sizes[0][i] >= 8 && sizes[1][j] >= 8) return _textSim(bags[0][i], sizes[0][i], bags[1][j], sizes[1][j]);
      final ta = thumbs[0][i], tb = thumbs[1][j];
      // Desconta a diferença de brilho geral antes de comparar.
      var ma = 0, mb = 0;
      for (var k = 0; k < ta.length; k++) {
        ma += ta[k];
        mb += tb[k];
      }
      final off = (ma - mb) ~/ ta.length;
      var sum = 0;
      for (var k = 0; k < ta.length; k++) {
        final v = ta[k] - tb[k] - off;
        sum += v < 0 ? -v : v;
      }
      return (1 - sum / ta.length / 50).clamp(0.0, 1.0);
    }

    final aligned = alignPages(na, nb, sim);

    // 5. Compara cada par.
    final pairs = <PagePair>[];
    for (var k = 0; k < aligned.length; k++) {
      if (ctx.run.canceled) throw const JobCanceled();
      ctx.report(0.82 + 0.18 * k / aligned.length, stage: 'Comparando ${k + 1} de ${aligned.length}');
      final (i, j) = aligned[k];
      final pair = PagePair(i == null ? null : i + 1, j == null ? null : j + 1);
      if (i != null) pair.imageA = _n(dir, 'va', i + 1, 'jpg');
      if (j != null) pair.imageB = _n(dir, 'vb', j + 1, 'jpg');
      if (i == null || j == null) {
        pair.status = i == null ? PairStatus.added : PairStatus.removed;
        final g = readPgm(_n(dir, i == null ? 'gb' : 'ga', (i ?? j)! + 1, 'pgm'));
        pair.aspectA = pair.aspectB = g.w / g.h;
        pairs.add(pair);
        continue;
      }
      final ga = readPgm(_n(dir, 'ga', i + 1, 'pgm')), gb = readPgm(_n(dir, 'gb', j + 1, 'pgm'));
      pair.aspectA = ga.w / ga.h;
      pair.aspectB = gb.w / gb.h;
      final bothNative = native[0][i] && native[1][j];
      final loose = ocrPage[0][i] || ocrPage[1][j];
      final text = diffWords(words[0][i], words[1][j], loose: loose);
      var tolerant = tolerance == CompareTolerance.tolerant || (tolerance == CompareTolerance.auto && !bothNative);
      var v = diffPages(ga, gb, tolerant: tolerant);
      if (!tolerant && tolerance == CompareTolerance.auto && text.isEmpty && v.changed > 0.03) {
        // Texto idêntico e "tudo diferente": é só o desenho que saiu um fio
        // diferente (outro programa gerou o PDF). Compara de novo com folga.
        v = diffPages(ga, gb, tolerant: true);
        tolerant = true;
      }
      pair
        ..tolerant = tolerant
        ..regions = v.regions
        ..changed = v.changed
        ..shiftX = v.shiftX
        ..shiftY = v.shiftY
        ..ocrText = loose;
      final visual = v.regions.isNotEmpty;
      if (bothNative) {
        pair.text = text;
        if (visual || text.isNotEmpty) pair.status = PairStatus.changed;
      } else if (visual) {
        // Texto de OCR só entra quando o desenho também mudou: sozinho, ele
        // acusaria erros de leitura como se fossem alterações.
        pair.text = text;
        pair.status = PairStatus.changed;
      }
      pairs.add(pair);
    }
    // As grades e os textos já cumpriram o papel; ficam só as imagens de visualização.
    for (final e in Directory(dir).listSync()) {
      if (e.path.endsWith('.pgm') || e.path.endsWith('.txt')) {
        try {
          e.deleteSync();
        } catch (_) {}
      }
    }
    ctx.report(1, stage: 'Pronto');
    return CompareResult(dir, p.basename(a.path), p.basename(b.path), na, nb, pairs, note: note);
  } catch (_) {
    try {
      Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
    rethrow;
  }
}

// ------------------------------------------------------------------ relatório

/// Texto para um PDF com fonte padrão (Windows-1252), já com os escapes.
String _pdfText(String s) {
  const map = {0x2013: 0x96, 0x2014: 0x97, 0x201C: 0x93, 0x201D: 0x94, 0x2018: 0x91, 0x2019: 0x92, 0x2026: 0x85, 0x2022: 0x95, 0x2212: 0x2D};
  final out = StringBuffer();
  for (final r in s.runes) {
    final c = map[r] ?? (r < 256 && (r >= 32) ? r : (r == 9 || r == 10 ? 32 : 0x3F));
    if (c == 0x28 || c == 0x29 || c == 0x5C) out.writeCharCode(0x5C);
    out.writeCharCode(c);
  }
  return out.toString();
}

/// Largura e altura de um JPEG.
(int, int) _jpegSize(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final m = b[i + 1];
    if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
      return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]);
    }
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  throw FfError('Imagem de página inválida.');
}

List<String> _wrap(String text, int width) {
  final lines = <String>[];
  var cur = '';
  for (final w in text.split(' ')) {
    if (cur.isNotEmpty && cur.length + w.length + 1 > width) {
      lines.add(cur);
      cur = '';
    }
    cur = cur.isEmpty ? w : '$cur $w';
    while (cur.length > width) {
      lines.add(cur.substring(0, width));
      cur = cur.substring(width);
    }
  }
  if (cur.isNotEmpty) lines.add(cur);
  return lines;
}

/// Relatório em PDF: resumo, páginas lado a lado com as diferenças marcadas
/// e a lista de textos alterados.
Job buildCompareReportJob(CompareResult r, String outDir, String name) {
  return Job(
    title: '$name.pdf',
    kind: 'Relatório',
    detail: r.summary,
    body: (ctx) async {
      final out = uniquePath(p.join(outDir, '$name.pdf'));
      await Directory(outDir).create(recursive: true);
      final sink = File(out).openWrite();
      var pos = 0;
      final offsets = <int, int>{};
      var next = 4; // 1 catálogo, 2 páginas, 3 fonte
      final kids = <int>[];
      void raw(List<int> b) {
        sink.add(b);
        pos += b.length;
      }

      void obj(int id, String head, [List<int>? stream]) {
        offsets[id] = pos;
        raw(latin1.encode('$id 0 obj\n$head\n'));
        if (stream != null) {
          raw(latin1.encode('stream\n'));
          raw(stream);
          raw(latin1.encode('\nendstream\n'));
        }
        raw(latin1.encode('endobj\n'));
      }

      const pw = 842.0, ph = 595.0;
      void page(String content, [Map<String, int> images = const {}]) {
        final id = next++, cid = next++;
        kids.add(id);
        final bytes = latin1.encode(content);
        obj(
            id,
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pw $ph] /Contents $cid 0 R /Resources << '
            '/Font << /F1 3 0 R >> /ExtGState << /G << /ca 0.16 >> >> '
            '/XObject << ${images.entries.map((e) => '/${e.key} ${e.value} 0 R').join(' ')} >> >> >>');
        obj(cid, '<< /Length ${bytes.length} >>', bytes);
      }

      String txt(double x, double y, double size, String s, [String color = '0.1 0.1 0.12']) =>
          'BT $color rg /F1 $size Tf 1 0 0 1 ${x.toStringAsFixed(1)} ${y.toStringAsFixed(1)} Tm (${_pdfText(s)}) Tj ET\n';

      raw(latin1.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'));
      obj(3, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');

      String label(PagePair x) => switch (x.status) {
            PairStatus.added => 'Novo p. ${x.b}: página adicionada (não existe no original)',
            PairStatus.removed => 'Original p. ${x.a}: página removida (não existe no novo)',
            PairStatus.changed => 'Original p. ${x.a}  ×  Novo p. ${x.b}: alterada'
                '${x.regions.isEmpty ? ' (só no texto)' : ' (${(x.changed * 100).toStringAsFixed(x.changed < 0.1 ? 1 : 0).replaceAll('.', ',')}% da página, '
                    '${x.regions.length} ${x.regions.length == 1 ? 'trecho' : 'trechos'})'}'
                '${x.text.isEmpty ? '' : ' · ${x.text.length} ${x.text.length == 1 ? 'alteração' : 'alterações'} de texto'}',
            _ => 'Original p. ${x.a}  ×  Novo p. ${x.b}: igual',
          };

      // Resumo
      final diffs = [for (final x in r.pairs) if (x.status != PairStatus.equal) x];
      final lines = <String>[
        'Original: ${r.nameA} (${r.pagesA} ${r.pagesA == 1 ? 'página' : 'páginas'})',
        'Novo: ${r.nameB} (${r.pagesB} ${r.pagesB == 1 ? 'página' : 'páginas'})',
        'Resultado: ${r.summary}. ${r.count(PairStatus.equal)} ${r.count(PairStatus.equal) == 1 ? 'página igual' : 'páginas iguais'}.',
        if (r.note != null) ..._wrap(r.note!, 150),
        '',
        for (final x in diffs) label(x),
      ];
      for (var start = 0; start < lines.length || start == 0; start += 34) {
        final c = StringBuffer();
        if (start == 0) c.write(txt(40, ph - 60, 20, 'Comparação de PDFs'));
        var y = ph - (start == 0 ? 95 : 50);
        for (final l in lines.skip(start).take(34)) {
          c.write(txt(40, y, 10.5, l));
          y -= 15;
        }
        c.write(txt(40, 24, 8, 'Gerado pelo FiLume PDF', '0.45 0.45 0.5'));
        page(c.toString());
      }

      // Páginas com diferenças, lado a lado.
      for (var k = 0; k < diffs.length; k++) {
        if (ctx.run.canceled) throw const JobCanceled();
        ctx.report(k / diffs.length, stage: 'Página ${k + 1} de ${diffs.length}');
        final x = diffs[k];
        final c = StringBuffer(txt(24, ph - 30, 11, label(x)));
        final images = <String, int>{};
        void side(String? file, double left, String tag, String title, double sx, double sy) {
          const boxW = 389.0, boxH = 500.0, top = 548.0;
          c.write(txt(left, top - 6, 9, title, '0.35 0.35 0.4'));
          if (file == null) {
            c.write('0.93 0.93 0.95 rg $left ${top - 14 - boxH} $boxW $boxH re f\n');
            c.write(txt(left + 110, top - 14 - boxH / 2, 11, '(esta página não existe aqui)', '0.45 0.45 0.5'));
            return;
          }
          final bytes = File(file).readAsBytesSync();
          final (iw, ih) = _jpegSize(bytes);
          final id = next++;
          obj(id, '<< /Type /XObject /Subtype /Image /Width $iw /Height $ih /ColorSpace /DeviceRGB /BitsPerComponent 8 '
              '/Filter /DCTDecode /Length ${bytes.length} >>', bytes);
          images[tag] = id;
          final s = (boxW / iw) < (boxH / ih) ? boxW / iw : boxH / ih;
          final w = iw * s, h = ih * s, y0 = top - 14 - h;
          c.write('q ${w.toStringAsFixed(2)} 0 0 ${h.toStringAsFixed(2)} $left ${y0.toStringAsFixed(2)} cm /$tag Do Q\n');
          c.write('0.6 0.6 0.65 RG 0.5 w $left ${y0.toStringAsFixed(2)} ${w.toStringAsFixed(2)} ${h.toStringAsFixed(2)} re S\n');
          for (final g in x.regions) {
            final rx = left + (g.x + sx) * w, ry = y0 + h - (g.y + sy + g.h) * h;
            final rect = '${rx.toStringAsFixed(2)} ${ry.toStringAsFixed(2)} ${(g.w * w).toStringAsFixed(2)} ${(g.h * h).toStringAsFixed(2)} re';
            c.write('q /G gs 0.9 0.1 0.1 rg $rect f Q\n0.85 0.1 0.1 RG 1 w $rect S\n');
          }
        }

        side(x.imageA, 24, 'A', 'Original${x.a == null ? '' : ' · página ${x.a}'}', 0, 0);
        side(x.imageB, 429, 'B', 'Novo${x.b == null ? '' : ' · página ${x.b}'}', x.shiftX, x.shiftY);
        page(c.toString(), images);

        // Texto alterado desta página.
        if (x.text.isNotEmpty) {
          final rows = <(String, String)>[];
          for (final t in x.text.take(60)) {
            if (t.removed.isNotEmpty) {
              for (final l in _wrap('- ${t.removed}', 150)) {
                rows.add((l, '0.75 0.1 0.1'));
              }
            }
            if (t.added.isNotEmpty) {
              for (final l in _wrap('+ ${t.added}', 150)) {
                rows.add((l, '0.05 0.5 0.2'));
              }
            }
            rows.add(('', ''));
          }
          if (x.text.length > 60) rows.add(('... e mais ${x.text.length - 60} alterações', '0.35 0.35 0.4'));
          for (var start = 0; start < rows.length; start += 40) {
            final t = StringBuffer(txt(24, ph - 30, 11,
                'Texto alterado · original p. ${x.a} × novo p. ${x.b}${x.ocrText ? ' (lido por OCR; pode ter erros de leitura)' : ''}'));
            var y = ph - 56;
            for (final (l, color) in rows.skip(start).take(40)) {
              if (l.isNotEmpty) t.write(txt(24, y, 9, l, color));
              y -= 12.5;
            }
            page(t.toString());
          }
        }
      }

      obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
      obj(2, '<< /Type /Pages /Count ${kids.length} /Kids [${kids.map((k) => '$k 0 R').join(' ')}] >>');
      final xref = pos;
      final ids = offsets.keys.toList()..sort();
      final xr = StringBuffer('xref\n0 ${ids.last + 1}\n0000000000 65535 f \n');
      for (var id = 1; id <= ids.last; id++) {
        xr.write(offsets.containsKey(id) ? '${offsets[id]!.toString().padLeft(10, '0')} 00000 n \n' : '0000000000 65535 f \n');
      }
      xr.write('trailer\n<< /Size ${ids.last + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
      raw(latin1.encode(xr.toString()));
      await sink.close();
      return JobResult('${kids.length} páginas · ${r.summary}', out);
    },
  );
}
