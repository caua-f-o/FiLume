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
  var sheets = 3, busy = 1, refuseRegions = false, hasAdf = true;
  final posts = <String>[];
  var glassLeft = 1, late404 = 0, lieEmpty = false, hateDuplexTag = false;
  String? posted;
  server.listen((r) async {
    final path = r.uri.path;
    if (r.method == 'GET' && path == '/eSCL/ScannerCapabilities') {
      r.response.write('<scan:ScannerCapabilities><pwg:MakeAndModel>Falso 3000</pwg:MakeAndModel>'
          '<scan:Platen><scan:PlatenInputCaps><scan:MaxWidth>2550</scan:MaxWidth><scan:MaxHeight>3508</scan:MaxHeight>'
          '<scan:ColorMode>RGB24</scan:ColorMode><scan:ColorMode>Grayscale8</scan:ColorMode><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>'
          '<scan:XResolution>100</scan:XResolution><scan:XResolution>300</scan:XResolution></scan:PlatenInputCaps></scan:Platen>'
          '${hasAdf ? '<scan:Adf><scan:AdfSimplexInputCaps><scan:MaxWidth>2550</scan:MaxWidth><scan:MaxHeight>4200</scan:MaxHeight>'
              '<scan:ColorMode>Grayscale8</scan:ColorMode><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>'
              '<scan:XResolution>150</scan:XResolution><scan:XResolution>300</scan:XResolution></scan:AdfSimplexInputCaps></scan:Adf>' : ''}'
          '</scan:ScannerCapabilities>');
    } else if (r.method == 'GET' && path == '/eSCL/ScannerStatus') {
      r.response.write('<scan:ScannerStatus><pwg:State>Idle</pwg:State>'
          '${hasAdf ? '<scan:AdfState>${sheets > 0 && !lieEmpty ? 'ScannerAdfLoaded' : 'ScannerAdfEmpty'}</scan:AdfState>' : ''}</scan:ScannerStatus>');
    } else if (r.method == 'POST' && path == '/eSCL/ScanJobs') {
      posted = await r.cast<List<int>>().transform(const SystemEncoding().decoder).join();
      posts.add(posted!);
      glassLeft = 1;
      if (refuseRegions && posted!.contains('ScanRegions')) {
        r.response.statusCode = 409;
      } else {
        r.response.statusCode = 201;
        r.response.headers.set('Location', '/eSCL/ScanJobs/abc');
      }
    } else if (r.method == 'GET' && path == '/eSCL/ScanJobs/abc/NextDocument') {
      if (busy-- > 0) {
        r.response.statusCode = 503;
      } else if (late404-- > 0 || (hateDuplexTag && posted!.contains('Duplex'))) {
        r.response.statusCode = 404;
      } else if (posted!.contains('Platen') ? glassLeft-- > 0 : sheets-- > 0) {
        r.response.headers.contentType = ContentType('image', 'jpeg');
        r.response.add([0xFF, 0xD8, 0xFF, 0xD9]);
      } else {
        r.response.statusCode = 404;
      }
    } else if (r.method == 'DELETE') {
      // trabalho descartado
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
  check('opções ajustadas ao scanner (150 dpi mais próximo de 200, área do alimentador)',
      posted != null && posted!.contains('<pwg:InputSource>Feeder') && posted!.contains('Grayscale8') && posted!.contains('<scan:XResolution>150') && posted!.contains('<pwg:Height>4200') && posted!.contains('<scan:Duplex>false'));
  sheets = 2;
  busy = 0;
  final auto = await scanner.scan(ScanSettings()
    ..driver = 'escl'
    ..device = dev.id);
  check('automático com papel no alimentador: usa o alimentador', auto.length == 2 && posted!.contains('Feeder'));
  final autoGlass = await scanner.scan(ScanSettings()
    ..driver = 'escl'
    ..device = dev.id);
  check('automático sem papel: vai de vidro', autoGlass.length == 1 && posted!.contains('Platen'));
  refuseRegions = true;
  posts.clear();
  sheets = 1;
  final retry = await scanner.scan(ScanSettings()
    ..driver = 'escl'
    ..device = dev.id
    ..source = 'feeder');
  check('recusa da área: tenta de novo sem ela', retry.length == 1 && posts.length == 2 && !posts.last.contains('ScanRegions'));
  refuseRegions = false;
  try {
    sheets = 2;
    await scanner.scan(ScanSettings()
      ..driver = 'escl'
      ..device = dev.id
      ..source = 'feeder'
      ..duplex = true);
    check('frente e verso sem suporte', false);
  } on ScanError catch (e) {
    check('frente e verso sem suporte avisa', e.message.contains('frente e verso'));
  }
  // Manias de scanners de verdade no alimentador
  Future<List<String>> feed() => scanner.scan(ScanSettings()
    ..driver = 'escl'
    ..device = dev.id
    ..source = 'feeder');
  sheets = 2;
  late404 = 3;
  check('404 enquanto puxa a 1ª folha: insiste e digitaliza', (await feed()).length == 2);
  late404 = 0;
  sheets = 2;
  lieEmpty = true;
  check('scanner diz "vazio" com papel: tenta mesmo assim', (await feed()).length == 2);
  lieEmpty = false;
  sheets = 2;
  hateDuplexTag = true;
  posts.clear();
  check('pedido completo não rende página: cai para o mínimo', (await feed()).length == 2 && !posts.last.contains('Duplex'), '(${posts.length} pedidos)');
  hateDuplexTag = false;
  hasAdf = false;
  try {
    await scanner.scan(ScanSettings()
      ..driver = 'escl'
      ..device = dev.id
      ..source = 'feeder');
    check('sem alimentador', false);
  } on ScanError catch (e) {
    check('scanner sem alimentador avisa', e.message.contains('não tem alimentador'));
  }
  hasAdf = true;
  final st = ScanSettings()
    ..driver = 'escl'
    ..duplex = true
    ..remember('escl', [dev]);
  final back = ScanSettings()..load(st.toJson());
  check('opções e scanners guardados', back.driver == 'escl' && back.duplex && back.knownFor('escl').single.name == 'Falso 3000');
  sheets = 5;
  busy = 0;
  final one = await scanner.scan(ScanSettings()
    ..driver = 'escl'
    ..device = dev.id
    ..source = 'glass');
  check('vidro: só 1 página', one.length == 1);
  sheets = 0;
  try {
    await scanner.scan(ScanSettings()
      ..driver = 'escl'
      ..device = dev.id
      ..source = 'feeder');
    check('alimentador vazio', false);
  } on ScanError catch (e) {
    check('alimentador vazio', e.message.contains('alimentador está vazio') && e.details.contains('AdfState: ScannerAdfEmpty'), '\n${e.details}');
  }
  try {
    await scanner.esclAt('127.0.0.1:1');
    check('endereço errado', false);
  } on ScanError {
    check('endereço errado recusado', true);
  }
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
