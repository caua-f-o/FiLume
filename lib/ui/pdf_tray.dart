import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/deskew.dart';
import '../core/ffmpeg.dart';
import '../core/format.dart';
import '../core/pdf.dart';
import '../core/scan.dart';
import '../core/state.dart';
import 'common.dart';
import 'modules.dart' show mesaAccepts;

TextStyle? _muted(BuildContext context) {
  final t = Theme.of(context);
  return t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
}

List<MediaInfo> _trayDocs(AppState state) => state.docs.ready.where(mesaAccepts).toList();

/// "Endireitar": mede a inclinação de cada imagem e guarda a correção.
/// Páginas de PDF ficam de fora (endireitar exigiria redesenhá-las).
Future<void> straighten(BuildContext context, AppState state, List<PageRef> refs) async {
  final tools = state.tools;
  final images = refs.where((r) => r.isImage).toList();
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (tools == null || images.isEmpty) {
    messenger?.showSnackBar(const SnackBar(
      content: Text('Endireitar funciona em imagens e digitalizações. Páginas de PDF saem como estão.'),
    ));
    return;
  }
  for (final r in images) {
    r.busy = true;
  }
  state.touch();
  var fixed = 0;
  for (final r in images) {
    try {
      r.skew = await detectSkew(tools, r.doc);
      if (r.skew != 0) fixed++;
    } catch (_) {
      // Sem medição, a página fica como está.
    }
    r.busy = false;
    state.touch();
  }
  messenger?.showSnackBar(SnackBar(
    content: Text(fixed == 0
        ? 'Nenhuma inclinação encontrada: as páginas já estão retas (ou não têm linhas de texto para medir).'
        : '$fixed ${fixed == 1 ? 'página endireitada' : 'páginas endireitadas'}.'),
  ));
}

// ------------------------------------------------------------ painel lateral

class PdfOrganizeView extends StatelessWidget {
  const PdfOrganizeView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final o = state.organizer;
    final t = Theme.of(context);
    final n = o.selected.length;
    final scope = n == 0 ? 'todas' : '$n selecionada${n == 1 ? '' : 's'}';
    void act(VoidCallback f) {
      f();
      state.touch();
    }

