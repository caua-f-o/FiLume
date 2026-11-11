import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/image.dart';
import '../core/state.dart';
import 'common.dart';
import 'settings_panels.dart' show fmtNum;

TextStyle? _muted(BuildContext context) {
  final t = Theme.of(context);
  return t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
}

Map<ImgFormat, String> _formats(AppState state, {bool lossyOnly = false}) => {
      for (final f in ImgFormat.values)
        if (f.available(state.encoders) && (!lossyOnly || f.lossy)) f: f.label,
    };

Widget _quality(BuildContext context, AppState state, int value, ValueChanged<int> onChanged) {
  final t = Theme.of(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Center(child: Text('Qualidade $value', style: t.textTheme.labelLarge)),
      Slider(
        value: value.toDouble(),
        min: 10,
        max: 100,
        divisions: 18,
        label: '$value',
        onChanged: (v) => onChanged(v.round()),
      ),
      Text('Menor = arquivo menor. De 75 a 90 quase não se nota diferença.', style: _muted(context)),
    ],
  );
}

class ImageConvertView extends StatelessWidget {
  const ImageConvertView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.imageConvert;
    final formats = _formats(state);
    final format = formats.containsKey(s.format) ? s.format : formats.keys.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Converter para'),
        Choice<ImgFormat>(
          key: ValueKey('icfmt-${formats.length}'),
          label: 'Formato',
          value: format,
          options: formats,
          onChanged: (f) {
            s.format = f;
            state.touch();
          },
        ),
        const SizedBox(height: 14),
        if (format.lossy)
          _quality(context, state, s.quality, (q) {
            s.quality = q;
            state.touch();
          })
        else
          Text('${format.label} guarda a imagem sem perda de qualidade.', style: _muted(context)),
        const SizedBox(height: 10),
        InfoBox(
          format.alpha
              ? 'Este formato mantém a transparência.'
              : 'Este formato não guarda transparência: áreas transparentes ficam brancas.',
          icon: Icons.layers_outlined,
        ),
      ],
    );
  }
}

class ImageCompressView extends StatelessWidget {
  const ImageCompressView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.imageCompress;
    final t = Theme.of(context);
    final formats = <ImgFormat?, String>{null: 'Manter o formato', ..._formats(state, lossyOnly: true)};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Como reduzir'),
        SegmentedButton<ImageCompressMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ImageCompressMode.quality, label: Text('Qualidade')),
            ButtonSegment(value: ImageCompressMode.targetSize, label: Text('Tamanho')),
            ButtonSegment(value: ImageCompressMode.percent, label: Text('Porcentagem')),
          ],
          selected: {s.mode},
          onSelectionChanged: (v) {
            s.mode = v.first;
            state.touch();
          },
        ),
        const SizedBox(height: 14),
        if (s.mode == ImageCompressMode.quality)
          _quality(context, state, s.quality, (q) {
            s.quality = q;
            state.touch();
          }),
        if (s.mode == ImageCompressMode.targetSize)
          PresetField(
            label: 'Tamanho máximo de cada imagem',
            suffix: 'KB',
            value: s.targetKb,
            parse: parseNumber,
            format: fmtNum,
            presets: const [100, 200, 500, 1024, 2048, 5120],
            presetLabel: (kb) => kb >= 1024 ? '${fmtNum(kb / 1024)} MB' : '${fmtNum(kb)} KB',
            onChanged: (v) {
              s.targetKb = v;
              state.touch();
            },
          ),
        if (s.mode == ImageCompressMode.percent) ...[
          Center(child: Text('${s.percent.round()}% do tamanho original', style: t.textTheme.labelLarge)),
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
        Choice<ImgFormat?>(
          key: ValueKey('ipfmt-${formats.length}'),
          label: 'Formato de saída',
          value: formats.containsKey(s.format) ? s.format : null,
          options: formats,
          onChanged: (f) {
            s.format = f;
            state.touch();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'WebP e AVIF ficam bem menores que JPG na mesma qualidade. '
            'PNG mantido é reduzido para 256 cores; para mirar num tamanho, escolha JPG, WebP ou AVIF.',
            style: _muted(context),
          ),
        ),
        const SizedBox(height: 10),
        const InfoBox(
          'As dimensões não mudam aqui. O FiLume nunca entrega um arquivo maior que o original.',
          icon: Icons.verified_outlined,
        ),
      ],
    );
  }
}

class ImageResizeView extends StatelessWidget {
  const ImageResizeView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.imageResize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Definir por'),
        Choice<ResizeMode>(
          label: 'Medida',
          value: s.mode,
          options: const {
            ResizeMode.longSide: 'Lado maior (px)',
            ResizeMode.width: 'Largura (px)',
            ResizeMode.height: 'Altura (px)',
            ResizeMode.percent: 'Porcentagem',
          },
          onChanged: (m) {
            s.mode = m;
            state.touch();
          },
        ),
        const SizedBox(height: 14),
        if (s.mode == ResizeMode.percent)
          PresetField(
            key: const ValueKey('rz-pct'),
            label: 'Tamanho em relação ao original',
            suffix: '%',
            value: s.percent,
            parse: parseNumber,
            format: fmtNum,
            presets: const [25, 50, 75, 150, 200],
            presetLabel: (v) => '${fmtNum(v)}%',
            onChanged: (v) {
              s.percent = v;
              state.touch();
            },
          )
        else
          PresetField(
            key: const ValueKey('rz-px'),
            label: 'Tamanho',
            suffix: 'px',
            value: s.pixels,
            parse: parseNumber,
            format: fmtNum,
            presets: const [720, 1080, 1280, 1920, 2560, 3840],
            presetLabel: (v) => fmtNum(v),
            onChanged: (v) {
              s.pixels = v;
              state.touch();
            },
          ),
        const SizedBox(height: 10),
        const InfoBox(
          'A proporção é sempre mantida e o formato continua o mesmo. '
          'Para aumentar com qualidade, use "Ampliar".',
          icon: Icons.aspect_ratio,
        ),
      ],
    );
  }
}

