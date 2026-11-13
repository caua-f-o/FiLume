import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/editor.dart';
import '../core/ffmpeg.dart';
import '../core/job.dart';
import '../core/pdf.dart';
import '../core/pdfium.dart';
import '../core/state.dart';
import '../ui/common.dart';
import '../ui/process_button.dart';
import 'pdf_app.dart' show JobStatusCard, ToolButton;
import 'save_dialog.dart';

enum EdTool {
  select('Selecionar', Icons.near_me_outlined),
  text('Texto', Icons.title),
  rect('Retângulo', Icons.crop_square),
  ellipse('Elipse', Icons.circle_outlined),
  line('Linha', Icons.horizontal_rule),
  arrow('Seta', Icons.arrow_right_alt),
  highlight('Marca-texto', Icons.border_color_outlined),
  whiteout('Corretivo', Icons.format_color_reset_outlined),
  pen('Caneta', Icons.draw_outlined);

  const EdTool(this.label, this.icon);
  final String label;
  final IconData icon;
  bool get shape => this == rect || this == ellipse || this == line || this == arrow;
}

/// Texto sendo digitado na página.
class TextEdit {
  TextEdit(this.page, this.block, this.x, this.top, this.width, this.style, String text) : controller = TextEditingController(text: text);
  final int page;

  /// Parágrafo que está sendo editado; null = texto novo.
  final TextBlock? block;
  final double x, top, width;
  final TextStyleSpec style;
  final TextEditingController controller;
  final FocusNode focus = FocusNode();
}

const _palette = [0xFF000000, 0xFF5F6368, 0xFFCC0000, 0xFFE67C00, 0xFF188038, 0xFF1A73E8, 0xFF7B1FA2, 0xFFFFFFFF];

/// O documento aberto no editor e o estado da tela (ferramenta, seleção, zoom).
class EditorSession extends ChangeNotifier {
  EditorSession(this.state);
  final AppState state;

  Editor? editor;
  String? path;

  /// Nome para sugerir ao salvar.
  String name = '';
  String? error;
  String? notice;
  bool busy = false;

  EdTool tool = EdTool.select;
  double zoom = 1;
  Selection? selection;
  TextEdit? editing;

  /// Página em que a pessoa mexeu por último (onde entram imagem e assinatura).
  int focusPage = 0;

  /// Estilo do texto novo (e do texto selecionado, quando há).
  TextStyleSpec style = TextStyleSpec(family: FontFamily.sans);
  int strokeColor = 0xFFCC0000;
  double strokeWidth = 2;
  bool filled = false;

  final Map<int, ui.Image> _images = {};
  final Set<int> _rendering = {};
  int _generation = 0;
  int _savedOps = 0;
  int _ops = 0;

  bool get unsaved => editor != null && _ops != _savedOps;

  void _reset() {
    editing?.controller.dispose();
    editing = null;
    selection = null;
    for (final i in _images.values) {
      i.dispose();
    }
    _images.clear();
    _generation++;
  }

