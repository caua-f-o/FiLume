import 'dart:ui' show PathMetric;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import 'geo.dart';

/// Cartão colorido com um detalhe geométrico à direita.
class GeoCard extends StatefulWidget {
  const GeoCard({
    super.key,
    required this.motif,
    required this.child,
    this.onTap,
    this.motifSize = 100,
    this.motifAlign = Alignment.centerRight,
    this.motifOffset = const Offset(-12, 0),
    this.radius = 22,
    this.padding = const EdgeInsets.all(18),
    this.tonal = true,
    this.dashed = false,
  });
  final String motif;
  final Widget child;
  final VoidCallback? onTap;
  final double motifSize;
  final Alignment motifAlign;
  final Offset motifOffset;
  final double radius;
  final EdgeInsets padding;

  /// true: fundo na cor do tema (destaque). false: fundo neutro.
  final bool tonal;
  final bool dashed;

  @override
  State<GeoCard> createState() => _GeoCardState();
}

class _GeoCardState extends State<GeoCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = widget.tonal ? cs.onPrimaryContainer : cs.onSurface;
    final base = widget.tonal ? cs.primaryContainer : cs.surfaceContainerLow;
    final radius = BorderRadius.circular(widget.radius);
    final lift = _hover && widget.onTap != null;
    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      transform: Matrix4.translationValues(0, lift ? -3 : 0, 0),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: widget.dashed
            ? null
            : Border.all(color: lift && !widget.tonal ? cs.primary : Colors.transparent),
        gradient: widget.dashed
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [base, Color.alphaBlend(base.withValues(alpha: 0.6), cs.surfaceContainerLow)],
              ),
        boxShadow: [
          if (lift && widget.tonal)
            BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 24, offset: const Offset(0, 10)),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (h) => setState(() => _hover = h),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned.fill(
                  child: Align(
                    alignment: widget.motifAlign,
                    child: Transform.translate(
                      offset: widget.motifOffset,
                      child: Motif(
                        widget.motif,
                        size: widget.motifSize,
                        color: (widget.tonal ? fg : cs.primary).withValues(alpha: 0.22),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: widget.padding,
                  child: DefaultTextStyle.merge(style: TextStyle(color: fg), child: widget.child),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.dashed) {
      card = CustomPaint(
        foregroundPainter: DashedBorderPainter(color: cs.outline, radius: widget.radius, width: 1),
        child: card,
      );
    }
    return card;
  }
}

/// Borda tracejada com cantos arredondados.
class DashedBorderPainter extends CustomPainter {
  DashedBorderPainter({required this.color, required this.radius, this.width = 2});
  final Color color;
  final double radius;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius((Offset.zero & size).deflate(width / 2), Radius.circular(radius));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    for (final PathMetric m in (Path()..addRRect(rect)).computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 12) {
        canvas.drawPath(m.extractPath(d, (d + 7).clamp(0, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorderPainter old) => old.color != color || old.radius != radius || old.width != width;
}

/// Botão principal em pílula com um cantinho dobrado, como folha de arquivo.
class FoldButton extends StatelessWidget {
  const FoldButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primary,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              right: 18,
              child: CustomPaint(size: const Size(18, 18), painter: _FoldPainter(cs.onPrimary.withValues(alpha: 0.24))),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
              child: Text(
                label,
                style: TextStyle(color: cs.onPrimary, fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FoldPainter extends CustomPainter {
  _FoldPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_FoldPainter old) => old.color != color;
}

/// Área grande para soltar arquivos, com ícone, texto e botão empilhados.
class DropZone extends StatefulWidget {
  const DropZone({super.key, required this.text, required this.onFiles, required this.onPick});
  final String text;
  final void Function(List<String> paths) onFiles;
  final VoidCallback onPick;

  @override
  State<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<DropZone> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        widget.onFiles([for (final f in d.files) f.path]);
      },
      child: CustomPaint(
        foregroundPainter: DashedBorderPainter(color: _dragging ? cs.primary : cs.outline, radius: 28),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: _dragging
                ? Color.alphaBlend(cs.primary.withValues(alpha: 0.10), cs.surfaceContainerLow)
                : cs.surfaceContainerLow,
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.all(28),
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 150,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        OverflowBox(
                          maxWidth: 236,
                          maxHeight: 236,
                          child: AnimatedScale(
                            scale: _dragging ? 0.86 : 1,
                            duration: const Duration(milliseconds: 260),
                            curve: Curves.easeOutBack,
                            child: Motif('drop', size: 236, color: cs.primary.withValues(alpha: 0.24)),
                          ),
                        ),
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.elliptical(28, 34),
                              topRight: Radius.elliptical(48, 30),
                              bottomRight: Radius.elliptical(32, 46),
                              bottomLeft: Radius.elliptical(44, 42),
                            ),
                            boxShadow: [BoxShadow(color: cs.primary.withValues(alpha: 0.22), blurRadius: 44)],
                          ),
                          child: Icon(Icons.file_upload_outlined, size: 34, color: cs.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Solte arquivos aqui', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: Text(
                      widget.text,
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.45),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FoldButton(label: 'Escolher arquivos', onPressed: widget.onPick),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Selo pequeno ("em breve").
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.background});
  final String text;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color ?? cs.onSurfaceVariant),
      ),
    );
  }
}
