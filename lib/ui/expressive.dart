import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Elementos no espírito do Material 3 Expressive: formas que se transformam,
/// progresso ondulado e movimento com um leve "quique".

const expressiveCurve = Curves.easeOutBack;
const expressiveDuration = Duration(milliseconds: 360);

/// Barra de progresso ondulada. Com [value] nulo, a onda ocupa a barra toda.
class WavyProgress extends StatefulWidget {
  const WavyProgress({super.key, required this.value, this.height = 14});
  final double? value;
  final double height;

  @override
  State<WavyProgress> createState() => _WavyProgressState();
}

class _WavyProgressState extends State<WavyProgress> with SingleTickerProviderStateMixin {
  late final AnimationController _phase =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _WavyPainter(
            phase: _phase,
            value: widget.value,
            color: cs.primary,
            track: cs.secondaryContainer,
          ),
        ),
      ),
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({required this.phase, required this.value, required this.color, required this.track})
      : super(repaint: phase);
  final Animation<double> phase;
  final double? value;
  final Color color;
  final Color track;

  static const _stroke = 4.0, _wavelength = 26.0, _gap = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final amp = math.max(0.0, mid - _stroke / 2 - 0.5);
    final v = value?.clamp(0.0, 1.0);
    final end = v == null ? size.width : math.max(_stroke, size.width * v);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;

    // Trilho reto no trecho que falta, com um ponto no fim.
    if (v != null && end + _gap < size.width - _stroke) {
      paint.color = track;
      canvas.drawLine(Offset(end + _gap, mid), Offset(size.width - _stroke / 2, mid), paint);
    }
    if (v != null) {
      canvas.drawCircle(Offset(size.width - _stroke / 2, mid), _stroke / 2, Paint()..color = color);
    }

    // Trecho concluído: onda em movimento.
    final shift = phase.value * _wavelength;
    final path = Path();
    for (var x = _stroke / 2; x <= end - _stroke / 2; x += 1.5) {
      final y = mid + amp * math.sin((x - shift) / _wavelength * 2 * math.pi);
      x == _stroke / 2 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    paint.color = v == null ? color.withValues(alpha: 0.55) : color;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WavyPainter old) =>
      old.value != value || old.color != color || old.track != track;
}

/// Indicador de atividade: uma forma "biscoito" que gira e pulsa.
class MorphLoader extends StatefulWidget {
  const MorphLoader({super.key, this.size = 26});
  final double size;

  @override
  State<MorphLoader> createState() => _MorphLoaderState();
}

class _MorphLoaderState extends State<MorphLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _t =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: RepaintBoundary(
        child: CustomPaint(painter: _MorphPainter(_t, Theme.of(context).colorScheme.primary)),
      ),
    );
  }
}

class _MorphPainter extends CustomPainter {
  _MorphPainter(this.t, this.color) : super(repaint: t);
  final Animation<double> t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = size.shortestSide / 2 * 0.84;
    final turn = t.value * 2 * math.pi;
    // A profundidade das "pétalas" pulsa: de quase círculo a flor.
    final depth = 0.06 + 0.10 * (0.5 + 0.5 * math.sin(turn * 2));
    final path = Path();
    const steps = 72;
    for (var i = 0; i <= steps; i++) {
      final a = i / steps * 2 * math.pi;
      final r = base * (1 + depth * math.cos(6 * a));
      final p = c + Offset(math.cos(a + turn), math.sin(a + turn)) * r;
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MorphPainter old) => old.color != color;
}

class GroupItem<T> {
  const GroupItem(this.value, this.label, this.icon);
  final T value;
  final String label;
  final IconData icon;
}

/// Grupo de botões conectados: o selecionado vira "pílula" e ganha destaque,
/// os vizinhos ficam mais quadrados.
class ConnectedButtonGroup<T> extends StatelessWidget {
  const ConnectedButtonGroup({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
  });
  final List<GroupItem<T>> items;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(right: i == items.length - 1 ? 0 : 4),
            child: _GroupButton(
              item: items[i],
              selected: items[i].value == selected,
              first: i == 0,
              last: i == items.length - 1,
              onTap: () => onSelected(items[i].value),
            ),
          ),
      ],
    );
  }
}

class _GroupButton extends StatefulWidget {
  const _GroupButton({
    required this.item,
    required this.selected,
    required this.first,
    required this.last,
    required this.onTap,
  });
  final GroupItem<Object?> item;
  final bool selected;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  State<_GroupButton> createState() => _GroupButtonState();
}

class _GroupButtonState extends State<_GroupButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    const outer = Radius.circular(22), inner = Radius.circular(8), pressed = Radius.circular(6);
    final BorderRadius radius;
    if (_down) {
      radius = const BorderRadius.all(pressed);
    } else if (widget.selected) {
      radius = const BorderRadius.all(outer);
    } else {
      radius = BorderRadius.horizontal(
        left: widget.first ? outer : inner,
        right: widget.last ? outer : inner,
      );
    }
    final fg = widget.selected ? cs.onPrimary : cs.onSurfaceVariant;
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedContainer(
        duration: expressiveDuration,
        curve: expressiveCurve,
        height: 44,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: widget.selected ? cs.primary : cs.surfaceContainerHighest.withValues(alpha: 0.7),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            child: AnimatedPadding(
              duration: expressiveDuration,
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(horizontal: widget.selected ? 20 : 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.item.icon, size: 18, color: fg),
                  const SizedBox(width: 8),
                  Text(
                    widget.item.label,
                    style: t.textTheme.labelLarge?.copyWith(
                      color: fg,
                      fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Título de página com tipografia enfatizada.
class PageTitle extends StatelessWidget {
  const PageTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Text(
      text,
      style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
    );
  }
}