    Widget btn(IconData icon, String label, VoidCallback? onTap) => FilledButton.tonalIcon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label),
        );
    final docs = _trayDocs(state);
    final none = o.pages.isEmpty;
    final hasImages = o.pages.any((r) => r.isImage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Páginas'),
        Text('${o.pages.length} páginas na bandeja  ·  ações valem para: $scope', style: t.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            btn(Icons.rotate_left, 'Girar', none ? null : () => act(() => o.rotate(o.targets, 270))),
            btn(Icons.rotate_right, 'Girar', none ? null : () => act(() => o.rotate(o.targets, 90))),
            btn(Icons.flip_camera_android_outlined, 'Inverter', none ? null : () => act(() => o.rotate(o.targets, 180))),
            btn(Icons.straighten, 'Endireitar', hasImages ? () => straighten(context, state, o.targets) : null),
            btn(Icons.delete_outline, 'Excluir selecionadas',
                n == 0 ? null : () => act(() => o.remove(o.selected.toList()))),
            btn(Icons.filter_alt_outlined, 'Manter só as selecionadas', n == 0 ? null : () => act(o.keepSelected)),
          ],
        ),
        const SectionLabel('Seleção e ordem'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            btn(Icons.select_all, 'Selecionar tudo', none ? null : () => act(() => o.selected.addAll(o.pages))),
            btn(Icons.deselect, 'Limpar seleção', n == 0 ? null : () => act(o.selected.clear)),
            btn(Icons.swap_vert, 'Inverter ordem', o.pages.length < 2 ? null : () => act(o.reverse)),
            btn(Icons.restore, 'Restaurar original', docs.isEmpty ? null : () => act(() => o.reset(docs))),
          ],
        ),
        if (hasImages) ...[
          const SectionLabel('Imagens e digitalizações'),
          Choice<PageFit>(
            label: 'Tamanho da página',
            value: state.pdfConvert.fit,
            options: {for (final f in PageFit.values) f: f.label},
            onChanged: (v) {
              state.pdfConvert.fit = v;
              state.touch();
            },
          ),
        ],
        const SizedBox(height: 14),
        const InfoBox(
          'Arraste uma página para mudar de lugar; clique para selecionar; dois cliques para ver de perto; '
          'botão direito para girar, inverter e endireitar. Páginas de PDF saem idênticas às originais.',
          icon: Icons.touch_app_outlined,
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- bandeja

/// Bandeja de páginas (ocupa o lugar da lista de arquivos): miniaturas com
/// zoom ou a lista simples, e o botão de digitalizar.
class OrganizerWorkspace extends StatelessWidget {
  const OrganizerWorkspace({super.key, required this.state});
  final AppState state;

  static const minZoom = 96.0, maxZoom = 340.0;

  void _zoom(double value) {
    state.trayZoom = value.clamp(minZoom, maxZoom);
    state.touch();
  }

  Future<void> _scan(BuildContext context) async {
    final scanner = state.scanner;
    if (scanner == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Digitalizar'),
          content: Text(Platform.isWindows
              ? 'O motor de digitalização não foi encontrado (pasta "scanner" ao lado do FiLume.exe).'
              : 'A digitalização por TWAIN só existe no Windows.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))],
        ),
      );
      return;
    }
    final pages = await showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ScanDialog(scanner: scanner, settings: state.scan),
    );
    if (pages != null && pages.isNotEmpty) state.docs.addPaths(pages);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final docs = _trayDocs(state);
    final o = state.organizer..sync(docs);
    for (final d in docs) {
      if (d.isPdf) state.thumbs.ensure(d, state.pdf);
    }
    final tray = state.trayView == 'tray';
    final Widget body;
    if (o.pages.isEmpty) {
      body = Center(
        child: Text(
          'Arraste PDFs ou imagens para cá, ou digitalize.\nAs páginas aparecem aqui, como numa bandeja.',
          textAlign: TextAlign.center,
          style: _muted(context),
        ),
      );
    } else if (tray) {
      body = GridView.builder(
        padding: const EdgeInsets.fromLTRB(0, 4, 6, 4),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: state.trayZoom,
          childAspectRatio: 0.66,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: o.pages.length,
        itemBuilder: (context, i) {
          final ref = o.pages[i];
          return _PageTile(
            key: ObjectKey(ref),
            state: state,
            index: i,
            ref: ref,
            docLetter: docs.length > 1 ? String.fromCharCode(65 + docs.indexOf(ref.doc) % 26) : null,
          );
        },
      );
    } else {
      body = _FileList(state: state);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 4),
          child: Row(
            children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: 'tray', icon: Icon(Icons.grid_view_rounded, size: 18), tooltip: 'Bandeja (miniaturas)'),
                  ButtonSegment(value: 'list', icon: Icon(Icons.view_list_rounded, size: 18), tooltip: 'Lista simples'),
                ],
                selected: {state.trayView},
                onSelectionChanged: (v) {
                  state.trayView = v.first;
                  state.touch();
                },
              ),
              const SizedBox(width: 8),
              if (tray) ...[
                IconButton(
                  tooltip: 'Diminuir miniaturas',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _zoom(state.trayZoom - 40),
                  icon: const Icon(Icons.zoom_out, size: 20),
                ),
                Expanded(
                  child: Slider(
                    value: state.trayZoom.clamp(minZoom, maxZoom),
                    min: minZoom,
                    max: maxZoom,
                    onChanged: _zoom,
                  ),
                ),
                IconButton(
                  tooltip: 'Aumentar miniaturas',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _zoom(state.trayZoom + 40),
                  icon: const Icon(Icons.zoom_in, size: 20),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => _scan(context),
                icon: Icon(Icons.scanner_outlined, size: 18, color: cs.onSecondaryContainer),
                label: const Text('Digitalizar'),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

/// Visão simplificada: só os arquivos, um por linha.
class _FileList extends StatelessWidget {
  const _FileList({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final items = state.docs.items;
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final info = item.info;
        final String sub;
        if (item.error != null) {
          sub = item.error!;
        } else if (info == null) {
          sub = 'Lendo informações…';
        } else if (info.isPdf) {
          sub = info.encrypted
              ? 'protegido por senha (não entra na bandeja)'
              : '${info.pages} ${info.pages == 1 ? 'página' : 'páginas'}  ·  ${fmtBytes(info.sizeBytes)}';
        } else {
          sub = 'Imagem  ·  ${info.width}×${info.height}  ·  ${fmtBytes(info.sizeBytes)}';
        }
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 4, right: 0),
          leading: Icon(
            info?.isImage == true ? Icons.image_outlined : Icons.picture_as_pdf_outlined,
            color: item.error != null ? cs.error : cs.primary,
          ),
          title: Text(p.basename(item.path), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: item.error != null ? cs.error : cs.onSurfaceVariant)),
          trailing: IconButton(
            tooltip: 'Remover',
            onPressed: () => state.docs.remove(item),
            icon: const Icon(Icons.close, size: 18),
          ),
        );
      },
    );
  }
}

