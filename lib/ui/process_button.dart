import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/job.dart';
import '../core/state.dart';

/// "Comprimir" → "Comprimindo"; nomes que não são verbos viram "Processando".
String gerund(String label) {
  final w = label.trim();
  if (w.contains(' ') || w.length < 4) return 'Processando';
  final l = w.toLowerCase();
  if (l.endsWith('ar')) return '${w.substring(0, w.length - 2)}ando';
  if (l.endsWith('er')) return '${w.substring(0, w.length - 2)}endo';
  if (l.endsWith('ir')) return '${w.substring(0, w.length - 2)}indo';
  return 'Processando';
}

enum _Phase { idle, running, done }

/// Botão principal das ferramentas. Ao iniciar, a seta perde a ponta, vira uma
/// barrinha, pula até o topo e desce puxando o enchimento, que acompanha o
/// progresso real da fila. No fim mostra "Concluído" e volta ao estado inicial.
class ProcessButton extends StatefulWidget {
  const ProcessButton({super.key, required this.queue, required this.label, required this.onPressed});
  final JobQueue queue;
  final String label;

  /// null = desabilitado (o rótulo explica o que falta).
  final VoidCallback? onPressed;

  @override
  State<ProcessButton> createState() => _ProcessButtonState();
}

class _ProcessButtonState extends State<ProcessButton> with TickerProviderStateMixin {
  late final AnimationController _jump = AnimationController(vsync: this, duration: const Duration(milliseconds: 340));
  late final AnimationController _fill = AnimationController(vsync: this);
  late final AnimationController _check = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
  _Phase _phase = _Phase.idle;
  String _runLabel = 'Processando';
  Timer? _reset;
  int _batch = 0; // quantas tarefas havia quando a rodada começou

