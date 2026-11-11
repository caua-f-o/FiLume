import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'pdf.dart';

/// Bandeja do organizador: as páginas de todos os PDFs e as imagens da lista
/// (arquivos ou digitalizações), na ordem em que vão sair, com giro e seleção.
class Organizer {
  final List<PageRef> pages = [];
  final Set<PageRef> selected = {};
  final Set<String> _known = {};

  /// Acompanha a lista de arquivos: PDFs novos entram no fim, removidos saem.
  void sync(List<MediaInfo> docs) {
    final paths = {for (final d in docs) d.path};
    if (_known.any((k) => !paths.contains(k))) {
      pages.removeWhere((r) => !paths.contains(r.doc.path));
      selected.removeWhere((r) => !paths.contains(r.doc.path));
      _known.removeWhere((k) => !paths.contains(k));
    }
    for (final d in docs) {
      if (_known.add(d.path)) {
        for (var n = 1; n <= d.pages; n++) {
          pages.add(PageRef(d, n));
        }
      }
    }
  }

  void reset(List<MediaInfo> docs) {
    pages.clear();
    selected.clear();
    _known.clear();
    sync(docs);
  }

  /// As selecionadas ou, sem seleção, todas.
  List<PageRef> get targets => selected.isEmpty ? List.of(pages) : pages.where(selected.contains).toList();

  void toggle(PageRef r) => selected.contains(r) ? selected.remove(r) : selected.add(r);

  void rotate(Iterable<PageRef> refs, int delta) {
    for (final r in refs) {
      r.rotation = (r.rotation + delta) % 360;
    }
  }

  /// Zera o "endireitar" das páginas.
  void straightenReset(Iterable<PageRef> refs) {
    for (final r in refs) {
      r.skew = 0;
    }
  }

  void remove(Iterable<PageRef> refs) {
    final gone = refs.toSet();
    pages.removeWhere(gone.contains);
    selected.removeAll(gone);
  }

  void keepSelected() {
    if (selected.isEmpty) return;
    pages.removeWhere((r) => !selected.contains(r));
    selected.clear();
  }

  void move(int from, int to) {
    if (from == to || from < 0 || from >= pages.length || to < 0 || to >= pages.length) return;
    pages.insert(to, pages.removeAt(from));
  }

  void reverse() {
    final r = pages.reversed.toList();
    pages
      ..clear()
      ..addAll(r);
  }
}

class _DocThumbs {
  _DocThumbs(this.dir);
  final String dir;
  int done = 0;
  bool started = false;
}

/// Miniaturas das páginas, desenhadas pelo Ghostscript em segundo plano, um
/// PDF por vez. Ficam em disco (pasta temporária), não na memória.
class PdfThumbs {
  PdfThumbs(this._onUpdate);
  final void Function() _onUpdate;
  final Map<String, _DocThumbs> _docs = {};
  final List<MediaInfo> _queue = [];
  Directory? _root;
  Process? _proc;
  bool _running = false;
  bool _disposed = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  void ensure(MediaInfo doc, PdfTools? tools) {
    if (_disposed || tools?.gs == null || _docs.containsKey(doc.path)) return;
    final root = _root ??= Directory.systemTemp.createTempSync('filume_paginas_');
    final dir = Directory(p.join(root.path, '${_docs.length}'))..createSync();
    _docs[doc.path] = _DocThumbs(dir.path);
    _queue.add(doc);
    _pump(tools!);
  }

  final Map<String, Future<String?>> _views = {};

  /// Página de PDF desenhada em tamanho de leitura, para o visualizador.
  Future<String?> renderPage(MediaInfo doc, int page, PdfTools? tools) {
    final gs = tools?.gs;
    if (_disposed || gs == null) return Future.value(null);
    return _views['${doc.path}#$page'] ??= () async {
      try {
        final root = _root ??= Directory.systemTemp.createTempSync('filume_paginas_');
        final out = p.join(root.path, 'ver_${_views.length}.jpg');
        final r = await Process.run(gs, [
          '-dNOPAUSE', '-dBATCH', '-dSAFER', '-dQUIET',
          '-sDEVICE=jpeg', '-dJPEGQ=88', '-r130', '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
          '-dFirstPage=$page', '-dLastPage=$page', '-sOutputFile=$out', doc.path,
        ]);
        return r.exitCode == 0 && File(out).existsSync() ? out : null;
      } catch (_) {
        return null;
      }
    }();
  }

  /// Arquivo da miniatura, ou null se a página ainda não foi desenhada.
  String? fileFor(String docPath, int page) {
    final d = _docs[docPath];
    if (d == null || page > d.done) return null;
    return p.join(d.dir, 'p_${page.toString().padLeft(5, '0')}.jpg');
  }

  Future<void> _pump(PdfTools tools) async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final doc = _queue.removeAt(0);
        final d = _docs[doc.path]!;
        d.started = true;
        try {
          final proc = await Process.start(tools.gs!, [
            '-dNOPAUSE', '-dBATCH', '-dSAFER',
            '-sDEVICE=jpeg', '-dJPEGQ=72', '-r40', '-dTextAlphaBits=4', '-dGraphicsAlphaBits=4',
            '-sOutputFile=${p.join(d.dir, 'p_%05d.jpg')}', doc.path,
          ]);
          _proc = proc;
          final re = RegExp(r'^Page (\d+)');
          final out = proc.stdout
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())
              .listen((line) {
            final m = re.firstMatch(line);
            if (m == null) return;
            // "Page N" aparece quando a N começa: as anteriores já estão em disco.
            d.done = int.parse(m[1]!) - 1;
            final now = DateTime.now();
            if (now.difference(_lastNotify).inMilliseconds > 350) {
              _lastNotify = now;
              _onUpdate();
            }
          }).asFuture<void>();
          proc.stderr.drain<void>().ignore();
          final code = await proc.exitCode;
          await out.catchError((_) {});
          if (code == 0) d.done = doc.pages;
        } catch (_) {
          // Sem miniaturas, o organizador mostra só o número da página.
        }
        _proc = null;
        if (!_disposed) _onUpdate();
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _proc?.kill();
    try {
      _root?.deleteSync(recursive: true);
    } catch (_) {}
  }
}
