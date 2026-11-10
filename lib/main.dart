import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'core/state.dart';
import 'ui/common.dart';
import 'ui/video_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FiLumeApp());
}

/// Verde-amarelado de vagalume.
const _seed = Color(0xFFB4D43C);

ThemeData _theme(Brightness brightness) {
  final cs = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: cs.surface,
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(
          const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
  );
}

class FiLumeApp extends StatefulWidget {
  const FiLumeApp({super.key});

  @override
  State<FiLumeApp> createState() => _FiLumeAppState();
}

class _FiLumeAppState extends State<FiLumeApp> {
  final AppState state = AppState();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    state.init();
    // Ao fechar a janela, encerra o FFmpeg em andamento e apaga o arquivo
    // incompleto, em vez de deixar um processo órfão consumindo a máquina.
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      state.queue.cancelAll();
      for (var i = 0; i < 30 && state.queue.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return AppExitResponse.exit;
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FiLume',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: Shell(state: state),
    );
  }
}

class _Module {
  const _Module(this.name, this.icon, this.selectedIcon, this.tools);
  final String name;
  final IconData icon;
  final IconData selectedIcon;
  final List<String> tools;
}

const _modules = [
  _Module('Vídeo', Icons.movie_outlined, Icons.movie, []),
  _Module('Áudio', Icons.graphic_eq, Icons.graphic_eq,
      ['Conversor', 'Compressor', 'Mixer', 'Splitter', 'Merger']),
  _Module('Imagem', Icons.image_outlined, Icons.image,
      ['Conversor', 'Compressor', 'Redimensionador', 'Rotacionador']),
  _Module('Documentos', Icons.description_outlined, Icons.description,
      ['Conversor', 'Compressor', 'Organizador de PDF']),
];

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(cs.primary.withValues(alpha: 0.07), cs.surface),
              cs.surface,
              Color.alphaBlend(cs.tertiary.withValues(alpha: 0.08), cs.surface),
            ],
          ),
        ),
        child: Row(
          children: [
            NavigationRail(
              backgroundColor: Colors.transparent,
              minWidth: 92,
              labelType: NavigationRailLabelType.all,
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              leading: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const FireflyLogo(size: 48),
                    Text('FiLume',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                  ],
                ),
              ),
              destinations: [
                for (final m in _modules)
                  NavigationRailDestination(
                    icon: Icon(m.icon),
                    selectedIcon: Icon(m.selectedIcon),
                    label: Text(m.name),
                  ),
              ],
            ),
            Expanded(
              // IndexedStack mantém a página de vídeo viva ao trocar de módulo.
              child: IndexedStack(
                sizing: StackFit.expand,
                index: _index,
                children: [
                  VideoPage(state: widget.state),
                  for (final m in _modules.skip(1)) _SoonPage(module: m),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SoonPage extends StatelessWidget {
  const _SoonPage({required this.module});
  final _Module module;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(module.name, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Este módulo ainda não está pronto. Ferramentas planejadas:',
              style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final tool in module.tools)
                SizedBox(
                  width: 220,
                  child: Panel(
                    child: Row(
                      children: [
                        Icon(module.icon, color: cs.onSurfaceVariant),
                        const SizedBox(width: 12),
                        Expanded(child: Text(tool, style: t.textTheme.titleSmall)),
                        Text('em breve', style: t.textTheme.labelSmall?.copyWith(color: cs.tertiary)),
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
