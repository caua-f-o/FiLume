import 'dart:io';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/pdf.dart';
import '../core/state.dart';
import 'common.dart';
import 'settings_panels.dart' show fmtNum;

TextStyle? _muted(BuildContext context) {
  final t = Theme.of(context);
  return t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
}

class PdfCompressView extends StatelessWidget {
  const PdfCompressView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.pdfCompress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Nível de compressão'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final l in PdfLevel.values)
              ChoiceChip(
                label: Text(l.label),
                selected: s.level == l,
                showCheckmark: false,
                onSelected: (_) {
                  s.level = l;
                  state.touch();
                },
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('${s.level.hint} Imagens reduzidas para ${s.level.dpi} dpi.', style: _muted(context)),
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Converter para tons de cinza'),
          subtitle: const Text('Reduz mais em documentos coloridos que não precisam de cor.'),
          value: s.grayscale,
          onChanged: (v) {
            s.grayscale = v;
            state.touch();
          },
        ),
        const SizedBox(height: 8),
        const InfoBox(
          'O ganho vem quase todo das imagens: PDFs escaneados ou com fotos encolhem muito; '
          'PDFs só de texto já são pequenos e mudam pouco. O texto continua selecionável.',
          icon: Icons.compress,
        ),
      ],
    );
  }
}

class PdfSplitView extends StatelessWidget {
  const PdfSplitView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.pdfSplit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Dividir'),
        Choice<PdfSplitMode>(
          label: 'Como dividir',
          value: s.mode,
          options: const {
            PdfSplitMode.everyN: 'A cada N páginas',
            PdfSplitMode.size: 'Por tamanho máximo (MB)',
            PdfSplitMode.ranges: 'Por intervalos de páginas',
            PdfSplitMode.single: 'Uma página por arquivo',
          },
          onChanged: (m) {
            s.mode = m;
            state.touch();
          },
        ),
        const SizedBox(height: 14),
        if (s.mode == PdfSplitMode.everyN)
          PresetField(
            key: const ValueKey('pdf-every'),
            label: 'Páginas por parte',
            value: s.every.toDouble(),
            parse: (t) {
              final v = int.tryParse(t.trim());
              return v == null || v < 1 ? null : v.toDouble();
            },
            format: (v) => v.round().toString(),
            presets: const [2, 5, 10, 20, 50, 100],
            presetLabel: (v) => v.round().toString(),
            onChanged: (v) {
              s.every = v.round();
              state.touch();
            },
          ),
        if (s.mode == PdfSplitMode.size)
          PresetField(
            key: const ValueKey('pdf-size'),
            label: 'Tamanho máximo de cada parte',
            suffix: 'MB',
            value: s.sizeMb,
            parse: parseNumber,
            format: fmtNum,
            presets: const [1, 2, 5, 10, 20, 25],
            presetLabel: (mb) => '${fmtNum(mb)} MB',
            onChanged: (v) {
              s.sizeMb = v;
              state.touch();
            },
          ),
        if (s.mode == PdfSplitMode.ranges)
          ParsedField<String>(
            key: const ValueKey('pdf-ranges'),
            label: 'Intervalos',
            hint: 'Ex.: 1-3, 5, 8-12  (cada intervalo vira um PDF; "8-" vai até o fim)',
            initialText: s.ranges,
            allowEmpty: true,
            parse: (t) => RegExp(r'^[\d\s,;-]+$').hasMatch(t) ? t : null,
            onChanged: (v) {
              s.ranges = v ?? '';
              state.touch();
            },
          ),
        const SizedBox(height: 14),
        InfoBox(
          s.mode == PdfSplitMode.size
              ? 'As páginas são medidas antes e agrupadas para nenhuma parte passar do limite '
                  '(útil para anexos de e-mail e portais com teto de upload).'
              : 'Dividir não recomprime nada: as páginas saem idênticas às do original.',
        ),
        const SizedBox(height: 8),
        Text('As partes vão para uma pasta "<nome do arquivo>_partes".', style: _muted(context)),
      ],
    );
  }
}

class PdfMergeView extends StatelessWidget {
  const PdfMergeView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel('Unir em um só PDF'),
        InfoBox(
          'Os PDFs são unidos inteiros, na ordem da lista (use as setas para reordenar). '
          'Para escolher, girar ou tirar páginas, use a ferramenta Organizar.',
          icon: Icons.merge,
        ),
      ],
    );
  }
}

