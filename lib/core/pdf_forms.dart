import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart' show FfError, uniquePath;
import 'job.dart';
import 'pdf.dart';

// Formulários de PDF: ler os campos, preencher e "achatar" (os valores viram
// parte da página e deixam de ser editáveis).
//
// A lista de recursos (tipos de campo, valores herdados, estados de caixas e
// botões de opção, achatamento) foi levantada a partir do módulo de formulários
// do PdfCraft (https://github.com/storytold/pdfcraft, MIT OU Apache-2.0, © 2026
// ArtCraft Team e colaboradores do PdfCraft). O código aqui é novo: lê e grava a
// estrutura do arquivo pelo qpdf.

enum FieldKind { text, multiline, checkbox, radio, combo, list, signature, button }

class PdfField {
  PdfField({
    required this.name,
    required this.kind,
    required this.page,
    required this.value,
    this.options = const [],
    this.readOnly = false,
    this.required = false,
    this.maxLength,
    this.label,
  });

  /// Nome completo do campo (único no formulário).
  final String name;
  final FieldKind kind;

  /// Página (a partir de 1) onde o campo aparece.
  final int page;

  /// Texto, opção escolhida, ou '1'/'' para caixas de marcar.
  final String value;
  final List<String> options;
  final bool readOnly, required;
  final int? maxLength;

  /// Descrição do campo, quando o arquivo traz uma.
  final String? label;

  bool get fillable => !readOnly && kind != FieldKind.signature && kind != FieldKind.button;
}

class PdfForm {
  PdfForm(this.fields, this._header, this._objects, this._nodes);
  final List<PdfField> fields;
  final Map<String, dynamic> _header;
  final Map<String, dynamic> _objects;

  /// Por campo: o objeto que guarda o valor e os que aparecem na página.
  final Map<String, _Node> _nodes;

  bool get isEmpty => fields.isEmpty;
}

class _Node {
  _Node(this.owner, this.kind);
  final String owner;
  final FieldKind kind;

  /// Objeto de cada aparição na página → nome do estado "ligado" (caixas e opções).
  final Map<String, String?> widgets = {};
}

bool _okExit(int code) => code == 0 || code == 3;

