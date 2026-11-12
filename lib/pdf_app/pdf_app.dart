import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../core/ffmpeg.dart';
import '../core/job.dart';
import '../core/launch.dart';
import '../core/ocr.dart';
import '../core/pdf.dart';
import '../core/prefs.dart';
import '../core/state.dart';
import '../ui/common.dart';
import '../ui/modules.dart' show mesaAccepts;
import '../ui/pdf_panels.dart';
import '../ui/pdf_tray.dart';
import '../ui/process_button.dart';
import '../ui/settings_page.dart';
import '../ui/theme.dart';
import '../ui/title_bar.dart';
import 'save_dialog.dart';

/// FiLume PDF: o app dedicado de PDF. Mesmo programa do FiLume, aberto pelo
/// executável "FiLume PDF"; a bandeja de páginas é o centro de tudo.
class PdfApp extends StatefulWidget {
  const PdfApp({super.key, required this.state, this.files = const []});
  final AppState state;

  /// Arquivos recebidos na abertura (vindos do FiLume ou do "Abrir com").
  final List<String> files;

  @override
  State<PdfApp> createState() => _PdfAppState();
}

class _PdfAppState extends State<PdfApp> {
  AppState get state => widget.state;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    state.init();
    state.docs.addPaths(widget.files);
    windowManager.setTitle('FiLume PDF').catchError((_) {});
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
        final seed = seedFor(state.prefs, 'pdf');
        return MaterialApp(
          title: 'FiLume PDF',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(seed, Brightness.light),
          darkTheme: buildTheme(seed, Brightness.dark),
          themeMode: themeModeOf(state.prefs),
          home: PdfShell(state: state),
        );
      },
    );
  }
}

class _Tool {
  const _Tool(this.op, this.name, this.icon, this.motif);
  final TrayOp op;
  final String name;
  final IconData icon;
  final String motif;
}

const _tools = [
  _Tool(TrayOp.save, 'Organizar', Icons.auto_awesome_motion_outlined, 'organize'),
  _Tool(TrayOp.compress, 'Comprimir', Icons.compress, 'compress'),
  _Tool(TrayOp.split, 'Dividir', Icons.call_split, 'split'),
  _Tool(TrayOp.images, 'Imagens', Icons.image_outlined, 'image'),
  _Tool(TrayOp.protect, 'Senha', Icons.lock_outline, 'lock'),
];

const _suffix = {
  TrayOp.save: '_organizado',
  TrayOp.compress: '_comprimido',
  TrayOp.split: '_partes',
  TrayOp.images: '_imagens',
  TrayOp.protect: '_protegido',
};

class PdfShell extends StatefulWidget {
  const PdfShell({super.key, required this.state});
  final AppState state;

  @override
  State<PdfShell> createState() => _PdfShellState();
}

class _PdfShellState extends State<PdfShell> {
  /// Ferramenta aberta; -1 = ajustes.
  int _tool = 0;
  bool _dragging = false;

  AppState get state => widget.state;

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _addFiles(List<String> paths) {
    final ok = <String>[];
    for (final f in paths) {
      final ext = p.extension(f).toLowerCase().replaceFirst('.', '');
      if (ext == 'pdf' || imageExts.contains(ext)) ok.add(f);
    }
    state.docs.addPaths(ok);
    final skipped = paths.length - ok.length;
    if (skipped > 0) {
      _snack('${skipped == 1 ? '1 arquivo ignorado' : '$skipped arquivos ignorados'}: '
          'a bandeja aceita PDFs e imagens (JPG, PNG, WebP, BMP, TIFF, GIF).');
    }
  }

  Future<void> _pick() async {
    final files = await openFiles(acceptedTypeGroups: [
      const XTypeGroup(label: 'PDFs e imagens', extensions: ['pdf', ...imageExts]),
    ]);
    _addFiles([for (final f in files) f.path]);
  }

