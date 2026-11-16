import 'dart:io';

import 'package:flutter/material.dart';

import '../core/ffmpeg.dart' show revealInFileManager;
import '../core/format.dart';
import '../core/state.dart';
import '../core/update.dart';
import '../core/updater.dart';
import '../core/version.dart';

/// Canal em uso: o escolhido nos ajustes ou, sem escolha, o da versão instalada.
bool betaChannel(AppState state) => (state.prefs.updateChannel ?? (Version.parse(appVersion)!.isBeta ? 'beta' : 'stable')) == 'beta';

/// Consulta discreta na abertura (no máximo uma por dia). Só aparece algo se
/// houver versão nova que a pessoa ainda não pediu para pular.
Future<void> checkUpdatesOnStart(BuildContext context, AppState state) async {
  final prefs = state.prefs;
  if (!prefs.updateAuto || !Platform.isWindows) return;
  final last = DateTime.tryParse(prefs.updateLastCheck ?? '');
  if (last != null && DateTime.now().difference(last).inHours < 20) return;
  final newer = await state.updater.check(beta: betaChannel(state));
  if (state.updater.phase != UpdatePhase.failed) {
    prefs.updateLastCheck = DateTime.now().toIso8601String();
    prefs.save();
  }
  final r = state.updater.release;
  if (!newer || r == null || r.version.toString() == prefs.updateSkipped || !context.mounted) return;
  await showUpdateDialog(context, state);
}

/// Janela da atualização: mostra a versão nova, baixa, e instala.
Future<void> showUpdateDialog(BuildContext context, AppState state) =>
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _UpdateDialog(state: state));

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.state});
  final AppState state;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  Updater get up => widget.state.updater;
  List<String> _others = const [];
  bool _installing = false;

  Future<void> _download() async {
    if (await up.download()) await _refreshOthers();
  }

  Future<void> _refreshOthers() async {
    final o = await up.othersRunning();
    if (mounted) setState(() => _others = o);
  }

  Future<void> _install() async {
    setState(() => _installing = true);
    final state = widget.state;
    if (!await up.install()) {
      if (mounted) setState(() => _installing = false);
      return;
    }
    // O script espera este programa fechar para trocar os arquivos.
    state.queue.cancelAll();
    for (var i = 0; i < 30 && state.queue.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    state.cleanup();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return ListenableBuilder(
      listenable: up,
      builder: (context, _) {
        final r = up.release;
        final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
        final Widget body;
        final actions = <Widget>[];
        switch (up.phase) {
          case UpdatePhase.downloading:
            final frac = up.total > 0 ? up.received / up.total : null;
            body = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Baixando a versão ${r?.version}…'),
                const SizedBox(height: 14),
                LinearProgressIndicator(value: frac, borderRadius: BorderRadius.circular(8), minHeight: 8),
                const SizedBox(height: 8),
                Text('${fmtBytes(up.received)} de ${fmtBytes(up.total)}', style: small),
              ],
            );
            actions.add(TextButton(onPressed: up.cancel, child: const Text('Cancelar')));
          case UpdatePhase.extracting:
            body = const Row(children: [
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
              SizedBox(width: 14),
              Expanded(child: Text('Descompactando…')),
            ]);
          case UpdatePhase.ready:
            final busy = widget.state.queue.busy;
            body = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('A versão ${r?.version} está pronta. O FiLume fecha, troca os arquivos da pasta e abre de novo sozinho.'),
                if (_others.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${_others.toSet().length == 1 ? 'Também será fechado' : 'Também serão fechados'}: ${_others.toSet().join(', ')}. '
                    'Se houver algo em andamento ${_others.toSet().length == 1 ? 'nele' : 'neles'}, será interrompido.',
                    style: t.textTheme.bodyMedium?.copyWith(color: cs.error),
                  ),
                ],
                if (busy) ...[
                  const SizedBox(height: 12),
                  Text('Há tarefas em andamento: ao instalar agora elas são canceladas.', style: t.textTheme.bodyMedium?.copyWith(color: cs.error)),
                ],
              ],
            );
            actions
              ..add(TextButton(onPressed: _installing ? null : () => Navigator.pop(context), child: const Text('Depois')))
              ..add(FilledButton(
                onPressed: _installing ? null : _install,
                child: Text(_others.isEmpty ? 'Instalar e reabrir' : 'Fechar tudo e instalar'),
              ));
          case UpdatePhase.failed:
            body = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(up.error ?? 'A atualização falhou.'),
                const SizedBox(height: 10),
                Text('Nada foi alterado na instalação atual.', style: small),
              ],
            );
            actions.add(TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')));
            if (r != null) actions.add(FilledButton.tonal(onPressed: _download, child: const Text('Tentar de novo')));
          default:
            body = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Você tem a $appVersion. O download tem ${r == null ? '?' : fmtBytes(r.assetSize)} e a troca é feita na própria pasta do FiLume.'),
                if (r != null && r.notes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text('O que mudou', style: t.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 220),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(14)),
                    child: SingleChildScrollView(child: Text(_plain(r.notes), style: t.textTheme.bodySmall)),
                  ),
                ],
              ],
            );
            actions
              ..add(TextButton(
                onPressed: () {
                  if (r != null) widget.state.prefs.update(() => widget.state.prefs.updateSkipped = r.version.toString());
                  Navigator.pop(context);
                },
                child: const Text('Pular esta versão'),
              ))
              ..add(TextButton(onPressed: () => Navigator.pop(context), child: const Text('Agora não')))
              ..add(FilledButton(onPressed: r == null ? null : _download, child: const Text('Baixar e instalar')));
        }
        return AlertDialog(
          icon: const Icon(Icons.system_update_alt),
          title: Text(r == null ? 'Atualização' : 'FiLume ${r.version} disponível'),
          content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460, minWidth: 380), child: body),
          actions: actions,
        );
      },
    );
  }
}

