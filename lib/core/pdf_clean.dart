import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart' show FfError, uniquePath;
import 'job.dart';
import 'pdf.dart';

// Limpar: tira do PDF o que não aparece na página mas viaja junto com o
// arquivo (dados de autoria, scripts, anexos, comentários, marcadores,
// miniaturas e dados privados de outros programas).
//
// A lista do que remover segue o "Remove Hidden Information" e o otimizador do
// PdfCraft (https://github.com/storytold/pdfcraft, MIT OU Apache-2.0, © 2026
// ArtCraft Team e colaboradores do PdfCraft). O código é novo, sobre o qpdf.

class CleanOptions {
  const CleanOptions({this.metadata = true, this.scripts = true, this.attachments = true, this.comments = false, this.bookmarks = false, this.extras = true});

  /// Título, autor, programa de origem, datas e metadados XMP.
  final bool metadata;

  /// JavaScript e ações automáticas.
  final bool scripts;

  /// Arquivos anexados.
  final bool attachments;

  /// Comentários e marcações (links e campos de formulário ficam).
  final bool comments;

  /// Marcadores (o sumário lateral).
  final bool bookmarks;

  /// Miniaturas das páginas e dados privados de outros programas.
  final bool extras;

  bool get any => metadata || scripts || attachments || comments || bookmarks || extras;
}

class CleanReport {
  int metadata = 0, scripts = 0, attachments = 0, comments = 0, bookmarks = 0, extras = 0;
  int get total => metadata + scripts + attachments + comments + bookmarks + extras;

  String get summary {
    String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
    final parts = [
      if (metadata > 0) 'dados de autoria',
      if (scripts > 0) n(scripts, 'script', 'scripts'),
      if (attachments > 0) n(attachments, 'anexo', 'anexos'),
      if (comments > 0) n(comments, 'comentário', 'comentários'),
      if (bookmarks > 0) 'marcadores',
      if (extras > 0) n(extras, 'dado oculto', 'dados ocultos'),
    ];
    return parts.isEmpty ? 'Não havia nada a remover' : 'Removido: ${parts.join(', ')}';
  }
}

bool _ok(int code) => code == 0 || code == 3;