  /// Nome sugerido e pasta do primeiro arquivo (null quando é digitalização).
  (String, String?) _suggest(String path, TrayOp op) {
    final scanned = p.isWithin(Directory.systemTemp.path, path);
    final base = scanned ? 'Digitalização' : p.basenameWithoutExtension(path);
    return ('$base${scanned && op == TrayOp.save ? '' : _suffix[op]}', scanned ? null : p.dirname(path));
  }

  Future<void> _save() async {
    final pdf = state.pdf;
    if (pdf == null) return _snack('As ferramentas de PDF não foram encontradas (pasta "pdftools" ao lado do FiLume).');
    if (state.tools == null) return _snack('O FFmpeg não foi encontrado (pasta "ffmpeg" ao lado do FiLume).');
    final op = _tools[_tool].op;
    final prefs = state.prefs;
    final removing = op == TrayOp.protect && !state.pdfPassword.protect;
    if (op == TrayOp.protect && state.pdfPassword.password.isEmpty) return _snack('Digite a senha.');

    if (removing) {
      final locked = state.docs.ready.where((d) => d.isPdf && d.encrypted).toList();
      if (locked.isEmpty) return _snack('Solte aqui o PDF protegido para remover a senha dele.');
      final choice = await showSaveDialog(context, prefs,
          title: 'Remover senha', originalDir: p.dirname(locked.first.path), askName: false);
      if (choice == null) return;
      state.queue.addAll([
        for (final d in locked) buildPdfPasswordJob(d, state.pdfPassword, choice.dir, pdf)..module = 'pdf',
      ]);
      return;
    }

    final pages = state.organizer.pages;
    if (pages.isEmpty) return _snack('A bandeja está vazia: adicione PDFs ou imagens, ou digitalize.');
    if (pages.any((r) => r.busy)) return _snack('Espere o "endireitar" terminar.');
    final (name, dir) = _suggest(pages.first.doc.path, op);
    final choice = await showSaveDialog(
      context,
      prefs,
      title: op.label,
      name: name,
      folder: op.folder,
      originalDir: dir,
      imageQuality: pages.any((r) => r.isImage),
    );
    if (choice == null) return;
    state.queue.addAll([
      buildTrayJob(
        pages: pages,
        op: op,
        outDir: choice.dir,
        name: choice.name,
        tools: pdf,
        fit: state.pdfConvert.fit,
        jpegQ: choice.jpegQ,
        compress: state.pdfCompress,
        split: state.pdfSplit,
        convert: state.pdfConvert,
        password: state.pdfPassword.password,
        ocr: state.prefs.ocr ? WindowsOcr.recognize : null,
      )..module = 'pdf',
    ]);
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
                    _Rail(current: _tool, onGo: (i) => setState(() => _tool = i)),
                    Expanded(
                      child: _tool < 0
                          ? SettingsPage(prefs: state.prefs, mainApp: false, extra: _FoldersSection(prefs: state.prefs))
                          : ListenableBuilder(listenable: state, builder: (context, _) => _workArea(context)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (customTitleBar)
            const Positioned(top: 0, left: 0, right: 0, child: TitleBarOverlay(title: 'FiLume PDF')),
        ],
      ),
    );
  }

  Widget _workArea(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final o = state.organizer;
    void act(VoidCallback f) {
      f();
      state.touch();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Faixa fixa de ferramentas + bandeja.
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.delete): () => act(() => o.remove(o.selected.toList())),
                const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
                    act(() => o.selected.addAll(o.pages)),
                const SingleActivator(LogicalKeyboardKey.escape): () => act(o.selected.clear),
              },
              child: Focus(
                autofocus: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Toolbar(state: state, onAdd: _pick),
                    const SizedBox(height: 12),
                    Expanded(
                      child: DropTarget(
                        onDragEntered: (_) => setState(() => _dragging = true),
                        onDragExited: (_) => setState(() => _dragging = false),
                        onDragDone: (d) {
                          setState(() => _dragging = false);
                          _addFiles([for (final f in d.files) f.path]);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(width: 2, color: _dragging ? cs.primary : Colors.transparent),
                          ),
                          child: Panel(
                            padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
                            child: OrganizerWorkspace(state: state, showScan: false),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 340, child: _optionsPanel(context)),
        ],
      ),
    );
  }

  Widget _optionsPanel(BuildContext context) {
    final t = Theme.of(context);
    final tool = _tools[_tool];
    final removing = tool.op == TrayOp.protect && !state.pdfPassword.protect;
    return Panel(
      motif: tool.motif,
      motifAlign: Alignment.topRight,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tool.name, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: switch (tool.op) {
                TrayOp.save => _OrganizeOptions(state: state),
                TrayOp.compress => PdfCompressView(state: state),
                TrayOp.split => PdfSplitView(state: state, folderNote: false),
                TrayOp.images => PdfToImagesView(state: state, folderNote: false),
                TrayOp.protect => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PdfPasswordView(state: state),
                      if (removing) ...[
                        const SizedBox(height: 10),
                        const InfoBox(
                          'A senha é removida dos PDFs protegidos que você soltou aqui (eles não entram na bandeja). '
                          'Depois, é só soltar a cópia sem senha para trabalhar nela.',
                          icon: Icons.info_outline,
                        ),
                      ],
                    ],
                  ),
              },
            ),
          ),
          _Notices(state: state, onPassword: () => setState(() => _tool = 4)),
          _JobStatus(queue: state.queue),
          const SizedBox(height: 10),
          ProcessButton(queue: state.queue, label: removing ? 'Remover senha' : tool.op.label, onPressed: _save),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- barra lateral

