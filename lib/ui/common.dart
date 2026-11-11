import 'package:flutter/material.dart';

import 'geo.dart';

/// Cartão com um degradê bem sutil, usado em todos os painéis.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.motif,
    this.motifAlign = Alignment.bottomRight,
    this.motifSize = 120,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Detalhe geométrico desenhado num canto, atrás do conteúdo.
  final String? motif;
  final Alignment motifAlign;
  final double motifSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(cs.primary.withValues(alpha: 0.05), cs.surfaceContainerLow),
            cs.surfaceContainerLow,
            Color.alphaBlend(cs.tertiary.withValues(alpha: 0.04), cs.surfaceContainer),
          ],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            if (motif != null)
              Positioned.fill(
                child: Align(
                  alignment: motifAlign,
                  child: Transform.translate(
                    offset: Offset(motifAlign.x * motifSize * 0.14, motifAlign.y * motifSize * 0.14),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      child: Motif(
                        motif!,
                        key: ValueKey(motif),
                        size: motifSize,
                        color: cs.primary.withValues(alpha: 0.13),
                      ),
                    ),
                  ),
                ),
              ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

/// O "vagalume": um ponto de luz com brilho em volta.
class FireflyLogo extends StatelessWidget {
  const FireflyLogo({super.key, this.size = 44});
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              cs.primary.withValues(alpha: 0.55),
              cs.primary.withValues(alpha: 0.14),
              cs.primary.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
        child: Center(
          child: Container(
            width: size * 0.3,
            height: size * 0.3,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color.alphaBlend(Colors.white.withValues(alpha: 0.35), cs.primary),
              boxShadow: [BoxShadow(color: cs.primary.withValues(alpha: 0.8), blurRadius: size * 0.3)],
            ),
          ),
        ),
      ),
    );
  }
}

/// Botão principal com degradê suave; ao pressionar, a forma "aperta"
/// (de pílula para cantos menores), no estilo Material Expressive.
class GlowButton extends StatefulWidget {
  const GlowButton({super.key, required this.label, required this.icon, required this.onPressed});
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  State<GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<GlowButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;
    final fg = enabled ? cs.onPrimary : cs.onSurface.withValues(alpha: 0.38);
    final radius = BorderRadius.circular(_down && enabled ? 14 : 28);
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutBack,
        height: 56,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: enabled
              ? LinearGradient(colors: [
                  cs.primary,
                  Color.alphaBlend(cs.tertiary.withValues(alpha: 0.45), cs.primary),
                ])
              : null,
          color: enabled ? null : cs.onSurface.withValues(alpha: 0.10),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon, color: fg, size: 22),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      widget.label,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: fg, fontWeight: FontWeight.w700),
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

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(text,
          style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }
}

/// Menu suspenso que ocupa a largura toda.
class Choice<T> extends StatelessWidget {
  const Choice({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<T>(
      initialSelection: value,
      expandedInsets: EdgeInsets.zero,
      requestFocusOnTap: false,
      label: Text(label),
      onSelected: (v) {
        if (v != null) onChanged(v);
      },
      dropdownMenuEntries: [
        for (final e in options.entries) DropdownMenuEntry<T>(value: e.key, label: e.value),
      ],
    );
  }
}

/// Campo numérico com atalhos (chips) de valores comuns.
class PresetField extends StatefulWidget {
  const PresetField({
    super.key,
    required this.label,
    required this.value,
    required this.parse,
    required this.format,
    required this.presets,
    required this.presetLabel,
    required this.onChanged,
    this.suffix,
    this.hint,
  });
  final String label;
  final double value;
  final double? Function(String) parse;
  final String Function(double) format;
  final List<double> presets;
  final String Function(double) presetLabel;
  final ValueChanged<double> onChanged;
  final String? suffix;
  final String? hint;

  @override
  State<PresetField> createState() => _PresetFieldState();
}

class _PresetFieldState extends State<PresetField> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.format(widget.value));
  bool _invalid = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _typed(String text) {
    final v = widget.parse(text);
    final ok = v != null && v > 0;
    setState(() => _invalid = !ok);
    if (ok) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          onChanged: _typed,
          decoration: InputDecoration(
            labelText: widget.label,
            suffixText: widget.suffix,
            helperText: widget.hint,
            errorText: _invalid ? 'Valor inválido' : null,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in widget.presets)
              ChoiceChip(
                label: Text(widget.presetLabel(preset)),
                selected: (widget.value - preset).abs() < 1e-9,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  _ctrl.text = widget.format(preset);
                  setState(() => _invalid = false);
                  widget.onChanged(preset);
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// Caixa de dica com ícone.
class InfoBox extends StatelessWidget {
  const InfoBox(this.text, {super.key, this.icon = Icons.bolt});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: t.colorScheme.secondaryContainer.withValues(alpha: 0.45),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: t.colorScheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSecondaryContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Campo de texto que entrega um valor já interpretado (ou null se vazio).
class ParsedField<T> extends StatefulWidget {
  const ParsedField({
    super.key,
    required this.label,
    required this.initialText,
    required this.parse,
    required this.onChanged,
    this.allowEmpty = false,
    this.hint,
    this.suffix,
  });
  final String label;
  final String initialText;
  final T? Function(String) parse;
  final ValueChanged<T?> onChanged;
  final bool allowEmpty;
  final String? hint;
  final String? suffix;

  @override
  State<ParsedField<T>> createState() => _ParsedFieldState<T>();
}

class _ParsedFieldState<T> extends State<ParsedField<T>> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialText);
  bool _invalid = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _typed(String text) {
    if (text.trim().isEmpty) {
      setState(() => _invalid = !widget.allowEmpty);
      if (widget.allowEmpty) widget.onChanged(null);
      return;
    }
    final v = widget.parse(text);
    setState(() => _invalid = v == null);
    if (v != null) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      onChanged: _typed,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.hint,
        suffixText: widget.suffix,
        errorText: _invalid ? 'Valor inválido' : null,
      ),
    );
  }
}
