// Teste da ponte de digitalização pelo lado Dart (sem interface):
//   dart run tool/scan_bridge_test.dart
// Precisa do FiPDF.Scan compilado (FILUME_SCAN_EXE). Usa o aparelho de demonstração dele,
// então roda sem scanner nenhum (é o que acontece no build do GitHub).
import 'dart:io';

import 'package:filume/core/scan.dart';
import 'package:filume/core/scan_bridge.dart';

var bad = 0;
void check(String label, bool ok, [String extra = '']) {
  print('${ok ? 'OK' : 'FALHA'} $label ${ok ? '' : extra}');
  if (!ok) bad++;
}

Future<void> main() async {
  final exe = Platform.environment['FILUME_SCAN_EXE'];
  if (exe == null || !File(exe).existsSync()) {
    final must = Platform.environment['FILUME_REQUIRE_SCAN'] == '1';
    print('${must ? 'FALHA' : 'AVISO'}: sem o FiPDF.Scan (FILUME_SCAN_EXE); a ponte não foi testada.');
    exit(must ? 1 : 0);
  }
  final logDir = Platform.environment['FILUME_LOG_DIR'];
  final bridge = ScanBridge(exe: exe, demo: true, pingEvery: const Duration(seconds: 2));
  final scanner = Scanner(bridge: bridge);
  final dir = await Directory.systemTemp.createTemp('filume_bridge_');
  try {
    // ------------------------------------------------------------ subida e lista
    final sw = Stopwatch()..start();
    await bridge.ensure();
    print('  auxiliar pronto em ${sw.elapsedMilliseconds} ms; erros de driver: ${bridge.driverErrors}');
    final demo = bridge.devices.where((d) => d.driver == 'demo').firstOrNull;
    check('a ponte sobe e lista o aparelho de demonstração com URL local',
        demo != null && (demo.url ?? '').startsWith('http://127.0.0.1:'), bridge.devices.map((d) => '${d.id} ${d.url}').join(' | '));
    final local = await scanner.local();
    final dev = local.where((d) => d.driver == 'demo').firstOrNull;
    check('a lista do Scanner mostra o aparelho local com a etiqueta certa', dev != null && dev.viaBridge && dev.tag == 'Demonstração',
        local.map((d) => d.key).join(' | '));

    // --------------------------------------------------------------- digitalizar
    Future<List<String>> scanWith(void Function(ScanSettings s) set) {
      final s = ScanSettings()
        ..driver = 'demo'
        ..device = 'demo:1'
        ..dpi = 300;
      set(s);
      return scanner.scan(s);
    }

    final glass = await scanWith((s) => s.source = 'glass');
    final bytes = glass.isEmpty ? <int>[] : File(glass.first).readAsBytesSync();
    check('pelo vidro: uma página JPEG', glass.length == 1 && bytes.length > 1000 && bytes[0] == 0xFF && bytes[1] == 0xD8, '${glass.length} páginas');

    final auto = await scanWith((s) => s.source = 'auto');
    check('automático: o pedido sai com a origem "Auto" e a página chega', auto.length == 1);
    if (logDir != null) {
      final log = File('$logDir${Platform.pathSeparator}fipdf-scan.log');
      final text = log.existsSync() ? log.readAsStringSync() : '';
      check('o auxiliar recebeu a origem Auto', text.contains('origem Auto'), text.split('\n').where((l) => l.contains('Pedido')).join('\n'));
    }

    final feeder = await scanWith((s) => s.source = 'feeder');
    check('pelo alimentador: a página chega', feeder.length == 1);

    try {
      await scanWith((s) {
        s.source = 'feeder';
        s.duplex = true;
      });
      check('erro do aparelho vira mensagem em português', false, 'não deu erro');
    } on ScanError catch (e) {
      check('erro do aparelho vira mensagem em português', e.message.contains('alimentador está vazio'), e.toString());
    }

    try {
      final s = ScanSettings()
        ..driver = 'wia'
        ..device = 'wia:nao-existe';
      await scanner.scan(s);
      check('aparelho que sumiu: mensagem clara', false);
    } on ScanError catch (e) {
      check('aparelho que sumiu: mensagem clara', e.message.contains('não foi encontrado'), e.toString());
    }

    // ------------------------------------------------- o auxiliar cai e volta
    final first = bridge.processId;
    if (first != null) Process.killPid(first, ProcessSignal.sigkill);
    var back = false;
    for (var i = 0; i < 60 && !back; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      back = bridge.processId != null && bridge.processId != first && bridge.devices.isNotEmpty;
    }
    check('o auxiliar morre e a ponte sobe outro sozinha, com aviso', back && (bridge.notice ?? '').contains('reiniciado'), '${bridge.notice}');
    final again = await scanWith((s) => s.source = 'glass');
    check('depois de reiniciar, digitaliza de novo (porta nova)', again.length == 1);

    final refreshed = await bridge.refresh();
    check('atualizar devolve a lista de novo', refreshed.any((d) => d.driver == 'demo'));
  } finally {
    bridge.stop();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
