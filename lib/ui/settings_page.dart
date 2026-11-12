import 'package:flutter/material.dart';

import '../core/prefs.dart';
import 'home_widgets.dart';
import 'theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.prefs, this.extra, this.mainApp = true});
  final Prefs prefs;

  /// Seção a mais, mostrada antes das outras (pastas do FiLume PDF).
  final Widget? extra;

  /// Falso no FiLume PDF: esconde o que só vale para o app principal.
  final bool mainApp;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 8, 32, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ajustes',
              style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
            ),
            const SizedBox(height: 4),
            Text('As mudanças valem na hora e ficam guardadas neste computador.',
                style: t.textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 24),
            if (extra != null) ...[extra!, const SizedBox(height: 16)],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Section(
                        title: 'Tema',
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SegmentedButton<String>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: 'system', label: Text('Sistema')),
                              ButtonSegment(value: 'light', label: Text('Claro')),
                              ButtonSegment(value: 'dark', label: Text('Escuro')),
                            ],
                            selected: {prefs.theme},
                            onSelectionChanged: (s) => prefs.update(() => prefs.theme = s.first),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _Section(
                        title: 'Cores',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: _mode('tool', 'Uma cor por ferramenta',
                                      'PDF, Vídeo, Áudio e Imagem ganham cada um a sua cor.'),
                                ),
                                const SizedBox(width: 10),
                                Expanded(child: _mode('static', 'Padrão FiLume', 'Verde-vagalume em tudo.')),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: _mode(
                                    'system',
                                    'Cores do computador',
                                    prefs.systemAccent == null
                                        ? 'Segue a cor de destaque do Windows. Não foi possível lê-la agora; '
                                            'fica o verde do FiLume.'
                                        : 'Segue a cor de destaque do Windows.',
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(child: _mode('material', 'Paleta Material', 'Escolha uma das paletas abaixo.')),
                              ],
                            ),
                            if (prefs.colorMode == 'material') ...[
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text('Paleta', style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                                  for (final e in materialPalettes.entries)
                                    _Swatch(
                                      label: e.value.$1,
                                      color: buildTheme(e.value.$2, t.brightness).colorScheme.primary,
                                      selected: prefs.palette == e.key,
                                      onTap: () => prefs.update(() => prefs.palette = e.key),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (mainApp) ...[
                      const SizedBox(height: 16),
                      _Section(
                        title: 'Ao abrir o FiLume',
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SegmentedButton<String>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: 'home', label: Text('Tela inicial')),
                              ButtonSegment(value: 'last', label: Text('Última ferramenta')),
                            ],
                            selected: {prefs.startPage},
                            onSelectionChanged: (s) => prefs.update(() => prefs.startPage = s.first),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _Section(
                        title: 'Guardar arquivos recentes',
                        trailing: Switch(
                          value: prefs.keepRecents,
                          onChanged: (v) => prefs.update(() {
                            prefs.keepRecents = v;
                            if (!v) prefs.recents.clear();
                          }),
                        ),
                        child: Text(
                          'A lista fica só neste computador. Desligar apaga o histórico.',
                          style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13),
                        ),
                      ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: _Preview(prefs: prefs)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mode(String id, String label, String desc) => _ModeCard(
        label: label,
        desc: desc,
        selected: prefs.colorMode == id,
        onTap: () => prefs.update(() => prefs.colorMode = id),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(24)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                SizedBox(height: trailing == null ? 14 : 4),
                child,
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 16), trailing!],
        ],
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.label, required this.desc, required this.selected, required this.onTap});
  final String label, desc;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.onPrimaryContainer : cs.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? cs.primaryContainer : cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: selected ? cs.primary : cs.outlineVariant, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
                const SizedBox(height: 6),
                Text(desc, style: TextStyle(fontSize: 13, height: 1.4, color: fg.withValues(alpha: 0.85))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.label, required this.color, required this.selected, required this.onTap});
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(selected ? 14 : 22),
              border: Border.all(color: selected ? cs.onSurface : Colors.transparent, width: 3),
            ),
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.prefs});
  final Prefs prefs;

  static const _mods = [
    ('pdf', 'PDF Estúdio', Icons.picture_as_pdf_outlined, 'pages'),
    ('video', 'Vídeo', Icons.videocam_outlined, 'video'),
    ('audio', 'Áudio', Icons.music_note_outlined, 'audio'),
    ('image', 'Imagem', Icons.image_outlined, 'image'),
    ('files', 'Arquivos', Icons.swap_horiz, 'convert'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Prévia', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          for (final m in _mods) ...[
            Theme(
              data: buildTheme(seedFor(prefs, m.$1), t.brightness),
              child: Builder(builder: (context) {
                final mcs = Theme.of(context).colorScheme;
                return GeoCard(
                  motif: m.$4,
                  motifSize: 56,
                  motifOffset: const Offset(-8, 0),
                  radius: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(color: mcs.primary, borderRadius: BorderRadius.circular(11)),
                        child: Icon(m.$3, size: 18, color: mcs.onPrimary),
                      ),
                      const SizedBox(width: 12),
                      Text(m.$2, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerLeft, child: FoldButton(label: 'Botão principal', onPressed: () {})),
        ],
      ),
    );
  }
}
