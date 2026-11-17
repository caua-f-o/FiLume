import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/pdf_clean.dart';
import '../core/state.dart';
import '../ui/common.dart';
import '../ui/process_button.dart';
import 'doc_view.dart' show pickPdf;
import 'pdf_app.dart' show JobStatusCard;
import 'save_dialog.dart';

class CleanSession extends ChangeNotifier {
  final List<String> files = [];
  bool metadata = true, scripts = true, attachments = true, comments = false, bookmarks = false, extras = true;

  CleanOptions get options =>
      CleanOptions(metadata: metadata, scripts: scripts, attachments: attachments, comments: comments, bookmarks: bookmarks, extras: extras);

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  void add(Iterable<String> paths) {
    for (final f in paths) {
      if (f.toLowerCase().endsWith('.pdf') && !files.contains(f)) files.add(f);
    }
    notifyListeners();
  }
}

class CleanView extends StatelessWidget {
  const CleanView({super.key, required this.state, required this.session});
  final AppState state;
  final CleanSession session;

  Future<void> _run(BuildContext context) async {
    final tools = state.pdf;
    if (tools == null || session.files.isEmpty) return;
    final first = session.files.first;
    final choice = await showSaveDialog(
      context,
      state.prefs,
      title: session.files.length == 1 ? 'Salvar PDF limpo' : 'Salvar ${session.files.length} PDFs limpos',
      name: '${p.basenameWithoutExtension(first)}_limpo',
      originalDir: p.dirname(first),
    );
    if (choice == null) return;
    state.queue.addAll([
      for (final f in session.files)
        buildCleanJob(tools, f, choice.dir, session.files.length == 1 ? choice.name : '${p.basenameWithoutExtension(f)}_limpo', session.options)..module = 'pdf',
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final t = Theme.of(context);
        final cs = t.colorScheme;
        final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
        Widget opt(String title, String sub, bool v, void Function(bool) on) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(title),
              subtitle: Text(sub),
              value: v,
              onChanged: (x) => session.set(() => on(x)),
            );
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DropTarget(
                  onDragDone: (d) => session.add(d.files.map((f) => f.path)),
                  child: Panel(
                    padding: const EdgeInsets.fromLTRB(22, 18, 14, 14),
                    child: session.files.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.cleaning_services_outlined, size: 64, color: cs.primary),
                                const SizedBox(height: 14),
                                Text('Limpar', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                                const SizedBox(height: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 460),
                                  child: Text(
                                    'Tira do PDF o que não aparece na página mas vai junto quando você envia o arquivo: autor, programa de origem, scripts, anexos, '
                                    'dados ocultos e, se quiser, comentários e marcadores. Solte PDFs aqui ou escolha os arquivos.',
                                    textAlign: TextAlign.center,
                                    style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                FilledButton.icon(
                                  onPressed: () async {
                                    final f = await pickPdf();
                                    if (f != null) session.add([f]);
                                  },
                                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                                  label: const Text('Escolher PDF…'),
                                ),
                              ],
                            ),
                          )
                        : ListView(
                            children: [
                              for (final f in session.files)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.picture_as_pdf_outlined),
                                  title: Text(p.basename(f)),
                                  subtitle: Text(p.dirname(f), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => session.set(() => session.files.remove(f))),
                                ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(onPressed: () => session.set(session.files.clear), child: const Text('Limpar a lista')),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 340,
                child: Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('O que tirar', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text('O texto e as imagens das páginas não mudam.', style: small),
                      Expanded(
                        child: ListView(
                          children: [
                            opt('Dados de autoria', 'Título, autor, programa de origem e datas.', session.metadata, (v) => session.metadata = v),
                            opt('Scripts', 'JavaScript e ações que rodam ao abrir.', session.scripts, (v) => session.scripts = v),
                            opt('Anexos', 'Arquivos guardados dentro do PDF.', session.attachments, (v) => session.attachments = v),
                            opt('Dados ocultos', 'Miniaturas e dados privados de outros programas.', session.extras, (v) => session.extras = v),
                            opt('Comentários', 'Notas e marcações (links e campos ficam).', session.comments, (v) => session.comments = v),
                            opt('Marcadores', 'O sumário lateral.', session.bookmarks, (v) => session.bookmarks = v),
                          ],
                        ),
                      ),
                      JobStatusCard(queue: state.queue),
                      ProcessButton(
                        queue: state.queue,
                        label: session.files.isEmpty ? 'Escolha um PDF' : (session.options.any ? 'Limpar e salvar' : 'Marque algo para tirar'),
                        onPressed: session.files.isNotEmpty && session.options.any ? () => _run(context) : null,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
