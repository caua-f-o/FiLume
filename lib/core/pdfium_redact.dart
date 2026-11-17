part of 'pdfium.dart';

// Tarja de verdade: apaga o que está sob as áreas marcadas, em vez de só
// desenhar um retângulo por cima.
//
// O desenho da ferramenta (o que é removido, a conferência depois de gravar e a
// recusa em entregar o arquivo se algo sobrar) segue o módulo de redação do
// PdfCraft (https://github.com/storytold/pdfcraft, MIT OU Apache-2.0, © 2026
// ArtCraft Team e colaboradores do PdfCraft). O código aqui é novo e trabalha
// sobre o PDFium.

/// Retângulo em coordenadas de tela da página (pontos, y para baixo).
class Area {
  const Area(this.l, this.t, this.r, this.b);
  final double l, t, r, b;

  factory Area.fromPoints(double x1, double y1, double x2, double y2) =>
      Area(math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2));

  double get width => r - l;
  double get height => b - t;

  /// Sobrepõe a caixa dada por mais que [eps] nas duas direções?
  bool overlaps(double ol, double ot, double or, double ob, [double eps = 0.3]) =>
      math.min(r, or) - math.max(l, ol) > eps && math.min(b, ob) - math.max(t, ot) > eps;

  bool contains(double ol, double ot, double or, double ob, [double eps = 0.3]) =>
      ol >= l - eps && ot >= t - eps && or <= r + eps && ob <= b + eps;

  bool hasPoint(double x, double y) => x >= l && x <= r && y >= t && y <= b;

  Area union(Area o) => Area(math.min(l, o.l), math.min(t, o.t), math.max(r, o.r), math.max(b, o.b));

  Area inflate(double d) => Area(l - d, t - d, r + d, b + d);

  @override
  String toString() => 'Area(${l.toStringAsFixed(1)}, ${t.toStringAsFixed(1)}, ${r.toStringAsFixed(1)}, ${b.toStringAsFixed(1)})';
}

/// O que a tarja removeu.
class RedactReport {
  int pages = 0, texts = 0, images = 0, drawings = 0, others = 0, annotations = 0, patches = 0;

  /// Texto que estava sob as tarjas (para conferir depois que não sobrou em outro lugar).
  final StringBuffer removedText = StringBuffer();

  /// O texto de cada tarja, com os espaços, para procurar cópias em outros
  /// lugares do arquivo (comentários, marcadores).
  final List<String> snippets = [];

  int get objects => texts + images + drawings + others;
}

/// Um caractere da página com a sua caixa na tela.
class PageChar {
  PageChar(this.code, this.l, this.t, this.r, this.b);
  final int code;
  final double l, t, r, b;
  bool get hasBox => r - l > 0.01 && b - t > 0.01;
}

final class _FsRectF extends Struct {
  @Float()
  external double left;
  @Float()
  external double top;
  @Float()
  external double right;
  @Float()
  external double bottom;
}

class _RedactApi {
  _RedactApi(DynamicLibrary lib)
      : countChars = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFText_CountChars'),
        getUnicode = lib.lookupFunction<Uint32 Function(_H, Int32), int Function(_H, int)>('FPDFText_GetUnicode'),
        getCharBox = lib.lookupFunction<Int32 Function(_H, Int32, Pointer<Double>, Pointer<Double>, Pointer<Double>, Pointer<Double>),
            int Function(_H, int, Pointer<Double>, Pointer<Double>, Pointer<Double>, Pointer<Double>)>('FPDFText_GetCharBox'),
        countSegments = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFPath_CountSegments'),
        annotCount = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFPage_GetAnnotCount'),
        getAnnot = lib.lookupFunction<_H Function(_H, Int32), _H Function(_H, int)>('FPDFPage_GetAnnot'),
        closeAnnot = lib.lookupFunction<Void Function(_H), void Function(_H)>('FPDFPage_CloseAnnot'),
        removeAnnot = lib.lookupFunction<Int32 Function(_H, Int32), int Function(_H, int)>('FPDFPage_RemoveAnnot'),
        annotRect = lib.lookupFunction<Int32 Function(_H, Pointer<_FsRectF>), int Function(_H, Pointer<_FsRectF>)>('FPDFAnnot_GetRect');

  final int Function(_H) countChars;
  final int Function(_H, int) getUnicode;
  final int Function(_H, int, Pointer<Double>, Pointer<Double>, Pointer<Double>, Pointer<Double>) getCharBox;
  final int Function(_H) countSegments;
  final int Function(_H) annotCount;
  final _H Function(_H, int) getAnnot;
  final void Function(_H) closeAnnot;
  final int Function(_H, int) removeAnnot;
  final int Function(_H, Pointer<_FsRectF>) annotRect;
}

