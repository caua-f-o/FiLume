// Teste da digitalização própria: dart run tool/scan_test.dart
// Confere a leitura de mDNS e um ciclo eSCL completo contra um scanner de
// mentira; no Windows, lista também os scanners WIA de verdade.
import 'dart:io';
import 'dart:typed_data';
import 'package:filume/core/scan.dart';

List<int> _n(String name) => [
      for (final l in name.split('.')) ...[l.length, ...l.codeUnits],
      0,
    ];
List<int> _rr(String name, int type, List<int> data) =>
    [..._n(name), 0, type, 0, 1, 0, 0, 0, 120, data.length >> 8, data.length & 255, ...data];

Future<void> main() async {
  var bad = 0;
  void check(String label, bool ok, [String extra = '']) {
    print('${ok ? 'OK' : 'FALHA'} $label $extra');
    if (!ok) bad++;
  }

  // ---- mDNS
  final q = EsclScanner.buildQuery();
  check('pergunta mDNS', q.length > 12 && q[5] == 2);
  const inst = 'Canon G3010._uscan._tcp.local';
  final txt = [for (final kv in ['ty=Canon G3010 series', 'rs=/eSCL/']) ...[kv.length, ...kv.codeUnits]];
  final pkt = Uint8List.fromList([
    0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 3,
    ..._rr('_uscan._tcp.local', 12, _n(inst)),
    ..._rr(inst, 33, [0, 0, 0, 0, 0x1F, 0x90, ..._n('canon.local')]),
    ..._rr(inst, 16, txt),
    ..._rr('canon.local', 1, [192, 168, 0, 25]),
  ]);
  final devs = EsclScanner.parseResponse(pkt, '10.0.0.9');
  check('resposta mDNS', devs.length == 1 && devs[0].id == 'http://192.168.0.25:8080/eSCL' && devs[0].name == 'Canon G3010 series',
      devs.map((d) => '${d.name} ${d.id}').join());
  check('pacote lixo não derruba', EsclScanner.parseResponse(Uint8List.fromList(List.filled(40, 0xC0)), 'x').isEmpty);

  // ---- eSCL contra um scanner de mentira (3 folhas no alimentador)
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var sheets = 3, busy = 1;
  String? posted;
  var deleted = false;
  server.listen((r) async {
    final path = r.uri.path;
    if (r.method == 'GET' && path == '/eSCL/ScannerCapabilities') {
      r.response.write('<scan:ScannerCapabilities><pwg:MakeAndModel>Falso 3000</pwg:MakeAndModel></scan:ScannerCapabilities>');
    } else if (r.method == 'POST' && path == '/eSCL/ScanJobs') {
      posted = await r.cast<List<int>>().transform(const SystemEncoding().decoder).join();
      r.response.statusCode = 201;
      r.response.headers.set('Location', '/eSCL/ScanJobs/abc');
    } else if (r.method == 'GET' && path == '/eSCL/ScanJobs/abc/NextDocument') {
      if (busy-- > 0) {
        r.response.statusCode = 503;
      } else if (sheets-- > 0) {
        r.response.headers.contentType = ContentType('image', 'jpeg');
        r.response.add([0xFF, 0xD8, 0xFF, 0xD9]);
      } else {
        r.response.statusCode = 404;
      }
    } else if (r.method == 'DELETE') {
      deleted = true;
    } else {
      r.response.statusCode = 404;
    }
    await r.response.close();
  });
  final scanner = Scanner();
  final dev = await scanner.esclAt('127.0.0.1:${server.port}');
  check('scanner pelo endereço', dev.name == 'Falso 3000', dev.id);
  final live = <String>[];
  final pages = await scanner.scan(
      ScanSettings()
        ..driver = 'escl'
        ..device = dev.id
        ..source = 'feeder'
        ..dpi = 200
        ..color = 'gray',
      onPage: live.add);
  check('alimentador: 3 páginas, uma a uma', pages.length == 3 && live.length == 3 && pages.every((f) => File(f).lengthSync() == 4));
  check('opções enviadas', posted != null && posted!.contains('<pwg:InputSource>Feeder') && posted!.contains('Grayscale8') && posted!.contains('<scan:XResolution>200'));
  sheets = 5;
  busy = 0;
  final one = await scanner.scan(ScanSettings()
    ..driver = 'escl'
    ..device = dev.id);
  check('vidro: só 1 página', one.length == 1);
  sheets = 0;
  try {
    await scanner.scan(ScanSettings()
      ..driver = 'escl'
      ..device = dev.id
      ..source = 'feeder');
    check('alimentador vazio', false);
  } on ScanError catch (e) {
    check('alimentador vazio', e.message.contains('Sem papel'), e.message);
  }
  try {
    await scanner.esclAt('127.0.0.1:1');
    check('endereço errado', false);
  } on ScanError {
    check('endereço errado recusado', true);
  }
  check('sem DELETE sem cancelar', !deleted);
  await server.close(force: true);

  // ---- de verdade, no que esta máquina tiver
  try {
    final net = await EsclScanner.discover();
    print('rede: ${net.isEmpty ? 'nenhum scanner respondeu' : net.map((d) => '${d.name} @ ${d.id}').join('; ')}');
  } catch (e) {
    print('rede: busca falhou: $e');
  }
  if (Platform.isWindows) {
    try {
      final wia = await WiaScanner.devices();
      print('WIA: script rodou; ${wia.isEmpty ? 'nenhum scanner instalado' : wia.map((d) => d.name).join('; ')}');
    } catch (e) {
      print('WIA: $e');
    }
  }
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
