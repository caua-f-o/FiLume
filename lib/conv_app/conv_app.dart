import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../core/compress.dart' show VCodec;
import '../core/ffmpeg.dart';
import '../core/format.dart';
import '../core/heif.dart';
import '../core/job.dart';
import '../core/launch.dart';
import '../core/modules.dart';
import '../core/pdf.dart' show PageFit;
import '../core/state.dart';
import '../core/streams.dart' show ReLevel;
import '../core/universal.dart';
import '../pdf_app/pdf_app.dart' show JobStatusCard;
import '../ui/common.dart';
import '../ui/process_button.dart';
import '../ui/settings_page.dart';
import '../ui/theme.dart';
import '../ui/title_bar.dart';
import '../ui/modules_ui.dart';
import '../ui/update_ui.dart';

/// FiLume Conversor: o app dedicado que leva qualquer arquivo para outro
/// formato. Mesmo programa do FiLume, aberto pelo executável "FiLume Conversor".
class ConvApp extends StatefulWidget {
  const ConvApp({super.key, required this.state, this.files = const []});
  final AppState state;
  final List<String> files;

  @override
  State<ConvApp> createState() => _ConvAppState();
}

class _ConvAppState extends State<ConvApp> {
  AppState get state => widget.state;
  late final ConvSession session = ConvSession(state);
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    session.add(widget.files);
    state.init().then((_) => session.start());
    windowManager.setTitle('FiLume Conversor').catchError((_) {});
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
    session.dispose();
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.prefs,
      builder: (context, _) {
        final seed = seedFor(state.prefs, 'files');
        return MaterialApp(
          title: 'FiLume Conversor',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(seed, Brightness.light),
          darkTheme: buildTheme(seed, Brightness.dark),
          themeMode: themeModeOf(state.prefs),
          home: ConvShell(state: state, session: session),
        );
      },
    );
  }
}

/// Um arquivo na lista do conversor.
class ConvItem {
  ConvItem(this.path) : kind = kindOf(path)!;
  final String path;
  final FileKind kind;

  /// Leitura do arquivo (vídeo, áudio, imagem e PDF).
  MediaInfo? info;

  /// Tamanho de fotos HEIC, lido direto do arquivo (o FFmpeg enxerga os pedaços).
  (int, int)? dims;
  bool probing = true;
  String? error;
  List<OutFormat> targets = const [];
  OutFormat? target;

  /// A pessoa escolheu o formato à mão (não é mais o sugerido).
  bool picked = false;

  /// Última tarefa criada para este arquivo (mostra o andamento na linha).
  Job? job;

  int get size {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  String get describe {
    final i = info;
    final parts = <String>[kind.label, fmtBytes(size)];
    if (dims != null) {
      parts.add('${dims!.$1}×${dims!.$2}');
    } else if (i != null) {
      if (kind == FileKind.pdf) {
        parts.add(i.encrypted ? 'com senha' : '${i.pages} ${i.pages == 1 ? 'página' : 'páginas'}');
      } else {
        if (i.width > 0 && kind != FileKind.audio) parts.add('${i.width}×${i.height}');
        if (i.duration > 0 && kind != FileKind.image) parts.add(fmtDuration(i.duration));
      }
    }
    return parts.join(' · ');
  }
}

class ConvSession extends ChangeNotifier {
  ConvSession(this.state) {
    settings.outDir = state.prefs.convOutDir;
    state.queue.addListener(notifyListeners);
    _modulesSeen = state.modules.revision;
    state.modules.addListener(_modulesChanged);
  }
  final AppState state;
  final List<ConvItem> items = [];
  final UniversalSettings settings = UniversalSettings();

  /// O que este computador converte; null enquanto ainda está descobrindo.
  ConvCaps? caps;

  /// Falso enquanto a lista de formatos ainda é provisória (encoders e pacote
  /// de escritório ainda sendo detectados).
  bool capsReady = false;

  /// Último formato escolhido para cada tipo (vale para os próximos arquivos).
  final Map<FileKind, String> preferred = {};
  bool _probing = false;
  int _modulesSeen = 0;

