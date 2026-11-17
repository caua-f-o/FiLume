import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/ffmpeg.dart';
import '../core/job.dart';
import '../core/pdfium.dart';
import '../core/state.dart';
import '../ui/common.dart';
import '../ui/process_button.dart';
import 'doc_view.dart';
import 'pdf_app.dart' show JobStatusCard, ToolButton;
import 'save_dialog.dart';

const _noteColors = <int, String>{0xFFFFD54F: 'Amarelo', 0xFF81C784: 'Verde', 0xFF64B5F6: 'Azul', 0xFFF06292: 'Rosa', 0xFFE53935: 'Vermelho'};

class NotesSession extends DocSession {
  NotesSession(super.state);

  NoteKind tool = NoteKind.highlight;
  int color = 0xFFFFD54F;
  String author = Platform.environment['USERNAME'] ?? Platform.environment['USER'] ?? '';
  String pending = '';
  bool dirty = false;
  String? notice;
  List<PdfNote> all = const [];

  String get name => path == null ? 'documento' : '${p.basenameWithoutExtension(path!)}_comentado';

  @override
  void onDocChanged() {
    dirty = false;
    notice = null;
    reload();
  }

  void reload() {
    final d = doc;
    all = d == null ? const [] : [for (var i = 0; i < d.pageCount; i++) ...d.notes(i)];
  }

  /// Cria um comentário a partir do que a pessoa apontou na página.
  void create(int page, Area area) {
    final d = doc;
    if (d == null) return;
    notice = null;
    try {
      var areas = [area];
      if (tool == NoteKind.highlight || tool == NoteKind.underline || tool == NoteKind.strikeout) {
        final lines = d.lineBoxes(page, area);
        if (lines.isEmpty) {
          notice = 'Não há texto nessa área. Em páginas digitalizadas, use o Retângulo ou passe o OCR antes.';
          notifyListeners();
          return;
        }
        areas = lines;
      }
      d.addNote(page, tool, areas, text: pending.trim(), author: author.trim(), color: color);
      dirty = true;
      reload();
      invalidate(page);
    } on FfError catch (e) {
      notice = e.message;
      notifyListeners();
    }
  }

  void delete(PdfNote n) {
    final d = doc;
    if (d == null) return;
    if (d.removeNotes(n.page, [n.index]) > 0) dirty = true;
    reload();
    invalidate(n.page);
  }

  void deleteAll() {
    final d = doc;
    if (d == null) return;
    final pages = {for (final n in all) n.page};
    for (final pg in pages) {
      if (d.removeNotes(pg, [for (final n in all) if (n.page == pg) n.index]) > 0) dirty = true;
      invalidate(pg);
    }
    reload();
    notifyListeners();
  }
}

/// Grava o documento aberto (com os comentários) num arquivo novo.
Job _saveJob(NotesSession s, String outDir, String name) => Job(
      title: '$name.pdf',
      kind: 'Comentar',
      detail: '${s.all.length} ${s.all.length == 1 ? 'comentário' : 'comentários'}',
      body: (ctx) async {
        final d = s.doc;
        if (d == null) throw FfError('O documento foi fechado antes de salvar.');
        ctx.report(0.3, stage: 'Gravando');
        await Directory(outDir).create(recursive: true);
        final out = uniquePath(p.join(outDir, '$name.pdf'));
        d.save(out);
        s.set(() => s.dirty = false);
        return JobResult('Comentários gravados', out);
      },
    );

class NotesView extends StatefulWidget {
  const NotesView({super.key, required this.state, required this.session});
  final AppState state;
  final NotesSession session;

  @override
  State<NotesView> createState() => _NotesViewState();
}

class _NotesViewState extends State<NotesView> {
  late final _text = TextEditingController(text: widget.session.pending);
  late final _author = TextEditingController(text: widget.session.author);
  NotesSession get s => widget.session;

  @override
  void dispose() {
    _text.dispose();
    _author.dispose();
    super.dispose();
  }