class _Rail extends StatelessWidget {
  const _Rail({required this.current, required this.onGo});
  final int current;
  final ValueChanged<int> onGo;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < _tools.length; i++)
                    _RailItem(
                      icon: _tools[i].icon,
                      label: _tools[i].name,
                      selected: current == i,
                      onTap: () => onGo(i),
                    ),
                ],
              ),
            ),
          ),
          _RailItem(
            icon: Icons.open_in_new,
            label: 'FiLume',
            tooltip: 'Abrir o FiLume (vídeo, áudio e imagem)',
            selected: false,
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              if (!await launchMainApp()) {
                messenger.showSnackBar(const SnackBar(content: Text('Não encontrei o FiLume.exe nesta pasta.')));
              }
            },
          ),
          _RailItem(icon: Icons.tune, label: 'Ajustes', selected: current < 0, onTap: () => onGo(-1)),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.icon, required this.label, required this.selected, required this.onTap, this.tooltip});
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
                decoration: BoxDecoration(
                  color: selected ? cs.primaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 22, color: selected ? cs.onPrimaryContainer : fg),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? item : Tooltip(message: tooltip!, child: item);
  }
}

// ------------------------------------------------------- faixa de ferramentas

/// Faixa fixa: não muda ao trocar de ferramenta.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.state, required this.onAdd});
  final AppState state;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final o = state.organizer;
    final none = o.pages.isEmpty;
    final n = o.selected.length;
    final scope = n == 0 ? 'todas as páginas' : (n == 1 ? 'a página selecionada' : 'as $n selecionadas');
    void act(VoidCallback f) {
      f();
      state.touch();
    }

    Widget icon(IconData i, String tip, VoidCallback? onTap) =>
        IconButton.filledTonal(tooltip: tip, onPressed: onTap, icon: Icon(i, size: 20));
    Widget group(List<Widget> children) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(width: 6), children[i]],
          ],
        );
    final docs = state.docs.ready.where(mesaAccepts).toList();
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          group([
            FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add, size: 18), label: const Text('Adicionar')),
            FilledButton.tonalIcon(
              onPressed: () => OrganizerWorkspace.scan(context, state),
              icon: const Icon(Icons.scanner_outlined, size: 18),
              label: const Text('Digitalizar'),
            ),
            Tooltip(
              message: 'OCR: ao salvar, digitalizações e fotos ganham texto pesquisável\n'
                  '(dá para buscar, selecionar e copiar). A aparência não muda.',
              child: FilterChip(
                avatar: state.prefs.ocr ? null : const Icon(Icons.text_fields, size: 18),
                label: const Text('OCR'),
                selected: state.prefs.ocr,
                onSelected: (v) {
                  state.prefs.update(() => state.prefs.ocr = v);
                  state.touch();
                },
              ),
            ),
          ]),
          group([
            icon(Icons.rotate_left, 'Girar à esquerda ($scope)', none ? null : () => act(() => o.rotate(o.targets, 270))),
            icon(Icons.rotate_right, 'Girar à direita ($scope)', none ? null : () => act(() => o.rotate(o.targets, 90))),
            icon(Icons.flip_camera_android_outlined, 'Inverter 180° ($scope)',
                none ? null : () => act(() => o.rotate(o.targets, 180))),
            icon(
              Icons.straighten,
              'Endireitar imagens e digitalizações ($scope)',
              o.targets.any((r) => r.isImage) ? () => straighten(context, state, o.targets) : null,
            ),
            PopupMenuButton<PageFit>(
              tooltip: 'Tamanho da página (imagens e digitalizações)',
              onSelected: (f) => act(() => state.pdfConvert.fit = f),
              itemBuilder: (context) => [
                for (final f in PageFit.values)
                  CheckedPopupMenuItem(value: f, checked: state.pdfConvert.fit == f, child: Text(f.label)),
              ],
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(20)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.aspect_ratio, size: 18, color: cs.onSecondaryContainer),
                    const SizedBox(width: 8),
                    Text(state.pdfConvert.fit.label,
                        style: TextStyle(color: cs.onSecondaryContainer, fontWeight: FontWeight.w600)),
                    Icon(Icons.arrow_drop_down, color: cs.onSecondaryContainer),
                  ],
                ),
              ),
            ),
            icon(
              Icons.delete_outline,
              n == 0 ? 'Excluir (selecione páginas antes)' : 'Excluir ${n == 1 ? 'a página selecionada' : 'as $n selecionadas'}',
              n == 0 ? null : () => act(() => o.remove(o.selected.toList())),
            ),
          ]),
          group([
            icon(
              n == 0 ? Icons.select_all : Icons.deselect,
              n == 0 ? 'Selecionar tudo' : 'Limpar seleção',
              none ? null : () => act(() => n == 0 ? o.selected.addAll(o.pages) : o.selected.clear()),
            ),
            icon(Icons.restore, 'Restaurar a bandeja como os arquivos vieram',
                docs.isEmpty ? null : () => act(() => o.reset(docs))),
          ]),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ painel de opções

