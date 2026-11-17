import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';
import '../core/pdf_inspect.dart';
import '../core/pdfium.dart';
import '../core/state.dart';
import '../ui/common.dart';
import 'doc_view.dart' show pickPdf;

class CheckSession extends ChangeNotifier {
  CheckSession(this.state);
  final AppState state;
  PdfInspection? result;
  String? error;
  bool busy = false;

  Future<void> run(String file) async {
    final tools = state.pdf;
    if (tools == null || busy) return;
    busy = true;
    error = null;
    result = null;
    notifyListeners();
    try {
      result = await inspectPdf(tools, file, pdfium: Pdfium.load());
    } on FfError catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Não foi possível verificar o arquivo: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

class CheckView extends StatelessWidget {
  const CheckView({super.key, required this.state, required this.session});
  final AppState state;
  final CheckSession session;

  Future<void> _open([String? file]) async {
    final path = file ?? await pickPdf();
    if (path != null) await session.run(path);
  }

  Future<void> _saveReport(BuildContext context, PdfInspection r) async {
    final loc = await getSaveLocation(
      suggestedName: '${p.basenameWithoutExtension(r.file)}_verificacao.txt',
      acceptedTypeGroups: [const XTypeGroup(label: 'Texto', extensions: ['txt'])],
    );
    if (loc == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await File(loc.path).writeAsString(inspectionAsText(r));
      messenger.showSnackBar(const SnackBar(content: Text('Relatório salvo.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não foi possível salvar o relatório: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final t = Theme.of(context);
        final cs = t.colorScheme;
        final r = session.result;
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
          child: DropTarget(
            onDragDone: (d) {
              final pdfs = [for (final f in d.files) if (f.path.toLowerCase().endsWith('.pdf')) f.path];
              if (pdfs.isNotEmpty) _open(pdfs.first);
            },
            child: Panel(
              padding: const EdgeInsets.fromLTRB(22, 18, 14, 14),
              child: r == null ? _empty(context, t, cs) : _report(context, t, cs, r),
            ),
          ),
        );
      },
    );
  }

  Widget _empty(BuildContext context, ThemeData t, ColorScheme cs) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_outlined, size: 64, color: cs.primary),
            const SizedBox(height: 14),
            Text('Verificar', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                session.busy
                    ? 'Examinando o arquivo…'
                    : 'Confere se um PDF está pronto para leitores de tela (acessibilidade) e para ser guardado por muitos anos (PDF/A), '
                        'e diz como resolver o que faltar. Solte um PDF aqui ou escolha um arquivo.',
                textAlign: TextAlign.center,
                style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: session.busy || state.pdf == null ? null : _open,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('Abrir PDF…'),
            ),
            if (session.error != null) ...[
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(session.error!, textAlign: TextAlign.center, style: TextStyle(color: cs.error)),
              ),
            ],
          ],
        ),
      );

  Widget _report(BuildContext context, ThemeData t, ColorScheme cs, PdfInspection r) {
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    (IconData, Color) look(CheckLevel l) => switch (l) {
          CheckLevel.ok => (Icons.check_circle, Colors.green.shade600),
          CheckLevel.warn => (Icons.error_outline, Colors.orange.shade700),
          CheckLevel.fail => (Icons.cancel, cs.error),
          CheckLevel.info => (Icons.info_outline, cs.onSurfaceVariant),
        };
    return ListView(
      padding: const EdgeInsets.only(right: 10),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(r.file), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  Text('${r.pages} ${r.pages == 1 ? 'página' : 'páginas'} · PDF ${r.pdfVersion}${r.declaredPdfA == null ? '' : ' · ${r.declaredPdfA}'}', style: small),
                ],
              ),
            ),
            TextButton.icon(onPressed: _open, icon: const Icon(Icons.folder_open_outlined, size: 18), label: const Text('Verificar outro')),
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: inspectionAsText(r)));
                messenger.showSnackBar(const SnackBar(content: Text('Relatório copiado.')));
              },
              child: const Text('Copiar'),
            ),
            FilledButton.tonal(onPressed: () => _saveReport(context, r), child: const Text('Salvar relatório')),
          ],
        ),
        for (final g in CheckGroup.values) ...[
          SectionLabel(() {
            final fail = r.count(g, CheckLevel.fail), warn = r.count(g, CheckLevel.warn);
            return '${g.label} · ${fail == 0 && warn == 0 ? 'tudo certo' : [if (fail > 0) '$fail a resolver', if (warn > 0) '$warn de atenção'].join(', ')}';
          }()),
          for (final c in r.checks.where((c) => c.group == g))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 1), child: Icon(look(c.level).$1, size: 20, color: look(c.level).$2)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                        Text(c.detail, style: t.textTheme.bodyMedium),
                        if (c.tip != null) Text('Como resolver: ${c.tip}', style: small),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 6),
        Text('Esta é uma verificação dos pontos principais, não uma certificação de conformidade.', style: small),
      ],
    );
  }
}
