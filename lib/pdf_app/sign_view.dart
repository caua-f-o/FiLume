import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';
import '../core/pdf_sign.dart';
import '../core/state.dart';
import '../ui/common.dart';
import '../ui/process_button.dart';
import 'doc_view.dart' show pickPdf;
import 'pdf_app.dart' show JobStatusCard;
import 'save_dialog.dart';

class SignSession extends ChangeNotifier {
  SignSession(this.state);
  final AppState state;

  String? path;
  List<SignatureCheck>? checks;
  String? error;
  bool busy = false;

  /// Assinar com: arquivo de certificado ou certificado do Windows.
  bool useStore = Platform.isWindows;
  String? pfx;
  String password = '';
  List<StoreCert>? store;
  bool loadingStore = false;
  String? thumbprint;
  String reason = '', location = '';
  bool visible = true;

  String get name => path == null ? 'assinado' : '${p.basenameWithoutExtension(path!)}_assinado';

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  Future<void> open(String file) async {
    final tools = state.pdf;
    if (tools == null || busy) return;
    path = file;
    checks = null;
    error = null;
    busy = true;
    notifyListeners();
    try {
      checks = await verifySignatures(tools, file);
    } on FfError catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Não foi possível conferir as assinaturas: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> loadStore() async {
    if (loadingStore || store != null) return;
    loadingStore = true;
    notifyListeners();
    store = await listStoreCerts();
    if (store!.length == 1) thumbprint = store!.first.thumbprint;
    loadingStore = false;
    notifyListeners();
  }

  SignIdentity? get identity {
    if (useStore) return thumbprint == null ? null : SignIdentity.store(thumbprint!);
    return pfx == null ? null : SignIdentity.pfx(pfx!, password);
  }
}

class SignView extends StatelessWidget {
  const SignView({super.key, required this.state, required this.session});
  final AppState state;
  final SignSession session;

  Future<void> _open([String? file]) async {
    final path = file ?? await pickPdf();
    if (path != null) await session.open(path);
  }