  /// Ofertas de módulo que a pessoa dispensou nesta sessão.
  final Set<String> dismissedOffers = {};

  void dismissOffer(String id) {
    dismissedOffers.add(id);
    notifyListeners();
  }

  /// Um módulo foi instalado ou removido: os formatos possíveis mudam.
  Future<void> _modulesChanged() async {
    final rev = state.modules.revision;
    if (rev == _modulesSeen) return;
    _modulesSeen = rev;
    final tools = state.tools;
    if (tools == null || !capsReady) return;
    final fresh = await ConvCaps.detect(tools, state.pdf, encoders: caps?.encoders);
    caps = fresh;
    for (final i in items) {
      if (i.job == null || i.job!.finished) _retarget(i);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    state.modules.removeListener(_modulesChanged);
    state.queue.removeListener(notifyListeners);
    super.dispose();
  }

  /// Depois que as ferramentas foram localizadas: descobre os formatos possíveis.
  Future<void> start() async {
    final tools = state.tools;
    if (tools != null) {
      // Primeiro o básico (para a lista já funcionar), depois o que demora.
      caps = ConvCaps(pdf: state.pdf);
      notifyListeners();
      _probe();
      caps = await ConvCaps.detect(tools, state.pdf);
      capsReady = true;
      for (final i in items) {
        _retarget(i);
      }
    }
    notifyListeners();
  }

  /// Adiciona arquivos (pastas entram com tudo o que tiver dentro). Devolve
  /// quantos foram deixados de fora por não serem de um tipo conhecido.
  int add(Iterable<String> paths) {
    var skipped = 0;
    final have = {for (final i in items) i.path};
    void one(String path) {
      if (kindOf(path) == null) {
        skipped++;
      } else if (have.add(path)) {
        items.add(ConvItem(path));
      }
    }

    for (final path in paths) {
      if (FileSystemEntity.isDirectorySync(path)) {
        try {
          final inside = Directory(path).listSync(recursive: true).whereType<File>().map((f) => f.path).toList()..sort();
          for (final f in inside) {
            if (kindOf(f) != null) one(f);
          }
        } catch (_) {}
      } else {
        one(path);
      }
    }
    notifyListeners();
    _probe();
    return skipped;
  }

  void _retarget(ConvItem i) {
    final c = caps;
    if (c == null) return;
    i.targets = targetsFor(i.path, c, info: i.info);
    final keep = i.target;
    if (i.picked && keep != null && i.targets.any((t) => t.ext == keep.ext && t.group == keep.group)) return;
    i.picked = false;
    final want = preferred[i.kind];
    final own = extOf(i.path);
    i.target = i.targets.where((t) => t.ext == want && t.group.isEmpty).firstOrNull ??
        i.targets.where((t) => t.group.isEmpty && t.ext != own).firstOrNull ??
        i.targets.firstOrNull;
  }

  Future<void> _probe() async {
    if (_probing || caps == null) return;
    final tools = state.tools;
    if (tools == null) return;
    _probing = true;
    try {
      while (true) {
        final i = items.where((i) => i.probing).firstOrNull;
        if (i == null) break;
        try {
          switch (i.kind) {
            case FileKind.pdf:
              final pdf = state.pdf;
              if (pdf != null) i.info = await pdf.probe(i.path);
            case FileKind.image when isHeifPath(i.path):
              final h = await readHeif(i.path);
              if (h == null) {
                i.error = 'Este arquivo não parece ser uma foto HEIC/HEIF válida.';
              } else {
                i.dims = h.displaySize;
              }
            case FileKind.image || FileKind.video || FileKind.audio:
              final info = await tools.probe(i.path);
              if (i.kind == FileKind.image) {
                final size = await tools.imageDisplaySize(i.path);
                i.info = size == null || extOf(i.path) == 'gif' ? info : MediaInfo.image(info, size: size);
              } else {
                i.info = info;
                if (i.kind == FileKind.video && info.videoIndex == null) i.error = 'Este arquivo não tem imagem de vídeo.';
                if (i.kind == FileKind.audio && info.audioCount == 0) i.error = 'Este arquivo não tem áudio.';
              }
            default:
              if (!File(i.path).existsSync()) i.error = 'Arquivo não encontrado.';
          }
        } catch (e) {
          i.error = e is FfError ? e.message : 'Não foi possível ler este arquivo.';
        }
        i.probing = false;
        _retarget(i);
        notifyListeners();
      }
    } finally {
      _probing = false;
    }
  }

  void setTarget(ConvItem item, OutFormat f) {
    item
      ..target = f
      ..picked = true;
    if (f.group.isEmpty) preferred[item.kind] = f.ext;
    notifyListeners();
  }

  /// Aplica [f] a todos os arquivos do tipo [kind] que aceitam esse formato.
  void setAll(FileKind kind, OutFormat f) {
    if (f.group.isEmpty) preferred[kind] = f.ext;
    for (final i in items.where((i) => i.kind == kind)) {
      final t = i.targets.where((t) => t.ext == f.ext && t.group == f.group).firstOrNull;
      if (t != null) {
        i
          ..target = t
          ..picked = true;
      }
    }
    notifyListeners();
  }

  void remove(ConvItem i) {
    items.remove(i);
    notifyListeners();
  }

  void clear() {
    items.clear();
    notifyListeners();
  }

  void clearDone() {
    items.removeWhere((i) => i.job?.status == JobStatus.done);
    notifyListeners();
  }

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  /// Arquivos prontos para converter (lidos, sem erro e com formato escolhido).
  List<ConvItem> get ready => [
        for (final i in items)
          if (!i.probing && i.error == null && i.target != null && !(i.job != null && !i.job!.finished)) i,
      ];

  /// Imagens que vão virar PDF (candidatas a um PDF só).
  List<ConvItem> get imagesToPdf => [
        for (final i in ready)
          if (i.kind == FileKind.image && i.target!.ext == 'pdf') i,
      ];

  void convert() {
    final c = caps;
    if (c == null || !capsReady) return;
    final jobs = <Job>[];
    final merge = settings.mergeImagesPdf && imagesToPdf.length > 1 ? imagesToPdf : const <ConvItem>[];
    if (merge.isNotEmpty) {
      final job = buildImagesPdfJob([for (final i in merge) (i.path, i.info)], settings)..module = 'files';
      for (final i in merge) {
        i.job = job;
      }
      jobs.add(job);
    }
    for (final i in ready) {
      if (merge.contains(i)) continue;
      final job = buildUniversalJob(path: i.path, to: i.target!, settings: settings, caps: c, info: i.info)..module = 'files';
      i.job = job;
      jobs.add(job);
    }
    state.queue.addAll(jobs);
    notifyListeners();
  }
}

const _kindIcons = {
  FileKind.image: Icons.image_outlined,
  FileKind.video: Icons.videocam_outlined,
  FileKind.audio: Icons.music_note_outlined,
  FileKind.pdf: Icons.picture_as_pdf_outlined,
  FileKind.doc: Icons.description_outlined,
  FileKind.sheet: Icons.table_chart_outlined,
  FileKind.slides: Icons.slideshow_outlined,
  FileKind.subtitle: Icons.subtitles_outlined,
};

String _targetLabel(OutFormat f) => f.group.isEmpty ? f.label : '${f.label} (${f.group.toLowerCase()})';

class ConvShell extends StatefulWidget {
  const ConvShell({super.key, required this.state, required this.session});
  final AppState state;
  final ConvSession session;

