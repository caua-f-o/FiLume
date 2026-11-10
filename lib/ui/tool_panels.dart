import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/compress.dart';
import '../core/convert.dart';
import '../core/crop.dart';
import '../core/ffmpeg.dart';
import '../core/format.dart';
import '../core/merge.dart';
import '../core/mux.dart';
import '../core/state.dart';
import '../core/streams.dart';
import 'common.dart';
import 'preview_player.dart';

TextStyle? _muted(BuildContext context) {
  final t = Theme.of(context);
  return t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
}

/// Qualidade (e CPU/GPU) para as ferramentas que precisam recodificar.
class ReencodeSection extends StatelessWidget {
  const ReencodeSection({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final r = state.reencode;
    final gpu = state.caps.gpuFor(VCodec.h264);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Qualidade ao recodificar'),
        SegmentedButton<ReLevel>(
          showSelectedIcon: false,
          segments: [
            for (final l in ReLevel.values) ButtonSegment(value: l, label: Text(l.label)),
          ],
          selected: {r.level},
          onSelectionChanged: (v) {
            r.level = v.first;
            state.touch();
          },
        ),
        if (gpu != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('Usar a GPU (${EncoderCaps.gpuLabel(gpu)})'),
            subtitle: const Text('Bem mais rápido; arquivo um pouco maior.'),
            value: r.useGpu,
            onChanged: (v) {
              r.useGpu = v;
              state.touch();
            },
          ),
      ],
    );
  }
}

class ConvertSettingsView extends StatelessWidget {
  const ConvertSettingsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.convert;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Formato de saída'),
        SegmentedButton<ConvFormat>(
          showSelectedIcon: false,
          segments: [
            for (final f in ConvFormat.values) ButtonSegment(value: f, label: Text(f.label)),
          ],
          selected: {s.format},
          onSelectionChanged: (v) {
            s.format = v.first;
            state.touch();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(s.format.hint, style: _muted(context)),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Recodificar sempre'),
          subtitle: const Text('Desligado, só recodifica o que o formato não aceitar.'),
          value: s.forceReencode,
          onChanged: (v) {
            s.forceReencode = v;
            state.touch();
          },
        ),
        const SizedBox(height: 8),
        const InfoBox(
          'Quando o vídeo e o áudio já são aceitos pelo formato escolhido, o FiLume só troca a '
          '"embalagem": leva segundos, não perde qualidade e quase não usa CPU, mesmo em arquivos enormes. '
          'A lista mostra o que vai acontecer com cada arquivo.',
        ),
        ReencodeSection(state: state),
      ],
    );
  }
}

class TrimSettingsView extends StatelessWidget {
  const TrimSettingsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.trim;
    final info = state.video.preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (playerAvailable && info != null) ...[
          const SizedBox(height: 14),
          PreviewPlayer(
            key: const ValueKey('trim-player'),
            info: info,
            footer: (context, position) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        s.start = position();
                        if (s.end != null && s.end! <= s.start) s.end = null;
                        state.fieldRevision++;
                        state.touch();
                      },
                      icon: const Icon(Icons.first_page, size: 18),
                      label: const Text('Início aqui'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        final p = position();
                        if (p <= s.start) return;
                        s.end = p;
                        state.fieldRevision++;
                        state.touch();
                      },
                      icon: const Icon(Icons.last_page, size: 18),
                      label: const Text('Fim aqui'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SectionLabel('Trecho a manter'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ParsedField<double>(
                key: ValueKey('trim-start-${state.fieldRevision}'),
                label: 'Início',
                initialText: fmtDurationPrecise(s.start),
                parse: parseDuration,
                onChanged: (v) {
                  s.start = v ?? 0;
                  state.touch();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ParsedField<double>(
                key: ValueKey('trim-end-${state.fieldRevision}'),
                label: 'Fim',
                initialText: s.end == null ? '' : fmtDurationPrecise(s.end!),
                parse: parseDuration,
                allowEmpty: true,
                onChanged: (v) {
                  s.end = v;
                  state.touch();
                },
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              'Segundos, mm:ss ou h:mm:ss. Fim vazio = até o final do vídeo.'
              '${state.video.ready.length > 1 ? ' O mesmo trecho vale para todos os vídeos da lista.' : ''}',
              style: _muted(context)),
        ),
        const SectionLabel('Precisão'),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.bolt, size: 18), label: Text('Rápido')),
            ButtonSegment(value: true, icon: Icon(Icons.straighten, size: 18), label: Text('Exato')),
          ],
          selected: {s.precise},
          onSelectionChanged: (v) {
            s.precise = v.first;
            state.touch();
          },
        ),
        const SizedBox(height: 12),
        InfoBox(
          s.precise
              ? 'Exato: corta no quadro pedido, mas recodifica o trecho (mais lento, depende do tamanho do corte).'
              : 'Rápido: não recodifica, então é instantâneo e sem perda. O começo cai no keyframe '
                  'anterior, então o corte pode começar alguns segundos antes do pedido.',
          icon: s.precise ? Icons.straighten : Icons.bolt,
        ),
        if (s.precise) ReencodeSection(state: state),
      ],
    );
  }
}

