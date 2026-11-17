import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/ffmpeg.dart';
import '../core/pdfium.dart';
import '../core/state.dart';
import '../ui/common.dart';

/// Base das ferramentas que mostram as páginas de um PDF e deixam a pessoa
/// apontar coisas nelas (comentários, medidas).
class DocSession extends ChangeNotifier {
  DocSession(this.state);
  final AppState state;

  PdfiumBackend? doc;
  String? path;
  String? error;
  double zoom = 1.1;

  final Map<int, ui.Image> _images = {};
  final Map<int, double> _imageScale = {};
  final Set<int> _rendering = {};

  int get pageCount => doc?.pageCount ?? 0;

  /// Chamado depois que um arquivo abre ou fecha.
  void onDocChanged() {}

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
    _dropImages();
    onDocChanged();
    notifyListeners();
  }

  void open(String file) {
    doc?.close();
    doc = null;
    path = null;
    _dropImages();
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
    onDocChanged();
    notifyListeners();
  }

  void setZoom(double z) {
    zoom = z.clamp(0.4, 4.0);
    notifyListeners();
  }

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  /// A página mudou no arquivo: a imagem dela precisa ser refeita.
  void invalidate(int page) {
    _imageScale.remove(page);
    notifyListeners();
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

Future<String?> pickPdf() async => (await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'PDF', extensions: ['pdf'])]))?.path;

/// Área das páginas (ou a tela de boas-vindas da ferramenta), aceitando PDFs soltos.
class DocArea extends StatelessWidget {
  const DocArea({
    super.key,
    required this.session,
    required this.icon,
    required this.title,
    required this.intro,
    required this.onOpen,
    this.overlay,
    this.onDrag,
    this.onTap,
    this.dragPreview,
  });
  final DocSession session;
  final IconData icon;
  final String title, intro;
  final void Function([String? file]) onOpen;

  /// Desenho por cima da página (em coordenadas da página; o zoom já vem aplicado na tela).
  final void Function(Canvas canvas, int page, double zoom)? overlay;
  final void Function(int page, Area area)? onDrag;
  final void Function(int page, double x, double y)? onTap;

  /// Como mostrar a área enquanto o mouse arrasta.
  final void Function(Canvas canvas, Rect rect)? dragPreview;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final d = session.doc;
    return DropTarget(
      onDragDone: (drop) {
        final pdfs = [for (final f in drop.files) if (f.path.toLowerCase().endsWith('.pdf')) f.path];
        if (pdfs.isNotEmpty) onOpen(pdfs.first);
      },
      child: Panel(
        padding: const EdgeInsets.all(6),
        child: d == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 64, color: cs.primary),
                    const SizedBox(height: 14),
                    Text(title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Text('$intro Solte um PDF aqui ou escolha um arquivo.',
                          textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.folder_open_outlined, size: 18), label: const Text('Abrir PDF…')),
                    if (session.error != null) ...[
                      const SizedBox(height: 16),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Text(session.error!, textAlign: TextAlign.center, style: TextStyle(color: cs.error)),
                      ),
                    ],
                  ],
                ),
              )
            : _pages(context, d, cs),
      ),
    );
  }

  Widget _pages(BuildContext context, PdfiumBackend d, ColorScheme cs) {
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
                      child: SizedBox(width: w * session.zoom, height: h * session.zoom, child: _DocPage(area: this, index: i)),
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

class _DocPage extends StatefulWidget {
  const _DocPage({required this.area, required this.index});
  final DocArea area;
  final int index;

  @override
  State<_DocPage> createState() => _DocPageState();
}

class _DocPageState extends State<_DocPage> {
  Offset? _from, _to;

  @override
  Widget build(BuildContext context) {
    final a = widget.area, s = a.session;
    final image = s.imageFor(widget.index, MediaQuery.devicePixelRatioOf(context));
    final from = _from, to = _to;
    return MouseRegion(
      cursor: a.onDrag != null || a.onTap != null ? SystemMouseCursors.precise : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: a.onTap == null ? null : (d) => a.onTap!(widget.index, d.localPosition.dx / s.zoom, d.localPosition.dy / s.zoom),
        onPanStart: a.onDrag == null ? null : (d) => setState(() => _from = _to = d.localPosition),
        onPanUpdate: a.onDrag == null ? null : (d) => setState(() => _to = d.localPosition),
        onPanCancel: a.onDrag == null ? null : () => setState(() => _from = _to = null),
        onPanEnd: a.onDrag == null
            ? null
            : (_) {
                final p1 = _from, p2 = _to;
                setState(() => _from = _to = null);
                if (p1 == null || p2 == null) return;
                final area = Area.fromPoints(p1.dx / s.zoom, p1.dy / s.zoom, p2.dx / s.zoom, p2.dy / s.zoom);
                if (area.width > 2 || area.height > 2) a.onDrag!(widget.index, area);
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
              CustomPaint(
                painter: _OverlayPainter((canvas) {
                  a.overlay?.call(canvas, widget.index, s.zoom);
                  if (from != null && to != null) a.dragPreview?.call(canvas, Rect.fromPoints(from, to));
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(this.draw);
  final void Function(Canvas) draw;

  @override
  void paint(Canvas canvas, Size size) => draw(canvas);

  @override
  bool shouldRepaint(_OverlayPainter old) => true;
}
