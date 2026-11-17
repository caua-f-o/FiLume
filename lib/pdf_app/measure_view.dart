import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/measure.dart';
import '../core/state.dart';
import '../ui/common.dart';
import 'doc_view.dart';
import 'pdf_app.dart' show ToolButton;

enum MeasureMode { distance, area }

class Measurement {
  Measurement(this.page, this.mode, this.points);
  final int page;
  final MeasureMode mode;
  final List<(double, double)> points;
}

class MeasureSession extends DocSession {
  MeasureSession(super.state);

  MeasureMode mode = MeasureMode.distance;
  MeasureUnit unit = MeasureUnit.mm;
  MeasureScale scale = const MeasureScale();
  final List<Measurement> done = [];

  /// Medida em andamento (os pontos já clicados).
  int? livePage;
  final List<(double, double)> live = [];

  @override
  void onDocChanged() {
    done.clear();
    live.clear();
    livePage = null;
  }

  void tap(int page, double x, double y) {
    if (livePage != page) {
      live.clear();
      livePage = page;
    }
    live.add((x, y));
    if (mode == MeasureMode.distance && live.length == 2) finish();
    notifyListeners();
  }

  /// Fecha a medida em andamento.
  void finish() {
    final page = livePage;
    final need = mode == MeasureMode.distance ? 2 : 3;
    if (page != null && live.length >= need) done.add(Measurement(page, mode, [...live]));
    live.clear();
    livePage = null;
    notifyListeners();
  }

  void cancelLive() {
    live.clear();
    livePage = null;
    notifyListeners();
  }

  String describe(Measurement m) => m.mode == MeasureMode.distance
      ? formatLength(pathLength(m.points), unit, scale)
      : '${formatArea(polygonArea(m.points), unit, scale)} · contorno ${formatLength(pathLength(m.points, closed: true), unit, scale)}';

  String asText() {
    final sb = StringBuffer('Medidas de ${p.basename(path ?? '')}${scale.isIdentity ? '' : ' (escala $scale)'}\r\n');
    for (final m in done) {
      sb.write('Página ${m.page + 1} · ${m.mode == MeasureMode.distance ? 'Distância' : 'Área'}: ${describe(m)}\r\n');
    }
    return sb.toString();
  }
}

class MeasureView extends StatefulWidget {
  const MeasureView({super.key, required this.state, required this.session});
  final AppState state;
  final MeasureSession session;

  @override
  State<MeasureView> createState() => _MeasureViewState();
}

class _MeasureViewState extends State<MeasureView> {
  late final _scale = TextEditingController(text: widget.session.scale.toString());
  bool _scaleBad = false;
  MeasureSession get s => widget.session;

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  Future<void> _open([String? file]) async {
    final path = file ?? await pickPdf();
    if (path != null) s.open(path);
  }

