import 'package:flutter/material.dart';

import '../core/compress.dart';
import '../core/format.dart';
import '../core/split.dart';
import '../core/state.dart';
import 'common.dart';

String _mbLabel(double mb) => mb >= 1024 ? '${fmtNum(mb / 1024)} GB' : '${fmtNum(mb)} MB';

String fmtNum(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString().replaceAll('.', ',');

class CompressSettingsView extends StatelessWidget {
  const CompressSettingsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.compress;
    final caps = state.caps;
    final t = Theme.of(context);
    final gpu = caps.gpuFor(s.codec);
    final hasCpu = caps.cpuFor(s.codec) != null;
    final codecs = {
      for (final c in VCodec.values)
        if (caps.supports(c) || caps.usable.isEmpty) c: '${c.label} — ${c.hint}',
    };
    final usingGpu = s.useGpu && gpu != null || !hasCpu && gpu != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Como reduzir'),
        SegmentedButton<CompressMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: CompressMode.quality, label: Text('Qualidade')),
            ButtonSegment(value: CompressMode.targetSize, label: Text('Tamanho')),
            ButtonSegment(value: CompressMode.percent, label: Text('Porcentagem')),
          ],
          selected: {s.mode},
          onSelectionChanged: (v) {
            s.mode = v.first;
            state.touch();
          },
        ),
        const SizedBox(height: 14),
        if (s.mode == CompressMode.quality) ...[
          Row(
            children: [
              Text('Mais qualidade', style: t.textTheme.bodySmall),
              const Spacer(),
              Text('Nível ${s.crf}', style: t.textTheme.labelLarge),
              const Spacer(),
              Text('Menor arquivo', style: t.textTheme.bodySmall),
            ],
          ),
          Slider(
            value: s.crf.toDouble(),
            min: 14,
            max: 40,
            divisions: 26,
            label: '${s.crf}',
            onChanged: (v) {
              s.crf = v.round();
              state.touch();
            },
          ),
          Text(
            'Padrão do ${s.codec.label}: ${s.codec.defaultCrf}. O tamanho final depende do conteúdo do vídeo.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
        if (s.mode == CompressMode.targetSize) ...[
          PresetField(
            label: 'Tamanho final de cada vídeo',
            suffix: 'MB',
            value: s.targetMb,
            parse: parseNumber,
            format: fmtNum,
            presets: const [10, 25, 50, 100, 500, 2048],
            presetLabel: _mbLabel,
            onChanged: (v) {
              s.targetMb = v;
              state.touch();
            },
          ),
        ],
        if (s.mode == CompressMode.percent) ...[
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
        if (s.mode != CompressMode.quality && !usingGpu && s.codec != VCodec.av1)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Duas passadas'),
            subtitle: const Text('Acerta melhor o tamanho; leva quase o dobro do tempo.'),
            value: s.twoPass,
            onChanged: (v) {
              s.twoPass = v;
              state.touch();
            },
          ),
        const SectionLabel('Codificação'),
        Choice<VCodec>(
          key: ValueKey('codec-${codecs.length}-${s.codec}'),
          label: 'Codec',
          value: s.codec,
          options: codecs,
          onChanged: (c) {
            s
              ..codec = c
              ..crf = c.defaultCrf;
            if (caps.gpuFor(c) == null) s.useGpu = false;
            state.touch();
          },
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: false,
              enabled: hasCpu || gpu == null,
              icon: const Icon(Icons.memory, size: 18),
              label: const Text('CPU'),
            ),
            ButtonSegment(
              value: true,
              enabled: gpu != null,
              icon: const Icon(Icons.bolt, size: 18),
              label: Text(gpu == null ? 'GPU indisponível' : 'GPU ${EncoderCaps.gpuLabel(gpu)}'),
            ),
          ],
          selected: {usingGpu},
          onSelectionChanged: (v) {
            s.useGpu = v.first;
            state.touch();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            usingGpu
                ? 'GPU: muito mais rápido e leve na CPU; arquivo um pouco maior para a mesma qualidade.'
                : 'CPU: melhor qualidade por MB; mais lento em vídeos longos.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<Speed>(
          showSelectedIcon: false,
          segments: [
            for (final sp in Speed.values) ButtonSegment(value: sp, label: Text(sp.label)),
          ],
          selected: {s.speed},
          onSelectionChanged: (v) {
            s.speed = v.first;
            state.touch();
          },
        ),
        const SectionLabel('Imagem e áudio'),
        Row(
          children: [
            Expanded(
              child: Choice<int>(
                label: 'Resolução máx.',
                value: s.maxHeight,
                options: const {
                  0: 'Manter',
                  2160: '2160p (4K)',
                  1440: '1440p',
                  1080: '1080p',
                  720: '720p',
                  480: '480p',
                },
                onChanged: (v) {
                  s.maxHeight = v;
                  state.touch();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Choice<int>(
                label: 'FPS máx.',
                value: s.maxFps,
                options: const {0: 'Manter', 60: '60', 30: '30', 24: '24'},
                onChanged: (v) {
                  s.maxFps = v;
                  state.touch();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: Choice<AudioMode>(
                label: 'Áudio',
                value: s.audio,
                options: {for (final a in AudioMode.values) a: a.label},
                onChanged: (v) {
                  s.audio = v;
                  state.touch();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: Choice<OutContainer>(
                label: 'Formato',
                value: s.container,
                options: {for (final c in OutContainer.values) c: c.label},
                onChanged: (v) {
                  s.container = v;
                  state.touch();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Modo econômico'),
          subtitle: const Text(
              'Usa metade da CPU e menos memória. Bom para vídeos enormes ou para continuar usando o PC.'),
          value: s.eco,
          onChanged: (v) {
            s.eco = v;
            state.touch();
          },
        ),
      ],
    );
  }
}

class SplitSettingsView extends StatelessWidget {
  const SplitSettingsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.split;
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Dividir por'),
        SegmentedButton<SplitMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: SplitMode.size, label: Text('Tamanho')),
            ButtonSegment(value: SplitMode.duration, label: Text('Duração')),
            ButtonSegment(value: SplitMode.parts, label: Text('Nº de partes')),
          ],
          selected: {s.mode},
          onSelectionChanged: (v) {
            s.mode = v.first;
            state.touch();
          },
        ),
        const SizedBox(height: 16),
        if (s.mode == SplitMode.size)
          PresetField(
            key: const ValueKey('split-size'),
            label: 'Tamanho máximo de cada parte',
            suffix: 'MB',
            value: s.sizeMb,
            parse: parseNumber,
            format: fmtNum,
            presets: const [10, 25, 50, 100, 500, 1024, 2048, 4096],
            presetLabel: _mbLabel,
            onChanged: (v) {
              s.sizeMb = v;
              state.touch();
            },
          ),
        if (s.mode == SplitMode.duration)
          PresetField(
            key: const ValueKey('split-duration'),
            label: 'Duração de cada parte',
            hint: 'Segundos, mm:ss ou h:mm:ss',
            value: s.seconds,
            parse: parseDuration,
            format: fmtDuration,
            presets: const [30, 60, 300, 600, 1800, 3600],
            presetLabel: fmtDuration,
            onChanged: (v) {
              s.seconds = v;
              state.touch();
            },
          ),
        if (s.mode == SplitMode.parts)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                onPressed: s.parts > 2
                    ? () {
                        s.parts--;
                        state.touch();
                      }
                    : null,
                icon: const Icon(Icons.remove),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text('${s.parts} partes', style: t.textTheme.titleLarge),
              ),
              IconButton.filledTonal(
                onPressed: s.parts < 500
                    ? () {
                        s.parts++;
                        state.touch();
                      }
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        const SizedBox(height: 18),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: t.colorScheme.secondaryContainer.withValues(alpha: 0.45),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.bolt, size: 18, color: t.colorScheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Divide sem recodificar: rápido, sem perda de qualidade e quase sem usar CPU ou '
                    'memória, mesmo em vídeos de muitos GB. Os cortes caem no keyframe mais próximo, '
                    'então a duração de cada parte pode variar alguns segundos.'
                    '${s.mode == SplitMode.size ? ' Por tamanho, o vídeo é analisado antes para nenhuma parte passar do limite.' : ''}',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'As partes vão para uma pasta "<nome do vídeo>_partes".',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
