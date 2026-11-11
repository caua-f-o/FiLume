import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/state.dart';
import 'home_page.dart' show routeFiles;
import 'home_widgets.dart';
import 'modules.dart';
import 'tool_page.dart';

class _PdfTool {
  const _PdfTool(this.index, this.name, this.desc, this.icon, this.motif, this.radius);
  final int index;
  final String name, desc, motif;
  final IconData icon;
  final BorderRadius radius;
}

const _r14 = BorderRadius.all(Radius.circular(14));
const _round = BorderRadius.all(Radius.circular(22));

/// Índices iguais aos de [docsModule.tools].
const _tools = [
  _PdfTool(0, 'Comprimir', 'Quatro níveis de compressão. Nunca entrega um arquivo maior que o original.',
      Icons.compress, 'compress', _round),
  _PdfTool(1, 'Dividir', 'A cada N páginas, por tamanho em MB, por intervalos ou página a página.',
      Icons.call_split, 'split', _r14),
  _PdfTool(2, 'Unir', 'Junta vários PDFs na ordem que você escolher.', Icons.merge, 'merge',
      BorderRadius.only(
        topLeft: Radius.circular(22),
        topRight: Radius.circular(22),
        bottomRight: Radius.circular(22),
        bottomLeft: Radius.circular(8),
      )),
  _PdfTool(4, 'PDF → Imagens', 'Exporta as páginas como PNG ou JPG.', Icons.image_outlined, 'image', _r14),
  _PdfTool(5, 'Imagens → PDF', 'Monta um PDF a partir de fotos, prints e digitalizações.',
      Icons.picture_as_pdf_outlined, 'pages', _round),
  _PdfTool(6, 'Senha', 'Protege um PDF com senha ou remove a senha de um que você já pode abrir.',
      Icons.lock_outline, 'lock',
      BorderRadius.only(
        topLeft: Radius.circular(22),
        topRight: Radius.circular(8),
        bottomRight: Radius.circular(22),
        bottomLeft: Radius.circular(22),
      )),
];

/// Área dedicada ao PDF: tela de entrada com as ferramentas e, ao escolher
/// uma (ou soltar arquivos), a ferramenta aberta.
class PdfStudio extends StatelessWidget {
  const PdfStudio({super.key, required this.state, required this.onNavigate});
  final AppState state;
  final void Function(String page) onNavigate;

  void _open(int tool) {
    state.toolIndex[docsModule.title] = tool;
    state.pdfOpen = true;
    state.touch();
  }

  Future<void> _pick() async {
    final files = await openFiles(acceptedTypeGroups: [
      XTypeGroup(label: docsModule.typeLabel, extensions: docsModule.extensions),
    ]);
    if (files.isNotEmpty) routeFiles(state, [for (final f in files) f.path], pdfStudio: true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (state.pdfOpen) {
          return ToolPage(
            state: state,
            module: docsModule,
            onBack: () {
              state.pdfOpen = false;
              state.touch();
            },
          );
        }
        return _landing(context);
      },
    );
  }

  Widget _landing(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 8, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Transform.rotate(
                angle: -0.105,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(18)),
                  child: Icon(Icons.picture_as_pdf_outlined, size: 28, color: cs.onPrimaryContainer),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PDF Estúdio',
                      style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
                    ),
                    Text(
                      'Tudo que você precisa para seus PDFs.',
                      style: t.textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 360,
            child: DropZone(
              text: 'Solte PDFs ou imagens. O FiLume seleciona a ferramenta certa com base no arquivo escolhido.',
              onFiles: (paths) => routeFiles(state, paths, pdfStudio: true),
              onPick: _pick,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 420,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 10,
                  child: GeoCard(
                    motif: 'organize',
                    motifSize: 190,
                    motifAlign: Alignment.topRight,
                    motifOffset: const Offset(14, -10),
                    radius: 28,
                    padding: const EdgeInsets.all(28),
                    onTap: () => _open(3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('MAIS USADO',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
                        const SizedBox(height: 6),
                        const Text('Bandeja de páginas', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 340),
                          child: const Text(
                            'Uma bandeja com as miniaturas: arraste para reordenar, gire, endireite e apague. '
                            'Mistura PDFs, imagens e páginas digitalizadas.',
                            style: TextStyle(fontSize: 14, height: 1.45),
                          ),
                        ),
                        const Spacer(),
                        const FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.bottomLeft, child: _PagesStrip()),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 19,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var row = 0; row < 2; row++) ...[
                        if (row > 0) const SizedBox(height: 12),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var col = 0; col < 3; col++) ...[
                                if (col > 0) const SizedBox(width: 12),
                                Expanded(child: _toolCard(context, _tools[row * 3 + col])),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GeoCard(
            motif: 'convert',
            motifSize: 84,
            motifOffset: const Offset(-76, 0),
            radius: 24,
            tonal: false,
            dashed: true,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            onTap: () => onNavigate('files'),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: _tools[5].radius),
                  child: Icon(Icons.swap_horiz, size: 20, color: cs.onPrimaryContainer),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('Converter documentos',
                              style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, fontSize: 15)),
                          const SizedBox(width: 8),
                          const Pill('em breve'),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Word, Excel e PowerPoint para PDF, e PDF para texto. Abre o conversor de arquivos.',
                        style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward, color: cs.primary),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolCard(BuildContext context, _PdfTool tool) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return GeoCard(
      motif: tool.motif,
      motifSize: 96,
      motifAlign: Alignment.bottomRight,
      motifOffset: const Offset(10, 10),
      radius: 24,
      tonal: false,
      padding: const EdgeInsets.all(20),
      onTap: () => _open(tool.index),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: tool.radius),
            child: Icon(tool.icon, size: 22, color: cs.onPrimaryContainer),
          ),
          const SizedBox(height: 12),
          Text(tool.name, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              tool.desc,
              overflow: TextOverflow.fade,
              style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Miniaturas de páginas (uma sendo arrastada) no cartão "Organizar".
class _PagesStrip extends StatelessWidget {
  const _PagesStrip();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget line(double widthFactor, {double h = 4, Color? color}) => FractionallySizedBox(
          widthFactor: widthFactor,
          alignment: Alignment.centerLeft,
          child: Container(
            height: h,
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(color: color ?? cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(3)),
          ),
        );
    Widget page(List<Widget> lines, {bool lifted = false}) => Container(
          width: 64,
          height: 86,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            border: lifted ? Border.all(color: cs.primary, width: 3) : null,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: lifted ? 0.35 : 0.18),
                blurRadius: lifted ? 28 : 6,
                offset: Offset(0, lifted ? 14 : 2),
              ),
            ],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
        );
    return ExcludeSemantics(
      child: SizedBox(
        height: 110,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            page([line(0.7, h: 6, color: cs.outlineVariant), line(1), line(1), line(0.6)]),
            const SizedBox(width: 12),
            page([line(1, h: 30), line(1), line(0.7)]),
            const SizedBox(width: 12),
            Transform.translate(
              offset: const Offset(0, -16),
              child: Transform.rotate(
                angle: -0.14,
                child: page([line(0.5, h: 6, color: cs.primary), line(1), line(1), line(1), line(0.4)], lifted: true),
              ),
            ),
            const SizedBox(width: 12),
            CustomPaint(
              foregroundPainter:
                  DashedBorderPainter(color: cs.onPrimaryContainer.withValues(alpha: 0.45), radius: 8),
              child: const SizedBox(width: 64, height: 86),
            ),
          ],
        ),
      ),
    );
  }
}