  Future<void> open(String file, {String? suggested}) async {
    final pdfium = Pdfium.load();
    if (pdfium == null) {
      error = Pdfium.loadError;
      notifyListeners();
      return;
    }
    try {
      final pdfTools = state.pdf;
      final src = pdfTools == null ? file : await prepareForEdit(pdfTools, file);
      final ed = Editor(() => PdfiumBackend.open(src, pdfium));
      ed.page(0);
      editor?.close();
      _reset();
      editor = ed;
      path = file;
      name = suggested ?? '${p.basenameWithoutExtension(file)}_editado';
      error = notice = null;
      _ops = _savedOps = 0;
      focusPage = 0;
      tool = EdTool.select;
      // Avisa quando a página não tem nada editável por dentro.
      final first = ed.page(0);
      if (first.blocks.isEmpty && first.objs.any((o) => o.kind == ObjKind.image && o.width * o.height > 0.5 * first.width * first.height)) {
        notice = 'Esta página é uma imagem (digitalização): não há texto para editar. '
            'Dá para escrever por cima, cobrir com o corretivo, desenhar e inserir imagens.';
      } else if (first.blocks.isEmpty && first.objs.where((o) => o.kind == ObjKind.path).length > 50) {
        notice = 'Este PDF não tem texto de verdade: as letras foram desenhadas como formas '
            '(acontece com o "Microsoft Print to PDF" e outras impressoras virtuais). '
            'Dá para cobrir com o corretivo, escrever por cima, desenhar e inserir imagens.';
      } else if (first.blocks.isEmpty && first.objs.isNotEmpty && first.objs.every((o) => o.kind == ObjKind.other)) {
        notice = 'O conteúdo desta página está agrupado num bloco só, que o editor não abre. '
            'Dá para escrever por cima, cobrir com o corretivo, desenhar e inserir imagens.';
      }
    } on FfError catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Não foi possível abrir o arquivo para edição: $e';
    }
    notifyListeners();
  }

  /// Monta o que está na bandeja num PDF temporário e abre no editor.
  Future<void> openTray() async {
    final pdf = state.pdf, tools = state.tools;
    final pages = state.organizer.pages;
    if (pdf == null || tools == null || pages.isEmpty || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final dir = await Directory.systemTemp.createTemp('filume_editsrc_');
      final first = pages.first.doc.path;
      final base = p.isWithin(Directory.systemTemp.path, first) ? 'Digitalização' : p.basenameWithoutExtension(first);
      final job = buildTrayJob(pages: pages, op: TrayOp.save, outDir: dir.path, name: base, tools: pdf, fit: state.pdfConvert.fit);
      final r = await job.body(JobCtx(tools, FfRun(), (_, __, ___) {}));
      busy = false;
      await open(r.revealPath, suggested: '${base}_editado');
    } on FfError catch (e) {
      busy = false;
      error = e.message;
      notifyListeners();
    } catch (e) {
      busy = false;
      error = 'Não foi possível preparar o PDF da bandeja: $e';
      notifyListeners();
    }
  }

  void closeDoc() {
    editor?.close();
    editor = null;
    path = null;
    _reset();
    notifyListeners();
  }

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  void setTool(EdTool t) {
    commitText();
    tool = t;
    if (t != EdTool.select) selection = null;
    notifyListeners();
  }

  void setZoom(double z) {
    final v = z.clamp(0.4, 4.0);
    if (v == zoom) return;
    zoom = v;
    _generation++;
    notifyListeners();
  }

  // ---- imagens das páginas

  /// Imagem da página (pode ser de um zoom anterior, enquanto a nova não chega).
  ui.Image? imageFor(int page, double dpr) {
    final ed = editor;
    if (ed == null) return null;
    if (!_rendering.contains(page) && !_fresh.contains(page)) {
      _rendering.add(page);
      final gen = _generation;
      // Fora do quadro atual, para não travar a rolagem.
      Future<void>.delayed(Duration.zero, () {
        if (editor != ed) {
          _rendering.remove(page);
          return;
        }
        try {
          final (w, h) = ed.backend.pageSize(page);
          var scale = zoom * dpr;
          // Teto de ~14 megapixels por página.
          scale = math.min(scale, math.sqrt(14e6 / (w * h)));
          final rp = ed.backend.render(page, scale);
          ui.decodeImageFromPixels(rp.bgra, rp.width, rp.height, ui.PixelFormat.bgra8888, (img) {
            _rendering.remove(page);
            if (editor != ed) {
              img.dispose();
              return;
            }
            _images.remove(page)?.dispose();
            _images[page] = img;
            if (gen == _generation) _fresh.add(page);
            notifyListeners();
          });
        } catch (_) {
          _rendering.remove(page);
        }
      });
    }
    return _images[page];
  }

  /// Páginas cuja imagem está em dia com o documento e o zoom.
  final Set<int> _fresh = {};

  void _stale([int? page]) {
    if (page == null) {
      _fresh.clear();
    } else {
      _fresh.remove(page);
    }
  }

  // ---- alterações

  void apply(EditOp op) {
    final ed = editor;
    if (ed == null) return;
    try {
      ed.apply(op);
      _ops++;
      _stale(op.page);
      error = null;
    } on FfError catch (e) {
      error = e.message;
    } catch (e) {
      error = 'A alteração não pôde ser feita: $e';
    }
    notifyListeners();
  }

  void undo() {
    final ed = editor;
    if (ed == null || !ed.canUndo) return;
    commitText();
    try {
      ed.undo();
      _ops--;
    } catch (e) {
      error = 'Não foi possível desfazer: $e';
    }
    selection = null;
    _stale();
    notifyListeners();
  }

  void redo() {
    final ed = editor;
    if (ed == null || !ed.canRedo) return;
    commitText();
    try {
      ed.redo();
      _ops++;
    } catch (e) {
      error = 'Não foi possível refazer: $e';
    }
    selection = null;
    _stale();
    notifyListeners();
  }

  void markSaved() {
    _savedOps = _ops;
    notifyListeners();
  }

  void deleteSelection() {
    final s = selection;
    if (s == null || editing != null) return;
    selection = null;
    apply(DeleteOp(s.page, s.indices));
  }

  /// Seleciona o último objeto da página (o que acabou de entrar).
  void selectLast(int page) {
    final objs = editor?.page(page).objs;
    if (objs == null || objs.isEmpty) return;
    final o = objs.last;
    selection = Selection(page, [o.index], o.l, o.t, o.r, o.b, kind: o.kind);
    tool = EdTool.select;
    notifyListeners();
  }

  // ---- texto

  /// Abre a caixa de digitação: num parágrafo existente ou num ponto vazio.
  void startEdit(int page, {TextBlock? block, double x = 0, double y = 0}) {
    final ed = editor;
    if (ed == null) return;
    commitText();
    final model = ed.page(page);
    if (block != null) {
      final st = TextStyleSpec.of(block);
      var width = block.r - block.l, left = block.l;
      if (block.lines.length == 1) {
        if (st.align == HAlign.left) width = math.max(width, model.textRight - block.l);
      }
      style = st;
      editing = TextEdit(page, block, left, block.t, math.max(width, st.size * 4), st, block.lines.map((l) => l.text).join(' '));
    } else {
      final st = style.copy()..family ??= FontFamily.sans;
      final right = x < model.width - 80 ? model.width - 36 : x + 200;
      editing = TextEdit(page, null, x, y - st.size * 0.6, right - x, st, '');
    }
    selection = null;
    focusPage = page;
    notifyListeners();
    editing!.focus.requestFocus();
  }

  void cancelText() {
    final e = editing;
    if (e == null) return;
    editing = null;
    e.controller.dispose();
    notifyListeners();
  }

  /// Grava o que foi digitado na página.
  void commitText() {
    final e = editing, ed = editor;
    if (e == null || ed == null) return;
    editing = null;
    final text = e.controller.text.replaceAll('\r', '').trimRight();
    e.controller.dispose();
    final block = e.block;
    final lost = Editor.unsupported(text);
    if (block == null) {
      if (text.trim().isNotEmpty) {
        apply(ed.newText(e.page, text, e.style, e.x, e.top, e.x + e.width));
        if (lost.isNotEmpty) notice = 'Estes caracteres não existem nas fontes do editor e viraram "?": $lost';
      }
    } else if (text.trim().isEmpty) {
      apply(DeleteOp(e.page, block.indices));
    } else {
      final before = TextStyleSpec.of(block);
      final same = text == block.lines.map((l) => l.text).join(' ') &&
          e.style.family == null &&
          e.style.bold == before.bold &&
          e.style.italic == before.italic &&
          e.style.size == before.size &&
          e.style.color == before.color &&
          e.style.align == before.align;
      if (!same) {
        final op = ed.editBlock(e.page, block, text, e.style);
        apply(op);
        if (e.style.family == null && (op.substituted || op.font.standard != null)) {
          notice = 'A fonte original (${fontDisplayName(block.first.font)}) não tem todas as letras do texto novo; '
              'este parágrafo passou a usar ${familyOf(block.first.font).label.toLowerCase()}'
              '${lost.isEmpty ? '' : '. Caracteres sem suporte viraram "?": $lost'}.';
        }
      }
    }
    notifyListeners();
  }

  /// Muda o estilo: do texto em digitação, do parágrafo selecionado ou do próximo texto.
  void restyle(void Function(TextStyleSpec s) change) {
    final e = editing, sel = selection, ed = editor;
    if (e != null) {
      change(e.style);
      style = e.style.copy();
    } else if (sel != null && sel.block != null && ed != null) {
      final block = sel.block!;
      final st = TextStyleSpec.of(block);
      change(st);
      style = st.copy();
      apply(ed.editBlock(sel.page, block, block.lines.map((l) => l.text).join(' '), st));
      // O parágrafo refeito fica no fim da página: seleciona de novo.
      final again = ed.page(sel.page).hit(sel.page, (sel.l + sel.r) / 2, sel.t + st.size * 0.5);
      selection = again != null && again.isText ? again : null;
    } else {
      change(style);
    }
    notifyListeners();
  }

  /// Estilo que o painel mostra agora.
  TextStyleSpec get shownStyle {
    final e = editing, b = selection?.block;
    if (e != null) return e.style;
    if (b != null) return TextStyleSpec.of(b);
    style.family ??= FontFamily.sans; // "fonte original" só existe para texto que já estava no PDF
    return style;
  }

  // ---- imagem e assinatura

  Future<void> insertImage(String file) async {
    final ed = editor;
    if (ed == null) return;
    commitText();
    try {
      final bytes = await File(file).readAsBytes();
      final probe = await ui.instantiateImageCodec(bytes);
      final head = (await probe.getNextFrame()).image;
      final w0 = head.width, h0 = head.height;
      head.dispose();
      // Fotos grandes entram com no máximo 2000 px de lado: sobra qualidade e o PDF não incha.
      final k = math.min(1.0, 2000 / math.max(w0, h0));
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: (w0 * k).round(), targetHeight: (h0 * k).round());
      final img = (await codec.getNextFrame()).image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      final w = img.width, h = img.height;
      img.dispose();
      if (data == null) throw 'sem dados';
      final model = ed.page(focusPage);
      // Na tela, 96 px = 72 pt; cabe em metade da página.
      var pw = w0 * 0.75, ph = h0 * 0.75;
      final fit = math.min(1.0, math.min(model.width * 0.5 / pw, model.height * 0.5 / ph));
      pw *= fit;
      ph *= fit;
      apply(ImageOp(focusPage, data.buffer.asUint8List(), w, h, (model.width - pw) / 2, (model.height - ph) / 2, pw, ph));
      selectLast(focusPage);
    } catch (e) {
      error = 'Não foi possível inserir "${p.basename(file)}".';
      notifyListeners();
    }
  }

  /// Põe na página a assinatura desenhada ([strokes] em pontos, a partir de 0,0).
  void insertSignature(List<List<double>> strokes, double w, double h) {
    final ed = editor;
    if (ed == null || strokes.isEmpty) return;
    final model = ed.page(focusPage);
    final scale = math.min(1.0, 180 / math.max(w, 1));
    final ox = (model.width - w * scale) / 2, oy = model.height * 0.7;
    final moved = [
      for (final s in strokes) [for (var i = 0; i < s.length; i++) (i.isEven ? ox : oy) + s[i] * scale],
    ];
    apply(PathOp(focusPage, PathSpec.strokes(moved, stroke: 0xFF0B2A6F, width: 1.4), 'Assinatura'));
    selectLast(focusPage);
  }

  @override
  void dispose() {
    editor?.close();
    _reset();
    super.dispose();
  }
}

