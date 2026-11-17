import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';
import '../core/pdfium.dart';
import '../core/redact_job.dart';
import '../core/state.dart';
import '../ui/common.dart';
import '../ui/process_button.dart';
import 'pdf_app.dart' show JobStatusCard, ToolButton;
import 'save_dialog.dart';

/// O documento aberto na ferramenta de tarja e as áreas marcadas.
class RedactSession extends ChangeNotifier {
  RedactSession(this.state);
  final AppState state;

  PdfiumBackend? doc;
  String? path;
  String? error;
  double zoom = 1.1;

  /// Página → áreas marcadas (coordenadas de tela da página, em pontos).
  final Map<int, List<Area>> marks = {};
  final List<(int, Area)> _history = [];
  int color = 0xFF000000;
  bool scrub = true;
  bool searching = false;
  String? searchNote;

  final Map<int, ui.Image> _images = {};
  final Map<int, double> _imageScale = {};
  final Set<int> _rendering = {};

  String get name => path == null ? 'documento' : '${p.basenameWithoutExtension(path!)}_tarjado';
  int get count => marks.values.fold(0, (n, l) => n + l.length);
  int get pageCount => doc?.pageCount ?? 0;

  void _dropImages() {
    for (final i in _images.values) {
      i.dispose();
    }
    _images.clear();
    _imageScale.clear();
    _rendering.clear();
  }

  void close() {
    doc?.close();
    doc = null;
    path = null;
    marks.clear();
    _history.clear();
    searchNote = null;
    _dropImages();
    notifyListeners();
  }

  void open(String file) {
    close();
    error = null;
    final pdf = Pdfium.load();
    if (pdf == null) {
      error = Pdfium.loadError ?? 'O componente de PDF não foi encontrado.';
    } else {
      try {
        doc = PdfiumBackend.open(file, pdf);
        path = file;
      } on FfError catch (e) {
        error = e.message;
      }
    }
    notifyListeners();
  }

  void setZoom(double z) {
    zoom = z.clamp(0.4, 4.0);
    notifyListeners();
  }

  void add(int page, Area a) {
    if (a.width < 2 || a.height < 2) return;
    marks.putIfAbsent(page, () => []).add(a);
    _history.add((page, a));
    notifyListeners();
  }

  void remove(int page, Area a) {
    marks[page]?.remove(a);
    if (marks[page]?.isEmpty ?? false) marks.remove(page);
    _history.remove((page, a));
    notifyListeners();
  }

  void undo() {
    if (_history.isEmpty) return;
    final (page, a) = _history.removeLast();
    marks[page]?.remove(a);
    if (marks[page]?.isEmpty ?? false) marks.remove(page);
    notifyListeners();
  }

