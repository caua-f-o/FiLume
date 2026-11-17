import 'dart:convert';
import 'dart:io';

// Marcadores (o sumário lateral) ao reorganizar e unir PDFs: o qpdf monta as
// páginas, mas o documento novo nasce sem marcadores. Aqui eles são lidos dos
// arquivos de origem e refeitos apontando para as páginas na posição nova.
//
// O comportamento segue o módulo de organização do PdfCraft
// (https://github.com/storytold/pdfcraft, MIT OU Apache-2.0, © 2026 ArtCraft
// Team e colaboradores do PdfCraft): marcadores de páginas que saíram somem,
// os filhos de um marcador sem página sobem para o lugar dele. O código é novo.

class _Item {
  _Item(this.title, this.page, this.tail, this.open, this.kids);
  final String title;

  /// Página na posição nova (a partir de 1), ou null se ela saiu.
  int? page;
  final List<dynamic> tail;
  final bool open;
  final List<_Item> kids;
}

bool _ok(int code) => code == 0 || code == 3;

Future<Map<String, dynamic>?> _json(String qpdf, List<String> args) async {
  final r = await Process.run(qpdf, args, stdoutEncoding: const Utf8Codec(allowMalformed: true), stderrEncoding: utf8);
  if (!_ok(r.exitCode)) return null;
  try {
    return jsonDecode(r.stdout as String) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// [parts] são as páginas do documento novo, em ordem: (arquivo, página de origem a partir de 1).
/// Grava os marcadores em [out] (no lugar). Devolve quantos marcadores entraram;
/// qualquer problema deixa o arquivo como estava.
Future<int> carryOutlines(String qpdf, List<(String, int)> parts, String out) async {
  // Página de origem → primeira posição nova, por arquivo.
  final where = <String, Map<int, int>>{};
  for (var i = 0; i < parts.length; i++) {
    where.putIfAbsent(parts[i].$1, () => {}).putIfAbsent(parts[i].$2, () => i + 1);
  }
  final roots = <_Item>[];
  for (final file in where.keys) {
    final j = await _json(qpdf, ['--json=2', '--json-key=outlines', file]);
    final list = j?['outlines'];
    if (list is! List) continue;
    _Item? read(dynamic o) {
      if (o is! Map) return null;
      final from = (o['destpageposfrom1'] as num?)?.toInt();
      final dest = o['dest'];
      final kids = [for (final k in (o['kids'] as List? ?? const [])) ?read(k)];
      final item = _Item(
        '${o['title'] ?? ''}',
        from == null ? null : where[file]![from],
        dest is List && dest.length > 1 ? dest.sublist(1) : const ['/Fit'],
        o['open'] == true,
        kids,
      );
      // Sem página: aponta para o primeiro filho que ficou, ou some se nenhum ficou.
      if (item.page == null) {
        if (kids.isEmpty) return null;
        return _Item(item.title, kids.first.page, const ['/Fit'], item.open, kids);
      }
      return item;
    }

    for (final o in list) {
      final it = read(o);
      if (it != null) roots.add(it);
    }
  }
  if (roots.isEmpty) return 0;
  // Na ordem das páginas novas (ao unir, o primeiro arquivo vem antes).
  roots.sort((a, b) => (a.page ?? 0).compareTo(b.page ?? 0));

  final j = await _json(qpdf, ['--json=2', '--json-stream-data=none', '--json-key=qpdf', '--json-key=pages', out]);
  if (j == null) return 0;
  final q = j['qpdf'] as List;
  final header = (q[0] as Map).cast<String, dynamic>();
  final objects = (q[1] as Map).cast<String, dynamic>();
  final pages = [for (final pg in (j['pages'] as List? ?? const [])) (pg as Map)['object'] as String];
  final rootRef = ((objects['trailer'] as Map)['value'] as Map)['/Root'] as String;
  final catalog = (jsonDecode(jsonEncode((objects['obj:$rootRef'] as Map)['value'])) as Map).cast<String, dynamic>();

  var next = (header['maxobjectid'] as num).toInt();
  String alloc() => '${++next} 0 R';
  final changed = <String, dynamic>{};
  var count = 0;

  /// Escreve [items] como filhos de [parent]; devolve (primeiro, último, visíveis).
  (String, String, int) write(List<_Item> items, String parent) {
    final refs = [for (final _ in items) alloc()];
    var visible = 0;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      count++;
      final page = pages[(it.page! - 1).clamp(0, pages.length - 1)];
      final tail = it.tail.isEmpty || it.tail.first is! String ? const ['/Fit'] : it.tail;
      final d = <String, dynamic>{
        '/Title': 'u:${it.title}',
        '/Parent': parent,
        '/Dest': [page, ...tail],
        if (i > 0) '/Prev': refs[i - 1],
        if (i + 1 < items.length) '/Next': refs[i + 1],
      };
      if (it.kids.isNotEmpty) {
        final (first, last, inner) = write(it.kids, refs[i]);
        d['/First'] = first;
        d['/Last'] = last;
        // Positivo = aberto (mostra os filhos); negativo = fechado.
        d['/Count'] = it.open ? inner : -it.kids.length;
        if (it.open) visible += inner;
      }
      changed['obj:${refs[i]}'] = {'value': d};
      visible++;
    }
    return (refs.first, refs.last, visible);
  }

  final outlinesRef = alloc();
  final (first, last, visible) = write(roots, outlinesRef);
  changed['obj:$outlinesRef'] = {
    'value': {'/Type': '/Outlines', '/First': first, '/Last': last, '/Count': visible},
  };
  catalog['/Outlines'] = outlinesRef;
  changed['obj:$rootRef'] = {'value': catalog};
  header['maxobjectid'] = next;

  final dir = await Directory.systemTemp.createTemp('filume_marc_');
  try {
    final upd = File('${dir.path}${Platform.pathSeparator}marcadores.json');
    await upd.writeAsString(jsonEncode({
      'qpdf': [header, changed],
    }));
    final tmp = '${dir.path}${Platform.pathSeparator}com_marcadores.pdf';
    final r = await Process.run(qpdf, [out, '--update-from-json=${upd.path}', '--object-streams=generate', tmp], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (!_ok(r.exitCode) || !File(tmp).existsSync()) return 0;
    await File(tmp).copy(out);
    return count;
  } catch (_) {
    return 0;
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}