class _OrganizeOptions extends StatelessWidget {
  const _OrganizeOptions({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final o = state.organizer;
    final n = o.selected.length;
    final files = state.docs.ready.where(mesaAccepts).length;
    void act(VoidCallback f) {
      f();
      state.touch();
    }

    Widget btn(IconData icon, String label, VoidCallback? onTap) =>
        FilledButton.tonalIcon(onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Na bandeja'),
        Text(
          o.pages.isEmpty
              ? 'Nenhuma página ainda.'
              : '${o.pages.length} ${o.pages.length == 1 ? 'página' : 'páginas'} de $files '
                  '${files == 1 ? 'arquivo' : 'arquivos'}${n == 0 ? '' : '  ·  $n selecionada${n == 1 ? '' : 's'}'}',
          style: t.textTheme.bodyMedium,
        ),
        const SectionLabel('Ordem e seleção'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            btn(Icons.swap_vert, 'Inverter ordem', o.pages.length < 2 ? null : () => act(o.reverse)),
            btn(Icons.filter_alt_outlined, 'Manter só as selecionadas', n == 0 ? null : () => act(o.keepSelected)),
          ],
        ),
        const SizedBox(height: 16),
        const InfoBox(
          'Arraste uma página para mudar de lugar; clique para selecionar; dois cliques para ver de perto; '
          'botão direito para mais ações. Teclas: Delete exclui, Ctrl+A seleciona tudo. '
          'Páginas de PDF saem idênticas às originais.',
          icon: Icons.touch_app_outlined,
        ),
      ],
    );
  }
}