  void clear() {
    marks.clear();
    _history.clear();
    searchNote = null;
    notifyListeners();
  }

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  /// Marca todas as ocorrências de [query] no documento.
  Future<void> markAll(String query) async {
    final d = doc;
    if (d == null || query.trim().length < 2 || searching) return;
    searching = true;
    searchNote = null;
    notifyListeners();
    var found = 0, pages = 0;
    try {
      for (var i = 0; i < d.pageCount; i++) {
        if (doc != d) return;
        final hits = d.findText(i, query.trim());
        if (hits.isNotEmpty) pages++;
        for (final h in hits) {
          found++;
          for (final b in h.boxes) {
            // Não repete uma área já marcada.
            if (!(marks[i]?.any((a) => a.contains(b.l, b.t, b.r, b.b, 0.5)) ?? false)) {
              marks.putIfAbsent(i, () => []).add(b);
              _history.add((i, b));
            }
          }
        }
        // Deixa a tela respirar em documentos longos.
        if (i % 4 == 3) await Future<void>.delayed(Duration.zero);
      }
      searchNote = found == 0
          ? 'Nenhuma ocorrência de "$query". Se o PDF for digitalizado sem OCR, marque as áreas com o mouse.'
          : '$found ${found == 1 ? 'ocorrência marcada' : 'ocorrências marcadas'} em $pages ${pages == 1 ? 'página' : 'páginas'}.';
    } on FfError catch (e) {
      searchNote = e.message;
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  ui.Image? imageFor(int page, double dpr) {
    final d = doc;
    if (d == null) return null;
    final want = zoom * dpr;
    final have = _imageScale[page];
    if ((have == null || (have - want).abs() > 0.01) && !_rendering.contains(page)) {
      _rendering.add(page);
      Future<void>.delayed(Duration.zero, () {
        if (doc != d) return;
        try {
          final (w, h) = d.pageSize(page);
          final scale = math.min(want, math.sqrt(14e6 / (w * h)));
          final rp = d.render(page, scale);
          ui.decodeImageFromPixels(rp.bgra, rp.width, rp.height, ui.PixelFormat.bgra8888, (img) {
            _rendering.remove(page);
            if (doc != d) {
              img.dispose();
              return;
            }
            _images[page]?.dispose();
            _images[page] = img;
            _imageScale[page] = want;
            notifyListeners();
          });
        } catch (_) {
          _rendering.remove(page);
        }
      });
    }
    return _images[page];
  }

  @override
  void dispose() {
    doc?.close();
    doc = null;
    _dropImages();
    super.dispose();
  }
}

class RedactView extends StatefulWidget {
  const RedactView({super.key, required this.state, required this.session});
  final AppState state;
  final RedactSession session;

  @override
  State<RedactView> createState() => _RedactViewState();
}

class _RedactViewState extends State<RedactView> {
  final _query = TextEditingController();
  RedactSession get session => widget.session;
  AppState get state => widget.state;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _open([String? file]) async {
    final path = file ?? (await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'PDF', extensions: ['pdf'])]))?.path;
    if (path != null) session.open(path);
  }

  Future<void> _save() async {
    final pdf = state.pdf, src = session.path;
    if (pdf == null || src == null || session.count == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tarjar de verdade?'),
        content: const Text(
          'O conteúdo sob as tarjas é apagado do arquivo novo e não tem como voltar. '
          'O arquivo original não é alterado: o resultado é salvo como uma cópia.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tarjar e salvar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final choice = await showSaveDialog(context, state.prefs, title: 'Salvar PDF tarjado', name: session.name, originalDir: p.dirname(src));
    if (choice == null) return;
    final marks = {for (final e in session.marks.entries) e.key: [...e.value]};
    state.queue.addAll([buildRedactJob(src, marks, choice.dir, choice.name, pdf, color: session.color, scrub: session.scrub)..module = 'pdf']);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final open = session.doc != null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ribbon(context, open),
                    const SizedBox(height: 12),
                    Expanded(
                      child: DropTarget(
                        onDragDone: (d) {
                          final pdfs = [for (final f in d.files) if (f.path.toLowerCase().endsWith('.pdf')) f.path];
                          if (pdfs.isNotEmpty) _open(pdfs.first);
                        },
                        child: Panel(
                          padding: const EdgeInsets.all(6),
                          child: open ? _Pages(session: session) : _empty(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(width: 320, child: _side(context, open)),
            ],
          ),
        );
      },
    );
  }

  Widget _ribbon(BuildContext context, bool open) {
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          ToolButton(icon: Icons.folder_open_outlined, label: 'Abrir', tip: 'Abrir outro PDF', onTap: _open),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _query,
              enabled: open,
              onSubmitted: session.markAll,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Texto a tarjar em todo o documento (nome, CPF…)',
                prefixIcon: const Icon(Icons.search, size: 20),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: open && !session.searching ? () => session.markAll(_query.text) : null,
            child: Text(session.searching ? 'Procurando…' : 'Marcar todas'),
          ),
          const SizedBox(width: 8),
          ToolButton(icon: Icons.undo, label: 'Desfazer', tip: 'Tirar a última marca', enabled: session.count > 0, onTap: session.undo),
          ToolButton(icon: Icons.zoom_out, label: 'Menos', enabled: open, onTap: () => session.setZoom(session.zoom / 1.2)),
          ToolButton(icon: Icons.zoom_in, label: 'Mais', enabled: open, onTap: () => session.setZoom(session.zoom * 1.2)),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.format_color_fill, size: 64, color: cs.primary),
          const SizedBox(height: 14),
          Text('Tarjar', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(
              'Esconde informações para valer: o que fica sob a tarja é apagado do arquivo, não só coberto. '
              'Solte um PDF aqui ou escolha um arquivo.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: _open, icon: const Icon(Icons.folder_open_outlined, size: 18), label: const Text('Abrir PDF…')),
          if (session.error != null) ...[
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(session.error!, textAlign: TextAlign.center, style: TextStyle(color: cs.error)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _side(BuildContext context, bool open) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    final n = session.count;
    final pages = session.marks.keys.toList()..sort();
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Tarjar', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Arraste o mouse sobre a página para marcar uma área, ou procure um texto para marcar todas as vezes em que ele aparece. '
            'Clique numa marca para tirá-la.',
            style: small,
          ),
          if (session.searchNote != null) ...[
            const SizedBox(height: 10),
            Text(session.searchNote!, style: t.textTheme.bodySmall?.copyWith(color: cs.primary)),
          ],
          const SectionLabel('Marcas'),
          Expanded(
            child: n == 0
                ? Text(open ? 'Nenhuma área marcada ainda.' : 'Abra um PDF para começar.', style: small)
                : ListView(
                    children: [
                      for (final pg in pages)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.description_outlined, size: 20),
                          title: Text('Página ${pg + 1}'),
                          trailing: Text('${session.marks[pg]!.length}', style: t.textTheme.labelLarge),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(onPressed: session.clear, child: const Text('Limpar todas')),
                      ),
                    ],
                  ),
          ),
          const SectionLabel('Cor da tarja'),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0xFF000000, label: Text('Preta')),
              ButtonSegment(value: 0xFFFFFFFF, label: Text('Branca')),
            ],
            selected: {session.color},
            showSelectedIcon: false,
            onSelectionChanged: (s) => session.set(() => session.color = s.first),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Apagar título, autor e outros dados do arquivo'),
            subtitle: const Text('Esses dados costumam repetir nomes que foram tarjados.'),
            value: session.scrub,
            onChanged: (v) => session.set(() => session.scrub = v),
          ),
          const SizedBox(height: 10),
          JobStatusCard(queue: state.queue),
          ProcessButton(
            queue: state.queue,
            label: !open ? 'Abra um PDF' : (n == 0 ? 'Marque o que tarjar' : 'Tarjar e salvar ($n)'),
            onPressed: open && n > 0 && state.pdf != null ? _save : null,
          ),
        ],
      ),
    );
  }
}

