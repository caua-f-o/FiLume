import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';
import '../core/job.dart';
import '../core/prefs.dart';
import '../core/state.dart';
import 'expressive.dart';
import 'geo.dart';
import 'home_widgets.dart';
import 'modules.dart';
import 'theme.dart';

/// Envia cada arquivo para a lista do módulo certo e devolve o módulo do
/// primeiro arquivo reconhecido (para onde a tela deve ir).
String? routeFiles(AppState state, List<String> paths) {
  String? target;
  for (final path in paths) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    final String module;
    if (ext == 'pdf' || imageExts.contains(ext)) {
      module = 'pdf';
      state.docs.addPaths([path]);
    } else if (videoModule.extensions.contains(ext)) {
      module = 'video';
      state.video.addPaths([path]);
    } else if (audioModule.extensions.contains(ext)) {
      module = 'audio';
      state.audio.addPaths([path]);
    } else {
      continue;
    }
    target ??= module;
  }
  if (target == 'pdf') {
    // Imagens soltas sozinhas abrem direto em "Imagens → PDF".
    final onlyImages = paths.every((f) => p.extension(f).toLowerCase() != '.pdf');
    if (!state.pdfOpen) state.toolIndex[docsModule.title] = onlyImages ? 5 : 3;
    state.pdfOpen = true;
  }
  state.touch();
  return target;
}

class _Category {
  const _Category(this.id, this.name, this.sub, this.icon, this.motif, {this.soon = false});
  final String id, name, sub, motif;
  final IconData icon;
  final bool soon;
}

