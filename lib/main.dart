import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/prefs.dart';
import 'core/state.dart';
import 'ui/common.dart';
import 'ui/expressive.dart';
import 'ui/home_page.dart';
import 'ui/modules.dart';
import 'ui/pdf_studio.dart';
import 'ui/settings_page.dart';
import 'ui/theme.dart';
import 'ui/preview_player.dart';
import 'ui/title_bar.dart';
import 'ui/tool_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupWindowChrome();
  try {
    MediaKit.ensureInitialized();
    playerAvailable = true;
  } catch (_) {
    // Sem a biblioteca de reprodução o app funciona; só as prévias mudam.
    playerAvailable = false;
  }
  final state = AppState();
  await state.prefs.load();
  runApp(FiLumeApp(state: state));
}

class FiLumeApp extends StatefulWidget {
  const FiLumeApp({super.key, required this.state});
  final AppState state;

  @override
  State<FiLumeApp> createState() => _FiLumeAppState();
}

class _FiLumeAppState extends State<FiLumeApp> {
  AppState get state => widget.state;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    state.init();
    // Ao fechar a janela, encerra o FFmpeg em andamento e apaga o arquivo
    // incompleto, em vez de deixar um processo órfão consumindo a máquina.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        state.queue.cancelAll();
        for (var i = 0; i < 30 && state.queue.busy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        state.cleanup();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.prefs,
      builder: (context, _) {
        final seed = appSeed(state.prefs);
        return MaterialApp(
          title: 'FiLume',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(seed, Brightness.light),
          darkTheme: buildTheme(seed, Brightness.dark),
          themeMode: themeModeOf(state.prefs),
          home: Shell(state: state),
        );
      },
    );
  }
}

class _Page {
  const _Page(this.id, this.name, this.icon, this.selectedIcon, [this.soon = const []]);
  final String id, name;
  final IconData icon, selectedIcon;

  /// Ferramentas planejadas (módulo ainda não pronto).
  final List<String> soon;
}

const _pages = [
  _Page('home', 'Início', Icons.home_outlined, Icons.home),
  _Page('pdf', 'PDF', Icons.picture_as_pdf_outlined, Icons.picture_as_pdf),
  _Page('video', 'Vídeo', Icons.videocam_outlined, Icons.videocam),
  _Page('audio', 'Áudio', Icons.music_note_outlined, Icons.music_note),
  _Page('image', 'Imagem', Icons.image_outlined, Icons.image),
  _Page('files', 'Arquivos', Icons.swap_horiz, Icons.swap_horiz, [
    'Word, Excel e PowerPoint para PDF',
    'PDF para texto',
  ]),
];
const _settings = _Page('settings', 'Ajustes', Icons.tune, Icons.tune);

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late String _page = _initialPage();

  String _initialPage() {
    final prefs = widget.state.prefs;
    final wanted = switch (prefs.startPage) {
      'pdf' => 'pdf',
      'last' => prefs.lastPage,
      _ => 'home',
    };
    return _pages.any((p) => p.id == wanted) ? wanted : 'home';
  }

  void _go(String page) {
    if (page == _page) return;
    setState(() => _page = page);
    final prefs = widget.state.prefs;
    if (page != 'settings' && prefs.lastPage != page) {
      prefs.lastPage = page;
      prefs.save();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final state = widget.state;
    final page = _page == 'settings' ? _settings : _pages.firstWhere((p) => p.id == _page);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [
                    Color.alphaBlend(cs.primary.withValues(alpha: 0.09), cs.surface),
                    cs.surface,
                    Color.alphaBlend(cs.tertiary.withValues(alpha: 0.07), cs.surface),
                  ],
                ),
              ),
              child: Padding(
                // Espaço para a faixa da barra de título desenhada pelo app.
                padding: EdgeInsets.only(top: customTitleBar ? titleBarHeight + 4 : 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Rail(prefs: state.prefs, current: _page, onGo: _go),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOutCubic,
                        layoutBuilder: (current, previous) => Stack(
                          fit: StackFit.expand,
                          children: [...previous, if (current != null) current],
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(_page),
                          child: ModuleTheme(
                            prefs: state.prefs,
                            module: _page,
                            child: switch (_page) {
                              'home' => HomePage(state: state, onNavigate: _go),
                              'pdf' => PdfStudio(state: state, onNavigate: _go),
                              'video' => ToolPage(state: state, module: videoModule),
                              'audio' => ToolPage(state: state, module: audioModule),
                              'image' => ToolPage(state: state, module: imageModule),
                              'settings' => SettingsPage(prefs: state.prefs),
                              _ => _SoonPage(page: page),
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (customTitleBar)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TitleBarOverlay(),
            ),
        ],
      ),
    );
  }
}

/// Barra lateral. Na tela inicial ficam só os Ajustes (as categorias já estão
/// no cartão grande); nas outras telas aparecem todos os módulos.
class _Rail extends StatelessWidget {
  const _Rail({required this.prefs, required this.current, required this.onGo});
  final Prefs prefs;
  final String current;
  final void Function(String page) onGo;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    Widget item(_Page p) => _RailItem(
          page: p,
          selected: current == p.id,
          scheme: buildTheme(seedFor(prefs, p.id), brightness).colorScheme,
          onTap: () => onGo(p.id),
        );
    return SizedBox(
      width: 88,
      child: Column(
        children: [
          const SizedBox(height: 8),
          if (current != 'home')
            Expanded(
              child: SingleChildScrollView(
                child: Column(children: [for (final p in _pages) item(p)]),
              ),
            )
          else
            const Spacer(),
          item(_settings),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.page, required this.selected, required this.scheme, required this.onTap});
  final _Page page;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.onSurface : cs.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: 56,
                height: 32,
                decoration: BoxDecoration(
                  color: selected ? scheme.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  selected ? page.selectedIcon : page.icon,
                  size: 22,
                  color: selected ? scheme.onPrimaryContainer : fg,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                page.name,
                style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoonPage extends StatelessWidget {
  const _SoonPage({required this.page});
  final _Page page;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageTitle(page.name),
          const SizedBox(height: 4),
          Text(
            'Este módulo ainda não está pronto. Ferramentas planejadas:',
            style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final tool in page.soon)
                SizedBox(
                  width: 300,
                  child: Panel(
                    child: Row(
                      children: [
                        Icon(page.icon, color: cs.onSurfaceVariant),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(tool, style: t.textTheme.titleSmall),
                        ),
                        Text(
                          'em breve',
                          style: t.textTheme.labelSmall?.copyWith(
                            color: cs.tertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