/// Notas da versão sem a marcação do Markdown (títulos, negrito, links).
String _plain(String md) => md
    .replaceAll('\r\n', '\n')
    .replaceAllMapped(RegExp(r'^#{1,6}\s*(.+)$', multiLine: true), (m) => m[1]!.toUpperCase())
    .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'^[-*]\s+', multiLine: true), (m) => '• ')
    .replaceAll('`', '')
    .trim();

/// Cartão "Atualizações" dos Ajustes.
class UpdateSection extends StatelessWidget {
  const UpdateSection({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final prefs = state.prefs, up = state.updater;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    return ListenableBuilder(
      listenable: Listenable.merge([up, prefs]),
      builder: (context, _) {
        final beta = betaChannel(state);
        final r = up.release;
        final (IconData icon, String status) = switch (up.phase) {
          UpdatePhase.checking => (Icons.sync, 'Consultando o repositório…'),
          UpdatePhase.upToDate => (
              Icons.check_circle_outline,
              r != null && up.current > r.version
                  ? 'Você está na $appVersion, mais nova que a última ${beta ? 'publicada' : 'estável'} (${r.version}).'
                  : 'Você já tem a versão mais nova deste canal.'
            ),
          UpdatePhase.available || UpdatePhase.ready => (Icons.system_update_alt, 'Versão ${r?.version} disponível.'),
          UpdatePhase.downloading || UpdatePhase.extracting => (Icons.downloading, 'Baixando a versão ${r?.version}…'),
          UpdatePhase.failed => (Icons.error_outline, up.error ?? 'Não foi possível consultar.'),
          UpdatePhase.idle => (Icons.info_outline, 'Versão instalada: $appVersion.'),
        };
        final offer = up.phase == UpdatePhase.available || up.phase == UpdatePhase.ready || up.phase == UpdatePhase.downloading || up.phase == UpdatePhase.extracting;
        return Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(24)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Atualizações', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                  Text('FiLume $appVersion', style: small),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'O FiLume consulta as versões publicadas no GitHub, baixa o pacote e troca os arquivos desta pasta. '
                'Só a consulta e o download usam a internet; nenhum arquivo seu é enviado.',
                style: small,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 16,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, label: Text('Estável')),
                      ButtonSegment(value: true, label: Text('Beta')),
                    ],
                    selected: {beta},
                    onSelectionChanged: up.busy
                        ? null
                        : (s) {
                            prefs.update(() => prefs.updateChannel = s.first ? 'beta' : 'stable');
                            up.check(beta: s.first);
                          },
                  ),
                  Text(
                    beta ? 'Recebe as novidades antes; pode ter falhas.' : 'Só versões finais, mais testadas.',
                    style: small,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Procurar atualizações ao abrir'),
                subtitle: const Text('No máximo uma consulta por dia.'),
                value: prefs.updateAuto,
                onChanged: (v) => prefs.update(() => prefs.updateAuto = v),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 18, color: up.phase == UpdatePhase.failed ? cs.error : cs.primary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(status, style: t.textTheme.bodyMedium?.copyWith(color: up.phase == UpdatePhase.failed ? cs.error : null))),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (offer)
                    FilledButton.icon(
                      onPressed: () => showUpdateDialog(context, state),
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(up.phase == UpdatePhase.ready ? 'Instalar a ${r?.version}' : 'Ver e baixar a ${r?.version}'),
                    ),
                  FilledButton.tonalIcon(
                    onPressed: up.busy
                        ? null
                        : () async {
                            prefs.update(() => prefs.updateSkipped = null);
                            await up.check(beta: beta);
                          },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Procurar agora'),
                  ),
                  TextButton.icon(
                    onPressed: () => revealInFileManager(installDir),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Abrir a pasta do FiLume'),
                  ),
                ],
              ),
              if (!Platform.isWindows) ...[
                const SizedBox(height: 8),
                Text('A instalação automática existe só no Windows.', style: small),
              ],
            ],
          ),
        );
      },
    );
  }
}
