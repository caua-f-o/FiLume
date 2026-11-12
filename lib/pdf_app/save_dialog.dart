import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/prefs.dart';

/// O que a pessoa escolheu na caixa de salvar.
class SaveChoice {
  SaveChoice(this.dir, this.name, this.jpegQ);
  final String dir;
  final String name;

  /// Qualidade JPEG das imagens que entram no PDF (escala do FFmpeg: 1 = máxima).
  final int jpegQ;
}

const _qualities = <int, String>{1: 'Máxima', 2: 'Alta', 5: 'Equilibrada', 9: 'Leve'};

/// Tira do nome o que o Windows não aceita em nomes de arquivo.
String cleanFileName(String text) =>
    text.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '').trim().replaceAll(RegExp(r'[. ]+$'), '');

String? _documentsDir() {
  final env = Platform.environment;
  final home = env['USERPROFILE'] ?? env['HOME'];
  if (home == null) return null;
  final docs = p.join(home, 'Documents');
  return Directory(docs).existsSync() ? docs : home;
}

/// Caixa de salvar: nome, pasta (com os atalhos guardados) e qualidade.
Future<SaveChoice?> showSaveDialog(
  BuildContext context,
  Prefs prefs, {
  required String title,
  String name = '',
  bool askName = true,
  bool folder = false,
  String? originalDir,
  bool imageQuality = false,
}) =>
    showDialog<SaveChoice>(
      context: context,
      builder: (context) => _SaveDialog(
        prefs: prefs,
        title: title,
        name: name,
        askName: askName,
        folder: folder,
        originalDir: originalDir,
        imageQuality: imageQuality,
      ),
    );

class _SaveDialog extends StatefulWidget {
  const _SaveDialog({
    required this.prefs,
    required this.title,
    required this.name,
    required this.askName,
    required this.folder,
    required this.originalDir,
    required this.imageQuality,
  });
  final Prefs prefs;
  final String title, name;
  final bool askName, folder, imageQuality;
  final String? originalDir;

  @override
  State<_SaveDialog> createState() => _SaveDialogState();
}

class _SaveDialogState extends State<_SaveDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final List<String> _dirs;
  String? _dir;
  bool _remember = false;
  int _q = 2;

  Prefs get prefs => widget.prefs;

  @override
  void initState() {
    super.initState();
    final seen = <String>{};
    _dirs = [
      for (final d in [widget.originalDir, ...prefs.pdfFolders, prefs.pdfLastDir, _documentsDir()])
        if (d != null && seen.add(p.normalize(d)) && Directory(d).existsSync()) d,
    ];
    final last = prefs.pdfLastDir;
    _dir = last != null && _dirs.contains(last) ? last : (_dirs.isEmpty ? null : _dirs.first);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String _label(String dir) {
    if (dir == widget.originalDir) return 'Pasta do original';
    final base = p.basename(dir);
    return base.isEmpty ? dir : base;
  }

  Future<void> _browse() async {
    final dir = await getDirectoryPath(initialDirectory: _dir);
    if (dir == null || !mounted) return;
    setState(() {
      if (!_dirs.contains(dir)) _dirs.add(dir);
      _dir = dir;
      _remember = false;
    });
  }

  bool get _ok => _dir != null && (!widget.askName || cleanFileName(_name.text).isNotEmpty);

  void _submit() {
    if (!_ok) return;
    final dir = _dir!;
    prefs.update(() {
      prefs.pdfLastDir = dir;
      if (_remember && !prefs.pdfFolders.contains(dir)) prefs.pdfFolders.add(dir);
    });
    Navigator.pop(context, SaveChoice(dir, cleanFileName(_name.text), _q));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final muted = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final dir = _dir;
    final canRemember = dir != null && dir != widget.originalDir && !prefs.pdfFolders.contains(dir);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.askName) ...[
                TextField(
                  controller: _name,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: widget.folder ? 'Nome da pasta com os arquivos' : 'Nome do arquivo',
                    suffixText: widget.folder ? null : '.pdf',
                  ),
                ),
                const SizedBox(height: 18),
              ],
              Text('Salvar em', style: t.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final d in _dirs)
                    Tooltip(
                      message: d,
                      child: ChoiceChip(
                        avatar: Icon(d == widget.originalDir ? Icons.description_outlined : Icons.folder_outlined, size: 18),
                        label: Text(_label(d)),
                        showCheckmark: false,
                        selected: d == dir,
                        onSelected: (_) => setState(() {
                          _dir = d;
                          _remember = false;
                        }),
                      ),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Outra pasta…'),
                    onPressed: _browse,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(dir ?? 'Escolha uma pasta.', maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
              if (canRemember)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Guardar esta pasta nos atalhos'),
                  value: _remember,
                  onChanged: (v) => setState(() => _remember = v ?? false),
                ),
              if (widget.imageQuality) ...[
                const SizedBox(height: 14),
                Text('Qualidade das imagens e digitalizações',
                    style: t.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [for (final e in _qualities.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                  selected: {_q},
                  onSelectionChanged: (v) => setState(() => _q = v.first),
                ),
                const SizedBox(height: 6),
                Text('Vale para as imagens que viram página. Páginas de PDF saem como estão.', style: muted),
              ],
              const SizedBox(height: 6),
              Text('Nada é sobrescrito: se o nome já existir, sai com "(2)" no fim.', style: muted),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton.icon(
          onPressed: _ok ? _submit : null,
          icon: const Icon(Icons.save_alt, size: 18),
          label: const Text('Salvar'),
        ),
      ],
    );
  }
}
