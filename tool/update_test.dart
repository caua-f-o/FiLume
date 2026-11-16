// Teste do atualizador (sem interface): dart run tool/update_test.dart
// Usa um servidor local no lugar do GitHub; no Windows também roda o script
// que troca os arquivos, numa pasta de mentira.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:filume/core/update.dart';
import 'package:filume/core/version.dart';
import 'package:path/path.dart' as p;

var bad = 0;
void check(String label, bool ok, [String extra = '']) {
  print('${ok ? 'OK' : 'FALHA'} $label ${ok ? '' : extra}');
  if (!ok) bad++;
}

Uint8List zip(Map<String, List<int>> files) {
  final b = BytesBuilder();
  void u16(int v) => b.add([v & 255, v >> 8]);
  void u32(int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  final central = <(List<int>, int, int, int, int)>[];
  for (final e in files.entries) {
    final n = utf8.encode(e.key), comp = ZLibEncoder(raw: true).convert(e.value);
    var crc = 0xFFFFFFFF;
    for (final x in e.value) {
      crc ^= x;
      for (var k = 0; k < 8; k++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    crc ^= 0xFFFFFFFF;
    central.add((n, crc, comp.length, e.value.length, b.length));
    u32(0x04034b50); u16(20); u16(0x800); u16(8); u16(0); u16(0); u32(crc); u32(comp.length); u32(e.value.length); u16(n.length); u16(0);
    b.add(n); b.add(comp);
  }
  final cd = b.length;
  for (final (n, crc, csize, size, off) in central) {
    u32(0x02014b50); u16(20); u16(20); u16(0x800); u16(8); u16(0); u16(0); u32(crc); u32(csize); u32(size);
    u16(n.length); u16(0); u16(0); u16(0); u16(0); u32(0); u32(off);
    b.add(n);
  }
  final end = b.length;
  u32(0x06054b50); u16(0); u16(0); u16(central.length); u16(central.length); u32(end - cd); u32(cd); u16(0);
  return b.toBytes();
}

String sha(List<int> data) => (Sha256()..add(data)).close();

Future<void> main() async {
  // ------------------------------------------------------------- versões
  Version v(String s) => Version.parse(s)!;
  check('versão do programa é válida', Version.parse(appVersion) != null, appVersion);
  final pub = RegExp(r'^version:\s*([^\s+]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())?[1];
  check('versão do programa = pubspec', pub == appVersion, '$pub x $appVersion');
  check('ordem das versões', v('1.5.0') > v('1.5.0-beta.9') && v('1.5.0-beta.10') > v('1.5.0-beta.9') && v('1.5.1-beta.1') > v('1.5.0') &&
      v('v1.10.0') > v('1.9.9') && v('1.5.0').compareTo(v('1.5.0+15')) == 0 && !(v('1.5.0-beta.2') > v('1.5.0-beta.2')) && v('1.5.0-rc.1') > v('1.5.0-beta.9'));
  check('texto que não é versão', Version.parse('latest') == null && Version.parse('') == null);

  // --------------------------------------------------------------- SHA-256
  check('SHA-256: vetores conhecidos',
      sha(const []) == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' &&
          sha(ascii.encode('abc')) == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' &&
          sha(ascii.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')) == '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1' &&
          sha(List.filled(1000000, 0x61)) == 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');

  // ----------------------------------------------- escolha da release
  final dir = await Directory.systemTemp.createTemp('filume_updtest_');
  final pack = zip({
    'FiLume/FiLume.exe': utf8.encode('novo exe'),
    'FiLume/FiLume PDF.exe': utf8.encode('novo pdf'),
    'FiLume/data/ação.txt': utf8.encode('novo dado'),
  });
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  var corrupt = false, status = 200;
  server.listen((req) async {
    if (req.uri.path == '/releases') {
      req.response.statusCode = status;
      req.response.write(jsonEncode(releases(base, pack)));
    } else if (req.uri.path == '/ir') {
      // O GitHub redireciona o download para outro endereço.
      req.response.statusCode = 302;
      req.response.headers.set('location', '$base/pacote.zip');
    } else if (req.uri.path == '/pacote.zip') {
      final data = corrupt ? (Uint8List.fromList(pack)..[40] ^= 0xFF) : pack;
      req.response.headers.contentLength = data.length;
      req.response.add(data);
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
  final list = releases(base, pack);
  final stable = pickRelease(list, beta: false), beta = pickRelease(list, beta: true);
  check('canal estável ignora betas, rascunhos e releases sem pacote', stable?.version.toString() == '1.4.0', '${stable?.version}');
  check('canal beta pega a beta mais nova (10 > 9)', beta?.version.toString() == '1.5.0-beta.10', '${beta?.version}');
  final later = [...list, rel('v1.5.0', false, base, pack)];
  check('canal beta oferece a estável quando ela é mais nova', pickRelease(later, beta: true)?.version.toString() == '1.5.0');
  final got = await fetchLatest(beta: true, api: '$base/releases');
  check('consulta pela rede', got?.version.toString() == '1.5.0-beta.10' && got?.sha256 == sha(pack) && got!.notes.contains('Novidades'));
  status = 403;
  try {
    await fetchLatest(beta: true, api: '$base/releases');
    check('limite de consultas vira mensagem clara', false);
  } on UpdateError catch (e) {
    check('limite de consultas vira mensagem clara', e.message.contains('limitou'));
  }
  status = 200;
  try {
    await fetchLatest(beta: true, api: 'http://127.0.0.1:1/releases');
    check('sem conexão vira mensagem clara', false);
  } on UpdateError catch (e) {
    check('sem conexão vira mensagem clara', e.message.contains('conexão'), e.message);
  }

  // ------------------------------------------------------------ download
  final file = p.join(dir.path, 'baixado.zip');
  var last = 0;
  await downloadRelease(got!, file, onProgress: (r, t) => last = r);
  check('download (com redirecionamento) confere tamanho e resumo', File(file).lengthSync() == pack.length && last == pack.length);
  corrupt = true;
  try {
    await downloadRelease(got, file);
    check('download adulterado é recusado', false);
  } on UpdateError catch (e) {
    check('download adulterado é recusado', e.message.contains('não confere'));
  }
  corrupt = false;
  try {
    await downloadRelease(
        ReleaseInfo(version: got.version, notes: '', pageUrl: '', assetUrl: got.assetUrl, assetSize: pack.length + 5), file);
    check('download incompleto é recusado', false);
  } on UpdateError catch (e) {
    check('download incompleto é recusado', e.message.contains('incompleto'));
  }
  await downloadRelease(got, file);
  await server.close(force: true);

  // ------------------------------------------------- descompactar e trocar
  final root = await extractRelease(file, p.join(dir.path, 'novo'));
  check('descompacta e acha a pasta do programa', p.basename(root) == 'FiLume' && File(p.join(root, 'FiLume.exe')).readAsStringSync() == 'novo exe' &&
      File(p.join(root, 'data', 'ação.txt')).existsSync(), root);
  File(p.join(dir.path, 'ruim.zip')).writeAsBytesSync(zip({'outra/coisa.txt': [1]}));
  try {
    await extractRelease(p.join(dir.path, 'ruim.zip'), p.join(dir.path, 'ruim'));
    check('pacote sem o FiLume é recusado', false);
  } on UpdateError {
    check('pacote sem o FiLume é recusado', true);
  }
  check('pasta gravável é reconhecida', canWriteInstallDir(dir.path) && !canWriteInstallDir(p.join(dir.path, 'não existe')));

  if (Platform.isWindows) {
    final target = Directory(p.join(dir.path, 'instalado com espaço'))..createSync();
    File(p.join(target.path, 'FiLume.exe')).writeAsStringSync('velho exe');
    File(p.join(target.path, 'meu arquivo.txt')).writeAsStringSync('do usuário');
    final script = File(p.join(dir.path, 'aplicar.ps1'))..writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(applyScript)]);
    final log = p.join(dir.path, 'log.txt');
    Future<int> apply(List<String> extra) async => (await Process.run('powershell.exe', [
          '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path,
          '-Source', root, '-Target', target.path, '-Relaunch', '', '-Log', log, '-Quiet', ...extra,
        ])).exitCode;
    // Com um programa da pasta aberto, nada é trocado.
    final ping = p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'ping.exe');
    File(ping).copySync(p.join(target.path, 'aberto.exe'));
    final busy = await Process.start(p.join(target.path, 'aberto.exe'), ['-n', '60', '127.0.0.1']);
    final blocked = await apply(['-Wait', '2']);
    check('com programa aberto na pasta, a troca não acontece', blocked == 2 && File(p.join(target.path, 'FiLume.exe')).readAsStringSync() == 'velho exe', 'código $blocked');
    // Com -Close, o próprio script fecha o que estiver aberto e segue.
    final code = await apply(['-Wait', '20', '-Close', '-Grace', '1']);
    final ended = await busy.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -999);
    check('com -Close, o programa aberto é encerrado pelo script', ended != -999, 'continuou aberto');
    busy.kill();
    check('troca dos arquivos: novos entram, os do usuário ficam',
        code == 0 && File(p.join(target.path, 'FiLume.exe')).readAsStringSync() == 'novo exe' &&
            File(p.join(target.path, 'FiLume PDF.exe')).existsSync() && File(p.join(target.path, 'data', 'ação.txt')).readAsStringSync() == 'novo dado' &&
            File(p.join(target.path, 'meu arquivo.txt')).readAsStringSync() == 'do usuário',
        'código $code\n${File(log).existsSync() ? File(log).readAsStringSync() : ''}');
    check('a pasta temporária da versão nova é apagada no fim', !Directory(p.join(dir.path, 'novo')).existsSync());
  } else {
    print('AVISO: o script que troca os arquivos só roda no Windows; não foi testado aqui.');
  }
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}

Map<String, dynamic> rel(String tag, bool pre, String base, List<int> pack, {bool draft = false, bool asset = true}) => {
      'tag_name': tag,
      'prerelease': pre,
      'draft': draft,
      'body': 'Novidades da $tag',
      'html_url': '$base/pagina/$tag',
      'assets': [
        {'name': 'codigo.tar.gz', 'size': 10, 'browser_download_url': '$base/x'},
        if (asset) {'name': updateAsset, 'size': pack.length, 'browser_download_url': '$base/ir', 'digest': 'sha256:${sha(pack)}', 'state': 'uploaded'},
      ],
    };

List<Map<String, dynamic>> releases(String base, List<int> pack) => [
      rel('v1.5.0-beta.9', true, base, pack),
      rel('v1.5.0-beta.10', true, base, pack),
      rel('v1.6.0', false, base, pack, draft: true),
      rel('v1.4.1', false, base, pack, asset: false),
      rel('v1.4.0', false, base, pack),
      rel('v1.3.0', false, base, pack),
      rel('nightly', true, base, pack),
    ];