class PdfToImagesView extends StatelessWidget {
  const PdfToImagesView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.pdfConvert;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Cada página vira uma imagem'),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('JPG')),
            ButtonSegment(value: true, label: Text('PNG')),
          ],
          selected: {s.png},
          onSelectionChanged: (v) {
            s.png = v.first;
            state.touch();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(s.png ? 'PNG: sem perda, arquivos maiores.' : 'JPG: leve, ideal para fotos e scans.',
              style: _muted(context)),
        ),
        const SizedBox(height: 12),
        Choice<int>(
          label: 'Resolução',
          value: s.dpi,
          options: const {
            72: '72 dpi — tela, bem leve',
            150: '150 dpi — leitura confortável',
            300: '300 dpi — impressão',
          },
          onChanged: (v) {
            s.dpi = v;
            state.touch();
          },
        ),
        const SizedBox(height: 8),
        Text('As imagens vão para uma pasta "<nome do arquivo>_imagens".', style: _muted(context)),
      ],
    );
  }
}

class ImagesToPdfView extends StatelessWidget {
  const ImagesToPdfView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state.pdfConvert;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Imagens viram um PDF'),
        Choice<PageFit>(
          label: 'Tamanho da página',
          value: s.fit,
          options: {for (final f in PageFit.values) f: f.label},
          onChanged: (v) {
            s.fit = v;
            state.touch();
          },
        ),
        const SizedBox(height: 12),
        const InfoBox(
          'Cada imagem vira uma página, na ordem da lista (use as setas). Em A4, a página fica em pé '
          'ou deitada conforme a imagem. Fundo transparente vira branco.',
          icon: Icons.image_outlined,
        ),
      ],
    );
  }
}

class PdfPasswordView extends StatefulWidget {
  const PdfPasswordView({super.key, required this.state});
  final AppState state;

  @override
  State<PdfPasswordView> createState() => _PdfPasswordViewState();
}

class _PdfPasswordViewState extends State<PdfPasswordView> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.state.pdfPassword.password);
  bool _show = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final s = state.pdfPassword;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Senha do PDF'),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: true, icon: Icon(Icons.lock_outline, size: 18), label: Text('Proteger')),
            ButtonSegment(value: false, icon: Icon(Icons.lock_open, size: 18), label: Text('Remover')),
          ],
          selected: {s.protect},
          onSelectionChanged: (v) {
            s.protect = v.first;
            state.touch();
          },
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _ctrl,
          obscureText: !_show,
          onChanged: (v) {
            s.password = v;
            state.touch();
          },
          decoration: InputDecoration(
            labelText: s.protect ? 'Nova senha' : 'Senha atual',
            suffixIcon: IconButton(
              tooltip: _show ? 'Esconder' : 'Mostrar',
              onPressed: () => setState(() => _show = !_show),
              icon: Icon(_show ? Icons.visibility_off : Icons.visibility, size: 20),
            ),
          ),
        ),
        const SizedBox(height: 14),
        InfoBox(
          s.protect
              ? 'O PDF passa a pedir essa senha para abrir (criptografia AES de 256 bits). '
                  'Guarde a senha: sem ela não dá para recuperar o arquivo.'
              : 'Gera uma cópia sem senha. É preciso saber a senha atual — isso não quebra senhas.',
          icon: s.protect ? Icons.lock_outline : Icons.lock_open,
        ),
      ],
    );
  }
}

/// Ações do organizador (painel da direita).
class PdfOrganizeView extends StatelessWidget {
  const PdfOrganizeView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final o = state.organizer;
    final t = Theme.of(context);
    final n = o.selected.length;
    final scope = n == 0 ? 'todas' : '$n selecionada${n == 1 ? '' : 's'}';
    void act(VoidCallback f) {
      f();
      state.touch();
    }

