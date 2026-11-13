import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/compare.dart';
import '../core/ffmpeg.dart';
import '../core/job.dart';
import '../core/ocr.dart';
import '../core/state.dart';
import '../ui/common.dart';
import '../ui/process_button.dart';
import 'pdf_app.dart' show JobStatusCard;
import 'save_dialog.dart';

/// Estado do comparador: os dois arquivos, o andamento e o resultado.
/// Vive enquanto o app está aberto, mesmo trocando de ferramenta.
class CompareSession extends ChangeNotifier {
  CompareSession(this.state);
  final AppState state;

  /// 0 = original, 1 = novo.
  final List<MediaInfo?> files = [null, null];
  final List<bool> loading = [false, false];
  CompareTolerance tolerance = CompareTolerance.auto;

  bool running = false;
  double progress = 0;
  String stage = '';
  String? error;
  CompareResult? result;
  FfRun? _run;

  /// Par em exibição (índice em result.pairs).
  int selected = 0;
  bool onlyDiffs = true;
  bool marks = true;

  bool get ready => files[0] != null && files[1] != null && !running;

  List<int> get visible {
    final r = result;
    if (r == null) return const [];
    return [
      for (var i = 0; i < r.pairs.length; i++)
        if (!onlyDiffs || r.pairs[i].status != PairStatus.equal) i,
    ];
  }

  void _drop() {
    result?.dispose();
    result = null;
  }

  Future<void> load(int slot, String path) async {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    if (ext != 'pdf' && !imageExts.contains(ext)) {
      error = 'O comparador aceita PDFs e imagens.';
      notifyListeners();
      return;
    }
    loading[slot] = true;
    error = null;
    notifyListeners();
    try {
      final MediaInfo info;
      if (ext == 'pdf') {
        final pdf = state.pdf ?? (throw FfError('As ferramentas de PDF não foram encontradas.'));
        info = await pdf.probe(path);
        if (info.encrypted) throw FfError('"${p.basename(path)}" é protegido por senha. Remova a senha antes (ferramenta Senha).');
      } else {
        final tools = state.tools ?? (throw FfError('O FFmpeg não foi encontrado.'));
        info = MediaInfo.image(await tools.probe(path), size: await tools.imageDisplaySize(path));
      }
      files[slot] = info;
      _drop();
    } catch (e) {
      error = e is FfError ? e.message : 'Não foi possível abrir "${p.basename(path)}".';
    }
    loading[slot] = false;
    notifyListeners();
  }

  /// Arquivos soltos em [slot]. Dois de uma vez preenchem original e novo.
  Future<void> drop(List<String> paths, int slot) async {
    if (paths.isEmpty || running) return;
    if (paths.length >= 2) {
      await load(0, paths[0]);
      await load(1, paths[1]);
    } else {
      await load(slot, paths.first);
    }
  }

  void clear(int slot) {
    files[slot] = null;
    _drop();
    notifyListeners();
  }

  void swap() {
    final t = files[0];
    files[0] = files[1];
    files[1] = t;
    _drop();
    notifyListeners();
  }

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  void select(int index) {
    selected = index;
    notifyListeners();
  }

  /// Vai para a diferença anterior (-1) ou seguinte (+1).
  void step(int dir) {
    final v = visible;
    if (v.isEmpty) return;
    final at = v.indexOf(selected);
    selected = v[(at < 0 ? 0 : at + dir).clamp(0, v.length - 1)];
    notifyListeners();
  }

