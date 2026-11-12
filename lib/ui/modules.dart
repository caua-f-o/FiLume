import 'package:flutter/material.dart';

import '../core/audio.dart';
import '../core/compress.dart';
import '../core/convert.dart';
import '../core/crop.dart';
import '../core/ffmpeg.dart';
import '../core/format.dart';
import '../core/merge.dart';
import '../core/mux.dart';
import '../core/split.dart';
import '../core/state.dart' show imageExts;
import '../core/trim.dart';
import 'audio_panels.dart';
import 'settings_panels.dart';
import 'tool_page.dart';
import 'tool_panels.dart';
import '../core/image.dart';
import 'image_panels.dart';

String? _splitHint(SplitSettings s, int n) {
  if (n <= 1) return 'não precisa dividir';
  return '${s.mode == SplitMode.parts ? '' : '≈ '}$n partes';
}

final videoModule = ModuleDef(
  id: 'video',
  title: 'Vídeo',
  one: 'vídeo',
  many: 'vídeos',
  typeLabel: 'Vídeos',
  extensions: const [
    'mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v', 'ts', 'm2ts', 'mts', 'flv', 'wmv', 'mpg', 'mpeg', '3gp',
  ],
  inputs: (s) => s.video,
  tools: [
    ToolDef(
      label: 'Comprimir',
      icon: Icons.compress,
      panel: (s) => CompressSettingsView(state: s),
      jobs: (s, ready) =>
          [for (final i in ready) buildCompressJob(i, s.compress, s.outputDir, s.caps)],
      hint: (s, info) {
        final target = targetBytesFor(s.compress, info);
        if (target == null) return null;
        if (target >= info.sizeBytes) return 'já é menor que o alvo';
        return '→ ~${fmtBytes(target)}';
      },
    ),
    ToolDef(
      label: 'Dividir',
      icon: Icons.call_split,
      panel: (s) => SplitSettingsView(state: s),
      jobs: (s, ready) => [for (final i in ready) buildSplitJob(i, s.split, s.outputDir)],
      hint: (s, info) => _splitHint(s.split, s.split.estimateParts(info)),
    ),
    ToolDef(
      label: 'Converter',
      icon: Icons.swap_horiz,
      panel: (s) => ConvertSettingsView(state: s),
      jobs: (s, ready) => [
        for (final i in ready) buildConvertJob(i, s.convert, s.reencode, s.outputDir, s.caps),
      ],
      hint: (s, info) {
        final plan = convertPlan(info, s.convert);
        if (plan.copyVideo && plan.copyAudio) return 'sem recodificar';
        return plan.copyVideo ? 'recodifica o áudio' : 'recodifica';
      },
    ),
    ToolDef(
      label: 'Cortar',
      icon: Icons.content_cut,
      usesPreview: true,
      panel: (s) => TrimSettingsView(state: s),
      jobs: (s, ready) => [
        for (final i in ready) buildTrimJob(i, s.trim, s.reencode, s.outputDir, s.caps),
      ],
      hint: (s, info) {
        final range = s.trim.rangeFor(info);
        return range == null ? 'trecho inválido' : '→ ${fmtDuration(range.$2 - range.$1)}';
      },
    ),
    ToolDef(
      label: 'Unir',
      icon: Icons.merge,
      ordered: true,
      panel: (s) => MergeSettingsView(state: s),
      jobs: (s, ready) => [buildMergeJob(ready, s.merge, s.reencode, s.outputDir, s.caps)],
      blocked: (s, ready) => ready.length < 2 ? 'Adicione pelo menos 2 vídeos' : null,
    ),
    ToolDef(
      label: 'Recortar',
      icon: Icons.crop,
      usesPreview: true,
      panel: (s) => CropSettingsView(state: s),
      jobs: (s, ready) => [
        for (final i in ready) buildCropJob(i, s.crop, s.reencode, s.outputDir, s.caps),
      ],
      hint: (s, info) {
        if (s.crop.mode == CropMode.auto) return null;
        final r = s.crop.rectFor(info);
        return r == null ? 'sem mudança' : '→ ${r.w}×${r.h}';
      },
    ),
    ToolDef(
      label: 'Mux',
      icon: Icons.layers_outlined,
      panel: (s) => MuxSettingsView(state: s),
      jobs: (s, ready) => [for (final i in ready) buildMuxJob(i, s.mux, s.outputDir, s.caps)],
      blocked: (s, ready) => s.mux.changesSomething ? null : 'Escolha um áudio ou uma legenda',
    ),
  ],
);

