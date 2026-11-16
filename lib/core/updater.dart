import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'update.dart';
import 'version.dart';

enum UpdatePhase { idle, checking, upToDate, available, downloading, extracting, ready, failed }

/// Estado da atualização, compartilhado pela tela de ajustes e pelo aviso na abertura.
class Updater extends ChangeNotifier {
  UpdatePhase phase = UpdatePhase.idle;
  ReleaseInfo? release;
  String? error;
  int received = 0, total = 0;
  bool _cancel = false;

  /// Pasta com a versão nova já descompactada, pronta para instalar.
  String? staged;

  Version get current => Version.parse(appVersion)!;

  bool get busy => phase == UpdatePhase.checking || phase == UpdatePhase.downloading || phase == UpdatePhase.extracting;

  void _set(UpdatePhase p, {String? err}) {
    phase = p;
    error = err;
    notifyListeners();
  }

  /// Consulta o repositório. Devolve true se há versão mais nova.
  Future<bool> check({required bool beta}) async {
    if (busy) return false;
    _set(UpdatePhase.checking);
    try {
      final r = await fetchLatest(beta: beta);
      release = r;
      staged = null;
      final newer = r != null && r.version > current;
      _set(newer ? UpdatePhase.available : UpdatePhase.upToDate);
      return newer;
    } on UpdateError catch (e) {
      _set(UpdatePhase.failed, err: e.message);
    } catch (e) {
      _set(UpdatePhase.failed, err: 'Não foi possível consultar as atualizações: $e');
    }
    return false;
  }

  /// Baixa e descompacta a versão encontrada.
  Future<bool> download() async {
    final r = release;
    if (r == null || busy) return false;
    if (!Platform.isWindows) {
      _set(UpdatePhase.failed, err: 'A atualização automática existe só no Windows.');
      return false;
    }
    if (!canWriteInstallDir()) {
      _set(UpdatePhase.failed,
          err: 'O FiLume está numa pasta protegida ($installDir) e não pode trocar os próprios arquivos. '
              'Mova a pasta do FiLume para Documentos ou Área de Trabalho, ou baixe a versão nova pelo site.');
      return false;
    }
    _cancel = false;
    received = 0;
    total = r.assetSize;
    _set(UpdatePhase.downloading);
    final work = Directory(updateWorkDir);
    try {
      if (work.existsSync()) work.deleteSync(recursive: true);
      work.createSync(recursive: true);
      final zip = p.join(work.path, updateAsset);
      var last = DateTime.now();
      await downloadRelease(r, zip, canceled: () => _cancel, onProgress: (got, all) {
        received = got;
        total = all;
        final now = DateTime.now();
        if (now.difference(last).inMilliseconds > 150) {
          last = now;
          notifyListeners();
        }
      });
      _set(UpdatePhase.extracting);
      staged = await extractRelease(zip, p.join(work.path, 'novo'));
      try {
        File(zip).deleteSync();
      } catch (_) {}
      _set(UpdatePhase.ready);
      return true;
    } on JobCanceled {
      _set(UpdatePhase.available);
    } on UpdateError catch (e) {
      _set(UpdatePhase.failed, err: e.message);
    } on FileSystemException catch (e) {
      _set(UpdatePhase.failed, err: 'Não foi possível gravar o download (${e.osError?.message ?? e.message}). Há espaço em disco?');
    } catch (e) {
      _set(UpdatePhase.failed, err: 'A atualização falhou: $e');
    }
    return false;
  }

  void cancel() => _cancel = true;

  /// Outros programas do FiLume abertos (precisam fechar para a troca).
  Future<List<String>> othersRunning() async {
    if (!Platform.isWindows) return const [];
    try {
      final r = await runPowershell(
        r"$d = $args[0].TrimEnd('\') + '\'; Get-Process | Where-Object { $_.Id -ne [int]$args[1] -and $_.Path -and "
        r"$_.Path.StartsWith($d, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.MainWindowTitle + '|' + $_.ProcessName }",
        [installDir, '$pid'],
      ).timeout(const Duration(seconds: 15));
      return [
        for (final line in const LineSplitter().convert(r.stdout.toString()))
          if (line.trim().isNotEmpty) line.split('|').firstWhere((s) => s.trim().isNotEmpty, orElse: () => line).trim(),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Inicia a troca dos arquivos. Depois disso o programa deve fechar.
  Future<bool> install() async {
    final s = staged;
    if (s == null) return false;
    try {
      await launchApply(s);
      return true;
    } catch (e) {
      _set(UpdatePhase.failed, err: 'Não foi possível iniciar a instalação: $e');
      return false;
    }
  }
}