  Future<void> compare() async {
    final a = files[0], b = files[1], pdf = state.pdf, tools = state.tools;
    if (a == null || b == null || pdf == null || tools == null || running) return;
    _drop();
    // Sobras de comparações antigas (o app fechou com uma aberta).
    try {
      final old = DateTime.now().subtract(const Duration(hours: 12));
      for (final e in Directory.systemTemp.listSync()) {
        if (e is Directory && p.basename(e.path).startsWith('filume_cmp_') && e.statSync().modified.isBefore(old)) {
          e.deleteSync(recursive: true);
        }
      }
    } catch (_) {}
    running = true;
    progress = 0;
    stage = 'Começando';
    error = null;
    notifyListeners();
    final run = _run = FfRun();
    try {
      final r = await comparePdfs(
        JobCtx(tools, run, (pr, st, _) {
          progress = pr;
          if (st != null) stage = st;
          notifyListeners();
        }),
        pdf,
        a,
        b,
        tolerance: tolerance,
        ocr: Platform.isWindows ? WindowsOcr.recognize : null,
      );
      result = r;
      final first = r.pairs.indexWhere((x) => x.status != PairStatus.equal);
      selected = first < 0 ? 0 : first;
      onlyDiffs = !r.identical;
    } on JobCanceled {
      // parado pela pessoa
    } on FfError catch (e) {
      error = e.message;
    } catch (e) {
      error = run.canceled ? null : 'A comparação falhou: $e';
    }
    running = false;
    _run = null;
    notifyListeners();
  }

  void cancel() => _run?.cancel();

  @override
  void dispose() {
    _run?.cancel();
    result?.dispose();
    super.dispose();
  }
}

Future<String?> _pickFile() async {
  final f = await openFile(acceptedTypeGroups: [
    const XTypeGroup(label: 'PDFs e imagens', extensions: ['pdf', ...imageExts]),
  ]);
  return f?.path;
}

const _slotNames = ['Original', 'Novo'];

Color _statusColor(ColorScheme cs, PairStatus s) => switch (s) {
      PairStatus.equal => cs.outline,
      PairStatus.changed => const Color(0xFFE08A00),
      PairStatus.added => const Color(0xFF2E9E5B),
      PairStatus.removed => cs.error,
    };

String _statusLabel(PairStatus s) => switch (s) {
      PairStatus.equal => 'Igual',
      PairStatus.changed => 'Alterada',
      PairStatus.added => 'Adicionada',
      PairStatus.removed => 'Removida',
    };

String _pct(double v) => v <= 0
    ? ''
    : v < 0.001
        ? 'menos de 0,1%'
        : '${(v * 100).toStringAsFixed(v < 0.1 ? 1 : 0).replaceAll('.', ',')}%';

/// Área do comparador: no lugar da bandeja, a comparação lado a lado.
class CompareView extends StatelessWidget {
  const CompareView({super.key, required this.state, required this.session});
  final AppState state;
  final CompareSession session;

