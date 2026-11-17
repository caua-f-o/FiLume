import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'job.dart';
import 'pdf.dart';
import 'pdfium.dart';

bool _ok(int code) => code == 0 || code == 3;

/// Apaga título, autor, assunto etc. e os metadados XMP de [file], gravando em [out].
Future<bool> scrubMetadata(PdfTools tools, String file, String out) async {
  final r = await Process.run(tools.qpdf, ['--json=2', '--json-stream-data=none', '--json-key=qpdf', file], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (!_ok(r.exitCode)) return false;
  final q = (jsonDecode(r.stdout as String) as Map)['qpdf'] as List;
  final objects = (q[1] as Map).cast<String, dynamic>();
  final trailer = ((objects['trailer'] as Map?)?['value'] as Map?)?.cast<String, dynamic>();
  if (trailer == null) return false;
  final changed = <String, dynamic>{};
  final info = trailer['/Info'];
  if (info is String && objects['obj:$info'] is Map) changed['obj:$info'] = {'value': <String, dynamic>{}};
  final root = trailer['/Root'];
  final rootObj = root is String ? objects['obj:$root'] : null;
  if (rootObj is Map && rootObj['value'] is Map) {
    final value = (jsonDecode(jsonEncode(rootObj['value'])) as Map).cast<String, dynamic>();
    // O PyMuPDF e outros também guardam uma cópia do /Info dentro do catálogo.
    final had = value.remove('/Metadata') != null;
    final hadInfo = value.remove('/Info') != null;
    if (had || hadInfo) changed['obj:$root'] = {'value': value};
  }
  if (changed.isEmpty) return false;
  final upd = File('$out.json');
  try {
    await upd.writeAsString(jsonEncode({
      'qpdf': [q[0], changed],
    }));
    final w = await Process.run(tools.qpdf, [file, '--update-from-json=${upd.path}', out], stdoutEncoding: utf8, stderrEncoding: utf8);
    return _ok(w.exitCode) && File(out).existsSync();
  } finally {
    try {
      await upd.delete();
    } catch (_) {}
  }
}

/// Em quantos textos do arquivo (comentários, marcadores, nomes de anexos,
/// metadados) ainda aparece algum dos [snippets].
Future<int> stillHolding(PdfTools tools, String file, List<String> snippets) async {
  final needles = {for (final s in snippets) s.toLowerCase()}..removeWhere((s) => s.length < 4);
  if (needles.isEmpty) return 0;
  final r = await Process.run(tools.qpdf, ['--json=2', '--json-stream-data=none', '--json-key=qpdf', file], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (!_ok(r.exitCode)) return 0;
  var count = 0;
  void walk(dynamic v) {
    if (v is Map) {
      v.values.forEach(walk);
    } else if (v is List) {
      v.forEach(walk);
    } else if (v is String && v.startsWith('u:')) {
      final low = v.toLowerCase();
      if (needles.any(low.contains)) count++;
    }
  }

  try {
    walk(jsonDecode(r.stdout as String));
  } catch (_) {}
  return count;
}

/// Tarja [file] nas áreas de [marks] (página → áreas) e grava o resultado.
///
/// Depois de gravar, o arquivo é reaberto e conferido: se ainda houver texto sob
/// alguma tarja, nada é entregue.
Job buildRedactJob(
  String file,
  Map<int, List<Area>> marks,
  String outDir,
  String name,
  PdfTools tools, {
  int color = 0xFF000000,
  bool scrub = true,
  void Function(RedactReport report)? onReport,
}) {
  final total = marks.values.fold<int>(0, (n, l) => n + l.length);
  return Job(
    title: '$name.pdf',
    kind: 'Tarjar',
    detail: '$total ${total == 1 ? 'tarja' : 'tarjas'}',
    body: (ctx) async {
      final pdf = Pdfium.load();
      if (pdf == null) throw FfError(Pdfium.loadError ?? 'O componente de PDF não foi encontrado.');
      final work = await Directory.systemTemp.createTemp('filume_tarja_');
      try {
        ctx.report(0.05, stage: 'Preparando');
        final src = await prepareForEdit(tools, file);
        final raw = p.join(work.path, 'tarjado.pdf');
        final RedactReport report;
        final backend = PdfiumBackend.open(src, pdf);
        try {
          ctx.report(0.25, stage: 'Apagando o conteúdo');
          report = backend.redact(marks, color: color);
          backend.save(raw);
        } finally {
          backend.close();
          if (src != file) {
            try {
              await Directory(p.dirname(src)).delete(recursive: true);
            } catch (_) {}
          }
        }
        // O qpdf regrava só o que ainda é usado: o que foi removido das páginas
        // (imagens, textos antigos) não fica esquecido dentro do arquivo.
        ctx.report(0.6, stage: 'Limpando o arquivo');
        var best = p.join(work.path, 'limpo.pdf');
        final r = await Process.run(tools.qpdf, ['--object-streams=generate', '--compress-streams=y', raw, best]);
        if (!_ok(r.exitCode) || !File(best).existsSync()) {
          throw FfError('Não foi possível limpar o arquivo depois de tarjar.', r.stderr.toString());
        }
        if (scrub) {
          final clean = p.join(work.path, 'sem_metadados.pdf');
          if (await scrubMetadata(tools, best, clean)) best = clean;
        }
        ctx.report(0.85, stage: 'Conferindo');
        final check = PdfiumBackend.open(best, pdf);
        final Map<int, String> left;
        try {
          left = check.leaks(marks);
        } finally {
          check.close();
        }
        if (left.isNotEmpty) {
          final pages = (left.keys.map((i) => i + 1).toList()..sort()).join(', ');
          throw FfError('A conferência achou texto ainda legível sob uma tarja (página $pages). Nada foi gravado, por segurança.');
        }
        final elsewhere = await stillHolding(tools, best, report.snippets);
        final out = uniquePath(p.join(outDir, '$name.pdf'));
        await Directory(outDir).create(recursive: true);
        await File(best).copy(out);
        onReport?.call(report);
        final n = report.objects;
        return JobResult(
          '$total ${total == 1 ? 'tarja aplicada' : 'tarjas aplicadas'} · $n ${n == 1 ? 'item apagado' : 'itens apagados'} do arquivo',
          out,
          warning: elsewhere > 0
              ? 'Atenção: o texto tarjado ainda aparece em $elsewhere ${elsewhere == 1 ? 'outro lugar' : 'outros lugares'} do arquivo '
                  '(comentários, marcadores ou anexos). Confira antes de enviar.'
              : (report.patches > 0 ? 'Trechos vizinhos às tarjas viraram imagem (o texto deles não pode mais ser selecionado).' : null),
        );
      } finally {
        try {
          await work.delete(recursive: true);
        } catch (_) {}
      }
    },
  );
}