    Widget btn(IconData icon, String label, VoidCallback? onTap) => FilledButton.tonalIcon(
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label),
        );
    final docs = state.docs.ready.where((d) => d.isPdf && !d.encrypted).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Páginas'),
        Text('${o.pages.length} páginas na mesa  ·  ações valem para: $scope', style: t.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            btn(Icons.rotate_left, 'Girar', o.pages.isEmpty ? null : () => act(() => o.rotate(o.targets, 270))),
            btn(Icons.rotate_right, 'Girar', o.pages.isEmpty ? null : () => act(() => o.rotate(o.targets, 90))),
            btn(Icons.delete_outline, 'Excluir selecionadas',
                n == 0 ? null : () => act(() => o.remove(o.selected.toList()))),
            btn(Icons.filter_alt_outlined, 'Manter só as selecionadas', n == 0 ? null : () => act(o.keepSelected)),
          ],
        ),
        const SectionLabel('Seleção e ordem'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            btn(Icons.select_all, 'Selecionar tudo',
                o.pages.isEmpty ? null : () => act(() => o.selected.addAll(o.pages))),
            btn(Icons.deselect, 'Limpar seleção', n == 0 ? null : () => act(o.selected.clear)),
            btn(Icons.swap_vert, 'Inverter ordem', o.pages.length < 2 ? null : () => act(o.reverse)),
            btn(Icons.restore, 'Restaurar original', docs.isEmpty ? null : () => act(() => o.reset(docs))),
          ],
        ),
        const SizedBox(height: 14),
        const InfoBox(
          'Arraste uma página para mudar de lugar; clique para selecionar. '
          'Adicione mais PDFs para misturar páginas de vários arquivos. '
          'Nada é recomprimido: as páginas saem idênticas às originais.',
          icon: Icons.touch_app_outlined,
        ),
      ],
    );
  }
}

/// Mesa de páginas do organizador (ocupa o lugar da lista de arquivos).
class OrganizerWorkspace extends StatelessWidget {
  const OrganizerWorkspace({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final docs = state.docs.ready.where((d) => d.isPdf && !d.encrypted).toList();
    final o = state.organizer..sync(docs);
    for (final d in docs) {
      state.thumbs.ensure(d, state.pdf);
    }
    if (o.pages.isEmpty) {
      return Center(child: Text('Adicione PDFs para ver as páginas aqui.', style: _muted(context)));
    }
    final multi = docs.length > 1;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(0, 4, 6, 4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 148,
        childAspectRatio: 0.66,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: o.pages.length,
      itemBuilder: (context, i) {
        final ref = o.pages[i];
        return _PageTile(
          key: ObjectKey(ref),
          state: state,
          index: i,
          ref: ref,
          docLetter: multi ? String.fromCharCode(65 + docs.indexOf(ref.doc) % 26) : null,
        );
      },
    );
  }
}

class _PageTile extends StatelessWidget {
  const _PageTile({super.key, required this.state, required this.index, required this.ref, this.docLetter});
  final AppState state;
  final int index;
  final PageRef ref;
  final String? docLetter;

  Widget _thumb(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final file = state.thumbs.fileFor(ref.doc.path, ref.page);
    final Widget page = file == null
        ? ColoredBox(
            color: cs.surfaceContainerHighest,
            child: Center(
              child: Text('${ref.page}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.onSurfaceVariant)),
            ),
          )
        : Image.file(
            File(file),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            cacheWidth: 220,
            errorBuilder: (_, _, _) => ColoredBox(color: cs.surfaceContainerHighest),
          );
    return RotatedBox(quarterTurns: ref.rotation ~/ 90, child: page);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final o = state.organizer;
    final selected = o.selected.contains(ref);
    void act(VoidCallback f) {
      f();
      state.touch();
    }

    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != index,
      onAcceptWithDetails: (d) => act(() => o.move(d.data, index)),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        return Draggable<int>(
          data: index,
          feedback: Opacity(
            opacity: 0.85,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(width: 96, height: 130, child: _thumb(context)),
            ),
          ),
          childWhenDragging: const Opacity(opacity: 0.25, child: ColoredBox(color: Colors.grey)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: selected ? cs.primary.withValues(alpha: 0.16) : cs.surfaceContainerHigh.withValues(alpha: 0.6),
              border: Border.all(
                width: 2,
                color: hovering ? cs.tertiary : (selected ? cs.primary : Colors.transparent),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => act(() => o.toggle(ref)),
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
                        child: _thumb(context),
                      ),
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${index + 1}${docLetter == null ? '' : '  ·  $docLetter${ref.page}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.labelMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Girar',
                          visualDensity: VisualDensity.compact,
                          iconSize: 17,
                          onPressed: () => act(() => o.rotate([ref], 90)),
                          icon: const Icon(Icons.rotate_right),
                        ),
                        IconButton(
                          tooltip: 'Excluir página',
                          visualDensity: VisualDensity.compact,
                          iconSize: 17,
                          onPressed: () => act(() => o.remove([ref])),
                          icon: const Icon(Icons.close),
                        ),
                      ],
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