class ImageRotateView extends StatelessWidget {
  const ImageRotateView({super.key, required this.state});
  final AppState state;

  static const _icons = {
    RotateOp.right: Icons.rotate_right,
    RotateOp.left: Icons.rotate_left,
    RotateOp.half: Icons.sync,
    RotateOp.flipH: Icons.flip,
    RotateOp.flipV: Icons.swap_vert,
  };

  @override
  Widget build(BuildContext context) {
    final s = state.imageRotate;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('O que fazer'),
        for (final op in RotateOp.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: s.op == op ? cs.secondaryContainer : cs.surfaceContainerHighest,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: s.op == op ? cs.primary : cs.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                dense: true,
                selected: s.op == op,
                leading: Icon(_icons[op], color: s.op == op ? cs.onSecondaryContainer : cs.onSurfaceVariant),
                title: Text(
                  op.label,
                  style: TextStyle(
                    color: s.op == op ? cs.onSecondaryContainer : cs.onSurface,
                    fontWeight: s.op == op ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                onTap: () {
                  s.op = op;
                  state.touch();
                },
              ),
            ),
          ),
        Text('O formato continua o mesmo; fotos em JPG são regravadas em qualidade alta.', style: _muted(context)),
      ],
    );
  }
}

class UpscaleView extends StatelessWidget {
  const UpscaleView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.upscale;
    final formats = {
      for (final f in const [ImgFormat.png, ImgFormat.jpg, ImgFormat.webp])
        if (f.available(state.encoders)) f: f.label,
    };
    final ai = s.engine == UpscaleEngine.ai;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Método'),
        SegmentedButton<UpscaleEngine>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: UpscaleEngine.ai, label: Text('IA')),
            ButtonSegment(value: UpscaleEngine.classic, label: Text('Clássico')),
            ButtonSegment(value: UpscaleEngine.pixel, label: Text('Pixel art')),
          ],
          selected: {s.engine},
          onSelectionChanged: (v) {
            s.engine = v.first;
            state.touch();
          },
        ),
        const SizedBox(height: 8),
        Text(
          switch (s.engine) {
            UpscaleEngine.ai => 'Recria detalhes de verdade (Real-ESRGAN). Usa a placa de vídeo; '
                'leva de segundos a alguns minutos por imagem.',
            UpscaleEngine.classic => 'Só estica e dá nitidez: rápido e funciona em qualquer computador, '
                'mas não inventa detalhe novo.',
            UpscaleEngine.pixel => 'Para sprites e pixel art: aumenta mantendo as bordas duras (xBR).',
          },
          style: _muted(context),
        ),
        if (ai && state.upscaler == null) ...[
          const SizedBox(height: 10),
          const InfoBox(
            'O ampliador por IA não foi encontrado (pasta "upscaler" ao lado do FiLume.exe). '
            'Use o modo Clássico por enquanto.',
            icon: Icons.warning_amber_rounded,
          ),
        ],
        if (ai) ...[
          const SectionLabel('Tipo de imagem'),
          Choice<UpscaleModel>(
            label: 'Modelo',
            value: s.model,
            options: {for (final m in UpscaleModel.values) m: m.label},
            onChanged: (m) {
              s.model = m;
              state.touch();
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              switch (s.model) {
                UpscaleModel.photo => 'O mais forte para fotos, texturas e prints.',
                UpscaleModel.anime => 'Traço limpo e cores chapadas: desenho, mangá, anime.',
                UpscaleModel.animeFast => 'Bem mais rápido e leve; ótimo para lotes de ilustrações.',
              },
              style: _muted(context),
            ),
          ),
        ],
        const SectionLabel('Quanto ampliar'),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 2, label: Text('2×')),
            ButtonSegment(value: 3, label: Text('3×')),
            ButtonSegment(value: 4, label: Text('4×')),
          ],
          selected: {s.factor},
          onSelectionChanged: (v) {
            s.factor = v.first;
            state.touch();
          },
        ),
        const SectionLabel('Salvar como'),
        Choice<ImgFormat>(
          key: ValueKey('upfmt-${formats.length}'),
          label: 'Formato',
          value: formats.containsKey(s.format) ? s.format : ImgFormat.png,
          options: formats,
          onChanged: (f) {
            s.format = f;
            state.touch();
          },
        ),
        const SizedBox(height: 10),
        InfoBox(
          ai
              ? 'A IA precisa de placa de vídeo com Vulkan (praticamente todas de 2016 para cá, '
                  'inclusive as integradas). Sem ela, o FiLume avisa e você pode usar o Clássico.'
              : 'Dica: para fotos e ilustrações, o modo IA dá um resultado bem superior.',
          icon: ai ? Icons.memory : Icons.auto_awesome,
        ),
      ],
    );
  }
}
