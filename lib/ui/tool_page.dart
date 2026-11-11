import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';
import '../core/format.dart';
import '../core/job.dart';
import '../core/state.dart';
import 'common.dart';
import 'expressive.dart';
import 'geo.dart';
import 'process_button.dart';

/// Uma ferramenta de um módulo: rótulo, painel de opções e como virar tarefas.
class ToolDef {
  const ToolDef({
    required this.label,
    required this.icon,
    required this.panel,
    required this.jobs,
    this.hint,
    this.blocked,
    this.ordered = false,
    this.usesPreview = false,
    this.accepts,
    this.needs,
    this.workspace,
    this.actionLabel,
  });
  final String label;
  final IconData icon;
  final Widget Function(AppState state) panel;
  final List<Job> Function(AppState state, List<MediaInfo> ready) jobs;

  /// Prévia do resultado mostrada ao lado de cada arquivo.
  final String? Function(AppState state, MediaInfo info)? hint;

  /// Mensagem quando ainda não dá para começar (null = pode).
  final String? Function(AppState state, List<MediaInfo> ready)? blocked;

  /// A ordem da lista importa (mostra números e setas).
  final bool ordered;

  /// Tem prévia: clicar num arquivo escolhe qual aparece nela.
  final bool usesPreview;

  /// Quais arquivos da lista esta ferramenta usa (null = todos).
  final bool Function(MediaInfo info)? accepts;

  /// O que pedir quando nenhum arquivo serve (ex.: "PDFs").
  final String? needs;

  /// Área de trabalho própria no lugar da lista de arquivos (ex.: páginas).
  final Widget Function(AppState state)? workspace;

  /// Texto do botão principal (null = "<ferramenta> N <arquivos>").
  final String Function(AppState state, List<MediaInfo> ready)? actionLabel;
}

class ModuleDef {
  const ModuleDef({
    required this.id,
    required this.title,
    required this.one,
    required this.many,
    required this.typeLabel,
    required this.extensions,
    required this.inputs,
    required this.tools,
    this.audio = false,
    this.docs = false,
    this.missing,
  });
  /// "video", "audio", "pdf": identifica o módulo nas cores e nos recentes.
  final String id;
  final String title;

  /// "vídeo" / "vídeos", "áudio" / "áudios".
  final String one;
  final String many;
  final String typeLabel;
  final List<String> extensions;
  final InputList Function(AppState state) inputs;
  final List<ToolDef> tools;
  final bool audio;
  final bool docs;

  /// Aviso quando falta algum programa de que o módulo depende (null = ok).
  final String? Function(AppState state)? missing;
}

class ToolPage extends StatefulWidget {
  const ToolPage({super.key, required this.state, required this.module, this.onBack});
  final AppState state;
  final ModuleDef module;

  /// Mostra uma seta de voltar antes do título (ex.: voltar ao PDF Estúdio).
  final VoidCallback? onBack;

  @override
  State<ToolPage> createState() => _ToolPageState();
}

class _ToolPageState extends State<ToolPage> {
  bool _dragging = false;

  int get _index => (state.toolIndex[widget.module.title] ?? 0).clamp(0, widget.module.tools.length - 1);

  AppState get state => widget.state;
  ModuleDef get module => widget.module;
  InputList get inputs => module.inputs(state);
  ToolDef get _tool => module.tools[_index];

  Future<void> _pickFiles() async {
    final files = await openFiles(acceptedTypeGroups: [
      XTypeGroup(label: module.typeLabel, extensions: module.extensions),
      const XTypeGroup(label: 'Todos os arquivos'),
    ]);
    inputs.addPaths(files.map((f) => f.path));
  }

