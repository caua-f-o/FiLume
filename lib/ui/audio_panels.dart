import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/audio.dart';
import '../core/format.dart';
import '../core/state.dart';
import 'common.dart';
import 'settings_panels.dart' show fmtNum;

TextStyle? _muted(BuildContext context) {
  final t = Theme.of(context);
  return t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
}

Widget _bitrateChips(int value, ValueChanged<int> onChanged, {List<int> options = audioBitrates}) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final k in options)
          ChoiceChip(
            label: Text('$k'),
            selected: value == k,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => onChanged(k),
          ),
      ],
    );

/// Formato, bitrate e mono — compartilhado por converter, unir e mixar.
class AudioOutSection extends StatelessWidget {
  const AudioOutSection({super.key, required this.state, this.title = 'Formato de saída'});
  final AppState state;
  final String title;

  @override
  Widget build(BuildContext context) {
    final o = state.audioOut;
    final formats = {
      for (final f in AudioFormat.values)
        if (f.available(state.caps)) f: f.lossy ? f.label : '${f.label} — sem perda',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(title),
        Choice<AudioFormat>(
          key: ValueKey('afmt-${formats.length}'),
          label: 'Formato',
          value: formats.containsKey(o.format) ? o.format : formats.keys.first,
          options: formats,
          onChanged: (f) {
            o.format = f;
            state.touch();
          },
        ),
        if (o.format.lossy) ...[
          const SizedBox(height: 12),
          Text('Bitrate (kb/s) — quanto maior, melhor e mais pesado', style: _muted(context)),
          const SizedBox(height: 6),
          _bitrateChips(o.kbps, (k) {
            o.kbps = k;
            state.touch();
          }),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Converter para mono'),
          subtitle: const Text('Bom para voz; em música perde o estéreo.'),
          value: o.mono,
          onChanged: (v) {
            o.mono = v;
            state.touch();
          },
        ),
      ],
    );
  }
}

class AudioConvertView extends StatelessWidget {
  const AudioConvertView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AudioOutSection(state: state),
        const SizedBox(height: 8),
        const InfoBox(
          'Também funciona com vídeos: solte um MP4 ou MKV aqui para extrair só o áudio dele.',
          icon: Icons.movie_outlined,
        ),
      ],
    );
  }
}

class AudioCompressView extends StatelessWidget {
  const AudioCompressView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.audioCompress;
    final t = Theme.of(context);
    final formats = {
      for (final f in AudioFormat.values)
        if (f.lossy && f != AudioFormat.ogg && f.available(state.caps)) f: f.label,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Como reduzir'),
        SegmentedButton<AudioCompressMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: AudioCompressMode.bitrate, label: Text('Bitrate')),
            ButtonSegment(value: AudioCompressMode.targetSize, label: Text('Tamanho')),
            ButtonSegment(value: AudioCompressMode.percent, label: Text('Porcentagem')),
          ],
          selected: {s.mode},
          onSelectionChanged: (v) {
            s.mode = v.first;
            state.touch();
          },
        ),
        const SizedBox(height: 14),
        if (s.mode == AudioCompressMode.bitrate) ...[
          Text('Bitrate (kb/s) — menor = arquivo menor', style: _muted(context)),
          const SizedBox(height: 6),
          _bitrateChips(s.kbps, (k) {
            s.kbps = k;
            state.touch();
          }, options: const [32, 48, 64, 96, 128, 160]),
          const SizedBox(height: 6),
          Text('Voz fica boa a partir de 48; música, de 96 a 128.', style: _muted(context)),
        ],
        if (s.mode == AudioCompressMode.targetSize)
          PresetField(
            label: 'Tamanho final de cada áudio',
            suffix: 'MB',
            value: s.targetMb,
            parse: parseNumber,
            format: fmtNum,
            presets: const [1, 5, 10, 16, 25, 50, 100],
            presetLabel: (mb) => '${fmtNum(mb)} MB',
            onChanged: (v) {
              s.targetMb = v;
              state.touch();
            },
          ),
        if (s.mode == AudioCompressMode.percent) ...[
          Center(
            child: Text('${s.percent.round()}% do tamanho original', style: t.textTheme.labelLarge),
          ),
          Slider(
            value: s.percent,
            min: 10,
            max: 90,
            divisions: 16,
            label: '${s.percent.round()}%',
            onChanged: (v) {
              s.percent = v;
              state.touch();
            },
          ),
        ],
        const SectionLabel('Formato'),
        Choice<AudioFormat>(
          key: ValueKey('acfmt-${formats.length}'),
          label: 'Formato',
          value: formats.containsKey(s.format) ? s.format : formats.keys.first,
          options: formats,
          onChanged: (f) {
            s.format = f;
            state.touch();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Opus é o que soa melhor em bitrates baixos; MP3 toca em qualquer lugar.',
              style: _muted(context)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Converter para mono'),
          subtitle: const Text('Em gravações de voz, melhora a qualidade no mesmo tamanho.'),
          value: s.mono,
          onChanged: (v) {
            s.mono = v;
            state.touch();
          },
        ),
      ],
    );
  }
}

class AudioMergeView extends StatelessWidget {
  const AudioMergeView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.audioMerge;
    final ready = state.audio.ready;
    final recode = s.forceReencode || !audioMergeCompatible(ready);
    final String status;
    if (ready.length < 2) {
      status = 'Adicione pelo menos 2 áudios. Eles são unidos na ordem da lista; use as setas para reordenar.';
    } else if (!recode) {
      status = 'Os ${ready.length} áudios têm o mesmo formato: serão unidos sem recodificar, '
          'em segundos e sem perda. A ordem é a da lista (use as setas).';
    } else {
      status = 'Os áudios têm formatos diferentes, então o resultado é recodificado no formato abaixo. '
          'A ordem é a da lista (use as setas).';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Unir em um só arquivo'),
        InfoBox(status, icon: recode && ready.length >= 2 ? Icons.graphic_eq : Icons.bolt),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Recodificar sempre'),
          subtitle: const Text('Ligue para escolher o formato do resultado.'),
          value: s.forceReencode,
          onChanged: (v) {
            s.forceReencode = v;
            state.touch();
          },
        ),
        if (recode) AudioOutSection(state: state),
      ],
    );
  }
}

class AudioMixView extends StatelessWidget {
  const AudioMixView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.mix;
    final t = Theme.of(context);
    final ready = state.audio.ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Tocar tudo ao mesmo tempo'),
        const InfoBox(
          'Sobrepõe os áudios da lista num só (voz + trilha, por exemplo). '
          'Ajuste o volume de cada um abaixo; um limitador evita que a soma estoure.',
          icon: Icons.tune,
        ),
        const SectionLabel('Volumes'),
        if (ready.isEmpty) Text('Adicione pelo menos 2 áudios.', style: _muted(context)),
        for (final info in ready)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(p.basename(info.path),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium),
                  ),
                  Text('${(s.gainOf(info.path) * 100).round()}%', style: t.textTheme.labelMedium),
                ],
              ),
              Slider(
                value: s.gainOf(info.path),
                max: 2,
                divisions: 40,
                onChanged: (v) {
                  s.gains[info.path] = v;
                  state.touch();
                },
              ),
            ],
          ),
        const SizedBox(height: 4),
        Choice<MixLength>(
          label: 'Duração do resultado',
          value: s.length,
          options: {for (final l in MixLength.values) l: l.label},
          onChanged: (l) {
            s.length = l;
            state.touch();
          },
        ),
        AudioOutSection(state: state),
      ],
    );
  }
}
