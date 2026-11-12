import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Verdadeiro quando a barra de título nativa foi escondida e o app desenha
/// a própria (área de arrastar + botões da janela).
bool customTitleBar = false;

const double titleBarHeight = 34;

/// Esconde a barra de título do sistema; o conteúdo passa a ocupar a janela toda.
Future<void> setupWindowChrome() async {
  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    customTitleBar = true;
  } catch (_) {
    customTitleBar = false;
  }
}

/// Faixa transparente no topo: arrastar move a janela, duplo clique maximiza.
class TitleBarOverlay extends StatefulWidget {
  const TitleBarOverlay({super.key, this.title = 'FiLume'});
  final String title;

  @override
  State<TitleBarOverlay> createState() => _TitleBarOverlayState();
}

class _TitleBarOverlayState extends State<TitleBarOverlay> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _sync();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _sync() async {
    try {
      final m = await windowManager.isMaximized();
      if (mounted && m != _maximized) setState(() => _maximized = m);
    } catch (_) {}
  }

  @override
  void onWindowMaximize() => _sync();

  @override
  void onWindowUnmaximize() => _sync();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: titleBarHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.primary,
                        boxShadow: [
                          BoxShadow(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _CaptionButton(
            tooltip: 'Minimizar',
            icon: Icons.remove,
            onTap: () => windowManager.minimize(),
          ),
          _CaptionButton(
            tooltip: _maximized ? 'Restaurar' : 'Maximizar',
            icon: _maximized ? Icons.filter_none : Icons.crop_square,
            iconSize: _maximized ? 13 : 15,
            onTap: () => _maximized ? windowManager.unmaximize() : windowManager.maximize(),
          ),
          _CaptionButton(
            tooltip: 'Fechar',
            icon: Icons.close,
            danger: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.iconSize = 16,
    this.danger = false,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double iconSize;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color bg;
    if (!_hover) {
      bg = Colors.transparent;
    } else if (widget.danger) {
      bg = const Color(0xFFC42B1C);
    } else {
      bg = cs.onSurface.withValues(alpha: 0.10);
    }
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 800),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 46,
            color: bg,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hover && widget.danger ? Colors.white : cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