  @override
  State<ConvShell> createState() => _ConvShellState();
}

class _ConvShellState extends State<ConvShell> {
  bool _settings = false;
  bool _dragging = false;

  AppState get state => widget.state;
  ConvSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) checkUpdatesOnStart(context, state);
    });
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _add(List<String> paths) {
    final skipped = session.add(paths);
    if (skipped > 0) {
      _snack('${skipped == 1 ? '1 arquivo ficou de fora' : '$skipped arquivos ficaram de fora'}: tipo que o conversor ainda não conhece.');
    }
  }

  Future<void> _pick() async {
    final files = await openFiles(acceptedTypeGroups: [
      XTypeGroup(label: 'Arquivos que o FiLume converte', extensions: universalExts),
      const XTypeGroup(label: 'Todos os arquivos'),
    ]);
    _add([for (final f in files) f.path]);
  }

  Future<void> _open(Future<bool> Function() launch, String name) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await launch()) messenger.showSnackBar(SnackBar(content: Text('Não consegui abrir o $name nesta pasta.')));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
                padding: EdgeInsets.only(top: customTitleBar ? titleBarHeight + 4 : 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 88,
                      child: Column(
                        children: [
                          const SizedBox(height: 8),
                          _RailButton(icon: Icons.swap_horiz, label: 'Converter', selected: !_settings, onTap: () => setState(() => _settings = false)),
                          const Spacer(),
                          _RailButton(
                            icon: Icons.open_in_new,
                            label: 'FiLume',
                            tooltip: 'Abrir o FiLume (vídeo, áudio e imagem)',
                            onTap: () => _open(launchMainApp, 'FiLume'),
                          ),
                          _RailButton(
                            icon: Icons.picture_as_pdf_outlined,
                            label: 'PDF',
                            tooltip: 'Abrir o FiLume PDF',
                            onTap: () => _open(() => launchPdfApp(const []), 'FiLume PDF'),
                          ),
                          _RailButton(icon: Icons.tune, label: 'Ajustes', selected: _settings, onTap: () => setState(() => _settings = true)),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _settings
                          ? SettingsPage(prefs: state.prefs, mainApp: false, updates: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [ModulesSection(state: state), const SizedBox(height: 16), UpdateSection(state: state)]))
                          : ListenableBuilder(listenable: Listenable.merge([session, state]), builder: (context, _) => _work(context)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (customTitleBar)
            const Positioned(top: 0, left: 0, right: 0, child: TitleBarOverlay(title: 'FiLume Conversor')),
        ],
      ),
    );
  }

  Widget _work(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (d) {
                setState(() => _dragging = false);
                _add([for (final f in d.files) f.path]);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(width: 2, color: _dragging ? cs.primary : Colors.transparent),
                ),
                child: Panel(
                  padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
                  child: session.items.isEmpty ? _empty(context) : _list(context),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 340, child: _options(context)),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final loading = state.toolsLoading;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_horiz, size: 56, color: cs.primary),
            const SizedBox(height: 12),
            Text('Solte aqui o que quiser converter', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Fotos (inclusive HEIC do iPhone), vídeos, áudios, PDFs, Word, Excel, PowerPoint e legendas. '
              'Pode misturar tudo e soltar pastas inteiras: cada arquivo ganha a sua lista de formatos.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(onPressed: loading ? null : _pick, icon: const Icon(Icons.add), label: const Text('Escolher arquivos')),
            if (!loading && state.tools == null) ...[
              const SizedBox(height: 16),
              const InfoBox('O FFmpeg não foi encontrado na pasta do FiLume. Sem ele o conversor não funciona.', icon: Icons.error_outline),
            ],
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final n = session.items.length;
    final done = session.items.where((i) => i.job?.status == JobStatus.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('$n ${n == 1 ? 'arquivo' : 'arquivos'}', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(onPressed: _pick, icon: const Icon(Icons.add, size: 18), label: const Text('Adicionar')),
            if (done > 0)
              TextButton.icon(onPressed: session.clearDone, icon: const Icon(Icons.done_all, size: 18), label: const Text('Tirar os prontos')),
            TextButton.icon(
              onPressed: state.queue.busy ? null : session.clear,
              icon: const Icon(Icons.clear_all, size: 18),
              label: const Text('Limpar'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ..._offers(),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(right: 6, bottom: 4),
            itemCount: n,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, k) => _row(context, session.items[k], cs, t),
          ),
        ),
      ],
    );
  }

  /// Módulos que resolveriam o que falta para os arquivos da lista.
  List<Widget> _offers() {
    final caps = session.caps;
    if (caps == null || !session.capsReady) return const [];
    final kinds = {for (final i in session.items) i.kind};
    final o = caps.office;
    final out = <Widget>[];
    if (kinds.contains(FileKind.pdf) && o.pdf2docx == null && !session.dismissedOffers.contains(pdfWordModule.id)) {
      out.add(ModuleOffer(
        state: state,
        spec: pdfWordModule,
        text: !o.pdfToDocx
            ? (o.msWord
                ? 'O Word deste computador não abre PDF (isso só existe a partir do Word 2013). Com o módulo, o PDF vira um documento do Word editável.'
                : 'Com ele, o PDF vira um documento do Word editável, com parágrafos, tabelas e imagens.')
            : 'Deixa o PDF → Word bem mais fiel: remonta parágrafos e tabelas em vez de espalhar o texto em caixas soltas.',
        onDismiss: () => session.dismissOffer(pdfWordModule.id),
      ));
    }
    const officeKinds = [FileKind.doc, FileKind.sheet, FileKind.slides];
    if (officeKinds.any((k) => kinds.contains(k) && !caps.officeFor(k)) && !session.dismissedOffers.contains(officeModule.id)) {
      out.add(ModuleOffer(
        state: state,
        spec: officeModule,
        text: 'Para converter Word, Excel e PowerPoint sem ter um pacote de escritório compatível instalado.',
        onDismiss: () => session.dismissOffer(officeModule.id),
      ));
    }
    return out;
  }

  Widget _row(BuildContext context, ConvItem i, ColorScheme cs, ThemeData t) {
    final job = i.job;
    final note = i.error ?? (i.probing || session.caps == null ? null : (i.targets.isEmpty ? missingNote(i.path, session.caps!) ?? 'Nenhum formato disponível para este arquivo.' : null));
    Widget status;
    if (job == null || job.status == JobStatus.canceled) {
      status = IconButton(
        tooltip: 'Tirar da lista',
        visualDensity: VisualDensity.compact,
        onPressed: () => session.remove(i),
        icon: const Icon(Icons.close, size: 16),
      );
    } else if (job.status == JobStatus.done) {
      status = IconButton(
        tooltip: 'Pronto: ${job.result?.summary ?? ''}\nAbrir a pasta',
        visualDensity: VisualDensity.compact,
        onPressed: () => revealInFileManager(job.result!.revealPath),
        icon: Icon(job.result?.warning == null ? Icons.check_circle : Icons.check_circle_outline, size: 20, color: cs.primary),
      );
    } else if (job.status == JobStatus.failed) {
      status = Tooltip(
        message: job.error ?? 'Falhou',
        child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.error_outline, size: 20, color: cs.error)),
      );
    } else {
      status = Padding(
        padding: const EdgeInsets.all(10),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.5, value: job.status == JobStatus.running && job.progress > 0 ? job.progress : null),
        ),
      );
    }
    final sub = note ?? (job?.status == JobStatus.failed ? (job!.error ?? 'Falhou').split('\n').first : (job?.result?.warning ?? (i.probing ? 'Lendo…' : i.describe)));
    final alert = note != null || job?.status == JobStatus.failed;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Icon(_kindIcons[i.kind], color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(i.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    sub,
                    maxLines: alert ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodySmall?.copyWith(color: alert ? cs.error : (job?.result?.warning != null ? cs.tertiary : cs.onSurfaceVariant)),
                  ),
                ],
              ),
            ),
            if (i.targets.isNotEmpty && i.error == null) ...[
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              _TargetButton(
                value: i.target,
                options: i.targets,
                enabled: job == null || job.finished,
                onChanged: (f) => session.setTarget(i, f),
              ),
            ],
            status,
          ],
        ),
      ),
    );
  }

  Widget _options(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final s = session.settings;
    final caps = session.caps;
    final items = session.items;
    final kinds = {for (final i in items) i.kind};
    bool to(FileKind k, bool Function(OutFormat f) test) => items.any((i) => i.kind == k && i.target != null && test(i.target!));
    final imgLossy = to(FileKind.image, (f) => const {'jpg', 'webp', 'avif', 'heic', 'jxl'}.contains(f.ext)) || to(FileKind.pdf, (f) => f.ext == 'jpg');
    final imgAny = to(FileKind.image, (f) => f.group.isEmpty && f.ext != 'pdf');
    final imgPdf = session.imagesToPdf.length;
    final video = to(FileKind.video, (f) => f.group.isEmpty && f.ext != 'gif') || to(FileKind.image, (f) => f.group == 'Vídeo');
    final gif = to(FileKind.video, (f) => f.ext == 'gif');
    const lossyAudio = {'mp3', 'm4a', 'opus', 'ogg', 'ac3', 'wma'};
    final audio = to(FileKind.audio, (f) => true) || to(FileKind.video, (f) => f.group == 'Só o áudio');
    final audioLossy = to(FileKind.audio, (f) => lossyAudio.contains(f.ext)) || to(FileKind.video, (f) => f.group == 'Só o áudio' && lossyAudio.contains(f.ext));
    final pdfImg = to(FileKind.pdf, (f) => f.ext == 'jpg' || f.ext == 'png');
    final ready = session.ready.length;
    final officeKinds = kinds.intersection({FileKind.doc, FileKind.sheet, FileKind.slides});
    void set(VoidCallback f) => session.set(f);

    return Panel(
      motif: 'convert',
      motifAlign: Alignment.topRight,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Converter', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (items.isEmpty) ...[
                    const SizedBox(height: 14),
                    const InfoBox(
                      'Tudo é convertido neste computador: nenhum arquivo é enviado para a internet.',
                      icon: Icons.lock_outline,
                    ),
                  ],
                  // Um seletor por tipo presente: muda todos os arquivos daquele tipo de uma vez.
                  if (kinds.isNotEmpty && caps != null) ...[
                    const SectionLabel('Converter todos para'),
                    for (final k in FileKind.values.where(kinds.contains))
                      if (_commonTargets(k).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Icon(_kindIcons[k], size: 18, color: cs.onSurfaceVariant),
                              const SizedBox(width: 8),
                              Expanded(child: Text('${k.label}${_count(k) > 1 ? ' (${_count(k)})' : ''}', style: t.textTheme.bodyMedium)),
                              _TargetButton(
                                value: _shared(k),
                                options: _commonTargets(k),
                                enabled: true,
                                placeholder: 'vários',
                                onChanged: (f) => session.setAll(k, f),
                              ),
                            ],
                          ),
                        ),
                  ],
                  if (imgLossy || imgAny || imgPdf > 0) ...[
                    const SectionLabel('Imagens'),
                    if (imgLossy) ...[
                      Row(
                        children: [
                          Expanded(child: Text('Qualidade', style: t.textTheme.bodyMedium)),
                          Text('${s.imageQuality}', style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                      Slider(
                        value: s.imageQuality.toDouble(),
                        min: 40,
                        max: 100,
                        divisions: 12,
                        label: '${s.imageQuality}',
                        onChanged: (v) => set(() => s.imageQuality = v.round()),
                      ),
                    ],
                    if (imgAny)
                      Choice<int>(
                        label: 'Tamanho',
                        value: s.imageMaxSide,
                        options: const {0: 'Original', 3840: 'Até 3840 px (4K)', 2560: 'Até 2560 px', 1920: 'Até 1920 px', 1280: 'Até 1280 px', 800: 'Até 800 px'},
                        onChanged: (v) => set(() => s.imageMaxSide = v),
                      ),
                    if (imgPdf > 0) ...[
                      const SizedBox(height: 10),
                      Choice<PageFit>(
                        label: 'Página do PDF',
                        value: s.pdfFit,
                        options: {for (final f in PageFit.values) f: f.label},
                        onChanged: (v) => set(() => s.pdfFit = v),
                      ),
                      if (imgPdf > 1)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text('Juntar as $imgPdf imagens num PDF só'),
                          subtitle: const Text('Na ordem da lista. Desligado: um PDF por imagem.'),
                          value: s.mergeImagesPdf,
                          onChanged: (v) => set(() => s.mergeImagesPdf = v),
                        ),
                    ],
                  ],
                  if (video) ...[
                    const SectionLabel('Vídeos'),
                    SegmentedButton<ReLevel>(
                      showSelectedIcon: false,
                      segments: [for (final l in ReLevel.values) ButtonSegment(value: l, label: Text(l.label))],
                      selected: {s.videoLevel},
                      onSelectionChanged: (v) => set(() => s.videoLevel = v.first),
                    ),
                    const SizedBox(height: 10),
                    Choice<int>(
                      label: 'Resolução',
                      value: s.videoMaxHeight,
                      options: const {0: 'Original', 2160: 'Até 4K (2160p)', 1080: 'Até Full HD (1080p)', 720: 'Até HD (720p)', 480: 'Até 480p'},
                      onChanged: (v) => set(() => s.videoMaxHeight = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Sempre recodificar'),
                      subtitle: const Text('Desligado, quando só o formato muda o vídeo é copiado sem perda (bem mais rápido).'),
                      value: s.forceReencode,
                      onChanged: (v) => set(() => s.forceReencode = v),
                    ),
                    if (caps != null && caps.enc.gpuFor(VCodec.h264) != null)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text('Usar a placa de vídeo'),
                        subtitle: const Text('Mais rápido; o arquivo pode sair um pouco maior.'),
                        value: s.videoGpu,
                        onChanged: (v) => set(() => s.videoGpu = v),
                      ),
                  ],
                  if (gif) ...[
                    const SectionLabel('GIF animado'),
                    Row(
                      children: [
                        Expanded(
                          child: Choice<int>(
                            label: 'Largura',
                            value: s.gifWidth,
                            options: const {320: '320 px', 480: '480 px', 640: '640 px', 800: '800 px'},
                            onChanged: (v) => set(() => s.gifWidth = v),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Choice<int>(
                            label: 'Quadros/s',
                            value: s.gifFps,
                            options: const {8: '8', 12: '12', 15: '15', 24: '24'},
                            onChanged: (v) => set(() => s.gifFps = v),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (audio) ...[
                    const SectionLabel('Áudio'),
                    if (audioLossy)
                      Choice<int>(
                        label: 'Qualidade',
                        value: s.audioKbps,
                        options: const {96: '96 kb/s (voz)', 128: '128 kb/s', 192: '192 kb/s (boa)', 256: '256 kb/s', 320: '320 kb/s (máxima)'},
                        onChanged: (v) => set(() => s.audioKbps = v),
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Mono'),
                      value: s.audioMono,
                      onChanged: (v) => set(() => s.audioMono = v),
                    ),
                  ],
                  if (pdfImg) ...[
                    const SectionLabel('PDF para imagem'),
                    Choice<int>(
                      label: 'Resolução',
                      value: s.pdfDpi,
                      options: const {96: '96 dpi (tela)', 150: '150 dpi', 200: '200 dpi', 300: '300 dpi (impressão)', 600: '600 dpi'},
                      onChanged: (v) => set(() => s.pdfDpi = v),
                    ),
                  ],
                  if (caps != null && officeKinds.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    InfoBox(
                      officeKinds.every(caps.officeFor)
                          ? 'Documentos do Office são convertidos pelo ${caps.office.label} deste computador, sem abrir janela.'
                          : 'Para converter Word, Excel e PowerPoint, baixe o módulo "Documentos do Office" (aparece acima da lista e nos Ajustes). '
                              'Sem ele, o FiLume só faz texto → PDF e Word → texto.',
                      icon: officeKinds.every(caps.officeFor) ? Icons.info_outline : Icons.warning_amber_outlined,
                    ),
                  ],
                  const SectionLabel('Onde salvar'),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('Junto do original')),
                      ButtonSegment(value: true, label: Text('Numa pasta')),
                    ],
                    selected: {s.outDir != null},
                    onSelectionChanged: (v) async {
                      if (!v.first) {
                        set(() => s.outDir = null);
                        state.prefs.update(() => state.prefs.convOutDir = null);
                        return;
                      }
                      final dir = await getDirectoryPath();
                      if (dir == null) return;
                      set(() => s.outDir = dir);
                      state.prefs.update(() => state.prefs.convOutDir = dir);
                    },
                  ),
                  if (s.outDir != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(s.outDir!, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Nada é sobrescrito: se já existir um arquivo com o mesmo nome, o novo ganha um número.',
                      style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
          JobStatusCard(queue: state.queue),
          const SizedBox(height: 10),
          ProcessButton(
            queue: state.queue,
            label: !session.capsReady && items.isNotEmpty && state.tools != null
                ? 'Preparando…'
                : ready == 0
                    ? (items.isEmpty ? 'Adicione arquivos' : 'Nada para converter')
                    : 'Converter ${ready == 1 ? '1 arquivo' : '$ready arquivos'}',
            onPressed: ready == 0 || !session.capsReady ? null : session.convert,
          ),
        ],
      ),
    );
  }

  int _count(FileKind k) => session.items.where((i) => i.kind == k).length;

  /// Formatos que todos os arquivos do tipo aceitam.
  List<OutFormat> _commonTargets(FileKind k) {
    final list = [for (final i in session.items) if (i.kind == k && !i.probing && i.error == null) i.targets];
    if (list.isEmpty) return const [];
    return [
      for (final f in list.first)
        if (list.every((l) => l.any((x) => x.ext == f.ext && x.group == f.group))) f,
    ];
  }

  /// Formato em comum entre os arquivos do tipo (null = cada um com o seu).
  OutFormat? _shared(FileKind k) {
    OutFormat? found;
    for (final i in session.items.where((i) => i.kind == k && i.target != null)) {
      if (found == null) {
        found = i.target;
      } else if (found.ext != i.target!.ext || found.group != i.target!.group) {
        return null;
      }
    }
    return found;
  }
}

/// Botão que mostra o formato escolhido e abre a lista de formatos possíveis.
class _TargetButton extends StatelessWidget {
  const _TargetButton({required this.value, required this.options, required this.enabled, required this.onChanged, this.placeholder = '—'});
  final OutFormat? value;
  final List<OutFormat> options;
  final bool enabled;
  final ValueChanged<OutFormat> onChanged;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final groups = <String>[];
    for (final o in options) {
      if (!groups.contains(o.group)) groups.add(o.group);
    }
    return PopupMenuButton<OutFormat>(
      enabled: enabled,
      tooltip: 'Escolher o formato',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final g in groups) ...[
          if (g.isNotEmpty) ...[
            const PopupMenuDivider(),
            PopupMenuItem<OutFormat>(
              enabled: false,
              height: 28,
              child: Text(g, style: t.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            ),
          ],
          for (final o in options.where((o) => o.group == g))
            PopupMenuItem<OutFormat>(
              value: o,
              height: 38,
              child: Row(
                children: [
                  SizedBox(width: 22, child: value != null && value!.ext == o.ext && value!.group == o.group ? Icon(Icons.check, size: 16, color: cs.primary) : null),
                  Text(o.label),
                ],
              ),
            ),
        ],
      ],
      child: Container(
        constraints: const BoxConstraints(minWidth: 96),
        padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
        decoration: BoxDecoration(
          color: enabled ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                value == null ? placeholder : _targetLabel(value!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.labelLarge?.copyWith(color: enabled ? cs.onPrimaryContainer : cs.onSurfaceVariant, fontWeight: FontWeight.w700),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 20, color: enabled ? cs.onPrimaryContainer : cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({required this.icon, required this.label, required this.onTap, this.selected = false, this.tooltip});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.onSurface : cs.onSurfaceVariant;
    final item = Semantics(
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
                decoration: BoxDecoration(color: selected ? cs.primaryContainer : Colors.transparent, borderRadius: BorderRadius.circular(16)),
                child: Icon(icon, size: 22, color: selected ? cs.onPrimaryContainer : fg),
              ),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: fg)),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? item : Tooltip(message: tooltip!, child: item);
  }
}
