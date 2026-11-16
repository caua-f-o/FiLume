import 'package:flutter/foundation.dart';

import 'ffmpeg.dart';
import 'modules.dart';
import 'update.dart';

enum ModulePhase { idle, downloading, extracting, failed }

class ModuleStatus {
  ModulePhase phase = ModulePhase.idle;
  String? error;
  int received = 0, total = 0;
  bool cancel = false;

  bool get busy => phase == ModulePhase.downloading || phase == ModulePhase.extracting;
}

/// Estado dos módulos, compartilhado pelos Ajustes e pelo Conversor.
class ModuleManager extends ChangeNotifier {
  /// O que está publicado; null enquanto ninguém consultou.
  Map<String, ModuleRelease>? catalog;
  String? catalogError;
  bool checking = false;

  /// Muda a cada instalação ou remoção (quem usa os módulos refaz a detecção).
  int revision = 0;

  final _status = <String, ModuleStatus>{};
  final _installed = <String, String?>{};

  ModuleStatus status(ModuleSpec spec) => _status.putIfAbsent(spec.id, ModuleStatus.new);

  /// Versão instalada (null = não instalado).
  String? installed(ModuleSpec spec) => _installed.putIfAbsent(spec.id, () => installedModuleVersion(spec));

  bool get anyBusy => _status.values.any((s) => s.busy);

  /// Há versão publicada diferente da instalada?
  bool updateAvailable(ModuleSpec spec) {
    final have = installed(spec), pub = catalog?[spec.id];
    return have != null && pub != null && pub.version != have;
  }

  /// Consulta a lista publicada no repositório.
  Future<bool> refresh() async {
    if (checking) return false;
    checking = true;
    catalogError = null;
    notifyListeners();
    try {
      catalog = await fetchModuleCatalog();
      return true;
    } on UpdateError catch (e) {
      catalogError = e.message;
    } catch (e) {
      catalogError = 'Não foi possível consultar os módulos: $e';
    } finally {
      checking = false;
      notifyListeners();
    }
    return false;
  }

  /// Baixa e instala (ou atualiza) um módulo.
  Future<bool> install(ModuleSpec spec) async {
    final st = status(spec);
    if (st.busy) return false;
    st
      ..phase = ModulePhase.downloading
      ..error = null
      ..received = 0
      ..total = 0
      ..cancel = false;
    notifyListeners();
    try {
      // Sempre consulta de novo: a lista guardada pode apontar para um pacote que já foi trocado.
      await refresh();
      if (catalog == null) throw UpdateError(catalogError ?? 'Não foi possível consultar os módulos.');
      final release = catalog?[spec.id];
      if (release == null) throw UpdateError('Este módulo ainda não foi publicado no repositório.');
      st.total = release.size;
      var last = DateTime.now();
      await installModule(
        spec,
        release,
        canceled: () => st.cancel,
        onProgress: (got, all) {
          st.received = got;
          st.total = all;
          final now = DateTime.now();
          if (now.difference(last).inMilliseconds > 150) {
            last = now;
            notifyListeners();
          }
        },
        onExtracting: () {
          st.phase = ModulePhase.extracting;
          notifyListeners();
        },
      );
      st.phase = ModulePhase.idle;
      _installed.remove(spec.id);
      revision++;
      notifyListeners();
      return true;
    } on JobCanceled {
      st.phase = ModulePhase.idle;
    } on UpdateError catch (e) {
      st
        ..phase = ModulePhase.failed
        ..error = e.message;
    } catch (e) {
      st
        ..phase = ModulePhase.failed
        ..error = 'A instalação do módulo falhou: $e';
    }
    _installed.remove(spec.id);
    notifyListeners();
    return false;
  }

  void cancel(ModuleSpec spec) => status(spec).cancel = true;

  bool remove(ModuleSpec spec) {
    final st = status(spec);
    if (st.busy) return false;
    try {
      removeModule(spec);
      st
        ..phase = ModulePhase.idle
        ..error = null;
      return true;
    } on UpdateError catch (e) {
      st
        ..phase = ModulePhase.failed
        ..error = e.message;
      return false;
    } finally {
      _installed.remove(spec.id);
      revision++;
      notifyListeners();
    }
  }
}