/// Arquivos que ficaram fora da bandeja (protegidos por senha ou ilegíveis).
class _Notices extends StatelessWidget {
  const _Notices({required this.state, required this.onPassword});
  final AppState state;
  final VoidCallback onPassword;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final out = [
      for (final i in state.docs.items)
        if (i.error != null || (i.info != null && i.info!.isPdf && i.info!.encrypted)) i,
    ];
    if (out.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      constraints: const BoxConstraints(maxHeight: 132),
      decoration: BoxDecoration(color: cs.errorContainer.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(16)),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final i in out)
              Row(
                children: [
                  Icon(i.error != null ? Icons.error_outline : Icons.lock_outline, size: 18, color: cs.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${p.basename(i.path)}: ${i.error ?? 'protegido por senha, ficou fora da bandeja'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer),
                    ),
                  ),
                  if (i.error == null)
                    TextButton(onPressed: onPassword, child: const Text('Senha')),
                  IconButton(
                    tooltip: 'Tirar da lista',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => state.docs.remove(i),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// O último trabalho: andamento, resultado (com "abrir pasta") ou o erro.
class _JobStatus extends StatelessWidget {
  const _JobStatus({required this.queue});
  final JobQueue queue;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        if (queue.jobs.isEmpty) return const SizedBox.shrink();
        final job = queue.running ?? queue.jobs.last;
        final t = Theme.of(context);
        final cs = t.colorScheme;
        final small = t.textTheme.bodySmall;
        final (IconData icon, Color color, String text) = switch (job.status) {
          JobStatus.done => (Icons.check_circle_outline, cs.primary, job.result?.summary ?? 'Concluído'),
          JobStatus.failed => (Icons.error_outline, cs.error, job.error ?? 'Falhou'),
          JobStatus.canceled => (Icons.block, cs.onSurfaceVariant, 'Cancelado'),
          _ => (Icons.hourglass_top, cs.onSurfaceVariant, '${job.stage}${queue.waiting > 0 ? '  ·  +${queue.waiting} na fila' : ''}'),
        };
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(job.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: small?.copyWith(fontWeight: FontWeight.w700)),
                    job.status == JobStatus.failed
                        ? SelectableText(text, maxLines: 5, style: small?.copyWith(color: cs.error))
                        : Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: small),
                    if (job.result?.warning != null) Text(job.result!.warning!, style: small?.copyWith(color: cs.tertiary)),
                  ],
                ),
              ),
              if (job.status == JobStatus.done)
                IconButton(
                  tooltip: 'Abrir a pasta do resultado',
                  onPressed: () => revealInFileManager(job.result!.revealPath),
                  icon: const Icon(Icons.folder_open, size: 20),
                ),
              job.finished
                  ? IconButton(
                      tooltip: 'Dispensar',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => queue.remove(job),
                      icon: const Icon(Icons.close, size: 16),
                    )
                  : IconButton(
                      tooltip: 'Cancelar',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => queue.cancel(job),
                      icon: const Icon(Icons.stop_circle_outlined, size: 20),
                    ),
            ],
          ),
        );
      },
    );
  }
}

// -------------------------------------------------------------------- ajustes

/// Pastas favoritas: aparecem na hora de salvar, sem abrir o explorador.
class _FoldersSection extends StatelessWidget {
  const _FoldersSection({required this.prefs});
  final Prefs prefs;

  Future<void> _add() async {
    final dir = await getDirectoryPath();
    if (dir == null || prefs.pdfFolders.contains(dir)) return;
    prefs.update(() => prefs.pdfFolders.add(dir));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pastas para salvar', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            'Aparecem como atalho na hora de salvar, para não precisar abrir o explorador de arquivos toda vez.',
            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 12),
          for (final dir in prefs.pdfFolders)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.folder_outlined, color: cs.primary),
              title: Text(p.basename(dir).isEmpty ? dir : p.basename(dir)),
              subtitle: Text(dir, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                tooltip: 'Remover dos atalhos',
                onPressed: () => prefs.update(() => prefs.pdfFolders.remove(dir)),
                icon: const Icon(Icons.close, size: 18),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _add,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('Adicionar pasta'),
            ),
          ),
        ],
      ),
    );
  }
}
