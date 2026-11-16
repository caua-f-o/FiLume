// Teste dos módulos (sem interface): dart run tool/modules_test.dart
// Usa um servidor local no lugar do GitHub e uma pasta de mentira.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:filume/core/modules.dart';
import 'package:filume/core/office.dart';
import 'package:filume/core/universal.dart';
import 'package:filume/core/update.dart';
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
  // ------------------------------------------------------------- catálogo
  final good = 'a' * 64;
  final cat = parseModuleCatalog(jsonEncode({
    'modules': [
      {'id': 'pdf-word', 'version': '3', 'file': 'modulo-pdf-word-3.zip', 'size': 10, 'sha256': good.toUpperCase()},
      {'id': 'fora', 'version': '1', 'file': '../fora.zip', 'size': 10, 'sha256': good},
      {'id': 'pasta', 'version': '1', 'file': 'a/b.zip', 'size': 10, 'sha256': good},
      {'id': 'url', 'version': '1', 'file': 'https://exemplo.com/x.zip', 'size': 10, 'sha256': good},
      {'id': 'semresumo', 'version': '1', 'file': 'x.zip', 'size': 10},
      {'id': 'resumocurto', 'version': '1', 'file': 'x.zip', 'size': 10, 'sha256': 'abc'},
      {'id': 'vazio', 'version': '1', 'file': 'x.zip', 'size': 0, 'sha256': good},
      'lixo',
    ],
  }));
  check('catálogo: só entram módulos com arquivo simples, tamanho e resumo', cat.keys.join(',') == 'pdf-word' && cat['pdf-word']!.sha256 == good, cat.keys.join(','));
  var threw = false;
  try {
    parseModuleCatalog('[]');
  } on FormatException {
    threw = true;
  }
  check('catálogo em formato errado é recusado', threw);
  check('módulos conhecidos têm identificadores únicos', knownModules.map((m) => m.id).toSet().length == knownModules.length);

  // ------------------------------------------------------ servidor de mentira
  final dir = await Directory.systemTemp.createTemp('filume_modtest_');
  modulesDirOverride = p.join(dir.path, 'módulos com espaço');
  final entry = pdfWordModule.entry;
  final v1 = zip({entry: utf8.encode('programa v1'), 'lib/dado.txt': utf8.encode('um')});
  final v2 = zip({'pdf-word/$entry': utf8.encode('programa v2'), 'pdf-word/lib/outro.txt': utf8.encode('dois')});
  final empty = zip({'leia-me.txt': utf8.encode('sem programa')});
  final files = <String, List<int>>{'v1.zip': v1, 'v2.zip': v2, 'vazio.zip': empty};
  var index = <String, Object>{};
  var corrupt = false, missingIndex = false;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}/m';
  server.listen((req) async {
    final name = req.uri.pathSegments.last;
    if (name == modulesIndex && !missingIndex) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(index));
    } else if (files.containsKey(name)) {
      final data = [...files[name]!];
      if (corrupt) data[data.length ~/ 2] ^= 0xFF;
      req.response.contentLength = data.length;
      req.response.add(data);
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
  Map<String, Object> rel(String version, String file) =>
      {'id': 'pdf-word', 'version': version, 'file': file, 'size': files[file]!.length, 'sha256': sha(files[file]!)};

  missingIndex = true;
  try {
    await fetchModuleCatalog(base: base);
    check('lista ainda não publicada vira mensagem clara', false);
  } on UpdateError catch (e) {
    check('lista ainda não publicada vira mensagem clara', e.message.contains('ainda não foi publicada'), e.message);
  }
  missingIndex = false;
  try {
    await fetchModuleCatalog(base: 'http://127.0.0.1:1/m');
    check('sem conexão vira mensagem clara', false);
  } on UpdateError catch (e) {
    check('sem conexão vira mensagem clara', e.message.contains('conexão'), e.message);
  }

  // ------------------------------------------------------------- instalar
  check('nada instalado no começo', installedModuleVersion(pdfWordModule) == null && moduleEntry(pdfWordModule) == null);
  index = {'modules': [rel('1', 'v1.zip')]};
  var got = (await fetchModuleCatalog(base: base))['pdf-word']!;
  var last = 0, extracting = false;
  await installModule(pdfWordModule, got, base: base, onProgress: (r, t) => last = r, onExtracting: () => extracting = true);
  final exe = moduleEntry(pdfWordModule) ?? '';
  check('instala: programa no lugar, versão anotada, andamento informado',
      exe.isNotEmpty && File(exe).readAsStringSync() == 'programa v1' && installedModuleVersion(pdfWordModule) == '1' && last == v1.length && extracting &&
          File(p.join(moduleDir('pdf-word'), 'lib', 'dado.txt')).existsSync());
  check('sem sobras de download na pasta', Directory(modulesDir).listSync().map((e) => p.basename(e.path)).join(',') == 'pdf-word',
      Directory(modulesDir).listSync().map((e) => p.basename(e.path)).join(','));
  check('espaço ocupado é medido', moduleDiskSize(pdfWordModule) > 10);

  // Download adulterado: nada muda.
  index = {'modules': [rel('2', 'v2.zip')]};
  got = (await fetchModuleCatalog(base: base))['pdf-word']!;
  corrupt = true;
  try {
    await installModule(pdfWordModule, got, base: base);
    check('download adulterado é recusado', false);
  } on UpdateError catch (e) {
    check('download adulterado é recusado', e.message.contains('não confere'), e.message);
  }
  corrupt = false;
  check('depois da falha, a versão antiga continua inteira', installedModuleVersion(pdfWordModule) == '1' && File(exe).readAsStringSync() == 'programa v1');

  // Atualização (pacote com uma pasta por fora).
  await installModule(pdfWordModule, got, base: base);
  check('atualiza: troca tudo, sem misturar com a versão antiga',
      installedModuleVersion(pdfWordModule) == '2' && File(exe).readAsStringSync() == 'programa v2' &&
          !File(p.join(moduleDir('pdf-word'), 'lib', 'dado.txt')).existsSync() && File(p.join(moduleDir('pdf-word'), 'lib', 'outro.txt')).existsSync());

  // Pacote sem o programa.
  index = {'modules': [rel('3', 'vazio.zip')]};
  got = (await fetchModuleCatalog(base: base))['pdf-word']!;
  try {
    await installModule(pdfWordModule, got, base: base);
    check('pacote sem o programa é recusado', false);
  } on UpdateError catch (e) {
    check('pacote sem o programa é recusado', e.message.contains('sem o programa') && installedModuleVersion(pdfWordModule) == '2', e.message);
  }

  // Cancelar no meio.
  index = {'modules': [rel('1', 'v1.zip')]};
  got = (await fetchModuleCatalog(base: base))['pdf-word']!;
  var canceled = false;
  try {
    await installModule(pdfWordModule, got, base: base, canceled: () => true);
  } catch (_) {
    canceled = true;
  }
  check('cancelar não mexe no que está instalado', canceled && installedModuleVersion(pdfWordModule) == '2');
  await server.close(force: true);

  // ------------------------------------------- o conversor enxerga o módulo
  final office = await OfficeTools.locate();
  check('o conversor acha o módulo instalado', Platform.environment['FILUME_PDF2DOCX'] != null || office.pdf2docx == exe, '${office.pdf2docx}');
  List<String> pdfTargets(OfficeTools o) => targetsFor('a.pdf', ConvCaps(office: o)).map((t) => t.ext).toList();
  check('Word 2007 não oferece PDF → Word', pdfTargets(OfficeTools(msWord: true, wordVersion: 12)).isEmpty && !OfficeTools(msWord: true, wordVersion: 14).wordOpensPdf);
  check('Word 2013 em diante oferece', pdfTargets(OfficeTools(msWord: true, wordVersion: 15)).join(',') == 'docx,odt');
  check('só com o módulo: DOCX sim, ODT não', pdfTargets(OfficeTools(pdf2docx: 'x')).join(',') == 'docx');
  check('módulo + LibreOffice: DOCX e ODT', pdfTargets(OfficeTools(pdf2docx: 'x', soffice: 'y')).join(',') == 'docx,odt');

  removeModule(pdfWordModule);
  check('remover apaga o módulo', installedModuleVersion(pdfWordModule) == null && !Directory(moduleDir('pdf-word')).existsSync());
  removeModule(pdfWordModule);
  await dir.delete(recursive: true);
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
