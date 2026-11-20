import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/launch.dart';
import 'core/prefs.dart';
import 'core/state.dart';
import 'ui/home_page.dart';
import 'ui/modules.dart';
import 'pdf_app/pdf_app.dart';
import 'ui/pdf_launch.dart';
import 'ui/settings_page.dart';
import 'ui/theme.dart';
import 'ui/preview_player.dart';
import 'ui/title_bar.dart';
import 'ui/modules_ui.dart';
import 'ui/update_ui.dart';
import 'conv_app/conv_app.dart';
import 'ui/tool_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupWindowChrome();
  if (isConverterApp(args)) {
    // FiLume Conversor: só o que a conversão precisa (sem player nem prévias).
    final state = AppState(pdfOnly: true);
    await state.prefs.load();
    runApp(ConvApp(state: state, files: fileArgs(args)));
    return;
  }
  if (isPdfApp(args)) {
    // FiPDF: não carrega o player nem nada de vídeo, áudio ou imagem.
    final state = AppState(pdfOnly: true);
    await state.prefs.load();
    // O auxiliar dos scanners deste computador sobe junto, em segundo plano: quando a pessoa
    // abrir "Digitalizar", os aparelhos já estão listados.
    state.scanner.bridge.warmUp();
    runApp(PdfApp(state: state, files: fileArgs(args)));
    return;
  }
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
  const _Page(this.id, this.name, this.icon, this.selectedIcon);
  final String id, name;
  final IconData icon, selectedIcon;
}

const _pages = [
  _Page('home', 'Início', Icons.home_outlined, Icons.home),
  _Page('pdf', 'PDF', Icons.open_in_new, Icons.open_in_new),
  _Page('video', 'Vídeo', Icons.videocam_outlined, Icons.videocam),
  _Page('audio', 'Áudio', Icons.music_note_outlined, Icons.music_note),
  _Page('image', 'Imagem', Icons.image_outlined, Icons.image),
  _Page('files', 'Conversor', Icons.swap_horiz, Icons.swap_horiz),
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
    final wanted = prefs.startPage == 'last' ? prefs.lastPage : 'home';
    return wanted != 'pdf' && wanted != 'files' && _pages.any((p) => p.id == wanted) ? wanted : 'home';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkUpdatesOnStart(context, widget.state);
    });
  }

  void _go(String page) {
    if (page == 'pdf') {
      // PDF mora no app dedicado: oferece abrir, levando os arquivos soltos aqui.
      final state = widget.state;
      final files = List<String>.of(state.pendingPdfs);
      state.pendingPdfs.clear();
      final busy = [state.video, state.audio, state.images].any((l) => l.items.isNotEmpty);
      offerPdfApp(context, state, files, keepOpen: busy);
      return;
    }
    if (page == 'files') {
      // O conversor universal também é um app à parte; este continua aberto.
      final messenger = ScaffoldMessenger.of(context);
      launchConverterApp().then((ok) {
        if (!ok) messenger.showSnackBar(const SnackBar(content: Text('Não consegui abrir o FiLume Conversor.')));
      });
      return;
    }
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
                              'video' => ToolPage(state: state, module: videoModule),
                              'audio' => ToolPage(state: state, module: audioModule),
                              'image' => ToolPage(state: state, module: imageModule),
                              'settings' => SettingsPage(prefs: state.prefs, updates: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [ModulesSection(state: state), const SizedBox(height: 16), UpdateSection(state: state)])),
                              _ => const SizedBox.shrink(),
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