  void _paint(Canvas canvas, int page, double zoom, ColorScheme cs) {
    final line = Paint()
      ..color = cs.primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fill = Paint()..color = cs.primary.withValues(alpha: 0.16);
    final dot = Paint()..color = cs.primary;
    void shape(List<(double, double)> pts, MeasureMode mode, bool closed, String? label) {
      if (pts.isEmpty) return;
      final path = Path()..moveTo(pts.first.$1 * zoom, pts.first.$2 * zoom);
      for (final q in pts.skip(1)) {
        path.lineTo(q.$1 * zoom, q.$2 * zoom);
      }
      if (closed) {
        path.close();
        canvas.drawPath(path, fill);
      }
      canvas.drawPath(path, line);
      for (final q in pts) {
        canvas.drawCircle(Offset(q.$1 * zoom, q.$2 * zoom), 3.5, dot);
      }
      if (label == null) return;
      // Rótulo no meio da medida, sobre um fundo para ler em qualquer página.
      final cx = pts.map((q) => q.$1).reduce((a, b) => a + b) / pts.length * zoom;
      final cy = pts.map((q) => q.$2).reduce((a, b) => a + b) / pts.length * zoom;
      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final box = Rect.fromCenter(center: Offset(cx, cy - (mode == MeasureMode.distance ? 14 : 0)), width: tp.width + 12, height: tp.height + 6);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(8)), Paint()..color = cs.primary);
      tp.paint(canvas, Offset(box.left + 6, box.top + 3));
    }

    for (final m in s.done) {
      if (m.page == page) shape(m.points, m.mode, m.mode == MeasureMode.area, s.describe(m).split(' · ').first);
    }
    if (s.livePage == page) shape(s.live, s.mode, false, null);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final open = s.doc != null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Panel(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          ToolButton(icon: Icons.folder_open_outlined, label: 'Abrir', onTap: _open),
                          const SizedBox(width: 10),
                          ToolButton(
                            icon: Icons.straighten,
                            label: 'Distância',
                            active: s.mode == MeasureMode.distance,
                            enabled: open,
                            onTap: () => s.set(() {
                              s.mode = MeasureMode.distance;
                              s.live.clear();
                            }),
                          ),
                          ToolButton(
                            icon: Icons.pentagon_outlined,
                            label: 'Área',
                            active: s.mode == MeasureMode.area,
                            enabled: open,
                            onTap: () => s.set(() {
                              s.mode = MeasureMode.area;
                              s.live.clear();
                            }),
                          ),
                          if (s.mode == MeasureMode.area && s.live.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            FilledButton.tonal(onPressed: s.live.length >= 3 ? s.finish : null, child: const Text('Fechar a área')),
                            TextButton(onPressed: s.cancelLive, child: const Text('Cancelar')),
                          ],
                          const Spacer(),
                          ToolButton(icon: Icons.zoom_out, label: 'Menos', enabled: open, onTap: () => s.setZoom(s.zoom / 1.2)),
                          ToolButton(icon: Icons.zoom_in, label: 'Mais', enabled: open, onTap: () => s.setZoom(s.zoom * 1.2)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: DocArea(
                        session: s,
                        icon: Icons.straighten,
                        title: 'Medir',
                        intro: 'Mede distâncias e áreas sobre a página, com escala para plantas e mapas.',
                        onOpen: _open,
                        onTap: s.tap,
                        overlay: (canvas, page, zoom) => _paint(canvas, page, zoom, cs),
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

  Widget _side(BuildContext context, bool open) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Medir', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            s.mode == MeasureMode.distance
                ? 'Clique no ponto inicial e no ponto final.'
                : 'Clique em cada canto da área e depois em "Fechar a área".',
            style: small,
          ),
          const SectionLabel('Unidade'),
          SegmentedButton<MeasureUnit>(
            segments: [for (final u in MeasureUnit.values) ButtonSegment(value: u, label: Text(u.label))],
            selected: {s.unit},
            showSelectedIcon: false,
            onSelectionChanged: (v) => s.set(() => s.unit = v.first),
          ),
          const SectionLabel('Escala do desenho'),
          TextField(
            controller: _scale,
            onChanged: (v) {
              final parsed = MeasureScale.parse(v);
              setState(() => _scaleBad = parsed == null);
              if (parsed != null) s.set(() => s.scale = parsed);
            },
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              hintText: '1:100',
              helperText: 'Papel : real. Use 1:1 para medir o tamanho no papel.',
              errorText: _scaleBad ? 'Escreva como 1:100' : null,
            ),
          ),
          SectionLabel('Medidas (${s.done.length})'),
          Expanded(
            child: s.done.isEmpty
                ? Text(open ? 'Nenhuma medida ainda.' : 'Abra um PDF para começar.', style: small)
                : ListView.builder(
                    itemCount: s.done.length,
                    itemBuilder: (context, i) {
                      final m = s.done[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(m.mode == MeasureMode.distance ? Icons.straighten : Icons.pentagon_outlined, size: 20),
                        title: Text(s.describe(m)),
                        subtitle: Text('Página ${m.page + 1}'),
                        trailing: IconButton(
                          tooltip: 'Tirar esta medida',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => s.set(() => s.done.removeAt(i)),
                        ),
                      );
                    },
                  ),
          ),
          if (s.done.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: s.asText()));
                    messenger.showSnackBar(const SnackBar(content: Text('Medidas copiadas.')));
                  },
                  child: const Text('Copiar as medidas'),
                ),
                TextButton(onPressed: () => s.set(s.done.clear), child: const Text('Limpar')),
              ],
            ),
          const SizedBox(height: 6),
          Text('As medidas não alteram o arquivo.', style: small),
        ],
      ),
    );
  }
}