/// A imagem de uma página, já com o giro e o "endireitar" aplicados.
class _PageImage extends StatelessWidget {
  const _PageImage({required this.state, required this.ref, required this.cacheWidth, this.file});
  final AppState state;
  final PageRef ref;
  final int cacheWidth;

  /// Arquivo a mostrar no lugar da miniatura (página de PDF em alta).
  final String? file;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final path = file ?? (ref.isImage ? ref.doc.path : state.thumbs.fileFor(ref.doc.path, ref.page));
    Widget page = path == null
        ? ColoredBox(
            color: cs.surfaceContainerHighest,
            child: Center(
              child: Text('${ref.page}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.onSurfaceVariant)),
            ),
          )
        : Image.file(
            File(path),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            cacheWidth: cacheWidth,
            errorBuilder: (_, _, _) => ColoredBox(
              color: cs.surfaceContainerHighest,
              child: Icon(Icons.broken_image_outlined, color: cs.onSurfaceVariant),
            ),
          );
    if (ref.skew != 0) page = Transform.rotate(angle: ref.skew * math.pi / 180, child: page);
    return RotatedBox(quarterTurns: ref.rotation ~/ 90, child: page);
  }
}

class _PageTile extends StatelessWidget {
  const _PageTile({super.key, required this.state, required this.index, required this.ref, this.docLetter});
  final AppState state;
  final int index;
  final PageRef ref;
  final String? docLetter;

  void _act(VoidCallback f) {
    f();
    state.touch();
  }

  /// A seleção inteira quando a página clicada faz parte dela; senão, só ela.
  List<PageRef> get _targets {
    final o = state.organizer;
    return o.selected.contains(ref) ? o.pages.where(o.selected.contains).toList() : [ref];
  }