class MergeSettingsView extends StatelessWidget {
  const MergeSettingsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.merge;
    final ready = state.video.ready;
    final compatible = mergeCompatible(ready);
    final recode = s.forceReencode || !compatible;
    final String status;
    if (ready.length < 2) {
      status = 'Adicione pelo menos 2 vídeos. Eles são unidos na ordem da lista; use as setas para reordenar.';
    } else if (!recode) {
      status = 'Os ${ready.length} vídeos têm o mesmo formato: serão unidos sem recodificar, '
          'em segundos e sem perda. A ordem é a da lista (use as setas).';
    } else {
      status = 'Os vídeos serão recodificados no formato do primeiro da lista '
          '(${ready.first.width}×${ready.first.height}); os demais ganham barras se a proporção for diferente. '
          'A ordem é a da lista (use as setas).';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Unir em um só arquivo'),
        InfoBox(status, icon: recode && ready.length >= 2 ? Icons.movie_filter_outlined : Icons.bolt),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Recodificar sempre'),
          subtitle: const Text('Ligue se o resultado sem recodificar travar ou perder sincronia.'),
          value: s.forceReencode,
          onChanged: (v) {
            s.forceReencode = v;
            state.touch();
          },
        ),
        if (recode) ReencodeSection(state: state),
      ],
    );
  }
}

class CropSettingsView extends StatelessWidget {
  const CropSettingsView({super.key, required this.state});
  final AppState state;

  Widget _margin(String label, int value, void Function(int) set) => Expanded(
        child: ParsedField<int>(
          label: label,
          suffix: 'px',
          initialText: '$value',
          parse: (text) {
            final v = int.tryParse(text.trim());
            return v == null || v < 0 ? null : v;
          },
          onChanged: (v) {
            set(v ?? 0);
            state.touch();
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = state.crop;
    final t = Theme.of(context);
    final info = state.video.preview;
    final rect = info == null ? null : s.rectFor(info);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Recortar a imagem'),
        SegmentedButton<CropMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: CropMode.aspect, label: Text('Proporção')),
            ButtonSegment(value: CropMode.manual, label: Text('Margens')),
            ButtonSegment(value: CropMode.auto, label: Text('Barras pretas')),
          ],
          selected: {s.mode},
          onSelectionChanged: (v) {
            s.mode = v.first;
            state.touch();
          },
        ),
        const SizedBox(height: 14),
        if (s.mode == CropMode.aspect) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in CropAspect.values)
                ChoiceChip(
                  label: Text(a.label),
                  selected: s.aspect == a,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) {
                    s.aspect = a;
                    state.touch();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Posição', style: t.textTheme.bodySmall),
              Expanded(
                child: Slider(
                  value: s.anchor,
                  divisions: 20,
                  onChanged: (v) {
                    s.anchor = v;
                    state.touch();
                  },
                ),
              ),
              TextButton(
                onPressed: s.anchor == 0.5
                    ? null
                    : () {
                        s.anchor = 0.5;
                        state.touch();
                      },
                child: const Text('Centro'),
              ),
            ],
          ),
        ],
        if (s.mode == CropMode.manual) ...[
          Text('Quanto tirar de cada lado:', style: _muted(context)),
          const SizedBox(height: 10),
          Row(
            children: [
              _margin('Esquerda', s.left, (v) => s.left = v),
              const SizedBox(width: 10),
              _margin('Direita', s.right, (v) => s.right = v),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _margin('Cima', s.top, (v) => s.top = v),
              const SizedBox(width: 10),
              _margin('Baixo', s.bottom, (v) => s.bottom = v),
            ],
          ),
        ],
        if (s.mode == CropMode.auto)
          const InfoBox(
            'Detecta e remove as barras pretas (letterbox) de cada vídeo, analisando alguns trechos curtos.',
            icon: Icons.auto_fix_high,
          ),
        if (s.mode != CropMode.auto) ...[
          const SizedBox(height: 14),
          if (info == null)
            Text('Adicione um vídeo para ver a prévia.', style: _muted(context))
          else ...[
            if (playerAvailable)
              PreviewPlayer(
                key: const ValueKey('crop-player'),
                info: info,
                overlay: rect == null
                    ? null
                    : CustomPaint(
                        painter: _CropPainter(
                          Rect.fromLTWH(rect.x / info.width, rect.y / info.height,
                              rect.w / info.width, rect.h / info.height),
                          t.colorScheme.primary,
                        ),
                      ),
              )
            else
              _CropPreview(state: state, info: info, rect: rect),
            const SizedBox(height: 6),
            Text(
              rect == null
                  ? 'Sem recorte: ${info.width}×${info.height}'
                  : '${info.width}×${info.height} → ${rect.w}×${rect.h}'
                      '${state.video.ready.length > 1 ? ' · clique num vídeo da lista para trocar a prévia' : ''}',
              textAlign: TextAlign.center,
              style: _muted(context),
            ),
          ],
        ],
        ReencodeSection(state: state),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Recortar sempre recodifica o vídeo; o áudio é mantido como está.',
              style: _muted(context)),
        ),
      ],
    );
  }
}