  Future<void> _pickOutputDir() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Salvar aqui');
    if (dir != null) {
      state.outputDir = dir;
      state.touch();
    }
  }

  List<MediaInfo> _accepted() {
    final accepts = _tool.accepts;
    return accepts == null ? inputs.ready : inputs.ready.where(accepts).toList();
  }

  void _start() {
    final ready = _accepted();
    if (ready.isEmpty) return;
    state.queue.addAll([
      for (final job in _tool.jobs(state, ready)) job..module = module.id,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final readyList = _accepted();
        final ready = readyList.length;
        final tool = _tool;
        final missing = state.toolsLoading ? null : module.missing?.call(state);
        final blocked = ready == 0
            ? 'Adicione ${tool.needs ?? module.many} para começar'
            : tool.blocked?.call(state, readyList);
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (widget.onBack != null) ...[
                    IconButton(
                      tooltip: 'Voltar',
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: 4),
                  ],
                  PageTitle(module.title),
                  const SizedBox(width: 20),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConnectedButtonGroup<int>(
                        items: [
                          for (var i = 0; i < module.tools.length; i++)
                            GroupItem(i, module.tools[i].label, module.tools[i].icon),
                        ],
                        selected: _index,
                        onSelected: (i) {
                          state.toolIndex[module.title] = i;
                          state.touch();
                        },
                      ),
                    ),
                  ),
                ],
              ),
              if (!state.toolsLoading && state.tools == null) ...[
                const SizedBox(height: 14),
                _MissingFfmpeg(onRetry: state.init),
              ] else if (missing != null) ...[
                const SizedBox(height: 14),
                _MissingFfmpeg(onRetry: state.init, message: missing),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ListenableBuilder(
                        listenable: state.queue,
                        builder: (context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 5, child: _filesPanel(context)),
                            if (state.queue.jobs.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Expanded(flex: 5, child: _QueuePanel(queue: state.queue)),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 380,
                      child: Panel(
                        padding: EdgeInsets.zero,
                        motif: toolMotifs[tool.label],
                        motifAlign: Alignment.topRight,
                        motifSize: 104,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                // A chave recria o painel ao trocar de ferramenta
                                // (e, com isso, libera o player da prévia).
                                child: KeyedSubtree(
                                  key: ValueKey('${module.title}-$_index'),
                                  child: tool.panel(state),
                                ),
                              ),
                            ),
                            Divider(height: 1, color: t.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _OutputDirRow(
                                    dir: state.outputDir,
                                    onPick: _pickOutputDir,
                                    onReset: () {
                                      state.outputDir = null;
                                      state.touch();
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  ProcessButton(
                                    queue: state.queue,
                                    label: blocked ??
                                        tool.actionLabel?.call(state, readyList) ??
                                        '${tool.label} $ready ${ready == 1 ? module.one : module.many}',
                                    onPressed:
                                        blocked == null && state.tools != null && missing == null ? _start : null,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _filesPanel(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final items = inputs.items;
    final tool = _tool;
    final preview = tool.usesPreview && items.length > 1 ? inputs.preview : null;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        inputs.addPaths(details.files.map((f) => f.path));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: _dragging ? cs.primary : Colors.transparent, width: 2),
        ),
        child: Panel(
          motif: moduleMotifs[module.id],
          motifSize: 150,
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Arquivos', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  if (items.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text('${items.length}',
                        style: t.textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                  const Spacer(),
                  if (items.isNotEmpty) TextButton(onPressed: inputs.clear, child: const Text('Limpar')),
                  const SizedBox(width: 4),
                  FilledButton.tonalIcon(
                    onPressed: _pickFiles,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Adicionar'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                // Ferramentas com área própria (a bandeja) cuidam do estado vazio.
                child: items.isEmpty && tool.workspace == null
                    ? InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: _pickFiles,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const FireflyLogo(size: 72),
                              const SizedBox(height: 8),
                              Text('Arraste ${module.many} para cá', style: t.textTheme.titleMedium),
                              const SizedBox(height: 4),
                              Text('ou clique para escolher',
                                  style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      )
                    : tool.workspace != null
                        ? tool.workspace!(state)
                        : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final item = items[i];
                          final info = item.info;
                          return _FileTile(
                            item: item,
                            audio: module.audio,
                            docs: module.docs,
                            hint: info == null
                                ? null
                                : (tool.accepts != null && !tool.accepts!(info)
                                    ? 'não se aplica aqui'
                                    : tool.hint?.call(state, info)),
                            onRemove: () => inputs.remove(item),
                            order: tool.ordered ? i + 1 : null,
                            onMove: tool.ordered ? (delta) => inputs.move(item, delta) : null,
                            canMoveUp: i > 0,
                            canMoveDown: i < items.length - 1,
                            selected: preview != null && identical(info, preview),
                            onSelect: tool.usesPreview && info != null ? () => inputs.select(item) : null,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MissingFfmpeg extends StatelessWidget {
  const _MissingFfmpeg({required this.onRetry, this.message});
  final VoidCallback onRetry;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message ??
                'FFmpeg não encontrado. Coloque ffmpeg.exe e ffprobe.exe na pasta "ffmpeg" ao lado do FiLume.exe.',
                style: TextStyle(color: cs.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Tentar de novo')),
          ],
        ),
      ),
    );
  }
}

class _OutputDirRow extends StatelessWidget {
  const _OutputDirRow({required this.dir, required this.onPick, required this.onReset});
  final String? dir;
  final VoidCallback onPick;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.folder_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Tooltip(
            message: dir ?? 'Cada resultado fica ao lado do vídeo original',
            child: Text(
              dir == null ? 'Salvar na pasta do original' : p.basename(dir!).isEmpty ? dir! : p.basename(dir!),
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodyMedium,
            ),
          ),
        ),
        if (dir != null)
          IconButton(
            tooltip: 'Voltar a salvar na pasta do original',
            visualDensity: VisualDensity.compact,
            onPressed: onReset,
            icon: const Icon(Icons.close, size: 18),
          ),
        TextButton(onPressed: onPick, child: const Text('Alterar')),
      ],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.item,
    required this.hint,
    required this.onRemove,
    this.order,
    this.onMove,
    this.canMoveUp = false,
    this.canMoveDown = false,
    this.audio = false,
    this.docs = false,
    this.selected = false,
    this.onSelect,
  });
  final InputItem item;
  final String? hint;
  final VoidCallback onRemove;

  /// Posição na lista (mostrada ao unir vídeos).
  final int? order;
  final void Function(int delta)? onMove;
  final bool canMoveUp;
  final bool canMoveDown;

  /// Lista do módulo de áudio: mostra os dados da faixa de áudio.
  final bool audio;

  /// Lista do módulo Documentos (PDFs e imagens).
  final bool docs;

  /// É o arquivo mostrado na prévia.
  final bool selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final info = item.info;
    final String sub;
    if (item.error != null) {
      sub = item.error!;
    } else if (info == null) {
      sub = 'Lendo informações…';
    } else if (docs) {
      sub = info.isPdf
          ? [
              if (info.encrypted) 'protegido por senha' else '${info.pages} ${info.pages == 1 ? 'página' : 'páginas'}',
              fmtBytes(info.sizeBytes),
            ].join('  ·  ')
          : ['Imagem', '${info.width}×${info.height}', fmtBytes(info.sizeBytes)].join('  ·  ');
    } else {
      sub = audio
          ? [
              fmtDuration(info.duration),
              (info.aCodec ?? '?').toUpperCase(),
              if (info.sampleRate > 0) '${(info.sampleRate / 1000).toStringAsFixed(1).replaceAll('.0', '')} kHz',
              if (info.channels > 0) info.channels == 1 ? 'mono' : (info.channels == 2 ? 'estéreo' : '${info.channels} canais'),
              if (info.hasVideo) 'áudio de vídeo' else fmtBytes(info.sizeBytes),
              if (!info.hasVideo && info.bitrate > 0) fmtBitrate(info.bitrate),
            ].join('  ·  ')
          : [
        fmtDuration(info.duration),
        '${info.width}×${info.height}',
        if (info.fps > 0) '${info.fps.round()} fps',
        (info.vCodec ?? '?').toUpperCase(),
        fmtBytes(info.sizeBytes),
        if (info.bitrate > 0) fmtBitrate(info.bitrate),
      ].join('  ·  ');
    }
    final row = Row(
        children: [
          if (order != null && item.error == null)
            SizedBox(
              width: 24,
              child: Text('$order',
                  textAlign: TextAlign.center,
                  style: t.textTheme.titleMedium?.copyWith(color: cs.primary)),
            )
          else
            Icon(
              item.error != null
                  ? Icons.error_outline
                  : (docs
                      ? (item.info?.isPdf ?? true ? Icons.picture_as_pdf_outlined : Icons.image_outlined)
                      : (audio ? Icons.audiotrack : Icons.movie_outlined)),
              color: item.error != null ? cs.error : cs.primary,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: item.path,
                  waitDuration: const Duration(milliseconds: 600),
                  child: Text(p.basename(item.path),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall
                      ?.copyWith(color: item.error != null ? cs.error : cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: 10),
            Text(hint!, style: t.textTheme.labelMedium?.copyWith(color: cs.tertiary)),
          ],
          if (onMove != null) ...[
            IconButton(
              tooltip: 'Subir',
              visualDensity: VisualDensity.compact,
              onPressed: canMoveUp ? () => onMove!(-1) : null,
              icon: const Icon(Icons.arrow_upward, size: 18),
            ),
            IconButton(
              tooltip: 'Descer',
              visualDensity: VisualDensity.compact,
              onPressed: canMoveDown ? () => onMove!(1) : null,
              icon: const Icon(Icons.arrow_downward, size: 18),
            ),
          ],
          IconButton(
            tooltip: 'Remover da lista',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSelect,
          child: Padding(padding: const EdgeInsets.fromLTRB(6, 4, 0, 4), child: row),
        ),
      ),
    );
  }
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({required this.queue});
  final JobQueue queue;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final jobs = queue.jobs;
    final done = jobs.where((j) => j.finished).length;
    return Panel(
      motif: 'queue',
      motifSize: 104,
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Fila', style: t.textTheme.titleMedium),
              const SizedBox(width: 8),
              Text('$done de ${jobs.length}',
                  style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const Spacer(),
              if (queue.busy)
                TextButton(onPressed: queue.cancelAll, child: const Text('Cancelar tudo')),
              if (done > 0)
                TextButton(onPressed: queue.clearFinished, child: const Text('Limpar concluídos')),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              itemCount: jobs.length,
              itemBuilder: (context, i) => _JobTile(job: jobs[i], queue: queue),
            ),
          ),
        ],
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.queue});
  final Job job;
  final JobQueue queue;

  void _showError(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Não deu certo'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: SelectableText(job.error ?? '')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    final Widget leading = switch (job.status) {
      JobStatus.queued => Icon(Icons.schedule, color: cs.onSurfaceVariant),
      JobStatus.running => const SizedBox(
          width: 24, height: 24, child: MorphLoader(size: 24)),
      JobStatus.done => Icon(Icons.check_circle, color: cs.primary),
      JobStatus.failed => Icon(Icons.error, color: cs.error),
      JobStatus.canceled => Icon(Icons.block, color: cs.onSurfaceVariant),
    };

    final List<Widget> body;
    switch (job.status) {
      case JobStatus.running:
        final eta = job.eta;
        body = [
          const SizedBox(height: 6),
          WavyProgress(value: job.progress <= 0 ? null : job.progress),
          const SizedBox(height: 4),
          Text(
            [
              fmtPercent(job.progress),
              job.stage,
              if (job.speed != null) job.speed!,
              if (eta != null) 'faltam ${fmtDuration(eta.inSeconds.toDouble())}',
            ].join('  ·  '),
            style: small,
          ),
        ];
      case JobStatus.done:
        final r = job.result;
        body = [
          Text(r?.summary ?? 'Concluído', style: small?.copyWith(color: cs.onSurface)),
          if (r?.warning != null) Text(r!.warning!, style: small?.copyWith(color: cs.tertiary)),
        ];
      case JobStatus.failed:
        body = [
          Text((job.error ?? 'Falhou').split('\n').first,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: cs.error)),
        ];
      case JobStatus.queued:
      case JobStatus.canceled:
        body = [Text(job.stage, style: small)];
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: SizedBox(width: 24, child: leading)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge),
                Text('${job.kind}  ·  ${job.detail}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                ...body,
              ],
            ),
          ),
          if (job.status == JobStatus.failed && (job.error ?? '').contains('\n'))
            TextButton(onPressed: () => _showError(context), child: const Text('Detalhes')),
          if (job.status == JobStatus.done && job.result != null)
            IconButton(
              tooltip: 'Mostrar na pasta',
              visualDensity: VisualDensity.compact,
              onPressed: () => revealInFileManager(job.result!.revealPath),
              icon: const Icon(Icons.folder_open, size: 20),
            ),
          IconButton(
            tooltip: job.finished ? 'Tirar da fila' : 'Cancelar',
            visualDensity: VisualDensity.compact,
            onPressed: () => job.finished ? queue.remove(job) : queue.cancel(job),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}
