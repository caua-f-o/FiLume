part of 'pdfium.dart';

// Comentários e marcações (anotações do PDF): listar, criar e remover.
//
// O conjunto de recursos segue o módulo de anotações do PdfCraft
// (https://github.com/storytold/pdfcraft, MIT OU Apache-2.0, © 2026 ArtCraft
// Team e colaboradores do PdfCraft). O código aqui é novo, sobre o PDFium.

enum NoteKind {
  note('Nota', 1),
  highlight('Marca-texto', 9),
  underline('Sublinhado', 10),
  strikeout('Riscado', 12),
  box('Retângulo', 5),
  other('Outro', 0);

  const NoteKind(this.label, this.subtype);
  final String label;
  final int subtype;
}

/// Uma anotação da página.
class PdfNote {
  PdfNote({required this.page, required this.index, required this.kind, required this.typeName, required this.area, this.text = '', this.author = '', this.date = ''});
  final int page;

  /// Posição na lista de anotações da página (muda quando algo é removido).
  final int index;
  final NoteKind kind;

  /// Nome do tipo para mostrar (inclui os que o FiPDF não cria, como "Carimbo").
  final String typeName;
  final Area area;
  final String text, author, date;
}

final class _FsQuad extends Struct {
  @Float()
  external double x1;
  @Float()
  external double y1;
  @Float()
  external double x2;
  @Float()
  external double y2;
  @Float()
  external double x3;
  @Float()
  external double y3;
  @Float()
  external double x4;
  @Float()
  external double y4;
}

class _AnnotApi {
  _AnnotApi(DynamicLibrary lib)
      : create = lib.lookupFunction<_H Function(_H, Int32), _H Function(_H, int)>('FPDFPage_CreateAnnot'),
        subtype = lib.lookupFunction<Int32 Function(_H), int Function(_H)>('FPDFAnnot_GetSubtype'),
        setRect = lib.lookupFunction<Int32 Function(_H, Pointer<_FsRectF>), int Function(_H, Pointer<_FsRectF>)>('FPDFAnnot_SetRect'),
        setColor = lib.lookupFunction<Int32 Function(_H, Int32, Uint32, Uint32, Uint32, Uint32), int Function(_H, int, int, int, int, int)>('FPDFAnnot_SetColor'),
        appendQuad = lib.lookupFunction<Int32 Function(_H, Pointer<_FsQuad>), int Function(_H, Pointer<_FsQuad>)>('FPDFAnnot_AppendAttachmentPoints'),
        setString = lib.lookupFunction<Int32 Function(_H, Pointer<Uint8>, Pointer<Uint16>), int Function(_H, Pointer<Uint8>, Pointer<Uint16>)>(
            'FPDFAnnot_SetStringValue'),
        getString = lib.lookupFunction<UnsignedLong Function(_H, Pointer<Uint8>, Pointer<Uint16>, UnsignedLong),
            int Function(_H, Pointer<Uint8>, Pointer<Uint16>, int)>('FPDFAnnot_GetStringValue'),
        setFlags = lib.lookupFunction<Int32 Function(_H, Int32), int Function(_H, int)>('FPDFAnnot_SetFlags'),
        setAP = lib.lookupFunction<Int32 Function(_H, Int32, Pointer<Uint16>), int Function(_H, int, Pointer<Uint16>)>('FPDFAnnot_SetAP');

  final _H Function(_H, int) create;
  final int Function(_H) subtype;
  final int Function(_H, Pointer<_FsRectF>) setRect;
  final int Function(_H, int, int, int, int, int) setColor;
  final int Function(_H, Pointer<_FsQuad>) appendQuad;
  final int Function(_H, Pointer<Uint8>, Pointer<Uint16>) setString;
  final int Function(_H, Pointer<Uint8>, Pointer<Uint16>, int) getString;
  final int Function(_H, int) setFlags;
  final int Function(_H, int, Pointer<Uint16>) setAP;
}

const _subtypeNames = <int, String>{
  1: 'Nota', 2: 'Link', 3: 'Texto livre', 4: 'Linha', 5: 'Retângulo', 6: 'Elipse', 7: 'Polígono', 8: 'Linha quebrada', //
  9: 'Marca-texto', 10: 'Sublinhado', 11: 'Sublinhado ondulado', 12: 'Riscado', 13: 'Carimbo', 14: 'Sinal de inserção', 15: 'Traço à mão',
  16: 'Balão', 17: 'Anexo', 18: 'Som', 19: 'Vídeo', 20: 'Campo de formulário', 21: 'Tela', 24: 'Marca-d\'água', 28: 'Marca de tarja',
};