// ----------------------------------------------------------------------- tela

class EditorView extends StatelessWidget {
  const EditorView({super.key, required this.state, required this.session});
  final AppState state;
  final EditorSession session;

  Future<bool> _confirmDiscard(BuildContext context) async {
    if (!session.unsaved) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Descartar as alterações?'),
        content: const Text('O documento aberto no editor tem alterações que ainda não foram salvas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Voltar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Descartar')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _open(BuildContext context, [String? file]) async {
    if (!await _confirmDiscard(context)) return;
    final path = file ?? (await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'PDF', extensions: ['pdf'])]))?.path;
    if (path != null) await session.open(path);
  }

  Future<void> _save(BuildContext context) async {
    final ed = session.editor, pdf = state.pdf;
    if (ed == null || pdf == null) return;
    session.commitText();
    final src = session.path;
    final temp = src == null || p.isWithin(Directory.systemTemp.path, src);
    final choice = await showSaveDialog(context, state.prefs,
        title: 'Salvar PDF editado', name: session.name, originalDir: temp ? null : p.dirname(src));
    if (choice == null) return;
    state.queue.addAll([buildEditorSaveJob(ed, choice.dir, choice.name, pdf)..module = 'pdf']);
    session.markSaved();
  }

  Future<void> _pickImage() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Imagens', extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif']),
    ]);
    if (f != null) await session.insertImage(f.path);
  }

  Future<void> _sign(BuildContext context) async {
    final r = await showDialog<(List<List<double>>, double, double)>(context: context, builder: (context) => const _SignDialog());
    if (r != null) session.insertSignature(r.$1, r.$2, r.$3);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final open = session.editor != null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): session.undo,
                    const SingleActivator(LogicalKeyboardKey.keyY, control: true): session.redo,
                    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): session.redo,
                    const SingleActivator(LogicalKeyboardKey.delete): session.deleteSelection,
                    const SingleActivator(LogicalKeyboardKey.escape): () {
                      session.editing != null ? session.cancelText() : session.set(() => session.selection = null);
                    },
                  },
                  child: Focus(
                    autofocus: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ribbon(context, open),
                        const SizedBox(height: 12),
                        Expanded(
                          child: DropTarget(
                            onDragDone: (d) {
                              final pdfs = [for (final f in d.files) if (f.path.toLowerCase().endsWith('.pdf')) f.path];
                              final imgs = [
                                for (final f in d.files)
                                  if (RegExp(r'\.(png|jpe?g|webp|bmp|gif)$').hasMatch(f.path.toLowerCase())) f.path,
                              ];
                              if (pdfs.isNotEmpty) {
                                _open(context, pdfs.first);
                              } else if (open && imgs.isNotEmpty) {
                                session.insertImage(imgs.first);
                              }
                            },
                            child: Panel(
                              padding: const EdgeInsets.all(6),
                              child: open ? _Pages(session: session) : _Empty(session: session, onOpen: () => _open(context)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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

  Widget _ribbon(BuildContext context, bool open) {
    final cs = Theme.of(context).colorScheme;
    final ed = session.editor;
    Widget sep() => Container(width: 1, height: 44, margin: const EdgeInsets.symmetric(horizontal: 8), color: cs.outlineVariant);
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: LayoutBuilder(
        builder: (context, box) {
          final dense = box.maxWidth < 1040;
          Widget tool(EdTool t, String tip) => ToolButton(
                dense: dense,
                icon: t.icon,
                label: t.label,
                tip: tip,
                active: session.tool == t,
                onTap: open ? () => session.setTool(t) : null,
              );
          final shape = session.tool.shape ? session.tool : EdTool.rect;
          return Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              ToolButton(dense: dense, icon: Icons.folder_open_outlined, label: 'Abrir', tip: 'Abrir um PDF para editar', onTap: () => _open(context)),
              sep(),
              tool(EdTool.select, 'Selecionar, mover e redimensionar.\nDois cliques num texto para editar.'),
              tool(EdTool.text, 'Clique num texto para editar ou num espaço vazio para escrever'),
              ToolButton(dense: dense, icon: Icons.image_outlined, label: 'Imagem', tip: 'Inserir uma imagem na página', onTap: open ? _pickImage : null),
              PopupMenuButton<EdTool>(
                tooltip: 'Formas: retângulo, elipse, linha e seta',
                enabled: open,
                onSelected: session.setTool,
                itemBuilder: (context) => [
                  for (final t in EdTool.values.where((t) => t.shape))
                    PopupMenuItem(value: t, child: Row(children: [Icon(t.icon, size: 20), const SizedBox(width: 12), Text(t.label)])),
                ],
                child: ToolButton(dense: dense, icon: shape.icon, label: 'Formas', dropdown: true, enabled: open, active: session.tool.shape),
              ),
              tool(EdTool.highlight, 'Marca-texto: arraste sobre o trecho'),
              tool(EdTool.whiteout, 'Corretivo: cobre de branco a área arrastada'),
              tool(EdTool.pen, 'Desenhar à mão livre'),
              ToolButton(dense: dense, icon: Icons.gesture, label: 'Assinar', tip: 'Desenhar a sua assinatura e pôr na página', onTap: open ? () => _sign(context) : null),
              sep(),
              ToolButton(
                dense: dense,
                icon: Icons.undo,
                label: 'Desfazer',
                tip: ed?.undoLabel == null ? 'Desfazer (Ctrl+Z)' : 'Desfazer: ${ed!.undoLabel} (Ctrl+Z)',
                onTap: ed != null && ed.canUndo ? session.undo : null,
              ),
              ToolButton(
                dense: dense,
                icon: Icons.redo,
                label: 'Refazer',
                tip: ed?.redoLabel == null ? 'Refazer (Ctrl+Y)' : 'Refazer: ${ed!.redoLabel} (Ctrl+Y)',
                onTap: ed != null && ed.canRedo ? session.redo : null,
              ),
              sep(),
              ToolButton(dense: dense, icon: Icons.zoom_out, label: 'Menos', tip: 'Diminuir o zoom', onTap: open ? () => session.setZoom(session.zoom / 1.2) : null),
              ToolButton(
                dense: dense,
                icon: Icons.fit_screen_outlined,
                label: '${(session.zoom * 100).round()}%',
                tip: 'Voltar para 100%',
                onTap: open ? () => session.setZoom(1) : null,
              ),
              ToolButton(dense: dense, icon: Icons.zoom_in, label: 'Mais', tip: 'Aumentar o zoom', onTap: open ? () => session.setZoom(session.zoom * 1.2) : null),
            ],
          );
        },
      ),
    );
  }

  Widget _side(BuildContext context, bool open) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final sel = session.selection;
    final st = session.shownStyle;
    final textOn = open && (session.tool == EdTool.text || session.editing != null || (sel?.isText ?? false));
    final shapeOn = open && (session.tool.shape || session.tool == EdTool.pen);
    final existing = session.editing?.block ?? sel?.block;
    Widget swatches(int current, ValueChanged<int> onPick, {bool enabled = true}) => Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in _palette)
              InkWell(
                customBorder: const CircleBorder(),
                onTap: enabled ? () => onPick(c) : null,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(c).withValues(alpha: enabled ? 1 : 0.35),
                    shape: BoxShape.circle,
                    border: Border.all(color: (current | 0xFF000000) == c ? cs.primary : cs.outlineVariant, width: (current | 0xFF000000) == c ? 3 : 1),
                  ),
                ),
              ),
          ],
        );
    return Panel(
      motif: 'pages',
      motifAlign: Alignment.topRight,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Editar', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (open) ...[
                    const SectionLabel('Documento'),
                    Text(session.path == null || p.isWithin(Directory.systemTemp.path, session.path!) ? 'PDF da bandeja' : p.basename(session.path!),
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      '${session.editor!.pageCount} ${session.editor!.pageCount == 1 ? 'página' : 'páginas'}'
                      '${session.unsaved ? ' · alterações não salvas' : ''}',
                      style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                  const SectionLabel('Texto'),
                  Choice<int>(
                    key: ValueKey('fam-${st.family}-${existing != null}'),
                    label: 'Fonte',
                    value: st.family == null ? -1 : st.family!.index,
                    options: {
                      if (existing != null) -1: 'Original (${fontDisplayName(existing.first.font)})',
                      for (final f in FontFamily.values) f.index: f.label,
                    },
                    onChanged: !textOn ? (_) {} : (v) => session.restyle((s) => s.family = v < 0 ? null : FontFamily.values[v]),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      IconButton.filledTonal(
                        tooltip: 'Letra menor',
                        onPressed: textOn && st.size > 4 ? () => session.restyle((s) => s.size = math.max(4, s.size - 1)) : null,
                        icon: const Icon(Icons.remove, size: 18),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text('${st.size == st.size.roundToDouble() ? st.size.round() : st.size.toStringAsFixed(1).replaceAll('.', ',')} pt',
                            textAlign: TextAlign.center, style: t.textTheme.titleSmall),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Letra maior',
                        onPressed: textOn && st.size < 144 ? () => session.restyle((s) => s.size = math.min(144, s.size + 1)) : null,
                        icon: const Icon(Icons.add, size: 18),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Negrito',
                        isSelected: st.bold,
                        onPressed: textOn ? () => session.restyle((s) => s.bold = !s.bold) : null,
                        icon: const Icon(Icons.format_bold),
                      ),
                      IconButton(
                        tooltip: 'Itálico',
                        isSelected: st.italic,
                        onPressed: textOn ? () => session.restyle((s) => s.italic = !s.italic) : null,
                        icon: const Icon(Icons.format_italic),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<HAlign>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: HAlign.left, icon: Icon(Icons.format_align_left, size: 18)),
                      ButtonSegment(value: HAlign.center, icon: Icon(Icons.format_align_center, size: 18)),
                      ButtonSegment(value: HAlign.right, icon: Icon(Icons.format_align_right, size: 18)),
                    ],
                    selected: {st.align},
                    onSelectionChanged: textOn ? (v) => session.restyle((s) => s.align = v.first) : null,
                  ),
                  const SizedBox(height: 12),
                  swatches(st.color, (c) => session.restyle((s) => s.color = c), enabled: textOn),
                  const SectionLabel('Traço e formas'),
                  swatches(session.strokeColor, (c) => session.set(() => session.strokeColor = c), enabled: shapeOn),
                  Row(
                    children: [
                      Text('Espessura', style: t.textTheme.bodySmall),
                      Expanded(
                        child: Slider(
                          value: session.strokeWidth,
                          min: 0.5,
                          max: 8,
                          divisions: 15,
                          label: '${session.strokeWidth.toStringAsFixed(1).replaceAll('.', ',')} pt',
                          onChanged: shapeOn ? (v) => session.set(() => session.strokeWidth = v) : null,
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Preencher retângulo e elipse'),
                    value: session.filled,
                    onChanged: shapeOn ? (v) => session.set(() => session.filled = v) : null,
                  ),
                  if (sel != null && session.editing == null) ...[
                    const SectionLabel('Selecionado'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (sel.block != null)
                          FilledButton.tonalIcon(
                            onPressed: () => session.startEdit(sel.page, block: sel.block),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Editar texto'),
                          ),
                        FilledButton.tonalIcon(
                          onPressed: session.deleteSelection,
                          icon: Icon(Icons.delete_outline, size: 18, color: cs.error),
                          label: const Text('Excluir'),
                        ),
                      ],
                    ),
                  ],
                  if (session.notice != null) ...[
                    const SizedBox(height: 14),
                    InfoBox(session.notice!, icon: Icons.info_outline),
                  ],
                  if (!open) ...[
                    const SizedBox(height: 14),
                    const InfoBox(
                      'Edite o PDF como num editor de texto: dois cliques num parágrafo para mudar o que está escrito '
                      '(a quebra de linha se refaz sozinha), arraste para mover, e insira textos, imagens, formas, '
                      'marcações e assinatura. Tudo acontece neste computador.',
                      icon: Icons.edit_document,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (session.error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16)),
              child: Text(session.error!, style: t.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer)),
            ),
          if (open) JobStatusCard(queue: state.queue),
          const SizedBox(height: 10),
          ProcessButton(queue: state.queue, label: 'Salvar PDF', onPressed: () => open ? _save(context) : _open(context)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.session, required this.onOpen});
  final EditorSession session;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final tray = session.state.organizer.pages.length;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_document, size: 64, color: cs.primary),
          const SizedBox(height: 14),
          Text('Editor de PDF', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Solte um PDF aqui ou escolha um arquivo para começar.', style: t.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.folder_open_outlined, size: 18), label: const Text('Abrir PDF…')),
              if (tray > 0)
                FilledButton.tonalIcon(
                  onPressed: session.busy ? null : session.openTray,
                  icon: const Icon(Icons.auto_awesome_motion_outlined, size: 18),
                  label: Text(session.busy ? 'Preparando…' : 'Editar o que está na bandeja ($tray ${tray == 1 ? 'página' : 'páginas'})'),
                ),
            ],
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
}