class _Pages extends StatelessWidget {
  const _Pages({required this.session});
  final RedactSession session;

  @override
  Widget build(BuildContext context) {
    final d = session.doc!;
    final cs = Theme.of(context).colorScheme;
    var widest = 0.0;
    for (var i = 0; i < math.min(d.pageCount, 40); i++) {
      widest = math.max(widest, d.pageSize(i).$1);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: ColoredBox(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(box.maxWidth, widest * session.zoom + 48),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 20),
                itemCount: d.pageCount,
                itemBuilder: (context, i) {
                  final (w, h) = d.pageSize(i);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Center(
                      child: SizedBox(width: w * session.zoom, height: h * session.zoom, child: _Page(session: session, index: i)),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatefulWidget {
  const _Page({required this.session, required this.index});
  final RedactSession session;
  final int index;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  Offset? _from, _to;

  RedactSession get s => widget.session;

  Area? get _drawing {
    final a = _from, b = _to;
    if (a == null || b == null) return null;
    return Area.fromPoints(a.dx / s.zoom, a.dy / s.zoom, b.dx / s.zoom, b.dy / s.zoom);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final image = s.imageFor(widget.index, MediaQuery.devicePixelRatioOf(context));
    final marks = s.marks[widget.index] ?? const <Area>[];
    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final x = d.localPosition.dx / s.zoom, y = d.localPosition.dy / s.zoom;
          final hit = marks.lastWhere((a) => a.hasPoint(x, y), orElse: () => const Area(0, 0, 0, 0));
          if (hit.width > 0) s.remove(widget.index, hit);
        },
        onPanStart: (d) => setState(() => _from = _to = d.localPosition),
        onPanUpdate: (d) => setState(() => _to = d.localPosition),
        onPanCancel: () => setState(() => _from = _to = null),
        onPanEnd: (_) {
          final a = _drawing;
          setState(() => _from = _to = null);
          if (a != null) s.add(widget.index, a);
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 14, offset: const Offset(0, 4))],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (image != null) RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
              CustomPaint(painter: _MarksPainter(marks, _drawing, s.zoom, cs.error, s.color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarksPainter extends CustomPainter {
  _MarksPainter(this.marks, this.drawing, this.zoom, this.accent, this.color);
  final List<Area> marks;
  final Area? drawing;
  final double zoom;
  final Color accent;
  final int color;

  @override
  void paint(Canvas canvas, Size size) {
    // Meio transparente, para ainda dar para ler o que vai ser apagado.
    final fill = Paint()..color = (color == 0xFF000000 ? Colors.black : Colors.white).withValues(alpha: 0.55);
    final edge = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final a in [...marks, if (drawing != null) drawing!]) {
      final r = Rect.fromLTRB(a.l * zoom, a.t * zoom, a.r * zoom, a.b * zoom);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, edge);
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => true;
}
