import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';
import '../core/pdf_forms.dart';
import '../core/state.dart';
import '../ui/common.dart';
import '../ui/process_button.dart';
import 'pdf_app.dart' show JobStatusCard;
import 'save_dialog.dart';

/// O formulário aberto e o que a pessoa digitou.
class FormsSession extends ChangeNotifier {
  FormsSession(this.state);
  final AppState state;

  String? path;
  PdfForm? form;
  String? error;
  bool loading = false;
  bool flatten = false;

  /// Só os campos que a pessoa mudou.
  final Map<String, String> values = {};
  final Map<String, TextEditingController> _controllers = {};

  String get name => path == null ? 'formulario' : '${p.basenameWithoutExtension(path!)}_preenchido';

  String valueOf(PdfField f) => values[f.name] ?? f.value;

  TextEditingController controller(PdfField f) => _controllers.putIfAbsent(f.name, () => TextEditingController(text: valueOf(f)));

  void setValue(PdfField f, String v) {
    if (v == f.value) {
      values.remove(f.name);
    } else {
      values[f.name] = v;
    }
    notifyListeners();
  }

  void set(VoidCallback fn) {
    fn();
    notifyListeners();
  }

  void _reset() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    values.clear();
    form = null;
    path = null;
  }

  Future<void> open(String file) async {
    final tools = state.pdf;
    if (tools == null || loading) return;
    _reset();
    error = null;
    loading = true;
    notifyListeners();
    try {
      form = await readForm(tools, file);
      path = file;
    } on FfError catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Não foi possível ler o arquivo: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void restore() {
    final f = form;
    if (f == null) return;
    values.clear();
    for (final field in f.fields) {
      _controllers[field.name]?.text = field.value;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }
}

class FormsView extends StatelessWidget {
  const FormsView({super.key, required this.state, required this.session});
  final AppState state;
  final FormsSession session;

  Future<void> _open([String? file]) async {
    final path = file ?? (await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'PDF', extensions: ['pdf'])]))?.path;
    if (path != null) await session.open(path);
  }

  Future<void> _save(BuildContext context) async {
    final tools = state.pdf, src = session.path, form = session.form;
    if (tools == null || src == null || form == null) return;
    final choice = await showSaveDialog(context, state.prefs, title: 'Salvar formulário', name: session.name, originalDir: p.dirname(src));
    if (choice == null) return;
    state.queue.addAll([
      buildFillJob(tools, src, form, {...session.values}, choice.dir, choice.name, flatten: session.flatten)..module = 'pdf',
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final form = session.form;
        final has = form != null && !form.isEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DropTarget(
                  onDragDone: (d) {
                    final pdfs = [for (final f in d.files) if (f.path.toLowerCase().endsWith('.pdf')) f.path];
                    if (pdfs.isNotEmpty) _open(pdfs.first);
                  },
                  child: Panel(
                    padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
                    child: has ? _fields(context, form) : _empty(context, form),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(width: 320, child: _side(context, has ? form : null)),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(BuildContext context, PdfForm? form) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final noFields = form != null && form.isEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fact_check_outlined, size: 64, color: cs.primary),
          const SizedBox(height: 14),
          Text('Formulários', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(
              session.loading
                  ? 'Lendo os campos…'
                  : noFields
                      ? '"${p.basename(session.path ?? '')}" não tem campos de formulário. Para escrever por cima da página, use o Editar.'
                      : 'Preencha os campos de um PDF e salve. Dá também para "achatar": os valores viram parte da página e ninguém mais altera. '
                          'Solte um PDF aqui ou escolha um arquivo.',
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: session.loading || state.pdf == null ? null : _open,
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
  }

  Widget _fields(BuildContext context, PdfForm form) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final pages = <int, List<PdfField>>{};
    for (final f in form.fields) {
      pages.putIfAbsent(f.page, () => []).add(f);
    }
    final order = pages.keys.toList()..sort();
    return ListView(
      padding: const EdgeInsets.only(right: 10),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(p.basename(session.path ?? ''),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            TextButton.icon(onPressed: _open, icon: const Icon(Icons.folder_open_outlined, size: 18), label: const Text('Abrir outro')),
          ],
        ),
        for (final pg in order) ...[
          SectionLabel(pg > 0 ? 'Página $pg' : 'Sem página'),
          for (final f in pages[pg]!)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _FieldRow(session: session, field: f, cs: cs),
            ),
        ],
      ],
    );
  }

  Widget _side(BuildContext context, PdfForm? form) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    final changed = session.values.length;
    final missing = form == null ? 0 : form.fields.where((f) => f.required && f.fillable && session.valueOf(f).isEmpty).length;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Formulários', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            form == null
                ? 'Abra um PDF com campos para preencher.'
                : '${form.fields.length} ${form.fields.length == 1 ? 'campo' : 'campos'} · $changed ${changed == 1 ? 'alterado' : 'alterados'}'
                    '${missing > 0 ? ' · $missing ${missing == 1 ? 'obrigatório vazio' : 'obrigatórios vazios'}' : ''}',
            style: small,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Achatar ao salvar'),
            subtitle: const Text('Os valores viram parte da página e os campos deixam de existir. Bom para enviar a versão final.'),
            value: session.flatten,
            onChanged: form == null ? null : (v) => session.set(() => session.flatten = v),
          ),
          if (form != null && changed > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: session.restore, child: const Text('Voltar aos valores do arquivo')),
            ),
          const Spacer(),
          JobStatusCard(queue: state.queue),
          ProcessButton(
            queue: state.queue,
            label: form == null
                ? 'Abra um formulário'
                : (changed == 0 && !session.flatten ? 'Preencha algum campo' : (session.flatten ? 'Salvar achatado' : 'Salvar preenchido')),
            onPressed: form != null && (changed > 0 || session.flatten) ? () => _save(context) : null,
          ),
        ],
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.session, required this.field, required this.cs});
  final FormsSession session;
  final PdfField field;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final f = field;
    final title = '${f.label ?? f.name}${f.required ? ' *' : ''}';
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(14));
    switch (f.kind) {
      case FieldKind.text || FieldKind.multiline:
        return TextField(
          controller: session.controller(f),
          enabled: f.fillable,
          maxLength: f.maxLength,
          minLines: f.kind == FieldKind.multiline ? 3 : 1,
          maxLines: f.kind == FieldKind.multiline ? 8 : 1,
          onChanged: (v) => session.setValue(f, v),
          decoration: InputDecoration(labelText: title, border: border, helperText: f.readOnly ? 'Somente leitura' : null),
        );
      case FieldKind.checkbox:
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(title),
          value: session.valueOf(f).isNotEmpty,
          onChanged: f.fillable ? (v) => session.setValue(f, v == true ? '1' : '') : null,
        );
      case FieldKind.combo || FieldKind.list || FieldKind.radio:
        final cur = session.valueOf(f);
        return InputDecorator(
          decoration: InputDecoration(labelText: title, border: border, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              value: cur.isEmpty || f.options.contains(cur) ? cur : null,
              hint: cur.isEmpty ? null : Text(cur),
              items: [
                const DropdownMenuItem(value: '', child: Text('(nenhuma)')),
                for (final o in f.options) DropdownMenuItem(value: o, child: Text(o)),
              ],
              onChanged: f.fillable ? (v) => session.setValue(f, v ?? '') : null,
            ),
          ),
        );
      case FieldKind.signature || FieldKind.button:
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(f.kind == FieldKind.signature ? Icons.draw_outlined : Icons.smart_button_outlined, color: cs.onSurfaceVariant),
          title: Text(f.label ?? f.name),
          subtitle: Text(f.kind == FieldKind.signature ? 'Campo de assinatura digital (não é preenchido aqui)' : 'Botão do formulário'),
        );
    }
  }
}