  Future<void> _open([String? file]) async {
    if (s.dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Descartar os comentários novos?'),
          content: const Text('O documento aberto tem comentários que ainda não foram salvos.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Descartar')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final path = file ?? await pickPdf();
    if (path != null) s.open(path);
  }

  Future<void> _save() async {
    final src = s.path;
    if (src == null) return;
    final choice = await showSaveDialog(context, widget.state.prefs, title: 'Salvar PDF comentado', name: s.name, originalDir: p.dirname(src));
    if (choice == null) return;
    widget.state.queue.addAll([_saveJob(s, choice.dir, choice.name)..module = 'pdf']);
  }

  Future<void> _export() async {
    final src = s.path;
    if (src == null) return;
    final loc = await getSaveLocation(
      suggestedName: '${p.basenameWithoutExtension(src)}_comentarios.txt',
      acceptedTypeGroups: [const XTypeGroup(label: 'Texto', extensions: ['txt'])],
    );
    if (loc == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await File(loc.path).writeAsString(notesAsText(p.basename(src), s.all));
      messenger.showSnackBar(const SnackBar(content: Text('Lista de comentários salva.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não foi possível salvar a lista: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final open = s.doc != null;
        final tapTool = s.tool == NoteKind.note;
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Panel(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ToolButton(icon: Icons.folder_open_outlined, label: 'Abrir', onTap: _open),
                            const SizedBox(width: 10),
                            for (final (k, icon) in const [
                              (NoteKind.highlight, Icons.border_color),
                              (NoteKind.underline, Icons.format_underlined),
                              (NoteKind.strikeout, Icons.format_strikethrough),
                              (NoteKind.note, Icons.sticky_note_2_outlined),
                              (NoteKind.box, Icons.crop_square),
                            ])
                              ToolButton(icon: icon, label: k.label, active: s.tool == k, enabled: open, onTap: () => s.set(() => s.tool = k)),
                            const SizedBox(width: 10),
                            for (final c in _noteColors.entries)
                              Tooltip(
                                message: c.value,
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => s.set(() => s.color = c.key),
                                  child: Container(
                                    width: 24,
                                    height: 24,
                                    margin: const EdgeInsets.symmetric(horizontal: 3),
                                    decoration: BoxDecoration(
                                      color: Color(c.key),
                                      shape: BoxShape.circle,
                                      border: Border.all(width: s.color == c.key ? 3 : 1, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: s.color == c.key ? 0.9 : 0.25)),
                                    ),
                                  ),
                                ),
                              ),
                            const SizedBox(width: 10),
                            ToolButton(icon: Icons.zoom_out, label: 'Menos', enabled: open, onTap: () => s.setZoom(s.zoom / 1.2)),
                            ToolButton(icon: Icons.zoom_in, label: 'Mais', enabled: open, onTap: () => s.setZoom(s.zoom * 1.2)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: DocArea(
                        session: s,
                        icon: Icons.rate_review_outlined,
                        title: 'Comentar',
                        intro: 'Marque trechos, sublinhe, risque e deixe notas num PDF, ou veja e apague os comentários que ele já tem.',
                        onOpen: _open,
                        onDrag: tapTool ? null : s.create,
                        onTap: tapTool ? (page, x, y) => s.create(page, Area(x, y, x + 20, y + 20)) : null,
                        dragPreview: (canvas, rect) => canvas.drawRect(rect, Paint()..color = Color(s.color).withValues(alpha: 0.35)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(width: 340, child: _side(context, open)),
            ],
          ),
        );
      },
    );
  }

  Widget _side(BuildContext context, bool open) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(14));
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Comentar', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            s.tool == NoteKind.note
                ? 'Clique na página onde a nota deve ficar.'
                : 'Arraste o mouse sobre o ${s.tool == NoteKind.box ? 'que quer destacar' : 'texto'}.',
            style: small,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            enabled: open,
            minLines: 2,
            maxLines: 4,
            onChanged: (v) => s.pending = v,
            decoration: InputDecoration(labelText: 'Texto do próximo comentário (opcional)', border: border, isDense: true),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _author,
            enabled: open,
            onChanged: (v) => s.author = v,
            decoration: InputDecoration(labelText: 'Seu nome nos comentários', border: border, isDense: true),
          ),
          if (s.notice != null) ...[
            const SizedBox(height: 10),
            Text(s.notice!, style: t.textTheme.bodySmall?.copyWith(color: cs.error)),
          ],
          SectionLabel('No documento (${s.all.length})'),
          Expanded(
            child: s.all.isEmpty
                ? Text(open ? 'Este PDF não tem comentários.' : 'Abra um PDF para começar.', style: small)
                : ListView.builder(
                    itemCount: s.all.length,
                    itemBuilder: (context, i) {
                      final n = s.all[i];
                      final who = [if (n.author.isNotEmpty) n.author, if (n.date.isNotEmpty) n.date].join(' · ');
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('Pág. ${n.page + 1} · ${n.typeName}', style: t.textTheme.labelLarge),
                        subtitle: Text([if (n.text.isNotEmpty) n.text, if (who.isNotEmpty) who].join('\n'), maxLines: 4, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(tooltip: 'Apagar este comentário', icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => s.delete(n)),
                      );
                    },
                  ),
          ),
          if (s.all.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                TextButton(onPressed: _export, child: const Text('Salvar a lista (.txt)')),
                TextButton(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: notesAsText(p.basename(s.path ?? ''), s.all)));
                    messenger.showSnackBar(const SnackBar(content: Text('Lista copiada.')));
                  },
                  child: const Text('Copiar'),
                ),
                TextButton(onPressed: s.deleteAll, child: const Text('Apagar todos')),
              ],
            ),
          const SizedBox(height: 8),
          JobStatusCard(queue: widget.state.queue),
          ProcessButton(
            queue: widget.state.queue,
            label: !open ? 'Abra um PDF' : (s.dirty ? 'Salvar com os comentários' : 'Nada novo para salvar'),
            onPressed: open && s.dirty ? _save : null,
          ),
        ],
      ),
    );
  }
}