  Future<void> _sign(BuildContext context) async {
    final tools = state.pdf, src = session.path, id = session.identity;
    if (tools == null || src == null || id == null) return;
    final already = session.checks?.isNotEmpty ?? false;
    if (already) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Este PDF já tem assinatura'),
          content: const Text(
            'O FiPDF regrava o arquivo antes de assinar, então as assinaturas que ele já tem deixam de valer na cópia nova. '
            'O arquivo original não muda.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Assinar mesmo assim')),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    final choice = await showSaveDialog(context, state.prefs, title: 'Salvar PDF assinado', name: session.name, originalDir: p.dirname(src));
    if (choice == null) return;
    state.queue.addAll([
      buildSignJob(tools, src, choice.dir, choice.name, id, reason: session.reason, location: session.location, visible: session.visible)..module = 'pdf',
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Padding(
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
                child: Panel(padding: const EdgeInsets.fromLTRB(22, 18, 14, 14), child: _left(context)),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(width: 340, child: _side(context)),
          ],
        ),
      ),
    );
  }

  Widget _left(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    if (session.path == null || (session.checks == null && session.error == null)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.draw_outlined, size: 64, color: cs.primary),
            const SizedBox(height: 14),
            Text('Assinar', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                session.busy
                    ? 'Conferindo as assinaturas…'
                    : 'Confere as assinaturas digitais de um PDF e assina com o seu certificado (arquivo .pfx ou o instalado no Windows, inclusive de cartão e token). '
                        'Solte um PDF aqui ou escolha um arquivo.',
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
          ],
        ),
      );
    }
    final checks = session.checks ?? const <SignatureCheck>[];
    return ListView(
      padding: const EdgeInsets.only(right: 10),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(p.basename(session.path!),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            ),
            TextButton.icon(onPressed: _open, icon: const Icon(Icons.folder_open_outlined, size: 18), label: const Text('Abrir outro')),
          ],
        ),
        if (session.error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(session.error!, style: TextStyle(color: cs.error))),
        SectionLabel('Assinaturas (${checks.length})'),
        if (checks.isEmpty && session.error == null) Text('Este PDF não tem assinatura digital.', style: small),
        for (final c in checks)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(18)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  c.intact == null ? Icons.help_outline : (c.intact! && c.coversWholeFile ? Icons.verified : (c.intact! ? Icons.error_outline : Icons.cancel)),
                  color: c.intact == null ? cs.onSurfaceVariant : (c.intact! && c.coversWholeFile ? Colors.green.shade600 : (c.intact! ? Colors.orange.shade700 : cs.error)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.signer ?? 'Assinante não identificado', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(c.verdict, style: t.textTheme.bodyMedium),
                      if (c.trustNote != null) Text(c.trustNote!, style: small),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (c.signedAt != null) 'Assinado em ${c.signedAt}',
                          if (c.issuer != null) 'emitido por ${c.issuer}',
                          if (c.validTo != null) 'certificado válido até ${c.validTo}',
                          'campo ${c.field}',
                        ].join(' · '),
                        style: small,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Text(
          'O FiPDF confere se o documento mudou depois de assinado e se o certificado é reconhecido por este computador. '
          'Ele não consulta a internet para saber se o certificado foi revogado; para valor legal, use também o validador oficial (como o do gov.br).',
          style: small,
        ),
      ],
    );
  }

  Widget _side(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(14));
    final open = session.path != null && session.checks != null;
    if (session.useStore && Platform.isWindows) session.loadStore();
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Assinar este PDF', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          if (Platform.isWindows)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Do Windows')),
                ButtonSegment(value: false, label: Text('Arquivo .pfx')),
              ],
              selected: {session.useStore},
              showSelectedIcon: false,
              onSelectionChanged: (v) => session.set(() => session.useStore = v.first),
            ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              children: [
                if (session.useStore) ...[
                  if (session.loadingStore) Text('Procurando certificados…', style: small),
                  if (session.store != null && session.store!.isEmpty)
                    Text('Nenhum certificado com chave para assinar está instalado para este usuário. Conecte o cartão ou token, ou use um arquivo .pfx.', style: small),
                  RadioGroup<String>(
                    groupValue: session.thumbprint,
                    onChanged: (v) => session.set(() => session.thumbprint = v),
                    child: Column(
                      children: [
                        for (final c in session.store ?? const <StoreCert>[])
                          RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: c.thumbprint,
                            title: Text(c.name),
                            subtitle: Text('${c.issuer} · até ${c.validTo}'),
                          ),
                      ],
                    ),
                  ),
                ] else ...[
                  OutlinedButton.icon(
                    onPressed: () async {
                      final f = await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'Certificado', extensions: ['pfx', 'p12'])]);
                      if (f != null) session.set(() => session.pfx = f.path);
                    },
                    icon: const Icon(Icons.badge_outlined, size: 18),
                    label: Text(session.pfx == null ? 'Escolher o certificado…' : p.basename(session.pfx!), overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    obscureText: true,
                    onChanged: (v) => session.password = v,
                    decoration: InputDecoration(labelText: 'Senha do certificado', border: border, isDense: true),
                  ),
                  const SizedBox(height: 6),
                  Text('A senha é usada só nesta assinatura e não fica guardada.', style: small),
                ],
                const SectionLabel('Detalhes (opcionais)'),
                TextField(
                  onChanged: (v) => session.reason = v,
                  decoration: InputDecoration(labelText: 'Motivo (ex.: "Aprovo este documento")', border: border, isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  onChanged: (v) => session.location = v,
                  decoration: InputDecoration(labelText: 'Local', border: border, isDense: true),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Carimbo visível'),
                  subtitle: const Text('Nome e data no canto da última página.'),
                  value: session.visible,
                  onChanged: (v) => session.set(() => session.visible = v),
                ),
              ],
            ),
          ),
          JobStatusCard(queue: state.queue),
          ProcessButton(
            queue: state.queue,
            label: !open ? 'Abra um PDF' : (session.identity == null ? 'Escolha o certificado' : 'Assinar e salvar'),
            onPressed: open && session.identity != null ? () => _sign(context) : null,
          ),
        ],
      ),
    );
  }
}