/// Um trecho de texto encontrado numa página.
class TextHit {
  TextHit(this.page, this.boxes, this.text);
  final int page;

  /// Uma caixa por linha que o trecho ocupa.
  final List<Area> boxes;
  final String text;
}

extension Redaction on PdfiumBackend {
  _RedactApi get _ra => _pdf._redact;

  /// Caixa na tela de um retângulo dado em coordenadas da página.
  Area _viewBox(int page, double x1, double y1, double x2, double y2) {
    final m = _toView(page);
    final xs = <double>[], ys = <double>[];
    for (final (x, y) in [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]) {
      final (vx, vy) = m.apply(x, y);
      xs.add(vx);
      ys.add(vy);
    }
    return Area(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
  }

  /// Todos os caracteres da página, na ordem de leitura do PDFium.
  List<PageChar> chars(int page) {
    final h = _page(page);
    final tp = _pdf.textLoadPage(h);
    if (tp == nullptr) return const [];
    final d4 = _pdf.alloc<Double>(32);
    final out = <PageChar>[];
    try {
      final n = _ra.countChars(tp);
      for (var i = 0; i < n; i++) {
        final code = _ra.getUnicode(tp, i);
        if (_ra.getCharBox(tp, i, d4, d4 + 1, d4 + 2, d4 + 3) != 0) {
          // (esquerda, direita, baixo, cima) na página
          final a = _viewBox(page, d4[0], d4[2], d4[1], d4[3]);
          out.add(PageChar(code, a.l, a.t, a.r, a.b));
        } else {
          out.add(PageChar(code, 0, 0, 0, 0));
        }
      }
    } finally {
      _pdf.textClosePage(tp);
      _pdf.free(d4);
    }
    return out;
  }

  /// Procura [query] na página (sem diferenciar maiúsculas) e devolve onde está.
  List<TextHit> findText(int page, String query) {
    final needle = query.toLowerCase();
    if (needle.trim().isEmpty) return const [];
    final cs = chars(page);
    // Texto corrido; quebras de linha viram espaço para o trecho poder atravessar linhas.
    final sb = StringBuffer();
    final owner = <int>[]; // posição no texto → índice do caractere
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i].code;
      final s = c == 0 || c == 0xFFFE || c == 0xFFFF ? ' ' : (c == 10 || c == 13 ? ' ' : String.fromCharCode(c));
      final low = s.toLowerCase();
      // Algumas letras mudam de comprimento ao virar minúscula; mantém uma posição por caractere.
      sb.write(low.length == s.length ? low : s);
      for (var k = 0; k < s.length; k++) {
        owner.add(i);
      }
    }
    final hay = sb.toString();
    final hits = <TextHit>[];
    var from = 0;
    while (true) {
      final at = hay.indexOf(needle, from);
      if (at < 0) break;
      from = at + math.max(1, needle.length);
      final boxes = <Area>[];
      Area? line;
      for (var k = at; k < at + needle.length && k < owner.length; k++) {
        final ch = cs[owner[k]];
        if (!ch.hasBox) continue;
        final box = Area(ch.l, ch.t, ch.r, ch.b);
        final cur = line;
        if (cur == null) {
          line = box;
        } else {
          final mid = (box.t + box.b) / 2;
          // Mesma linha: o meio do caractere cai dentro da altura da caixa atual.
          final midX = (box.l + box.r) / 2;
          // Mesma linha: o meio do caractere cai na altura da caixa atual; em texto
          // de pé (página girada), cai na largura dela e vem logo em seguida.
          final sameRow = mid >= cur.t - 0.5 && mid <= cur.b + 0.5 && box.l >= cur.l - cur.height;
          final sameColumn = midX >= cur.l - 0.5 && midX <= cur.r + 0.5 && box.t >= cur.t - cur.width && box.t <= cur.b + cur.width;
          if (sameRow || sameColumn) {
            line = cur.union(box);
          } else {
            boxes.add(cur);
            line = box;
          }
        }
      }
      if (line != null) boxes.add(line);
      if (boxes.isNotEmpty) hits.add(TextHit(page, [for (final b in boxes) b.inflate(0.8)], hay.substring(at, at + needle.length)));
    }
    return hits;
  }

  /// Texto cujos caracteres têm o centro dentro de alguma das áreas.
  String textUnder(int page, List<Area> areas, {bool spaces = false}) {
    final sb = StringBuffer();
    for (final c in chars(page)) {
      if (c.code == 32 && spaces && sb.isNotEmpty) {
        // Espaços gerados não têm caixa: entram se o texto em volta está sob a tarja.
        sb.write(' ');
        continue;
      }
      if (!c.hasBox || c.code <= 32) continue;
      final x = (c.l + c.r) / 2, y = (c.t + c.b) / 2;
      if (areas.any((a) => a.hasPoint(x, y))) sb.writeCharCode(c.code);
    }
    return sb.toString();
  }

  void _insertBgra(_H pageHandle, int page, Uint8List bgra, int width, int height, Area at) {
    final buf = _pdf.alloc<Uint8>(width * height * 4);
    buf.asTypedList(width * height * 4).setAll(0, bgra);
    // 3 = BGRx: 4 bytes por ponto, sem transparência (a imagem é opaca).
    final bmp = _pdf.bitmapCreate(width, height, 3, buf.cast(), width * 4);
    final img = _pdf.newImageObj(_doc);
    try {
      if (bmp == nullptr || img == nullptr || _pdf.imageSetBitmap(nullptr, 0, img, bmp) == 0) {
        if (img != nullptr) _pdf.objDestroy(img);
        throw FfError('Não foi possível refazer um trecho da página ${page + 1}.');
      }
      final inv = _toView(page).inverse();
      final (a, b) = inv.vec(at.width, 0);
      final (c, d) = inv.vec(0, -at.height);
      final (e, f) = inv.apply(at.l, at.b);
      _pdf.imageSetMatrix(img, a, b, c, d, e, f);
      _pdf.insertObject(pageHandle, img);
    } finally {
      if (bmp != nullptr) _pdf.bitmapDestroy(bmp);
      _pdf.free(buf);
    }
  }

  /// Aplica as tarjas: tudo o que está sob as áreas sai do arquivo.
  ///
  /// - texto, imagens e desenhos inteiramente cobertos são removidos;
  /// - o que está só em parte sob uma tarja é removido e a parte de fora volta
  ///   como imagem (com a tarja já pintada), para não sobrar nada legível;
  /// - comentários, links e campos sobre uma tarja são removidos;
  /// - no lugar fica um retângulo na cor [color].
  ///
  /// Quem chama deve gravar, reabrir e conferir com [leaks].
  RedactReport redact(Map<int, List<Area>> marks, {int color = 0xFF000000}) {
    final report = RedactReport();
    final cr = (color >> 16) & 255, cg = (color >> 8) & 255, cb = color & 255;
    for (final entry in marks.entries) {
      final page = entry.key;
      final (pw, ph) = pageSize(page);
      final bounds = Area(0, 0, pw, ph);
      final areas = [
        for (final a in entry.value)
          if (a.width > 0.5 && a.height > 0.5 && a.overlaps(0, 0, pw, ph, 0)) Area(math.max(0, a.l), math.max(0, a.t), math.min(pw, a.r), math.min(ph, a.b)),
      ];
      if (areas.isEmpty) continue;
      report.pages++;
      final h = _page(page);
      report.removedText.write(textUnder(page, areas));
      for (final a in areas) {
        final t = textUnder(page, [a], spaces: true).replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.length >= 4) report.snippets.add(t);
      }
      final objs = objects(page);
      final remove = <int>[];
      var patches = <Area>[];
      var wantsDetail = false;
      for (final o in objs) {
        if (o.r - o.l <= 0 && o.b - o.t <= 0) continue;
        final hit = areas.where((a) => a.overlaps(o.l, o.t, o.r, o.b)).toList();
        if (hit.isEmpty) continue;
        final covered = hit.any((a) => a.contains(o.l, o.t, o.r, o.b));
        if (!covered && o.kind == ObjKind.path) {
          // Linhas e retângulos simples (bordas de tabela, fundos) não carregam
          // informação: ficam, e a tarja cobre o trecho.
          final obj = _pdf.getObject(h, o.index);
          if (obj != nullptr && _ra.countSegments(obj) <= 6) continue;
        }
        remove.add(o.index);
        switch (o.kind) {
          case ObjKind.text:
            report.texts++;
          case ObjKind.image:
            report.images++;
            wantsDetail = true;
          case ObjKind.path:
            report.drawings++;
          case ObjKind.other:
            report.others++;
        }
        if (!covered) {
          patches.add(Area(math.max(0, o.l - 1), math.max(0, o.t - 1), math.min(pw, o.r + 1), math.min(ph, o.b + 1)));
        }
      }
      // Remendos que se tocam viram um só.
      var merged = true;
      while (merged) {
        merged = false;
        final next = <Area>[];
        for (final a in patches) {
          final i = next.indexWhere((b) => b.overlaps(a.l, a.t, a.r, a.b, -0.5));
          if (i < 0) {
            next.add(a);
          } else {
            next[i] = next[i].union(a);
            merged = true;
          }
        }
        patches = next;
      }
      patches = [
        for (final a in patches)
          if (a.overlaps(bounds.l, bounds.t, bounds.r, bounds.b, 0)) a,
      ];

      // A página como é hoje, com as tarjas pintadas: é daí que saem os remendos.
      RenderedPage? shot;
      var scale = 1.0;
      if (patches.isNotEmpty) {
        scale = (wantsDetail ? 300 : 200) / 72;
        // Páginas enormes: limita o tamanho da imagem.
        final longest = math.max(pw, ph) * scale;
        if (longest > 6000) scale *= 6000 / longest;
        shot = render(page, scale);
        for (final a in areas) {
          final x0 = (a.l * scale).floor().clamp(0, shot.width), x1 = (a.r * scale).ceil().clamp(0, shot.width);
          final y0 = (a.t * scale).floor().clamp(0, shot.height), y1 = (a.b * scale).ceil().clamp(0, shot.height);
          for (var y = y0; y < y1; y++) {
            var i = (y * shot.width + x0) * 4;
            for (var x = x0; x < x1; x++, i += 4) {
              shot.bgra[i] = cb;
              shot.bgra[i + 1] = cg;
              shot.bgra[i + 2] = cr;
              shot.bgra[i + 3] = 255;
            }
          }
        }
      }

      _removeRaw(h, remove);

      if (shot != null) {
        for (final a in patches) {
          final x0 = (a.l * scale).floor().clamp(0, shot.width - 1), x1 = (a.r * scale).ceil().clamp(x0 + 1, shot.width);
          final y0 = (a.t * scale).floor().clamp(0, shot.height - 1), y1 = (a.b * scale).ceil().clamp(y0 + 1, shot.height);
          final w = x1 - x0, ht = y1 - y0;
          final crop = Uint8List(w * ht * 4);
          for (var y = 0; y < ht; y++) {
            final src = ((y0 + y) * shot.width + x0) * 4;
            crop.setRange(y * w * 4, (y + 1) * w * 4, shot.bgra, src);
          }
          // O remendo ocupa exatamente os pixels recortados, para nada sair do lugar.
          _insertBgra(h, page, crop, w, ht, Area(x0 / scale, y0 / scale, x1 / scale, y1 / scale));
          report.patches++;
        }
      }

      // Comentários, links e campos sobre uma tarja.
      final rect = _pdf.alloc<_FsRectF>(32);
      try {
        for (var i = _ra.annotCount(h) - 1; i >= 0; i--) {
          final annot = _ra.getAnnot(h, i);
          if (annot == nullptr) continue;
          var hit = false;
          if (_ra.annotRect(annot, rect) != 0) {
            final box = _viewBox(page, rect.ref.left, rect.ref.bottom, rect.ref.right, rect.ref.top);
            hit = areas.any((a) => a.overlaps(box.l, box.t, box.r, box.b));
          }
          _ra.closeAnnot(annot);
          if (hit && _ra.removeAnnot(h, i) != 0) report.annotations++;
        }
      } finally {
        _pdf.free(rect);
      }

      // A tarja em si.
      final inv = _toView(page).inverse();
      for (final a in areas) {
        final (x0, y0) = inv.apply(a.l, a.t);
        final obj = _pdf.createPath(x0, y0);
        if (obj == nullptr) throw FfError('Não foi possível desenhar a tarja na página ${page + 1}.');
        for (final (x, y) in [(a.r, a.t), (a.r, a.b), (a.l, a.b)]) {
          final (px, py) = inv.apply(x, y);
          _pdf.pathLineTo(obj, px, py);
        }
        _pdf.pathClose(obj);
        _pdf.setFillColor(obj, cr, cg, cb, 255);
        _pdf.pathSetDrawMode(obj, 1, 0);
        _pdf.insertObject(h, obj);
      }
      _generate(page);
    }
    return report;
  }

  /// Confere um arquivo já tarjado: devolve, por página, o texto que ainda está
  /// sob alguma área (o esperado é um mapa vazio).
  Map<int, String> leaks(Map<int, List<Area>> marks) {
    final out = <int, String>{};
    for (final e in marks.entries) {
      if (e.key >= pageCount) continue;
      final left = textUnder(e.key, e.value);
      if (left.isNotEmpty) out[e.key] = left;
    }
    return out;
  }
}