  @override
  void initState() {
    super.initState();
    widget.queue.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(ProcessButton old) {
    super.didUpdateWidget(old);
    if (old.queue != widget.queue) {
      old.queue.removeListener(_sync);
      widget.queue.addListener(_sync);
    }
  }

  @override
  void dispose() {
    widget.queue.removeListener(_sync);
    _reset?.cancel();
    _jump.dispose();
    _fill.dispose();
    _check.dispose();
    super.dispose();
  }

  double _overall() {
    final q = widget.queue;
    final pending = q.jobs.where((j) => !j.finished).toList();
    if (pending.isEmpty) return 1;
    if (pending.length > _batch) _batch = pending.length;
    final done = _batch - pending.length;
    final cur = q.running?.progress ?? 0;
    return ((done + cur) / _batch).clamp(0.0, 1.0);
  }

  void _sync() {
    if (!mounted) return;
    final q = widget.queue;
    if (q.busy) {
      final kind = q.running?.kind;
      final label = kind == null ? _runLabel : gerund(kind);
      if (_phase != _Phase.running) {
        _reset?.cancel();
        _batch = 0;
        _check.value = 0;
        _fill.value = 0;
        setState(() {
          _phase = _Phase.running;
          _runLabel = label;
        });
        _jump.forward(from: 0);
      } else if (label != _runLabel) {
        setState(() => _runLabel = label);
      }
      _fill.animateTo(_overall(), duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    } else if (_phase == _Phase.running) {
      _finish();
    }
  }

  Future<void> _finish() async {
    final ok = widget.queue.jobs.any((j) => j.status == JobStatus.done);
    // Deixa o pulo e o enchimento terminarem mesmo em tarefas instantâneas.
    try {
      if (_jump.isAnimating) await _jump.forward().orCancel;
      await _fill.animateTo(1, duration: const Duration(milliseconds: 320), curve: Curves.easeInOut).orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || widget.queue.busy) return;
    if (!ok) {
      _toIdle();
      return;
    }
    setState(() => _phase = _Phase.done);
    _check.forward(from: 0);
    _reset = Timer(const Duration(milliseconds: 1100), _toIdle);
  }

  void _toIdle() {
    if (!mounted) return;
    _jump.value = 0;
    _fill.value = 0;
    _check.value = 0;
    setState(() => _phase = _Phase.idle);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final enabled = widget.onPressed != null || _phase != _Phase.idle;
    final bg = enabled ? cs.primary : cs.onSurface.withValues(alpha: 0.10);
    final fg = enabled ? cs.onPrimary : cs.onSurface.withValues(alpha: 0.38);
    final style = t.textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w700);
    final index = _phase.index;
    Widget label(int i, String text) => AnimatedSlide(
          offset: Offset(0, (i - index).toDouble()),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutBack,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            ),
          ),
        );
    return Semantics(
      button: true,
      enabled: widget.onPressed != null && _phase == _Phase.idle,
      label: switch (_phase) {
        _Phase.idle => widget.label,
        _Phase.running => _runLabel,
        _Phase.done => 'Concluído',
      },
      child: ExcludeSemantics(
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _phase == _Phase.idle ? widget.onPressed : null,
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  Expanded(
                    child: ClipRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          label(0, widget.label),
                          label(1, _runLabel),
                          label(2, 'Concluído'),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    height: 56,
                    child: ClipRect(
                      child: CustomPaint(
                        painter: _SidePainter(
                          repaint: Listenable.merge([_jump, _fill, _check]),
                          jump: _jump,
                          fill: _fill,
                          check: _check,
                          phase: _phase,
                          side: Color.alphaBlend(fg.withValues(alpha: enabled ? 0.20 : 0.08), bg),
                          fillColor: Color.alphaBlend(cs.onPrimary.withValues(alpha: 0.82), cs.primary),
                          arrow: fg,
                          bar: cs.onPrimary,
                          checkColor: cs.primary,
                        ),
                      ),
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

class _SidePainter extends CustomPainter {
  _SidePainter({
    required Listenable repaint,
    required this.jump,
    required this.fill,
    required this.check,
    required this.phase,
    required this.side,
    required this.fillColor,
    required this.arrow,
    required this.bar,
    required this.checkColor,
  }) : super(repaint: repaint);
  final Animation<double> jump, fill, check;
  final _Phase phase;
  final Color side, fillColor, arrow, bar, checkColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, cx = w / 2, cy = h / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = side);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 2.4;

    if (phase == _Phase.idle) {
      // Seta de "processar": haste + ponta.
      line.color = arrow;
      canvas.drawLine(Offset(cx, cy - 7), Offset(cx, cy + 6), line);
      canvas.drawPath(
        Path()
          ..moveTo(cx - 6, cy)
          ..lineTo(cx, cy + 6)
          ..lineTo(cx + 6, cy),
        line,
      );
      return;
    }

    const barLen = 10.0, topY = 4.0; // onde a barrinha encosta no topo
    final j = jump.value;
    if (phase == _Phase.running && j < 1) {
      // A ponta some, a haste abaixa um pouco e pula até o topo.
      final head = (1 - j * 4).clamp(0.0, 1.0);
      final double dy;
      if (j < 0.38) {
        dy = 6 * Curves.easeOut.transform(j / 0.38);
      } else {
        final k = Curves.easeInOut.transform((j - 0.38) / 0.62);
        dy = 6 + ((topY + barLen / 2 - cy) - 6) * k;
      }
      final len = 13 + (barLen - 13) * j;
      line.color = arrow;
      canvas.drawLine(Offset(cx, cy + dy - len / 2), Offset(cx, cy + dy + len / 2), line);
      if (head > 0) {
        line.color = arrow.withValues(alpha: arrow.a * head);
        canvas.drawPath(
          Path()
            ..moveTo(cx - 6, cy + dy)
            ..lineTo(cx, cy + dy + 6)
            ..lineTo(cx + 6, cy + dy),
          line,
        );
      }
      return;
    }

    // Enchimento com a borda de baixo curva, puxado pela barrinha.
    // A curva cresce nos primeiros instantes, para a barrinha sair do topo sem salto.
    final curve = 16.0 * (fill.value * 6).clamp(0.0, 1.0);
    final body = math.max(0.0, fill.value * (h + 16 + barLen + 8) - curve);
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w, body)
      ..quadraticBezierTo(cx, body + curve * 2, 0, body)
      ..close();
    canvas.drawPath(path, Paint()..color = fillColor);
    final tip = body + curve + topY;
    line
      ..color = bar
      ..strokeWidth = 3;
    canvas.drawLine(Offset(cx, tip), Offset(cx, tip + barLen), line);

    if (phase == _Phase.done && check.value > 0) {
      final full = Path()
        ..moveTo(cx - 8, cy + 0.5)
        ..lineTo(cx - 2.5, cy + 6)
        ..lineTo(cx + 8.5, cy - 5.5);
      final m = full.computeMetrics().first;
      line
        ..color = checkColor
        ..strokeWidth = 2.8;
      canvas.drawPath(m.extractPath(0, m.length * Curves.easeOut.transform(check.value)), line);
    }
  }

  @override
  bool shouldRepaint(_SidePainter old) =>
      old.phase != phase || old.side != side || old.fillColor != fillColor || old.arrow != arrow;
}