const _categories = [
  _Category('pdf', 'PDF Estúdio', 'Organizar · Comprimir · Dividir · Unir · Senha · Imagens',
      Icons.picture_as_pdf_outlined, 'pages'),
  _Category('video', 'Vídeo', 'Comprimir · Dividir · Cortar · Converter', Icons.videocam_outlined, 'video'),
  _Category('audio', 'Áudio', 'Converter · Comprimir · Mixar · Unir', Icons.music_note_outlined, 'audio'),
  _Category('image', 'Imagem', 'Converter · Comprimir · Redimensionar', Icons.image_outlined, 'image', soon: true),
  _Category('files', 'Arquivos', 'Conversor de documentos', Icons.swap_horiz, 'convert', soon: true),
];

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state, required this.onNavigate});
  final AppState state;
  final void Function(String page) onNavigate;

  Future<void> _pick() async {
    final files = await openFiles(acceptedTypeGroups: [
      XTypeGroup(label: 'Vídeos, áudios, PDFs e imagens', extensions: {
        ...videoModule.extensions,
        ...audioModule.extensions,
        ...docsModule.extensions,
      }.toList()),
      const XTypeGroup(label: 'Todos os arquivos'),
    ]);
    _route([for (final f in files) f.path]);
  }

  void _route(List<String> paths) {
    final target = routeFiles(state, paths);
    if (target != null) onNavigate(target);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 8, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'O que vamos fazer hoje?',
            style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
          ),
          const SizedBox(height: 6),
          Text(
            'Comece arrastando um arquivo ou selecione manualmente. As ferramentas estão à sua disposição.',
            style: t.textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 410,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 10,
                  child: DropZone(
                    text: 'É aqui que a mágica acontece: o FiLume seleciona a ferramenta certa '
                        'com base no arquivo escolhido.',
                    onFiles: _route,
                    onPick: _pick,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(flex: 14, child: _Categories(state: state, onNavigate: onNavigate)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: _Recents(prefs: state.prefs)),
                const SizedBox(width: 16),
                Expanded(child: _QueueCard(queue: state.queue)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Categories extends StatelessWidget {
  const _Categories({required this.state, required this.onNavigate});
  final AppState state;
  final void Function(String page) onNavigate;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final pdfTint = buildTheme(seedFor(state.prefs, 'pdf'), brightness).colorScheme.primary;
    Widget tile(_Category c, {bool wide = false}) => Theme(
          data: buildTheme(seedFor(state.prefs, c.id), brightness),
          child: Builder(builder: (context) {
            final mcs = Theme.of(context).colorScheme;
            return GeoCard(
              motif: c.motif,
              motifSize: wide ? 136 : 100,
              onTap: () => onNavigate(c.id),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(color: mcs.primary, borderRadius: BorderRadius.circular(16)),
                    child: Icon(c.icon, color: mcs.onPrimary, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                c.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (c.soon) ...[
                              const SizedBox(width: 8),
                              Pill(
                                'em breve',
                                color: mcs.onPrimaryContainer,
                                background: mcs.onPrimaryContainer.withValues(alpha: 0.14),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          c.sub,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.35,
                            color: mcs.onPrimaryContainer.withValues(alpha: 0.88),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: wide ? 110 : 24),
                ],
              ),
            );
          }),
        );
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.55)),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            Color.alphaBlend(cs.primary.withValues(alpha: 0.13), cs.surfaceContainer),
            cs.surfaceContainerLow,
            Color.alphaBlend(pdfTint.withValues(alpha: 0.12), cs.surfaceContainerLow),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 11, child: tile(_categories[0], wide: true)),
          const SizedBox(height: 12),
          Expanded(
            flex: 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tile(_categories[1])),
                const SizedBox(width: 12),
                Expanded(child: tile(_categories[2])),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tile(_categories[3])),
                const SizedBox(width: 12),
                Expanded(child: tile(_categories[4])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Recents extends StatelessWidget {
  const _Recents({required this.prefs});
  final Prefs prefs;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final items = prefs.recents.take(5).toList();
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
          decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(24)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Recentes', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                    onPressed: items.isEmpty ? null : prefs.clearRecents,
                    child: const Text('Limpar'),
                  ),
                ],
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 12, 20),
                  child: Text(
                    prefs.keepRecents
                        ? 'Os arquivos que você processar aparecem aqui.'
                        : 'O histórico de recentes está desligado nos Ajustes.',
                    style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              for (final r in items) ...[
                Divider(height: 1, color: cs.outlineVariant),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Builder(builder: (context) {
                        final mcs = buildTheme(seedFor(prefs, r.module), t.brightness).colorScheme;
                        return Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration:
                              BoxDecoration(color: mcs.primaryContainer, borderRadius: BorderRadius.circular(12)),
                          child: Text(
                            r.tag,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: mcs.onPrimaryContainer),
                          ),
                        );
                      }),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                            Text(r.detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Abrir pasta',
                        onPressed: () => revealInFileManager(r.path),
                        icon: const Icon(Icons.folder_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.queue});
  final JobQueue queue;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        final job = queue.running;
        final waiting = queue.waiting;
        final eta = job?.eta;
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(24)),
          child: Stack(
            children: [
              Positioned(
                right: 14,
                bottom: 10,
                child: Motif('queue', size: 84, color: cs.primary.withValues(alpha: 0.20)),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Fila', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 14),
                    if (job == null)
                      Text(
                        queue.jobs.any((j) => j.status == JobStatus.done)
                            ? 'Tudo concluído.'
                            : 'Nada em andamento.',
                        style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      )
                    else ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${job.kind}: ${job.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${(job.progress * 100).round()}%',
                              style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      WavyProgress(value: job.progress <= 0 ? null : job.progress),
                      const SizedBox(height: 8),
                      Text(
                        [
                          job.stage,
                          if (eta != null)
                            eta.inMinutes >= 1 ? 'faltam ~${eta.inMinutes} min' : 'faltam ~${eta.inSeconds} s',
                        ].join(' · '),
                        style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      if (waiting > 0) ...[
                        const SizedBox(height: 12),
                        Divider(height: 1, color: cs.outlineVariant),
                        const SizedBox(height: 12),
                        Text(
                          'Depois: $waiting ${waiting == 1 ? 'arquivo' : 'arquivos'} na espera',
                          style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