// -------------------------------------------------------------------- páginas

class _Pages extends StatelessWidget {
  const _Pages({required this.session});
  final EditorSession session;

  @override
  Widget build(BuildContext context) {
    final ed = session.editor!;
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: ColoredBox(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              // Largura da maior página (para a rolagem horizontal no zoom alto).
              width: math.max(box.maxWidth, ed.backend.pageSize(session.focusPage.clamp(0, ed.pageCount - 1)).$1 * session.zoom + 48),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 20),
                itemCount: ed.pageCount,
                itemBuilder: (context, i) {
                  final (w, h) = ed.backend.pageSize(i);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Center(
                      child: SizedBox(width: w * session.zoom, height: h * session.zoom, child: _Page(session: session, index: i)),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatefulWidget {
  const _Page({required this.session, required this.index});
  final EditorSession session;
  final int index;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  /// Arrasto em andamento, em pontos da página.
  Offset? _start, _now;
  bool _moving = false;
  int _corner = -1;
  List<double> _ink = [];
  DateTime _lastDown = DateTime(2000);
  Offset _lastDownAt = Offset.zero;
  TextBlock? _hover;

  EditorSession get s => widget.session;
  int get page => widget.index;
  Offset _pt(Offset local) => local / s.zoom;

  static const _handle = 7.0;

  /// Cantos da seleção: 0 cima-esq, 1 cima-dir, 2 baixo-dir, 3 baixo-esq.
  int _cornerAt(Selection sel, Offset pt) {
    final tol = _handle / s.zoom + 2;
    final corners = [Offset(sel.l, sel.t), Offset(sel.r, sel.t), Offset(sel.r, sel.b), Offset(sel.l, sel.b)];
    for (var i = 0; i < 4; i++) {
      if ((corners[i] - pt).distance <= tol) return i;
    }
    return -1;
  }

  void _down(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    final ed = s.editor;
    if (ed == null) return;
    final pt = _pt(e.localPosition);
    final now = DateTime.now();
    final twice = now.difference(_lastDown).inMilliseconds < 380 && (e.localPosition - _lastDownAt).distance < 6;
    _lastDown = now;
    _lastDownAt = e.localPosition;
    s.focusPage = page;
    if (s.editing != null) {
      s.commitText();
      return; // o primeiro clique fora só fecha a caixa de texto
    }
    final model = ed.page(page);
    switch (s.tool) {
      case EdTool.select:
        final sel = s.selection;
        if (sel != null && sel.page == page && !sel.isText) {
          final c = _cornerAt(sel, pt);
          if (c >= 0) {
            setState(() {
              _corner = c;
              _start = _now = pt;
            });
            return;
          }
        }
        final hit = model.hit(page, pt.dx, pt.dy);
        if (twice && hit != null && hit.isText) {
          s.startEdit(page, block: hit.block);
          return;
        }
        s.set(() => s.selection = hit);
        if (hit != null) {
          setState(() {
            _moving = true;
            _start = _now = pt;
          });
        }
      case EdTool.text:
        final hit = model.hit(page, pt.dx, pt.dy);
        if (hit != null && hit.isText) {
          s.startEdit(page, block: hit.block);
        } else {
          s.startEdit(page, x: pt.dx, y: pt.dy);
        }
      case EdTool.pen:
        setState(() => _ink = [pt.dx, pt.dy]);
      default:
        setState(() => _start = _now = pt);
    }
  }

  void _move(PointerMoveEvent e) {
    final pt = _pt(e.localPosition);
    if (_ink.isNotEmpty) {
      final lx = _ink[_ink.length - 2], ly = _ink[_ink.length - 1];
      if ((Offset(lx, ly) - pt).distance > 0.8) setState(() => _ink.addAll([pt.dx, pt.dy]));
    } else if (_start != null) {
      setState(() => _now = pt);
    }
  }

  /// Retângulo da seleção durante um redimensionamento, mantendo a proporção.
  Rect _resized(Selection sel, int c, Offset now) {
    final anchor = [Offset(sel.r, sel.b), Offset(sel.l, sel.b), Offset(sel.l, sel.t), Offset(sel.r, sel.t)][c];
    final w0 = math.max(1.0, sel.r - sel.l), h0 = math.max(1.0, sel.b - sel.t);
    final k = math.max(0.05, math.max((now.dx - anchor.dx).abs() / w0, (now.dy - anchor.dy).abs() / h0));
    final w = w0 * k, h = h0 * k;
    final left = c == 0 || c == 3 ? anchor.dx - w : anchor.dx;
    final top = c == 0 || c == 1 ? anchor.dy - h : anchor.dy;
    return Rect.fromLTWH(left, top, w, h);
  }

  void _up(PointerUpEvent e) {
    final start = _start, now = _now, sel = s.selection;
    final ink = _ink;
    final moving = _moving, corner = _corner;
    setState(() {
      _start = _now = null;
      _moving = false;
      _corner = -1;
      _ink = [];
    });
    if (ink.length >= 4) {
      s.apply(PathOp(page, PathSpec.ink(ink, stroke: s.strokeColor, width: s.strokeWidth), 'Caneta'));
      return;
    }
    if (start == null || now == null) return;
    final d = now - start;
    if (corner >= 0 && sel != null) {
      final r = _resized(sel, corner, now);
      final k = r.width / math.max(1.0, sel.r - sel.l);
      if ((k - 1).abs() > 0.01) {
        final anchor = [Offset(sel.r, sel.b), Offset(sel.l, sel.b), Offset(sel.l, sel.t), Offset(sel.r, sel.t)][corner];
        s.apply(ScaleOp(page, sel.indices, k, k, anchor.dx, anchor.dy));
        s.set(() => s.selection = Selection(page, sel.indices, r.left, r.top, r.right, r.bottom, kind: sel.kind));
      }
      return;
    }
    if (moving) {
      if (sel != null && d.distance * s.zoom > 3) {
        s.apply(MoveOp(page, sel.indices, d.dx, d.dy));
        final again = s.editor!.page(page).hit(page, (sel.l + sel.r) / 2 + d.dx, (sel.t + sel.b) / 2 + d.dy);
        s.set(() => s.selection = again ?? Selection(page, sel.indices, sel.l + d.dx, sel.t + d.dy, sel.r + d.dx, sel.b + d.dy, block: sel.block, kind: sel.kind));
      }
      return;
    }
    final rect = Rect.fromPoints(start, now);
    final tiny = d.distance < 3;
    switch (s.tool) {
      case EdTool.rect when !tiny:
        s.apply(PathOp(page, PathSpec.rect(rect.left, rect.top, rect.right, rect.bottom, stroke: s.strokeColor, width: s.strokeWidth, fill: s.filled ? s.strokeColor : null), 'Retângulo'));
        s.selectLast(page);
      case EdTool.ellipse when !tiny:
        s.apply(PathOp(page, PathSpec.ellipse(rect.left, rect.top, rect.right, rect.bottom, stroke: s.strokeColor, width: s.strokeWidth, fill: s.filled ? s.strokeColor : null), 'Elipse'));
        s.selectLast(page);
      case EdTool.line when !tiny:
        s.apply(PathOp(page, PathSpec.line(start.dx, start.dy, now.dx, now.dy, stroke: s.strokeColor, width: s.strokeWidth), 'Linha'));
        s.selectLast(page);
      case EdTool.arrow when !tiny:
        s.apply(PathOp(page, PathSpec.line(start.dx, start.dy, now.dx, now.dy, stroke: s.strokeColor, width: s.strokeWidth, arrow: true), 'Seta'));
        s.selectLast(page);
      case EdTool.highlight when !tiny:
        s.apply(PathOp(page, PathSpec.rect(rect.left, rect.top, rect.right, rect.bottom, fill: 0x99FFEB3B, multiply: true), 'Marca-texto'));
      case EdTool.whiteout when !tiny:
        s.apply(PathOp(page, PathSpec.rect(rect.left, rect.top, rect.right, rect.bottom, fill: 0xFFFFFFFF), 'Corretivo'));
      default:
        break;
    }
  }

  void _hoverAt(PointerHoverEvent e) {
    final ed = s.editor;
    if (ed == null || (s.tool != EdTool.select && s.tool != EdTool.text) || s.editing != null) {
      if (_hover != null) setState(() => _hover = null);
      return;
    }
    final pt = _pt(e.localPosition);
    final hit = ed.page(page).hit(page, pt.dx, pt.dy);
    final blk = hit?.block;
    if (blk?.first.index != _hover?.first.index) setState(() => _hover = blk);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final image = s.imageFor(page, MediaQuery.devicePixelRatioOf(context));
    final sel = s.selection?.page == page ? s.selection : null;
    final e = s.editing?.page == page ? s.editing : null;
    final z = s.zoom;
    Rect? selRect;
    if (sel != null) {
      selRect = Rect.fromLTRB(sel.l, sel.t, sel.r, sel.b);
      if (_corner >= 0 && _now != null) {
        selRect = _resized(sel, _corner, _now!);
      } else if (_moving && _start != null && _now != null) {
        selRect = selRect.shift(_now! - _start!);
      }
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: MouseRegion(
        cursor: switch (s.tool) {
          EdTool.select => _hover != null || sel != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
          EdTool.text => SystemMouseCursors.text,
          _ => SystemMouseCursors.precise,
        },
        onHover: _hoverAt,
        onExit: (_) {
          if (_hover != null) setState(() => _hover = null);
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (image != null) Positioned.fill(child: RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
              if (image == null) const Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5))),
              Positioned.fill(
                child: CustomPaint(
                  painter: _Overlay(
                    zoom: z,
                    color: cs.primary,
                    selection: selRect,
                    handles: sel != null && !sel.isText,
                    hover: _hover == null || sel?.block?.first.index == _hover!.first.index ? null : Rect.fromLTRB(_hover!.l, _hover!.t, _hover!.r, _hover!.b),
                    drag: _start != null && _now != null && !_moving && _corner < 0 ? (_start!, _now!) : null,
                    tool: s.tool,
                    stroke: Color(s.strokeColor),
                    strokeWidth: s.strokeWidth,
                    filled: s.filled,
                    ink: _ink,
                  ),
                ),
              ),
              if (e != null)
                Positioned(
                  left: e.x * z - 4,
                  top: e.top * z - 3,
                  width: e.width * z + 8,
                  child: Listener(
                    // Cliques dentro da caixa não passam para a página.
                    onPointerDown: (_) {},
                    behavior: HitTestBehavior.opaque,
                    child: _TextBox(session: s, edit: e, zoom: z),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Overlay extends CustomPainter {
  _Overlay({
    required this.zoom,
    required this.color,
    required this.selection,
    required this.handles,
    required this.hover,
    required this.drag,
    required this.tool,
    required this.stroke,
    required this.strokeWidth,
    required this.filled,
    required this.ink,
  });
  final double zoom, strokeWidth;
  final Color color, stroke;
  final Rect? selection, hover;
  final bool handles, filled;
  final (Offset, Offset)? drag;
  final EdTool tool;
  final List<double> ink;

  Rect _z(Rect r) => Rect.fromLTRB(r.left * zoom, r.top * zoom, r.right * zoom, r.bottom * zoom);

  @override
  void paint(Canvas canvas, Size size) {
    final h = hover;
    if (h != null) {
      canvas.drawRect(_z(h).inflate(3), Paint()..color = color.withValues(alpha: 0.07));
      canvas.drawRect(
          _z(h).inflate(3),
          Paint()
            ..color = color.withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }
    final sel = selection;
    if (sel != null) {
      final r = _z(sel).inflate(3);
      canvas.drawRect(
          r,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6);
      if (handles) {
        for (final c in [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]) {
          canvas.drawCircle(c, 5.5, Paint()..color = Colors.white);
          canvas.drawCircle(
              c,
              5.5,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.6);
        }
      }
    }
    final line = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * zoom
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final d = drag;
    if (d != null) {
      final a = d.$1 * zoom, b = d.$2 * zoom;
      final r = Rect.fromPoints(a, b);
      switch (tool) {
        case EdTool.rect:
          if (filled) canvas.drawRect(r, Paint()..color = stroke);
          canvas.drawRect(r, line);
        case EdTool.ellipse:
          if (filled) canvas.drawOval(r, Paint()..color = stroke);
          canvas.drawOval(r, line);
        case EdTool.line || EdTool.arrow:
          canvas.drawLine(a, b, line);
        case EdTool.highlight:
          canvas.drawRect(r, Paint()..color = const Color(0x99FFEB3B));
        case EdTool.whiteout:
          canvas.drawRect(r, Paint()..color = Colors.white);
          canvas.drawRect(
              r,
              Paint()
                ..color = color.withValues(alpha: 0.5)
                ..style = PaintingStyle.stroke);
        default:
          break;
      }
    }
    if (ink.length >= 4) {
      final path = Path()..moveTo(ink[0] * zoom, ink[1] * zoom);
      for (var i = 2; i + 1 < ink.length; i += 2) {
        path.lineTo(ink[i] * zoom, ink[i + 1] * zoom);
      }
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(_Overlay old) => true;
}

/// Caixa de digitação sobre a página, com a letra no tamanho e na cor do texto.
class _TextBox extends StatelessWidget {
  const _TextBox({required this.session, required this.edit, required this.zoom});
  final EditorSession session;
  final TextEdit edit;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = edit.style;
    final family = st.family ?? (edit.block == null ? FontFamily.sans : familyOf(edit.block!.first.font));
    final leading = edit.block != null && edit.block!.lines.length > 1 ? edit.block!.leading / edit.block!.size : 1.2;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): session.cancelText,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): session.commitText,
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: cs.primary, width: 1.6),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8)],
        ),
        child: TextField(
          controller: edit.controller,
          focusNode: edit.focus,
          maxLines: null,
          autofocus: true,
          cursorColor: cs.primary,
          textAlign: switch (st.align) { HAlign.left => TextAlign.left, HAlign.center => TextAlign.center, HAlign.right => TextAlign.right },
          style: TextStyle(
            fontFamily: switch (family) { FontFamily.sans => 'Arial', FontFamily.serif => 'Times New Roman', FontFamily.mono => 'Courier New' },
            fontSize: st.size * zoom,
            height: leading,
            color: Color(st.color | 0xFF000000),
            fontWeight: st.bold ? FontWeight.w700 : FontWeight.w400,
            fontStyle: st.italic ? FontStyle.italic : FontStyle.normal,
          ),
          decoration: const InputDecoration.collapsed(hintText: 'Digite aqui'),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ assinatura

class _SignDialog extends StatefulWidget {
  const _SignDialog();

  @override
  State<_SignDialog> createState() => _SignDialogState();
}

class _SignDialogState extends State<_SignDialog> {
  final List<List<double>> _strokes = [];
  static const _w = 460.0, _h = 180.0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Desenhe a sua assinatura'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _w,
            height: _h,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: cs.outlineVariant)),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => setState(() => _strokes.add([e.localPosition.dx, e.localPosition.dy])),
              onPointerMove: (e) {
                if (_strokes.isEmpty) return;
                final x = e.localPosition.dx.clamp(0.0, _w), y = e.localPosition.dy.clamp(0.0, _h);
                setState(() => _strokes.last.addAll([x, y]));
              },
              child: CustomPaint(painter: _SignPainter(_strokes)),
            ),
          ),
          const SizedBox(height: 8),
          Text('Use o mouse ou a caneta. Ela entra na página como um desenho, que dá para mover e redimensionar.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
      actions: [
        TextButton(onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear), child: const Text('Limpar')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _strokes.isEmpty
              ? null
              : () {
                  // Recorta na área usada e devolve em pontos (1 px da caixa = 0,75 pt).
                  var l = double.infinity, t = double.infinity, r = 0.0, b = 0.0;
                  for (final s in _strokes) {
                    for (var i = 0; i + 1 < s.length; i += 2) {
                      l = math.min(l, s[i]);
                      r = math.max(r, s[i]);
                      t = math.min(t, s[i + 1]);
                      b = math.max(b, s[i + 1]);
                    }
                  }
                  const k = 0.75;
                  Navigator.pop(context, (
                    [
                      for (final s in _strokes) [for (var i = 0; i < s.length; i++) (s[i] - (i.isEven ? l : t)) * k],
                    ],
                    (r - l) * k,
                    (b - t) * k,
                  ));
                },
          child: const Text('Pôr na página'),
        ),
      ],
    );
  }
}

class _SignPainter extends CustomPainter {
  _SignPainter(this.strokes);
  final List<List<double>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0B2A6F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in strokes) {
      if (s.length < 4) {
        if (s.length == 2) canvas.drawCircle(Offset(s[0], s[1]), 1, paint);
        continue;
      }
      final path = Path()..moveTo(s[0], s[1]);
      for (var i = 2; i + 1 < s.length; i += 2) {
        path.lineTo(s[i], s[i + 1]);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SignPainter old) => true;
}