class _CropPreview extends StatelessWidget {
  const _CropPreview({required this.state, required this.info, required this.rect});
  final AppState state;
  final MediaInfo info;
  final CropRect? rect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = rect;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 210),
        child: AspectRatio(
          aspectRatio: info.width / info.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: cs.surfaceContainerHighest),
                FutureBuilder<String?>(
                  future: state.thumbnail(info),
                  builder: (context, snap) {
                    final path = snap.data;
                    if (path == null) return const SizedBox.shrink();
                    return Image.file(
                      File(path),
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    );
                  },
                ),
                if (r != null)
                  CustomPaint(
                    painter: _CropPainter(
                      Rect.fromLTWH(r.x / info.width, r.y / info.height, r.w / info.width,
                          r.h / info.height),
                      cs.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect, this.color);

  /// Recorte em fração (0–1) da imagem.
  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final keep = Rect.fromLTWH(rect.left * size.width, rect.top * size.height,
        rect.width * size.width, rect.height * size.height);
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.62);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, keep.top), shade);
    canvas.drawRect(Rect.fromLTRB(0, keep.bottom, size.width, size.height), shade);
    canvas.drawRect(Rect.fromLTRB(0, keep.top, keep.left, keep.bottom), shade);
    canvas.drawRect(Rect.fromLTRB(keep.right, keep.top, size.width, keep.bottom), shade);
    canvas.drawRect(
      keep.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect || old.color != color;
}

const _audioExts = ['mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'ac3', 'wma', 'mka'];
const _subExts = ['srt', 'ass', 'ssa', 'vtt'];

class MuxSettingsView extends StatelessWidget {
  const MuxSettingsView({super.key, required this.state});
  final AppState state;

  Future<void> _pickAudio() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Áudio', extensions: _audioExts),
      XTypeGroup(label: 'Todos os arquivos'),
    ]);
    if (f != null) await state.setMuxAudio(f.path);
  }

  Future<void> _pickSubtitle() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Legendas', extensions: _subExts),
    ]);
    if (f != null) {
      state.mux.subtitlePath = f.path;
      state.touch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = state.mux;
    final cs = Theme.of(context).colorScheme;
    final audio = s.audio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Áudio'),
        Choice<MuxAudioMode>(
          label: 'O que fazer com o áudio',
          value: s.audioMode,
          options: {for (final m in MuxAudioMode.values) m: m.label},
          onChanged: (m) {
            s.audioMode = m;
            state.touch();
          },
        ),
        if (s.audioMode.needsFile) ...[
          const SizedBox(height: 10),
          _FileRow(
            icon: Icons.audiotrack,
            text: audio == null
                ? 'Nenhum áudio escolhido'
                : '${p.basename(audio.path)}  ·  ${fmtDuration(audio.duration)}',
            onPick: _pickAudio,
            onClear: audio == null ? null : () => state.setMuxAudio(null),
          ),
          if (state.muxAudioError != null)
            Text(state.muxAudioError!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.error)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Cortar no fim do áudio'),
            subtitle: const Text('Se o áudio for mais curto que o vídeo, o resultado termina junto com ele.'),
            value: s.shortest,
            onChanged: (v) {
              s.shortest = v;
              state.touch();
            },
          ),
        ],
        const SectionLabel('Legenda'),
        _FileRow(
          icon: Icons.subtitles_outlined,
          text: s.subtitlePath == null ? 'Nenhuma legenda para adicionar' : p.basename(s.subtitlePath!),
          onPick: _pickSubtitle,
          onClear: s.subtitlePath == null
              ? null
              : () {
                  s.subtitlePath = null;
                  state.touch();
                },
        ),
        const SizedBox(height: 14),
        const InfoBox(
          'O vídeo não é recodificado: as faixas são só montadas no mesmo arquivo, então é rápido '
          'e sem perda. A legenda entra como faixa que dá para ligar e desligar no player. '
          'O mesmo áudio/legenda é aplicado a todos os vídeos da lista.',
          icon: Icons.layers_outlined,
        ),
      ],
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.icon, required this.text, required this.onPick, this.onClear});
  final IconData icon;
  final String text;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium),
        ),
        if (onClear != null)
          IconButton(
            tooltip: 'Remover',
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
            icon: const Icon(Icons.close, size: 18),
          ),
        TextButton(onPressed: onPick, child: const Text('Escolher')),
      ],
    );
  }
}