  Future<void> _saveReport(BuildContext context) async {
    final r = session.result;
    if (r == null) return;
    final b = session.files[1];
    final choice = await showSaveDialog(
      context,
      state.prefs,
      title: 'Salvar relatório',
      name: '${p.basenameWithoutExtension(r.nameB)}_comparacao',
      originalDir: b == null ? null : p.dirname(b.path),
    );
    if (choice == null) return;
    state.queue.addAll([buildCompareReportJob(r, choice.dir, choice.name)..module = 'pdf']);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Panel(
                padding: const EdgeInsets.all(14),
                child: session.running
                    ? _Running(session: session)
                    : session.result == null
                        ? _Slots(session: session)
                        : _Results(session: session),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(width: 340, child: _options(context)),
          ],
        ),
      ),
    );
  }

  Widget _options(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final r = session.result;
    return Panel(
      motif: 'pages',
      motifAlign: Alignment.topRight,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Comparar', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionLabel('Arquivos'),
                  _FileRow(session: session, slot: 0),
                  Align(
                    child: IconButton(
                      tooltip: 'Trocar original e novo',
                      onPressed: session.running || (session.files[0] == null && session.files[1] == null) ? null : session.swap,
                      icon: const Icon(Icons.swap_vert),
                    ),
                  ),
                  _FileRow(session: session, slot: 1),
                  const SectionLabel('Tolerância'),
                  SegmentedButton<CompareTolerance>(
                    showSelectedIcon: false,
                    segments: [for (final c in CompareTolerance.values) ButtonSegment(value: c, label: Text(c.label))],
                    selected: {session.tolerance},
                    onSelectionChanged: session.running ? null : (v) => session.set(() => session.tolerance = v.first),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      switch (session.tolerance) {
                        CompareTolerance.auto =>
                          'PDFs digitais são comparados ponto a ponto; fotos e digitalizações, com folga para ruído, '
                              'brilho e folha fora do lugar.',
                        CompareTolerance.exact => 'Qualquer ponto diferente conta. Em fotos e digitalizações, acusa até o grão do papel.',
                        CompareTolerance.tolerant =>
                          'Ignora ruído, diferença de brilho e pequenos deslocamentos. Mudanças minúsculas podem passar.',
                      },
                      style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                  if (r != null) ...[
                    const SectionLabel('Resultado'),
                    Text(r.summary, style: t.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      '${r.count(PairStatus.equal)} ${r.count(PairStatus.equal) == 1 ? 'página igual' : 'páginas iguais'} · '
                      'original com ${r.pagesA}, novo com ${r.pagesB}',
                      style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    if (r.note != null) ...[const SizedBox(height: 10), InfoBox(r.note!, icon: Icons.info_outline)],
                  ] else ...[
                    const SizedBox(height: 14),
                    const InfoBox(
                      'O comparador emparelha as páginas (acha as inseridas e as removidas), marca na página o que mudou '
                      'e lista as palavras que saíram e entraram. Funciona também com fotos e digitalizações.',
                      icon: Icons.difference_outlined,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (session.error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16)),
              child: Text(session.error!, style: t.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer)),
            ),
          if (r != null) JobStatusCard(queue: state.queue),
          const SizedBox(height: 10),
          if (session.running)
            OutlinedButton.icon(onPressed: session.cancel, icon: const Icon(Icons.stop_circle_outlined), label: const Text('Parar'))
          else if (r == null)
            FilledButton.icon(
              onPressed: session.ready ? session.compare : null,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.difference_outlined),
              label: Text(session.ready ? 'Comparar' : 'Escolha os dois arquivos'),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: session.ready ? session.compare : null,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Comparar de novo'),
            ),
            const SizedBox(height: 8),
            ProcessButton(queue: state.queue, label: 'Salvar relatório', onPressed: () => _saveReport(context)),
          ],
        ],
      ),
    );
  }
}

