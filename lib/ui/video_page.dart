import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/compress.dart';
import '../core/ffmpeg.dart';
import '../core/format.dart';
import '../core/job.dart';
import '../core/split.dart';
import '../core/state.dart';
import 'common.dart';
import 'settings_panels.dart';

enum VideoTool { compress, split }

const _videoExts = [
  'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', 'ts', 'm2ts', 'mts', 'flv', 'wmv', 'mpg', 'mpeg', '3gp',
];

class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.state});
  final AppState state;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  VideoTool _tool = VideoTool.compress;
  bool _dragging = false;

  AppState get state => widget.state;

  Future<void> _pickFiles() async {
    final files = await openFiles(acceptedTypeGroups: const [
      XTypeGroup(label: 'Vídeos', extensions: _videoExts),
      XTypeGroup(label: 'Todos os arquivos'),
    ]);
    state.addPaths(files.map((f) => f.path));
  }

  Future<void> _pickOutputDir() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Salvar aqui');
    if (dir != null) {
      state.outputDir = dir;
      state.touch();
    }
  }

  void _start() {
    final ready = state.readyInputs;
    if (ready.isEmpty) return;
    state.queue.addAll([
      for (final info in ready)
        _tool == VideoTool.compress
            ? buildCompressJob(info, state.compress, state.outputDir, state.caps)
            : buildSplitJob(info, state.split, state.outputDir),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final ready = state.readyInputs.length;
        final verb = _tool == VideoTool.compress ? 'Comprimir' : 'Dividir';
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 20, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Vídeo', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 20),
                  SegmentedButton<VideoTool>(
                    segments: const [
                      ButtonSegment(
                          value: VideoTool.compress,
                          icon: Icon(Icons.compress),
                          label: Text('Comprimir')),
                      ButtonSegment(
                          value: VideoTool.split,
                          icon: Icon(Icons.content_cut),
                          label: Text('Dividir')),
                    ],
                    selected: {_tool},
                    onSelectionChanged: (v) => setState(() => _tool = v.first),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      'Em breve: conversor, cortador, merger, cropper, mux',
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              if (!state.toolsLoading && state.tools == null) ...[
                const SizedBox(height: 14),
                _MissingFfmpeg(onRetry: state.init),
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                child: _tool == VideoTool.compress
                                    ? CompressSettingsView(state: state)
                                    : SplitSettingsView(state: state),
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
                                  GlowButton(
                                    icon: _tool == VideoTool.compress ? Icons.compress : Icons.content_cut,
                                    label: ready == 0
                                        ? 'Adicione vídeos para começar'
                                        : '$verb $ready ${ready == 1 ? 'vídeo' : 'vídeos'}',
                                    onPressed: ready > 0 && state.tools != null ? _start : null,
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
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        state.addPaths(details.files.map((f) => f.path));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _dragging ? cs.primary : Colors.transparent, width: 2),
        ),
        child: Panel(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Arquivos', style: t.textTheme.titleMedium),
                  if (state.inputs.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text('${state.inputs.length}',
                        style: t.textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                  const Spacer(),
                  if (state.inputs.isNotEmpty)
                    TextButton(onPressed: state.clearInputs, child: const Text('Limpar')),
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
                child: state.inputs.isEmpty
                    ? InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: _pickFiles,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const FireflyLogo(size: 72),
                              const SizedBox(height: 8),
                              Text('Arraste vídeos para cá', style: t.textTheme.titleMedium),
                              const SizedBox(height: 4),
                              Text('ou clique para escolher',
                                  style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: state.inputs.length,
                        itemBuilder: (context, i) => _FileTile(
                          item: state.inputs[i],
                          hint: _hintFor(state.inputs[i]),
                          onRemove: () => state.removeInput(state.inputs[i]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Prévia do resultado para cada arquivo, conforme a ferramenta ativa.
  String? _hintFor(InputItem item) {
    final info = item.info;
    if (info == null) return null;
    if (_tool == VideoTool.split) {
      final n = state.split.estimateParts(info);
      if (n <= 1) return 'não precisa dividir';
      return '${state.split.mode == SplitMode.parts ? '' : '≈ '}$n partes';
    }
    final target = targetBytesFor(state.compress, info);
    if (target == null) return null;
    if (target >= info.sizeBytes) return 'já é menor que o alvo';
    return '→ ~${fmtBytes(target)}';
  }
}

class _MissingFfmpeg extends StatelessWidget {
  const _MissingFfmpeg({required this.onRetry});
  final VoidCallback onRetry;

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
  const _FileTile({required this.item, required this.hint, required this.onRemove});
  final InputItem item;
  final String? hint;
  final VoidCallback onRemove;

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
    } else {
      sub = [
        fmtDuration(info.duration),
        '${info.width}×${info.height}',
        if (info.fps > 0) '${info.fps.round()} fps',
        (info.vCodec ?? '?').toUpperCase(),
        fmtBytes(info.sizeBytes),
        if (info.bitrate > 0) fmtBitrate(info.bitrate),
      ].join('  ·  ');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            item.error != null ? Icons.error_outline : Icons.movie_outlined,
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
          IconButton(
            tooltip: 'Remover da lista',
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
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
          width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
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
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: job.progress <= 0 ? null : job.progress, minHeight: 6),
          ),
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