String _str(dynamic v) {
  if (v is! String) return '';
  if (v.startsWith('u:')) return v.substring(2);
  if (v.startsWith('b:')) {
    // Texto em bytes: PDFDocEncoding, que para o que interessa coincide com Latin-1.
    final hex = v.substring(2);
    return String.fromCharCodes([for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
  }
  if (v.startsWith('/')) return v.substring(1);
  return v;
}

/// Lê os campos de formulário de [file]. Devolve um formulário vazio se não houver.
Future<PdfForm> readForm(PdfTools tools, String file) async {
  final r = await Process.run(
    tools.qpdf,
    ['--json=2', '--json-stream-data=none', '--json-key=acroform', '--json-key=qpdf', file],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (!_okExit(r.exitCode)) {
    final err = r.stderr.toString();
    throw FfError(
      err.contains('password') ? '"${p.basename(file)}" é protegido por senha. Remova a senha antes (ferramenta Senha).' : 'Não foi possível ler "${p.basename(file)}".',
      err,
    );
  }
  final Map<String, dynamic> j;
  try {
    j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  } on FormatException catch (e) {
    throw FfError('O arquivo tem uma estrutura que não deu para ler.', '$e');
  }
  final q = j['qpdf'] as List;
  final header = (q[0] as Map).cast<String, dynamic>();
  final objects = (q[1] as Map).cast<String, dynamic>();
  Map<String, dynamic>? dict(String? ref) {
    final o = objects['obj:$ref'];
    if (o is! Map) return null;
    final v = o['value'] ?? (o['stream'] is Map ? (o['stream'] as Map)['dict'] : null);
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  /// Procura [key] no campo e, se faltar, nos pais (valores herdados).
  dynamic inherited(String? ref, String key) {
    for (var hops = 0; ref != null && hops < 32; hops++) {
      final d = dict(ref);
      if (d == null) return null;
      if (d.containsKey(key)) return d[key];
      final parent = d['/Parent'];
      ref = parent is String ? parent : null;
    }
    return null;
  }

  final fields = <PdfField>[];
  final nodes = <String, _Node>{};
  final list = (j['acroform'] is Map ? (j['acroform'] as Map)['fields'] : null) as List? ?? const [];
  for (final raw in list) {
    if (raw is! Map) continue;
    final name = raw['fullname'] as String? ?? '';
    final widget = raw['object'] as String?;
    if (name.isEmpty || widget == null) continue;
    final type = raw['fieldtype'] as String? ?? '';
    final flags = (raw['fieldflags'] as num?)?.toInt() ?? 0;
    final FieldKind kind;
    if (type == '/Tx') {
      kind = flags & 0x1000 != 0 ? FieldKind.multiline : FieldKind.text;
    } else if (type == '/Ch') {
      kind = flags & 0x20000 != 0 ? FieldKind.combo : FieldKind.list;
    } else if (type == '/Btn') {
      kind = raw['isradiobutton'] == true ? FieldKind.radio : (raw['ischeckbox'] == true ? FieldKind.checkbox : FieldKind.button);
    } else if (type == '/Sig') {
      kind = FieldKind.signature;
    } else {
      continue;
    }
    // O valor mora no nó que tem o nome (/T): o próprio objeto ou um dos pais.
    var owner = widget;
    for (var hops = 0; hops < 32; hops++) {
      final d = dict(owner);
      if (d == null || d.containsKey('/T')) break;
      final parent = d['/Parent'];
      if (parent is! String) break;
      owner = parent;
    }
    // Estado "ligado" desta aparição: a chave de /AP /N que não é /Off.
    String? on;
    if (kind == FieldKind.checkbox || kind == FieldKind.radio) {
      var n = (dict(widget)?['/AP'] as Map?)?['/N'];
      if (n is String) n = dict(n);
      if (n is Map) on = n.keys.cast<String>().where((k) => k != '/Off').firstOrNull;
      on ??= '/Yes';
    }
    final existing = nodes[name];
    if (existing != null) {
      // Outra aparição do mesmo campo (botões de opção, campo repetido em páginas).
      existing.widgets[widget] = on;
      if (kind == FieldKind.radio && on != null) {
        final i = fields.indexWhere((f) => f.name == name);
        final f = fields[i];
        fields[i] = PdfField(
          name: f.name,
          kind: f.kind,
          page: f.page,
          value: f.value,
          options: [...f.options, if (!f.options.contains(on.substring(1))) on.substring(1)],
          readOnly: f.readOnly,
          required: f.required,
          label: f.label,
        );
      }
      continue;
    }
    final node = _Node(owner, kind)..widgets[widget] = on;
    nodes[name] = node;
    final v = inherited(owner, '/V');
    String value;
    if (kind == FieldKind.checkbox) {
      value = v is String && v != '/Off' && v.startsWith('/') ? '1' : '';
    } else if (kind == FieldKind.radio) {
      value = v is String && v != '/Off' && v.startsWith('/') ? v.substring(1) : '';
    } else if (v is List) {
      value = v.isEmpty ? '' : _str(v.first);
    } else {
      value = _str(v);
    }
    final tu = inherited(owner, '/TU');
    final maxLen = inherited(owner, '/MaxLen');
    fields.add(PdfField(
      name: name,
      kind: kind,
      page: (raw['pageposfrom1'] as num?)?.toInt() ?? 0,
      value: value,
      options: kind == FieldKind.radio
          ? [if (on != null) on.substring(1)]
          : [for (final c in (raw['choices'] as List? ?? const [])) c.toString()],
      readOnly: flags & 1 != 0,
      required: flags & 2 != 0,
      maxLength: maxLen is num && maxLen > 0 ? maxLen.toInt() : null,
      label: tu is String && _str(tu).trim().isNotEmpty ? _str(tu) : null,
    ));
  }
  return PdfForm(fields, header, objects, nodes);
}

/// Grava em [out] uma cópia de [file] com os [values] (nome do campo → valor)
/// preenchidos. Com [flatten], os campos viram conteúdo fixo da página.
Future<void> fillForm(PdfTools tools, String file, String out, PdfForm form, Map<String, String> values, {bool flatten = false}) async {
  final changed = <String, Map<String, dynamic>>{};
  Map<String, dynamic>? edit(String ref) {
    final key = 'obj:$ref';
    final cur = changed[key];
    if (cur != null) return cur['value'] as Map<String, dynamic>;
    final o = form._objects[key];
    if (o is! Map || o['value'] is! Map) return null;
    final copy = (jsonDecode(jsonEncode(o['value'])) as Map).cast<String, dynamic>();
    changed[key] = {'value': copy};
    return copy;
  }

  var needAppearances = false;
  for (final e in values.entries) {
    final node = form._nodes[e.key];
    final field = form.fields.where((f) => f.name == e.key).firstOrNull;
    if (node == null || field == null) throw FfError('O formulário não tem o campo "${e.key}".');
    if (!field.fillable) continue;
    final owner = edit(node.owner);
    if (owner == null) throw FfError('O campo "${e.key}" tem uma estrutura que não deu para alterar.');
    var v = e.value;
    switch (node.kind) {
      case FieldKind.text || FieldKind.multiline || FieldKind.combo || FieldKind.list:
        if (node.kind == FieldKind.text) v = v.replaceAll(RegExp(r'[\r\n]+'), ' ');
        final max = field.maxLength;
        if (max != null && v.length > max) v = v.substring(0, max);
        if (node.kind == FieldKind.list && v.isNotEmpty && !field.options.contains(v)) {
          throw FfError('"$v" não é uma das opções do campo "${e.key}".');
        }
        if (v.isEmpty) {
          owner.remove('/V');
        } else {
          owner['/V'] = 'u:$v';
        }
        owner.remove('/I');
        // A aparência antiga mostra o valor antigo: é refeita ao gravar.
        for (final w in node.widgets.keys) {
          edit(w)?.remove('/AP');
        }
        needAppearances = true;
      case FieldKind.checkbox:
        final on = v.isNotEmpty && v != '0' && v.toLowerCase() != 'false';
        final state = node.widgets.values.whereType<String>().firstOrNull ?? '/Yes';
        owner['/V'] = on ? state : '/Off';
        for (final w in node.widgets.entries) {
          edit(w.key)?['/AS'] = on ? (w.value ?? state) : '/Off';
        }
      case FieldKind.radio:
        if (v.isNotEmpty && !field.options.contains(v)) throw FfError('"$v" não é uma das opções do campo "${e.key}".');
        owner['/V'] = v.isEmpty ? '/Off' : '/$v';
        for (final w in node.widgets.entries) {
          edit(w.key)?['/AS'] = v.isNotEmpty && w.value == '/$v' ? w.value : '/Off';
        }
      case FieldKind.signature || FieldKind.button:
        break;
    }
  }

  if (needAppearances) {
    // O dicionário do formulário pode estar solto ou dentro do catálogo.
    Map<String, dynamic>? acro;
    final trailer = form._objects['trailer'];
    final rootRef = trailer is Map && trailer['value'] is Map ? (trailer['value'] as Map)['/Root'] : null;
    if (rootRef is String) {
      final rootNow = form._objects['obj:$rootRef'];
      final cur = rootNow is Map && rootNow['value'] is Map ? (rootNow['value'] as Map)['/AcroForm'] : null;
      if (cur is String) {
        acro = edit(cur);
      } else if (cur is Map) {
        acro = (edit(rootRef)?['/AcroForm'] as Map?)?.cast<String, dynamic>();
        if (acro != null) edit(rootRef)!['/AcroForm'] = acro;
      }
    }
    if (acro != null) {
      acro['/NeedAppearances'] = true;
      // O qpdf só escreve acentos se a fonte do campo declarar a codificação
      // (WinAnsi cobre o português); sem isso, "é" e "ç" viram "?".
      final names = <String>{};
      for (final e in values.keys) {
        final node = form._nodes[e];
        if (node == null) continue;
        Object? da;
        String? ref = node.owner;
        for (var hops = 0; ref != null && hops < 32 && da == null; hops++) {
          final o = form._objects['obj:$ref'];
          final d = o is Map ? o['value'] : null;
          if (d is! Map) break;
          da = d['/DA'];
          final parent = d['/Parent'];
          ref = parent is String ? parent : null;
        }
        da ??= acro['/DA'];
        final m = RegExp(r'/([^\s/]+)\s+[\d.]+\s+Tf').firstMatch(_str(da));
        if (m != null) names.add('/${m[1]}');
      }
      Map<String, dynamic>? sub(Map<String, dynamic> parent, String key) {
        final cur = parent[key];
        if (cur is String) return edit(cur);
        if (cur is Map) return parent[key] = cur.cast<String, dynamic>();
        if (cur == null) return parent[key] = <String, dynamic>{};
        return null;
      }

      final fonts = sub(acro, '/DR').let((dr) => dr == null ? null : sub(dr, '/Font'));
      if (fonts != null) {
        const winAnsi = '/WinAnsiEncoding';
        for (final name in names) {
          final cur = fonts[name];
          if (cur == null) {
            fonts[name] = {'/Type': '/Font', '/Subtype': '/Type1', '/BaseFont': '/Helvetica', '/Encoding': winAnsi};
            continue;
          }
          final font = cur is String ? edit(cur) : (cur is Map ? cur.cast<String, dynamic>() : null);
          if (font == null) continue;
          final subtype = font['/Subtype'], base = '${font['/BaseFont']}';
          final simple = subtype == '/Type1' || subtype == '/TrueType';
          final symbolic = base.contains('Symbol') || base.contains('Dingbats');
          if (simple && !symbolic && !font.containsKey('/Encoding')) {
            font['/Encoding'] = winAnsi;
            if (cur is Map) fonts[name] = font;
          }
        }
      }
    }
  }

  final work = await Directory.systemTemp.createTemp('filume_form_');
  try {
    final args = <String>[file];
    if (changed.isNotEmpty) {
      final upd = File(p.join(work.path, 'valores.json'));
      await upd.writeAsString(jsonEncode({
        'qpdf': [form._header, changed],
      }));
      args.add('--update-from-json=${upd.path}');
    }
    if (needAppearances || flatten) args.add('--generate-appearances');
    if (flatten) args.add('--flatten-annotations=all');
    args.add(out);
    final r = await Process.run(tools.qpdf, args, stdoutEncoding: utf8, stderrEncoding: utf8);
    if (!_okExit(r.exitCode) || !File(out).existsSync()) {
      throw FfError('Não foi possível gravar o formulário preenchido.', r.stderr.toString());
    }
  } finally {
    try {
      await work.delete(recursive: true);
    } catch (_) {}
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

/// Tarefa que grava o formulário preenchido.
Job buildFillJob(PdfTools tools, String file, PdfForm form, Map<String, String> values, String outDir, String name, {bool flatten = false}) {
  final n = values.length;
  return Job(
    title: '$name.pdf',
    kind: flatten ? 'Preencher e achatar' : 'Preencher',
    detail: '$n ${n == 1 ? 'campo' : 'campos'}',
    body: (ctx) async {
      ctx.report(0.2, stage: 'Gravando os valores');
      await Directory(outDir).create(recursive: true);
      final out = uniquePath(p.join(outDir, '$name.pdf'));
      await fillForm(tools, file, out, form, values, flatten: flatten);
      // Letras que a fonte do campo não tem viram "?": avisa em vez de entregar calado.
      final odd = [
        for (final e in values.entries)
          if (e.value.runes.any((r) => r > 255 && !_winAnsiExtra.contains(r))) e.key,
      ];
      return JobResult(
        flatten ? 'Formulário preenchido e achatado' : 'Formulário preenchido',
        out,
        warning: odd.isEmpty
            ? null
            : 'Alguns símbolos (${odd.take(3).join(', ')}) podem não aparecer: a fonte dos campos só tem as letras do alfabeto latino.',
      );
    },
  );
}

/// Caracteres acima de 255 que a codificação WinAnsi também tem.
const _winAnsiExtra = {
  0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x017D, //
  0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x017E, 0x0178,
};