/// Linha de arquivo no painel: nome e páginas, escolher e tirar.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.session, required this.slot});
  final CompareSession session;
  final int slot;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final f = session.files[slot];
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: session.running
            ? null
            : () async {
                final path = await _pickFile();
                if (path != null) session.load(slot, path);
              },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Icon(slot == 0 ? Icons.description_outlined : Icons.note_add_outlined, color: cs.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_slotNames[slot], style: t.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                    Text(
                      session.loading[slot] ? 'Abrindo…' : (f == null ? 'Escolher arquivo…' : p.basename(f.path)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodyMedium?.copyWith(fontWeight: f == null ? FontWeight.w400 : FontWeight.w600),
                    ),
                    if (f != null)
                      Text(
                        f.isImage ? 'imagem' : '${f.pages} ${f.pages == 1 ? 'página' : 'páginas'}',
                        style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              if (f != null)
                IconButton(
                  tooltip: 'Tirar',
                  visualDensity: VisualDensity.compact,
                  onPressed: session.running ? null : () => session.clear(slot),
                  icon: const Icon(Icons.close, size: 16),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Antes de comparar: dois lugares grandes para soltar os arquivos.
class _Slots extends StatelessWidget {
  const _Slots({required this.session});
  final CompareSession session;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: _Slot(session: session, slot: 0)),
          const SizedBox(width: 14),
          Expanded(child: _Slot(session: session, slot: 1)),
        ],
      );
}

class _Slot extends StatefulWidget {
  const _Slot({required this.session, required this.slot});
  final CompareSession session;
  final int slot;

  @override
  State<_Slot> createState() => _SlotState();
}

class _SlotState extends State<_Slot> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final s = widget.session;
    final f = s.files[widget.slot];
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (d) {
        setState(() => _over = false);
        s.drop([for (final x in d.files) x.path], widget.slot);
      },
      child: Material(
        color: _over ? cs.primaryContainer : cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () async {
            final path = await _pickFile();
            if (path != null) s.load(widget.slot, path);
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: _over ? cs.primary : cs.outlineVariant, width: _over ? 2 : 1),
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  f != null ? Icons.check_circle_outline : (widget.slot == 0 ? Icons.description_outlined : Icons.note_add_outlined),
                  size: 56,
                  color: cs.primary,
                ),
                const SizedBox(height: 14),
                Text(_slotNames[widget.slot], style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(
                  s.loading[widget.slot]
                      ? 'Abrindo…'
                      : f != null
                          ? '${p.basename(f.path)}\n${f.isImage ? 'imagem' : '${f.pages} ${f.pages == 1 ? 'página' : 'páginas'}'}'
                          : widget.slot == 0
                              ? 'Solte aqui a versão antiga\n(ou clique para escolher)'
                              : 'Solte aqui a versão nova\n(ou clique para escolher)',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Running extends StatelessWidget {
  const _Running({required this.session});
  final CompareSession session;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.difference_outlined, size: 48, color: t.colorScheme.primary),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: session.progress, minHeight: 8),
            ),
            const SizedBox(height: 12),
            Text(session.stage, style: t.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- resultado

class _Results extends StatefulWidget {
  const _Results({required this.session});
  final CompareSession session;

  @override
  State<_Results> createState() => _ResultsState();
}

class _ResultsState extends State<_Results> {
  final _zoom = TransformationController();
  int _shown = -1;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final r = s.result!;
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final visible = s.visible;
    if (!visible.contains(s.selected) && visible.isNotEmpty) s.selected = visible.first;
    if (_shown != s.selected) {
      _shown = s.selected;
      _zoom.value = Matrix4.identity(); // página nova começa sem zoom
    }
    final at = visible.indexOf(s.selected);
    final pair = visible.isEmpty ? null : r.pairs[s.selected];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(r.summary, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            FilterChip(
              label: const Text('Só diferenças'),
              selected: s.onlyDiffs,
              onSelected: r.identical ? null : (v) => s.set(() => s.onlyDiffs = v),
            ),
            FilterChip(label: const Text('Marcações'), selected: s.marks, onSelected: (v) => s.set(() => s.marks = v)),
            IconButton.filledTonal(
              tooltip: 'Anterior',
              onPressed: at > 0 ? () => s.step(-1) : null,
              icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            ),
            IconButton.filledTonal(
              tooltip: 'Próxima',
              onPressed: at >= 0 && at < visible.length - 1 ? () => s.step(1) : null,
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            ),
            if (visible.isNotEmpty)
              Text('${at + 1} de ${visible.length}', style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            IconButton(
              tooltip: 'Tirar o zoom',
              onPressed: () => setState(() => _zoom.value = Matrix4.identity()),
              icon: const Icon(Icons.fit_screen_outlined, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: pair == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified_outlined, size: 56, color: cs.primary),
                      const SizedBox(height: 12),
                      Text('Nenhuma diferença encontrada', style: t.textTheme.titleLarge),
                      const SizedBox(height: 6),
                      Text('Desmarque "Só diferenças" para ver as páginas.',
                          style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 168, child: _PairList(session: s, visible: visible)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: _PageSide(pair: pair, side: 0, marks: s.marks, zoom: _zoom)),
                                const SizedBox(width: 10),
                                Expanded(child: _PageSide(pair: pair, side: 1, marks: s.marks, zoom: _zoom)),
                              ],
                            ),
                          ),
                          if (pair.text.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            SizedBox(height: 150, child: _TextChanges(pair: pair)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _PairList extends StatelessWidget {
  const _PairList({required this.session, required this.visible});
  final CompareSession session;
  final List<int> visible;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final pairs = session.result!.pairs;
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, k) {
        final i = visible[k];
        final x = pairs[i];
        final on = i == session.selected;
        final detail = x.status == PairStatus.changed
            ? [
                if (x.regions.isNotEmpty) _pct(x.changed),
                if (x.text.isNotEmpty) '${x.text.length} no texto',
              ].where((e) => e.isNotEmpty).join(' · ')
            : '';
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
            color: on ? cs.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => session.select(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: _statusColor(cs, x.status), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${x.a == null ? '—' : 'p. ${x.a}'}  →  ${x.b == null ? '—' : 'p. ${x.b}'}',
                            style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${_statusLabel(x.status)}${detail.isEmpty ? '' : '\n$detail'}',
                            style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Um lado da comparação: a página, com as diferenças marcadas por cima.
class _PageSide extends StatelessWidget {
  const _PageSide({required this.pair, required this.side, required this.marks, required this.zoom});
  final PagePair pair;
  final int side;
  final bool marks;
  final TransformationController zoom;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final file = side == 0 ? pair.imageA : pair.imageB;
    final number = side == 0 ? pair.a : pair.b;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_slotNames[side]}${number == null ? '' : ' · página $number'}',
          style: t.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ColoredBox(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              child: file == null
                  ? Center(
                      child: Text(
                        side == 0 ? 'Esta página não existe no original\n(foi adicionada)' : 'Esta página não existe no novo\n(foi removida)',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    )
                  : InteractiveViewer(
                      transformationController: zoom,
                      minScale: 1,
                      maxScale: 10,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: AspectRatio(
                            aspectRatio: side == 0 ? pair.aspectA : pair.aspectB,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.file(File(file), fit: BoxFit.fill, filterQuality: FilterQuality.medium, gaplessPlayback: true),
                                if (marks && pair.regions.isNotEmpty)
                                  CustomPaint(
                                    painter: _MarksPainter(
                                      pair.regions,
                                      side == 0 ? 0 : pair.shiftX,
                                      side == 0 ? 0 : pair.shiftY,
                                      side == 0 ? cs.error : const Color(0xFF2E9E5B),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MarksPainter extends CustomPainter {
  _MarksPainter(this.regions, this.dx, this.dy, this.color);
  final List<DiffRegion> regions;
  final double dx, dy;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withValues(alpha: 0.16);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final g in regions) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH((g.x + dx) * size.width, (g.y + dy) * size.height, g.w * size.width, g.h * size.height).inflate(2),
        const Radius.circular(3),
      );
      canvas.drawRRect(rect, fill);
      canvas.drawRRect(rect, line);
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => old.regions != regions || old.color != color || old.dx != dx || old.dy != dy;
}

/// Lista do que mudou no texto: o que saiu (riscado) e o que entrou.
class _TextChanges extends StatelessWidget {
  const _TextChanges({required this.pair});
  final PagePair pair;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final base = t.textTheme.bodyMedium;
    const green = Color(0xFF2E9E5B);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${pair.text.length} ${pair.text.length == 1 ? 'alteração' : 'alterações'} no texto'
            '${pair.ocrText ? ' · lido por OCR, pode ter erros de leitura' : ''}',
            style: muted,
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.separated(
              itemCount: pair.text.length,
              separatorBuilder: (_, __) => Divider(height: 10, color: cs.outlineVariant),
              itemBuilder: (context, i) {
                final c = pair.text[i];
                return SelectableText.rich(
                  TextSpan(
                    style: base,
                    children: [
                      if (c.before.isNotEmpty) TextSpan(text: '… ${c.before} ', style: muted),
                      if (c.removed.isNotEmpty)
                        TextSpan(
                          text: c.removed,
                          style: TextStyle(
                            color: cs.error,
                            decoration: TextDecoration.lineThrough,
                            backgroundColor: cs.error.withValues(alpha: 0.10),
                          ),
                        ),
                      if (c.removed.isNotEmpty && c.added.isNotEmpty) const TextSpan(text: '  '),
                      if (c.added.isNotEmpty)
                        TextSpan(
                          text: c.added,
                          style: TextStyle(color: green, fontWeight: FontWeight.w600, backgroundColor: green.withValues(alpha: 0.12)),
                        ),
                      if (c.after.isNotEmpty) TextSpan(text: ' ${c.after} …', style: muted),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