/// Data no formato do PDF (D:AAAAMMDDHHmmSS) → "dd/mm/aaaa hh:mm".
String formatPdfDate(String raw) {
  final m = RegExp(r'^D?:?(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?').firstMatch(raw.trim());
  if (m == null) return raw.trim();
  final d = '${m[3] ?? '01'}/${m[2] ?? '01'}/${m[1]}';
  return m[4] == null ? d : '$d ${m[4]}:${m[5] ?? '00'}';
}

extension Annotations on PdfiumBackend {
  _AnnotApi get _aa => _pdf._annot;

  String _annotString(_H annot, String key) {
    final k = _pdf.cstr(key);
    try {
      final need = _aa.getString(annot, k, nullptr, 0);
      if (need <= 2) return '';
      final buf = _pdf.alloc<Uint16>(need + 2);
      try {
        final got = _aa.getString(annot, k, buf, need);
        final units = buf.asTypedList(got ~/ 2).toList();
        while (units.isNotEmpty && units.last == 0) {
          units.removeLast();
        }
        return String.fromCharCodes(units);
      } finally {
        _pdf.free(buf);
      }
    } finally {
      _pdf.free(k);
    }
  }

  void _setAnnotString(_H annot, String key, String value) {
    final k = _pdf.cstr(key);
    final v = _pdf.wstr(value);
    _aa.setString(annot, k, v);
    _pdf.free(k);
    _pdf.free(v);
  }

  /// Comentários e marcações da página. Links, campos de formulário e balões
  /// (que só repetem o texto da nota a que pertencem) ficam de fora, a não ser
  /// com [all].
  List<PdfNote> notes(int page, {bool all = false}) {
    final h = _page(page);
    final rect = _pdf.alloc<_FsRectF>(32);
    final out = <PdfNote>[];
    try {
      final n = _ra.annotCount(h);
      for (var i = 0; i < n; i++) {
        final annot = _ra.getAnnot(h, i);
        if (annot == nullptr) continue;
        try {
          final sub = _aa.subtype(annot);
          if (!all && (sub == 2 || sub == 16 || sub == 20)) continue;
          var area = const Area(0, 0, 0, 0);
          if (_ra.annotRect(annot, rect) != 0) area = _viewBox(page, rect.ref.left, rect.ref.bottom, rect.ref.right, rect.ref.top);
          out.add(PdfNote(
            page: page,
            index: i,
            kind: NoteKind.values.firstWhere((k) => k.subtype == sub, orElse: () => NoteKind.other),
            typeName: _subtypeNames[sub] ?? 'Anotação',
            area: area,
            text: _annotString(annot, 'Contents'),
            author: _annotString(annot, 'T'),
            date: formatPdfDate(_annotString(annot, 'M')),
          ));
        } finally {
          _ra.closeAnnot(annot);
        }
      }
    } finally {
      _pdf.free(rect);
    }
    return out;
  }

