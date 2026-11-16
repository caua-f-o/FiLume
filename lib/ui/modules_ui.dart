import 'package:flutter/material.dart';

import '../core/ffmpeg.dart' show revealInFileManager;
import '../core/format.dart';
import '../core/module_manager.dart';
import '../core/modules.dart';
import '../core/state.dart';

String _sizeLabel(ModuleManager m, ModuleSpec spec) {
  final pub = m.catalog?[spec.id];
  return pub != null ? fmtBytes(pub.size) : 'cerca de ${spec.approxMb} MB';
}

/// Barra de andamento do download de um módulo, com o botão de cancelar.
class _ModuleProgress extends StatelessWidget {
  const _ModuleProgress({required this.manager, required this.spec});
  final ModuleManager manager;
  final ModuleSpec spec;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final st = manager.status(spec);
    final extracting = st.phase == ModulePhase.extracting;
    final frac = extracting || st.total <= 0 ? null : st.received / st.total;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: frac, borderRadius: BorderRadius.circular(8), minHeight: 6),
              const SizedBox(height: 6),
              Text(
                extracting
                    ? 'Descompactando…'
                    : st.total > 0
                        ? 'Baixando: ${fmtBytes(st.received)} de ${fmtBytes(st.total)}'
                        : 'Consultando o repositório…',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (!extracting) ...[
          const SizedBox(width: 10),
          TextButton(onPressed: () => manager.cancel(spec), child: const Text('Cancelar')),
        ],
      ],
    );
  }
}

/// Cartão "Módulos" dos Ajustes.
class ModulesSection extends StatelessWidget {
  const ModulesSection({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final m = state.modules;
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Módulos', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'Ferramentas grandes que nem todo mundo usa. Não vêm no pacote do FiLume: você baixa só as que quiser, '
              'direto do repositório no GitHub. Ficam numa pasta própria e continuam instaladas quando o FiLume é atualizado.',
              style: small,
            ),
            for (final spec in knownModules) ...[
              const SizedBox(height: 14),
              _ModuleTile(manager: m, spec: spec),
            ],
            const SizedBox(height: 14),
            if (m.catalogError != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(m.catalogError!, style: t.textTheme.bodyMedium?.copyWith(color: cs.error))),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: m.checking || m.anyBusy ? null : m.refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(m.checking ? 'Consultando…' : 'Procurar versões novas dos módulos'),
                ),
                TextButton.icon(
                  onPressed: () => revealInFileManager(modulesDir),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Abrir a pasta dos módulos'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({required this.manager, required this.spec});
  final ModuleManager manager;
  final ModuleSpec spec;

  Future<void> _remove(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remover o módulo "${spec.name}"?'),
        content: const Text('Os arquivos do módulo são apagados deste computador. Dá para baixar de novo quando quiser.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remover')),
        ],
      ),
    );
    if (ok == true) manager.remove(spec);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final st = manager.status(spec);
    final have = manager.installed(spec);
    final update = manager.updateAvailable(spec);
    final small = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 13);
    final String line;
    if (have == null) {
      line = 'Não instalado · download de ${_sizeLabel(manager, spec)}';
    } else if (update) {
      line = 'Instalado (versão $have) · há a versão ${manager.catalog![spec.id]!.version}, ${_sizeLabel(manager, spec)}';
    } else {
      line = 'Instalado (versão $have) · ocupa ${fmtBytes(moduleDiskSize(spec))}';
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(have == null ? Icons.extension_outlined : Icons.extension, size: 20, color: cs.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(spec.name, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(spec.summary, style: small),
                    const SizedBox(height: 4),
                    Text(line, style: small),
                  ],
                ),
              ),
              if (!st.busy) ...[
                const SizedBox(width: 12),
                if (have == null)
                  FilledButton.icon(
                    onPressed: () => manager.install(spec),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Baixar'),
                  )
                else ...[
                  if (update)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilledButton.tonal(onPressed: () => manager.install(spec), child: const Text('Atualizar')),
                    ),
                  TextButton(onPressed: () => _remove(context), child: const Text('Remover')),
                ],
              ],
            ],
          ),
          if (st.busy) ...[const SizedBox(height: 12), _ModuleProgress(manager: manager, spec: spec)],
          if (st.phase == ModulePhase.failed && st.error != null) ...[
            const SizedBox(height: 10),
            Text(st.error!, style: t.textTheme.bodySmall?.copyWith(color: cs.error)),
          ],
        ],
      ),
    );
  }
}

/// Oferta de um módulo dentro de uma ferramenta: explica para que serve e
/// baixa ali mesmo. Some quando o módulo já está instalado.
class ModuleOffer extends StatelessWidget {
  const ModuleOffer({super.key, required this.state, required this.spec, required this.text, this.onDismiss});
  final AppState state;
  final ModuleSpec spec;

  /// Por que o módulo ajuda nesta situação.
  final String text;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final m = state.modules;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        if (m.installed(spec) != null) return const SizedBox.shrink();
        final st = m.status(spec);
        final on = cs.onSecondaryContainer;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(color: cs.secondaryContainer.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.extension_outlined, size: 20, color: on),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Módulo "${spec.name}"', style: t.textTheme.labelLarge?.copyWith(color: on)),
                        const SizedBox(height: 2),
                        Text(text, style: t.textTheme.bodySmall?.copyWith(color: on)),
                      ],
                    ),
                  ),
                  if (!st.busy) ...[
                    const SizedBox(width: 10),
                    if (onDismiss != null) TextButton(onPressed: onDismiss, child: const Text('Agora não')),
                    FilledButton.tonalIcon(
                      onPressed: () => m.install(spec),
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(st.phase == ModulePhase.failed ? 'Tentar de novo' : 'Baixar (${_sizeLabel(m, spec)})'),
                    ),
                  ],
                ],
              ),
              if (st.busy) ...[const SizedBox(height: 10), _ModuleProgress(manager: m, spec: spec)],
              if (st.phase == ModulePhase.failed && st.error != null) ...[
                const SizedBox(height: 8),
                Text(st.error!, style: t.textTheme.bodySmall?.copyWith(color: cs.error)),
              ],
            ],
          ),
        );
      },
    );
  }
}
