import 'package:flutter/material.dart';

import '../core/audio.dart';
import '../core/compress.dart';
import '../core/convert.dart';
import '../core/crop.dart';
import '../core/ffmpeg.dart';
import '../core/format.dart';
import '../core/merge.dart';
import '../core/mux.dart';
import '../core/pdf.dart';
import '../core/split.dart';
import '../core/state.dart' show imageExts;
import '../core/trim.dart';
import 'audio_panels.dart';
import 'pdf_panels.dart';
import 'settings_panels.dart';
import 'tool_page.dart';
import 'tool_panels.dart';

String? _splitHint(SplitSettings s, int n) {
  if (n <= 1) return 'não precisa dividir';
  return '${s.mode == SplitMode.parts ? '' : '≈ '}$n partes';
}

final videoModule = ModuleDef(
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

final docsModule = ModuleDef(
  title: 'Documentos',
  one: 'arquivo',
  many: 'arquivos',
  typeLabel: 'PDFs e imagens',
  docs: true,
  extensions: const ['pdf', ...imageExts],
  inputs: (s) => s.docs,
  missing: (s) {
    if (s.pdf == null) {
      return 'Ferramentas de PDF não encontradas. A pasta "pdftools" deveria estar ao lado do FiLume.exe.';
    }
    if (s.pdf!.gs == null) {
      return 'Ghostscript não encontrado: comprimir, miniaturas e PDF → imagens ficam indisponíveis.';
    }
    return null;
  },
  tools: [
    ToolDef(
      label: 'Comprimir',
      icon: Icons.compress,
      needs: 'PDFs',
      accepts: _pdf,
      panel: (s) => PdfCompressView(state: s),
      jobs: (s, ready) =>
          [for (final i in ready) buildPdfCompressJob(i, s.pdfCompress, s.outputDir, s.pdf!)],
    ),
    ToolDef(
      label: 'Dividir',
      icon: Icons.call_split,
      needs: 'PDFs',
      accepts: _pdf,
      panel: (s) => PdfSplitView(state: s),
      jobs: (s, ready) => [for (final i in ready) buildPdfSplitJob(i, s.pdfSplit, s.outputDir, s.pdf!)],
      hint: (s, info) {
        final n = s.pdfSplit.estimateParts(info);
        if (n == null) return 'intervalos inválidos';
        if (n <= 1) return 'não precisa dividir';
        return '${s.pdfSplit.mode == PdfSplitMode.size ? '≈ ' : ''}$n partes';
      },
    ),
    ToolDef(
      label: 'Unir',
      icon: Icons.merge,
      needs: 'PDFs',
      accepts: _pdf,
      ordered: true,
      panel: (s) => PdfMergeView(state: s),
      jobs: (s, ready) => [buildPdfMergeJob(ready, s.outputDir, s.pdf!)],
      blocked: (s, ready) => ready.length < 2 ? 'Adicione pelo menos 2 PDFs' : null,
      actionLabel: (s, ready) => 'Unir ${ready.length} PDFs',
    ),
    ToolDef(
      label: 'Organizar',
      icon: Icons.dashboard_customize_outlined,
      needs: 'PDFs',
      accepts: _pdf,
      panel: (s) => PdfOrganizeView(state: s),
      workspace: (s) => OrganizerWorkspace(state: s),
      jobs: (s, ready) => [buildPdfOrganizeJob(s.organizer.pages, s.outputDir, s.pdf!)],
      blocked: (s, ready) {
        s.organizer.sync(ready);
        return s.organizer.pages.isEmpty ? 'Nenhuma página na mesa' : null;
      },
      actionLabel: (s, ready) => 'Salvar PDF com ${s.organizer.pages.length} páginas',
    ),
    ToolDef(
      label: 'PDF → Imagens',
      icon: Icons.image_outlined,
      needs: 'PDFs',
      accepts: _pdf,
      panel: (s) => PdfToImagesView(state: s),
      jobs: (s, ready) =>
          [for (final i in ready) buildPdfToImagesJob(i, s.pdfConvert, s.outputDir, s.pdf!)],
      hint: (s, info) => '→ ${info.pages} ${info.pages == 1 ? 'imagem' : 'imagens'}',
    ),
    ToolDef(
      label: 'Imagens → PDF',
      icon: Icons.picture_as_pdf_outlined,
      needs: 'imagens',
      accepts: (i) => i.isImage,
      ordered: true,
      panel: (s) => ImagesToPdfView(state: s),
      jobs: (s, ready) => [buildImagesToPdfJob(ready, s.pdfConvert, s.outputDir)],
      actionLabel: (s, ready) =>
          'Criar PDF com ${ready.length} ${ready.length == 1 ? 'imagem' : 'imagens'}',
    ),
    ToolDef(
      label: 'Senha',
      icon: Icons.lock_outline,
      needs: 'PDFs',
      accepts: (i) => i.isPdf,
      panel: (s) => PdfPasswordView(state: s),
      jobs: (s, ready) =>
          [for (final i in ready) buildPdfPasswordJob(i, s.pdfPassword, s.outputDir, s.pdf!)],
      blocked: (s, ready) => s.pdfPassword.password.isEmpty ? 'Digite a senha' : null,
      hint: (s, info) => info.encrypted ? 'tem senha' : null,
    ),
  ],
);