  /// Cria um comentário. [areas] são as caixas na tela: uma para nota e
  /// retângulo, uma por linha para marca-texto, sublinhado e riscado.
  void addNote(int page, NoteKind kind, List<Area> areas, {String text = '', String author = '', int color = 0xFFFFD54F, DateTime? when}) {
    if (areas.isEmpty || kind == NoteKind.other) return;
    final h = _page(page);
    final annot = _aa.create(h, kind.subtype);
    if (annot == nullptr) throw FfError('Não foi possível criar o comentário na página ${page + 1}.');
    final inv = _toView(page).inverse();
    final rect = _pdf.alloc<_FsRectF>(32);
    final quad = _pdf.alloc<_FsQuad>(64);
    try {
      var box = areas.first;
      for (final a in areas.skip(1)) {
        box = box.union(a);
      }
      if (kind == NoteKind.note) box = Area(box.l, box.t, box.l + 20, box.t + 20);
      // Caixa na página: os quatro cantos da tela levados de volta.
      final xs = <double>[], ys = <double>[];
      for (final (x, y) in [(box.l, box.t), (box.r, box.t), (box.r, box.b), (box.l, box.b)]) {
        final (px, py) = inv.apply(x, y);
        xs.add(px);
        ys.add(py);
      }
      rect.ref
        ..left = xs.reduce(math.min)
        ..right = xs.reduce(math.max)
        ..bottom = ys.reduce(math.min)
        ..top = ys.reduce(math.max);
      _aa.setRect(annot, rect);
      final r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255;
      _aa.setColor(annot, 0, r, g, b, 255);
      if (kind == NoteKind.highlight || kind == NoteKind.underline || kind == NoteKind.strikeout) {
        for (final a in areas) {
          final (x1, y1) = inv.apply(a.l, a.t);
          final (x2, y2) = inv.apply(a.r, a.t);
          final (x3, y3) = inv.apply(a.l, a.b);
          final (x4, y4) = inv.apply(a.r, a.b);
          quad.ref
            ..x1 = x1
            ..y1 = y1
            ..x2 = x2
            ..y2 = y2
            ..x3 = x3
            ..y3 = y3
            ..x4 = x4
            ..y4 = y4;
          _aa.appendQuad(annot, quad);
        }
      }
      if (text.isNotEmpty) _setAnnotString(annot, 'Contents', text);
      if (author.isNotEmpty) _setAnnotString(annot, 'T', author);
      final d = (when ?? DateTime.now()).toUtc();
      String two(int v) => v.toString().padLeft(2, '0');
      _setAnnotString(annot, 'M', "D:${d.year}${two(d.month)}${two(d.day)}${two(d.hour)}${two(d.minute)}${two(d.second)}Z");
      _aa.setFlags(annot, 4); // sai na impressão
    } finally {
      _pdf.free(rect);
      _pdf.free(quad);
      _ra.closeAnnot(annot);
    }
  }

  /// Remove anotações da página pelos índices de [notes].
  int removeNotes(int page, Iterable<int> indices) {
    final h = _page(page);
    var n = 0;
    for (final i in indices.toSet().toList()..sort((a, b) => b.compareTo(a))) {
      if (_ra.removeAnnot(h, i) != 0) n++;
    }
    return n;
  }
}

/// Lista de comentários em texto simples, para colar num e-mail ou guardar.
String notesAsText(String fileName, List<PdfNote> notes) {
  final sb = StringBuffer('Comentários de $fileName\r\n');
  var page = -1;
  for (final n in notes) {
    if (n.page != page) {
      page = n.page;
      sb.write('\r\nPágina ${page + 1}\r\n');
    }
    final who = [if (n.author.isNotEmpty) n.author, if (n.date.isNotEmpty) n.date].join(', ');
    sb.write('- ${n.typeName}${who.isEmpty ? '' : ' ($who)'}${n.text.isEmpty ? '' : ': ${n.text.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ')}'}\r\n');
  }
  if (notes.isEmpty) sb.write('\r\n(nenhum comentário)\r\n');
  return sb.toString();
}

extension TextLines on PdfiumBackend {
  /// Caixas, uma por linha, do texto cujos caracteres têm o centro dentro de
  /// [within]. Vazio se não há texto ali.
  List<Area> lineBoxes(int page, Area within) {
    final rows = <Area>[];
    for (final c in chars(page)) {
      if (!c.hasBox || c.code <= 32) continue;
      final x = (c.l + c.r) / 2, y = (c.t + c.b) / 2;
      if (!within.hasPoint(x, y)) continue;
      final box = Area(c.l, c.t, c.r, c.b);
      final i = rows.indexWhere((r) => y >= r.t && y <= r.b);
      if (i < 0) {
        rows.add(box);
      } else {
        rows[i] = rows[i].union(box);
      }
    }
    // Linhas que se sobrepõem na vertical (letras altas e baixas) viram uma só.
    rows.sort((a, b) => a.t.compareTo(b.t));
    final out = <Area>[];
    for (final r in rows) {
      if (out.isNotEmpty && (math.min(out.last.b, r.b) - math.max(out.last.t, r.t)) > 0.5 * math.min(out.last.height, r.height)) {
        out[out.length - 1] = out.last.union(r);
      } else {
        out.add(r);
      }
    }
    return out;
  }
}