  Future<void> _menu(BuildContext context, Offset at) async {
    final o = state.organizer;
    final targets = _targets;
    final many = targets.length > 1;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    PopupMenuItem<String> item(String value, IconData icon, String label, {bool enabled = true}) => PopupMenuItem(
          value: value,
          enabled: enabled,
          height: 40,
          child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)]),
        );
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        item('view', Icons.zoom_in, 'Ver'),
        const PopupMenuDivider(),
        item('left', Icons.rotate_left, 'Girar à esquerda'),
        item('right', Icons.rotate_right, 'Girar à direita'),
        item('flip', Icons.flip_camera_android_outlined, 'Inverter (180°)'),
        item('straighten', Icons.straighten, 'Endireitar', enabled: targets.any((r) => r.isImage)),
        if (targets.any((r) => r.skew != 0)) item('unstraighten', Icons.undo, 'Desfazer endireitar'),
        const PopupMenuDivider(),
        item('delete', Icons.delete_outline, many ? 'Excluir ${targets.length} páginas' : 'Excluir página'),
      ],
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'view':
        showPageViewer(context, state, index);
      case 'left':
        _act(() => o.rotate(targets, 270));
      case 'right':
        _act(() => o.rotate(targets, 90));
      case 'flip':
        _act(() => o.rotate(targets, 180));
      case 'straighten':
        straighten(context, state, targets);
      case 'unstraighten':
        _act(() => o.straightenReset(targets));
      case 'delete':
        _act(() => o.remove(targets));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final o = state.organizer;
    final selected = o.selected.contains(ref);
    final thumb = _PageImage(state: state, ref: ref, cacheWidth: state.trayZoom > 200 ? 640 : 320);
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != index,
      onAcceptWithDetails: (d) => _act(() => o.move(d.data, index)),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        return Draggable<int>(
          data: index,
          feedback: Opacity(
            opacity: 0.85,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(width: 96, height: 130, child: thumb),
            ),
          ),
          childWhenDragging: const Opacity(opacity: 0.25, child: ColoredBox(color: Colors.grey)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: selected ? cs.primary.withValues(alpha: 0.16) : cs.surfaceContainerHigh.withValues(alpha: 0.6),
              border: Border.all(
                width: 2,
                color: hovering ? cs.tertiary : (selected ? cs.primary : Colors.transparent),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              type: MaterialType.transparency,
              child: GestureDetector(
                onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
                child: InkWell(
                  onTap: () => _act(() => o.toggle(ref)),
                  onDoubleTap: () => showPageViewer(context, state, index),
                  child: Column(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRect(child: thumb),
                              if (ref.busy)
                                const Center(
                                  child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
                                ),
                              if (ref.skew != 0)
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  child: Tooltip(
                                    message: 'Endireitada (${ref.skew.toStringAsFixed(1)}°)',
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(8)),
                                      child: Icon(Icons.straighten, size: 13, color: cs.onPrimary),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${index + 1}${docLetter == null ? '' : '  ·  $docLetter${ref.isImage ? '' : ref.page}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.textTheme.labelMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Girar',
                            visualDensity: VisualDensity.compact,
                            iconSize: 17,
                            onPressed: () => _act(() => o.rotate([ref], 90)),
                            icon: const Icon(Icons.rotate_right),
                          ),
                          IconButton(
                            tooltip: 'Excluir página',
                            visualDensity: VisualDensity.compact,
                            iconSize: 17,
                            onPressed: () => _act(() => o.remove([ref])),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// --------------------------------------------------------------- visualizador

void showPageViewer(BuildContext context, AppState state, int index) {
  showDialog<void>(
    context: context,
    builder: (context) => _PageViewer(state: state, start: index),
  );
}

/// Visualizador com zoom: roda do mouse ou botões para aproximar, arrastar
/// para mover, setas para trocar de página.
class _PageViewer extends StatefulWidget {
  const _PageViewer({required this.state, required this.start});
  final AppState state;
  final int start;

  @override
  State<_PageViewer> createState() => _PageViewerState();
}

class _PageViewerState extends State<_PageViewer> {
  late int _index = widget.start;
  final _tc = TransformationController();
  Size _viewport = Size.zero;

  AppState get state => widget.state;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _setScale(double scale) {
    final s = scale.clamp(0.5, 8.0);
    final cx = _viewport.width / 2, cy = _viewport.height / 2;
    // Escala em torno do centro da área visível.
    _tc.value = Matrix4.identity()
      ..setEntry(0, 0, s)
      ..setEntry(1, 1, s)
      ..setEntry(0, 3, cx * (1 - s))
      ..setEntry(1, 3, cy * (1 - s));
  }

  void _go(int delta) {
    final n = state.organizer.pages.length;
    if (n == 0) return;
    setState(() => _index = (_index + delta).clamp(0, n - 1));
    _tc.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([state, _tc]),
      builder: (context, _) {
        final o = state.organizer;
        if (o.pages.isEmpty) return const SizedBox.shrink();
        final index = _index.clamp(0, o.pages.length - 1);
        final ref = o.pages[index];
        final scale = _tc.value.getMaxScaleOnAxis();
        void act(VoidCallback f) {
          f();
          state.touch();
        }

        Widget tool(IconData icon, String tip, VoidCallback? onTap) =>
            IconButton(tooltip: tip, onPressed: onTap, icon: Icon(icon));
        return Dialog(
          insetPadding: const EdgeInsets.all(28),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                child: Row(
                  children: [
                    Text('Página ${index + 1} de ${o.pages.length}',
                        style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    tool(Icons.chevron_left, 'Página anterior', index > 0 ? () => _go(-1) : null),
                    tool(Icons.chevron_right, 'Próxima página', index < o.pages.length - 1 ? () => _go(1) : null),
                    const Spacer(),
                    tool(Icons.zoom_out, 'Afastar', () => _setScale(scale / 1.4)),
                    SizedBox(
                      width: 56,
                      child: Text('${(scale * 100).round()}%', textAlign: TextAlign.center, style: t.textTheme.labelLarge),
                    ),
                    tool(Icons.zoom_in, 'Aproximar', () => _setScale(scale * 1.4)),
                    tool(Icons.fit_screen_outlined, 'Ajustar à janela', () => _tc.value = Matrix4.identity()),
                    const SizedBox(width: 12),
                    tool(Icons.rotate_left, 'Girar à esquerda', () => act(() => o.rotate([ref], 270))),
                    tool(Icons.rotate_right, 'Girar à direita', () => act(() => o.rotate([ref], 90))),
                    tool(Icons.flip_camera_android_outlined, 'Inverter (180°)', () => act(() => o.rotate([ref], 180))),
                    tool(Icons.straighten, 'Endireitar', ref.isImage ? () => straighten(context, state, [ref]) : null),
                    const SizedBox(width: 12),
                    tool(Icons.close, 'Fechar', () => Navigator.pop(context)),
                  ],
                ),
              ),
              Expanded(
                child: ColoredBox(
                  color: cs.surfaceContainerLowest,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      _viewport = box.biggest;
                      return InteractiveViewer(
                        transformationController: _tc,
                        minScale: 0.5,
                        maxScale: 8,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: ref.isImage
                                ? _PageImage(state: state, ref: ref, cacheWidth: 2600)
                                // Página de PDF: mostra a miniatura e troca pela versão nítida quando ficar pronta.
                                : FutureBuilder<String?>(
                                    key: ObjectKey(ref),
                                    future: state.thumbs.renderPage(ref.doc, ref.page, state.pdf),
                                    builder: (context, snap) =>
                                        _PageImage(state: state, ref: ref, cacheWidth: 2600, file: snap.data),
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- digitalizar

class _ScanDialog extends StatefulWidget {
  const _ScanDialog({required this.scanner, required this.settings});
  final ScanTools scanner;
  final ScanSettings settings;

  @override
  State<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends State<_ScanDialog> {
  List<String>? _devices;
  String? _error, _details;
  bool _scanning = false;
  Process? _proc;
  int _load = 0;

  ScanSettings get s => widget.settings;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    final ticket = ++_load;
    setState(() {
      _devices = null;
      _error = _details = null;
    });
    try {
      final list = await widget.scanner.devices(s.driver);
      if (!mounted || ticket != _load) return;
      setState(() {
        _devices = list;
        if (!list.contains(s.device)) s.device = list.isEmpty ? '' : list.first;
      });
    } catch (e) {
      if (!mounted || ticket != _load) return;
      setState(() {
        _devices = const [];
        _error = e is ScanError ? e.message : 'Não foi possível listar os scanners.';
        _details = e is ScanError ? e.details : '$e';
      });
    }
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = _details = null;
    });
    try {
      final pages = await widget.scanner.scan(s, onStart: (proc) => _proc = proc);
      if (mounted) Navigator.pop(context, pages);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e is ScanError ? e.message : 'A digitalização não funcionou.';
        _details = e is ScanError ? e.details : '$e';
      });
    } finally {
      _proc = null;
    }
  }

  void _cancel() {
    _proc?.kill();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final devices = _devices;
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(text, style: t.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
        );
    Widget seg<T>(Map<T, String> options, T value, ValueChanged<T> onChanged) => Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<T>(
            showSelectedIcon: false,
            segments: [for (final e in options.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {value},
            onSelectionChanged: _scanning ? null : (v) => setState(() => onChanged(v.first)),
          ),
        );
    return AlertDialog(
      title: const Text('Digitalizar'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              label('Driver'),
              seg({'twain': 'TWAIN', 'wia': 'WIA'}, s.driver, (v) {
                s.driver = v;
                _loadDevices();
              }),
              label('Scanner'),
              if (devices == null)
                const Row(children: [
                  SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5)),
                  SizedBox(width: 12),
                  Text('Procurando scanners…'),
                ])
              else if (devices.isEmpty)
                Text(
                  _error ?? 'Nenhum scanner encontrado por este driver. Confira se ele está ligado e instalado, '
                      'ou tente o outro driver.',
                  style: TextStyle(color: cs.error),
                )
              else
                Choice<String>(
                  key: ValueKey('${s.driver}-${devices.length}'),
                  label: 'Aparelho',
                  value: s.device,
                  options: {for (final d in devices) d: d},
                  onChanged: (v) => setState(() => s.device = v),
                ),
              label('Origem do papel'),
              seg({'glass': 'Vidro', 'feeder': 'Alimentador', 'duplex': 'Frente e verso'}, s.source, (v) => s.source = v),
              label('Resolução'),
              seg({150: '150 dpi', 200: '200 dpi', 300: '300 dpi', 600: '600 dpi'}, s.dpi, (v) => s.dpi = v),
              label('Cores'),
              seg({'color': 'Colorido', 'gray': 'Tons de cinza', 'bw': 'Preto e branco'}, s.color, (v) => s.color = v),
              if (_scanning) ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text('Digitalizando… as páginas entram na bandeja quando terminar.', style: _muted(context)),
              ],
              if (_error != null && (devices?.isNotEmpty ?? false)) ...[
                const SizedBox(height: 16),
                Text(_error!, style: TextStyle(color: cs.error, fontWeight: FontWeight.w600)),
              ],
              if (_details != null && _details!.isNotEmpty) ...[
                const SizedBox(height: 6),
                SelectableText(_details!, maxLines: 6, style: _muted(context)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancelar')),
        FilledButton(
          onPressed: _scanning || devices == null || devices.isEmpty || s.device.isEmpty ? null : _scan,
          child: const Text('Digitalizar'),
        ),
      ],
    );
  }
}