/// Grava em [out] uma cópia de [file] sem o que [options] pede para tirar.
Future<CleanReport> cleanPdf(PdfTools tools, String file, String out, [CleanOptions options = const CleanOptions()]) async {
  final r = await Process.run(tools.qpdf, ['--json=2', '--json-stream-data=none', '--json-key=qpdf', '--json-key=pages', '--json-key=encrypt', file],
      stdoutEncoding: const Utf8Codec(allowMalformed: true), stderrEncoding: utf8);
  if (!_ok(r.exitCode)) {
    final err = r.stderr.toString();
    throw FfError(err.contains('password') ? '"${p.basename(file)}" é protegido por senha. Remova a senha antes (ferramenta Senha).' : 'Não foi possível ler "${p.basename(file)}".', err);
  }
  final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  if ((j['encrypt'] as Map?)?['encrypted'] == true) throw FfError('Este PDF é protegido. Remova a proteção antes (ferramenta Senha).');
  final q = j['qpdf'] as List;
  final objects = (q[1] as Map).cast<String, dynamic>();
  final changed = <String, dynamic>{};
  final report = CleanReport();

  bool isRef(dynamic v) => v is String && RegExp(r'^\d+ \d+ R$').hasMatch(v);

  /// Cópia editável de um objeto que não é fluxo (dicionário ou lista).
  dynamic edit(String ref) {
    final key = 'obj:$ref';
    if (changed.containsKey(key)) return (changed[key] as Map)['value'];
    final o = objects[key];
    if (o is! Map || !o.containsKey('value')) return null;
    final copy = jsonDecode(jsonEncode(o['value']));
    changed[key] = {'value': copy};
    return copy;
  }

  dynamic peek(dynamic v) {
    if (!isRef(v)) return v;
    final key = 'obj:$v';
    if (changed.containsKey(key)) return (changed[key] as Map)['value'];
    final o = objects[key];
    return o is Map ? (o['value'] ?? (o['stream'] is Map ? (o['stream'] as Map)['dict'] : null)) : null;
  }

  /// Dicionário guardado em [holder] sob [key], pronto para alterar (direto ou por referência).
  Map<String, dynamic>? child(Map holder, String key) {
    final v = holder[key];
    if (isRef(v)) {
      final e = edit(v as String);
      return e is Map ? e.cast<String, dynamic>() : null;
    }
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  final trailer = ((objects['trailer'] as Map?)?['value'] as Map?) ?? const {};
  final rootRef = trailer['/Root'];
  if (!isRef(rootRef)) throw FfError('O PDF tem uma estrutura que não deu para ler.');
  final root = (edit(rootRef as String) as Map).cast<String, dynamic>();
  bool script(dynamic action) {
    final a = peek(action);
    return a is Map && (a['/S'] == '/JavaScript' || a.containsKey('/JS'));
  }

  if (options.metadata) {
    final info = trailer['/Info'];
    final cur = peek(info);
    if (isRef(info) && cur is Map && cur.isNotEmpty) {
      changed['obj:$info'] = {'value': <String, dynamic>{}};
      report.metadata++;
    }
    if (root.remove('/Metadata') != null) report.metadata++;
    if (root.remove('/Info') != null) report.metadata++;
  }
  if (options.scripts) {
    final names = child(root, '/Names');
    if (names != null && names.remove('/JavaScript') != null) report.scripts++;
    if (script(root['/OpenAction'])) {
      root.remove('/OpenAction');
      report.scripts++;
    }
    if (root.remove('/AA') != null) report.scripts++;
  }
  if (options.attachments) {
    final names = child(root, '/Names');
    if (names != null) {
      final files = peek(names['/EmbeddedFiles']);
      if (names.remove('/EmbeddedFiles') != null) {
        // Conta os anexos pelos nomes da árvore (pares nome, arquivo).
        var n = 0;
        void count(dynamic node) {
          final d = peek(node);
          if (d is! Map) return;
          final list = peek(d['/Names']);
          if (list is List) n += list.length ~/ 2;
          final kids = peek(d['/Kids']);
          if (kids is List) kids.forEach(count);
        }

        count(files);
        report.attachments += n == 0 ? 1 : n;
      }
    }
    root.remove('/AF');
  }
  if (options.bookmarks) {
    final outlines = peek(root['/Outlines']);
    if (root.remove('/Outlines') != null && outlines is Map && outlines.containsKey('/First')) report.bookmarks++;
    if (root['/PageMode'] == '/UseOutlines') root.remove('/PageMode');
  }
  if (options.extras) {
    if (root.remove('/PieceInfo') != null) report.extras++;
  }

  for (final pg in (j['pages'] as List? ?? const [])) {
    final ref = pg is Map ? pg['object'] : null;
    if (!isRef(ref)) continue;
    final now = peek(ref);
    if (now is! Map) continue;
    Map<String, dynamic>? page;
    Map<String, dynamic> pageEdit() => page ??= (edit(ref as String) as Map).cast<String, dynamic>();
    if (options.extras) {
      for (final k in const ['/Thumb', '/PieceInfo']) {
        if (now.containsKey(k)) {
          pageEdit().remove(k);
          report.extras++;
        }
      }
    }
    if (options.scripts && now.containsKey('/AA')) {
      pageEdit().remove('/AA');
      report.scripts++;
    }
    final annotsRaw = now['/Annots'];
    final annots = peek(annotsRaw);
    if (annots is! List || annots.isEmpty) continue;
    final keep = <dynamic>[];
    final dropped = <dynamic>{};
    for (final a in annots) {
      final d = peek(a);
      if (d is! Map) {
        keep.add(a);
        continue;
      }
      final sub = d['/Subtype'];
      if (options.attachments && sub == '/FileAttachment') {
        report.attachments++;
        dropped.add(a);
        continue;
      }
      if (options.comments && sub != '/Link' && sub != '/Widget') {
        if (sub != '/Popup') report.comments++;
        dropped.add(a);
        continue;
      }
      if (options.scripts && (script(d['/A']) || d.containsKey('/AA')) && isRef(a)) {
        final e = edit(a as String);
        if (e is Map) {
          if (script(e['/A'])) e.remove('/A');
          e.remove('/AA');
          report.scripts++;
        }
      }
      keep.add(a);
    }
    // Balões (popups) de anotações removidas apontam de volta para elas e as
    // manteriam no arquivo: saem junto.
    keep.removeWhere((a) {
      final d = peek(a);
      return d is Map && d['/Subtype'] == '/Popup' && dropped.contains(d['/Parent']);
    });
    if (keep.length != annots.length) {
      if (isRef(annotsRaw)) {
        changed['obj:$annotsRaw'] = {'value': keep};
      } else if (keep.isEmpty) {
        pageEdit().remove('/Annots');
      } else {
        pageEdit()['/Annots'] = keep;
      }
    }
  }

  final work = await Directory.systemTemp.createTemp('filume_limpar_');
  try {
    final upd = File(p.join(work.path, 'limpar.json'));
    await upd.writeAsString(jsonEncode({
      'qpdf': [q[0], changed],
    }));
    // O qpdf regrava só o que ainda é usado: o que foi desligado acima sai do arquivo.
    final w = await Process.run(tools.qpdf, [file, '--update-from-json=${upd.path}', '--object-streams=generate', out], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (!_ok(w.exitCode) || !File(out).existsSync()) throw FfError('Não foi possível gravar o arquivo limpo.', w.stderr.toString());
  } finally {
    try {
      await work.delete(recursive: true);
    } catch (_) {}
  }
  return report;
}

Job buildCleanJob(PdfTools tools, String file, String outDir, String name, CleanOptions options) => Job(
      title: '$name.pdf',
      kind: 'Limpar',
      detail: p.basename(file),
      body: (ctx) async {
        ctx.report(0.3, stage: 'Limpando');
        await Directory(outDir).create(recursive: true);
        final out = uniquePath(p.join(outDir, '$name.pdf'));
        final report = await cleanPdf(tools, file, out, options);
        return JobResult(report.summary, out);
      },
    );