final audioModule = ModuleDef(
  id: 'audio',
  title: 'Áudio',
  one: 'áudio',
  many: 'áudios',
  typeLabel: 'Áudios e vídeos',
  audio: true,
  extensions: const [
    'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'wma', 'ac3', 'mka', 'aiff',
    'mp4', 'mkv', 'mov', 'webm', 'avi',
  ],
  inputs: (s) => s.audio,
  tools: [
    ToolDef(
      label: 'Converter',
      icon: Icons.swap_horiz,
      panel: (s) => AudioConvertView(state: s),
      jobs: (s, ready) => [for (final i in ready) buildAudioConvertJob(i, s.audioOut, s.outputDir)],
      hint: (s, info) => '→ ${s.audioOut.format.ext.toUpperCase()}',
    ),
    ToolDef(
      label: 'Comprimir',
      icon: Icons.compress,
      panel: (s) => AudioCompressView(state: s),
      jobs: (s, ready) =>
          [for (final i in ready) buildAudioCompressJob(i, s.audioCompress, s.outputDir)],
      hint: (s, info) {
        final est = s.audioCompress.estimateBytes(info);
        return est == null ? null : '→ ~${fmtBytes(est)}';
      },
    ),
    ToolDef(
      label: 'Mixar',
      icon: Icons.tune,
      panel: (s) => AudioMixView(state: s),
      jobs: (s, ready) => [buildAudioMixJob(ready, s.mix, s.audioOut, s.outputDir)],
      blocked: (s, ready) => ready.length < 2 ? 'Adicione pelo menos 2 áudios' : null,
    ),
    ToolDef(
      label: 'Dividir',
      icon: Icons.call_split,
      panel: (s) => SplitSettingsView(state: s, audio: true),
      jobs: (s, ready) => [
        for (final i in ready) buildSplitJob(i, s.audioSplit, s.outputDir, audioOnly: true),
      ],
      hint: (s, info) {
        final bytes = audioBytes(info);
        if (bytes <= 0 && s.audioSplit.mode == SplitMode.size) return null;
        return _splitHint(s.audioSplit, s.audioSplit.estimateParts(info, sizeBytes: bytes));
      },
    ),
    ToolDef(
      label: 'Unir',
      icon: Icons.merge,
      ordered: true,
      panel: (s) => AudioMergeView(state: s),
      jobs: (s, ready) => [buildAudioMergeJob(ready, s.audioMerge, s.audioOut, s.outputDir)],
      blocked: (s, ready) => ready.length < 2 ? 'Adicione pelo menos 2 áudios' : null,
    ),
  ],
);

bool _pdf(MediaInfo i) => i.isPdf && !i.encrypted;

/// O que entra na bandeja do organizador: PDFs abertos e imagens.
bool mesaAccepts(MediaInfo i) => i.isImage || _pdf(i);

// --------------------------------------------------------------------- imagem

final imageModule = ModuleDef(
  id: 'image',
  title: 'Imagem',
  one: 'imagem',
  many: 'imagens',
  typeLabel: 'Imagens',
  docs: true, // mesma linha de informações das imagens do PDF Estúdio
  extensions: const [...imageExts, 'avif'],
  inputs: (s) => s.images,
  tools: [
    ToolDef(
      label: 'Ampliar',
      icon: Icons.auto_awesome,
      panel: (s) => UpscaleView(state: s),
      jobs: (s, ready) => [
        for (final i in ready) buildUpscaleJob(i, s.upscale, s.outputDir, s.encoders, s.upscaler),
      ],
      hint: (s, info) {
        final (w, h) = s.upscale.outSize(info);
        return '→ $w×$h';
      },
    ),
    ToolDef(
      label: 'Converter',
      icon: Icons.swap_horiz,
      panel: (s) => ImageConvertView(state: s),
      jobs: (s, ready) => [
        for (final i in ready) buildImageConvertJob(i, s.imageConvert, s.outputDir, s.encoders),
      ],
      hint: (s, info) => '→ ${s.imageConvert.format.label}',
    ),
    ToolDef(
      label: 'Comprimir',
      icon: Icons.compress,
      panel: (s) => ImageCompressView(state: s),
      jobs: (s, ready) => [
        for (final i in ready) buildImageCompressJob(i, s.imageCompress, s.outputDir, s.encoders),
      ],
      hint: (s, info) {
        final target = s.imageCompress.targetBytes(info);
        final format = s.imageCompress.outFormat(info, s.encoders);
        if (target == null) return '→ ${format.label}';
        if (!format.lossy) return 'escolha JPG, WebP ou AVIF';
        if (target >= info.sizeBytes) return 'já é menor que o alvo';
        return '→ até ${fmtBytes(target)}';
      },
    ),
    ToolDef(
      label: 'Redimensionar',
      icon: Icons.aspect_ratio,
      panel: (s) => ImageResizeView(state: s),
      jobs: (s, ready) => [
        for (final i in ready) buildImageResizeJob(i, s.imageResize, s.outputDir, s.encoders),
      ],
      hint: (s, info) {
        final (w, h) = s.imageResize.outSize(info);
        return '→ $w×$h';
      },
    ),
    ToolDef(
      label: 'Girar',
      icon: Icons.rotate_right,
      panel: (s) => ImageRotateView(state: s),
      jobs: (s, ready) => [
        for (final i in ready) buildImageRotateJob(i, s.imageRotate.op, s.outputDir, s.encoders),
      ],
      hint: (s, info) => s.imageRotate.op.label,
    ),
  ],
);
