import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'update.dart';

/// Módulos: ferramentas grandes que só parte das pessoas usa (por exemplo, o
/// conversor de PDF para Word). Não vêm no pacote do FiLume: são baixados do
/// repositório quando a pessoa pede e ficam numa pasta própria, fora da pasta
/// do programa, de modo que as atualizações não os apagam.
///
/// Como na atualização, a única coisa que sai do computador é o pedido de
/// download ao GitHub.

const modulesTag = 'modulos';
const modulesBase = 'https://github.com/$updateRepo/releases/download/$modulesTag';
const modulesIndex = 'modulos.json';

/// Um módulo que este FiLume sabe usar.
class ModuleSpec {
  const ModuleSpec({required this.id, required this.name, required this.summary, required this.entry, required this.approxMb});
  final String id, name, summary;

  /// Programa principal do módulo, a partir da pasta dele.
  final String entry;

  /// Tamanho aproximado do download, para mostrar antes de consultar a internet.
  final int approxMb;
}

const pdfWordModule = ModuleSpec(
  id: 'pdf-word',
  name: 'PDF → Word',
  summary: 'Transforma PDF em documento do Word editável, mantendo parágrafos, tabelas e imagens.',
  entry: 'filume-pdf2docx.exe',
  approxMb: 134,
);

const officeModule = ModuleSpec(
  id: 'documentos',
  name: 'Documentos do Office',
  summary: 'Converte Word, Excel e PowerPoint (e os formatos abertos) entre si e para PDF, sem precisar de Office instalado.',
  entry: 'program/soffice.exe',
  approxMb: 185,
);

const knownModules = [pdfWordModule, officeModule];

/// Para os testes apontarem para uma pasta de mentira.
String? modulesDirOverride;

/// Pasta onde os módulos ficam instalados.
String get modulesDir {
  if (modulesDirOverride case final String dir) return dir;
  final env = Platform.environment;
  final custom = env['FILUME_MODULES_DIR'];
  if (custom != null && custom.isNotEmpty) return custom;
  final base = env['LOCALAPPDATA'] ??
      env['APPDATA'] ??
      env['XDG_DATA_HOME'] ??
      (env['HOME'] == null ? Directory.systemTemp.path : p.join(env['HOME']!, '.local', 'share'));
  return p.join(base, 'FiLume', 'modulos');
}

String moduleDir(String id) => p.join(modulesDir, id);

/// Versão instalada de um módulo; null se não está instalado (ou está pela metade).
String? installedModuleVersion(ModuleSpec spec) {
  try {
    if (!File(p.joinAll([moduleDir(spec.id), ...spec.entry.split('/')])).existsSync()) return null;
    final j = jsonDecode(File(p.join(moduleDir(spec.id), 'modulo.json')).readAsStringSync());
    final v = j is Map ? j['version'] : null;
    return v is String && v.isNotEmpty ? v : null;
  } catch (_) {
    return null;
  }
}

/// Caminho do programa principal do módulo, se instalado.
String? moduleEntry(ModuleSpec spec) =>
    installedModuleVersion(spec) == null ? null : p.joinAll([moduleDir(spec.id), ...spec.entry.split('/')]);

/// Espaço que o módulo ocupa no disco.
int moduleDiskSize(ModuleSpec spec) {
  var total = 0;
  try {
    for (final e in Directory(moduleDir(spec.id)).listSync(recursive: true, followLinks: false)) {
      if (e is File) total += e.lengthSync();
    }
  } catch (_) {}
  return total;
}

/// O que está publicado para um módulo.
class ModuleRelease {
  ModuleRelease({required this.id, required this.version, required this.file, required this.size, required this.sha256});
  final String id, version, file, sha256;
  final int size;
}

final _safeFile = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// Lê a lista publicada (modulos.json). Entradas malformadas são ignoradas:
/// sem tamanho e resumo conferíveis, o módulo não é oferecido.
Map<String, ModuleRelease> parseModuleCatalog(String body) {
  final out = <String, ModuleRelease>{};
  final j = jsonDecode(body);
  final list = j is Map ? j['modules'] : null;
  if (list is! List) throw const FormatException('sem a lista de módulos');
  for (final m in list) {
    if (m is! Map) continue;
    final id = m['id'], version = m['version'], file = m['file'], size = m['size'], sha = m['sha256'];
    if (id is! String || version is! String || file is! String || size is! int || sha is! String) continue;
    if (version.isEmpty || size <= 0 || !_safeFile.hasMatch(file) || !_hex64.hasMatch(sha.toLowerCase())) continue;
    out[id] = ModuleRelease(id: id, version: version, file: file, size: size, sha256: sha.toLowerCase());
  }
  return out;
}

/// Consulta os módulos publicados. [base] existe para os testes.
Future<Map<String, ModuleRelease>> fetchModuleCatalog({String? base}) async {
  final client = updateHttpClient();
  try {
    final req = await client.getUrl(Uri.parse('${base ?? modulesBase}/$modulesIndex'));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    if (res.statusCode == 404) throw UpdateError('A lista de módulos ainda não foi publicada no repositório.');
    if (res.statusCode != 200) throw UpdateError('O GitHub respondeu com erro ${res.statusCode}.');
    return parseModuleCatalog(body);
  } on UpdateError {
    rethrow;
  } on TimeoutException {
    throw UpdateError('O GitHub demorou demais para responder.');
  } on SocketException {
    throw UpdateError('Sem conexão com a internet (ou o GitHub está fora do ar).');
  } on HandshakeException {
    throw UpdateError('Não foi possível abrir uma conexão segura com o GitHub.');
  } on FormatException {
    throw UpdateError('A lista de módulos veio num formato inesperado.');
  } on HttpException catch (e) {
    throw UpdateError('Falha ao consultar o GitHub: ${e.message}');
  } finally {
    client.close(force: true);
  }
}

void _wipe(String path) {
  try {
    final d = Directory(path);
    if (d.existsSync()) d.deleteSync(recursive: true);
  } catch (_) {}
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

/// Baixa, confere e instala um módulo. O módulo antigo (se houver) só é
/// trocado depois que o novo foi baixado, conferido e descompactado inteiro.
Future<void> installModule(
  ModuleSpec spec,
  ModuleRelease release, {
  String? base,
  void Function(int received, int total)? onProgress,
  void Function()? onExtracting,
  bool Function()? canceled,
}) async {
  final root = Directory(modulesDir);
  try {
    root.createSync(recursive: true);
  } on FileSystemException catch (e) {
    throw UpdateError('Não foi possível criar a pasta dos módulos (${e.osError?.message ?? e.message}).');
  }
  final zip = p.join(root.path, '.${spec.id}.baixando.zip');
  final fresh = p.join(root.path, '.${spec.id}.novo');
  final old = p.join(root.path, '.${spec.id}.velho');
  final target = moduleDir(spec.id);
  _wipe(zip);
  _wipe(fresh);
  try {
    await downloadRelease(
      ReleaseInfo(
        version: Version([0], const []),
        notes: '',
        pageUrl: '',
        assetUrl: '${base ?? modulesBase}/${release.file}',
        assetSize: release.size,
        sha256: release.sha256,
      ),
      zip,
      onProgress: onProgress,
      canceled: canceled,
    );
    onExtracting?.call();
    await unzipTo(zip, fresh);
    _wipe(zip);
    // O pacote pode trazer os arquivos soltos ou dentro de uma pasta só.
    bool has(String dir) => File(p.joinAll([dir, ...spec.entry.split('/')])).existsSync();
    var content = fresh;
    if (!has(content)) {
      final inner = Directory(fresh).listSync().whereType<Directory>().where((d) => has(d.path)).firstOrNull;
      if (inner == null) throw UpdateError('O pacote do módulo veio sem o programa dentro. Nada foi instalado.');
      content = inner.path;
    }
    File(p.join(content, 'modulo.json')).writeAsStringSync(jsonEncode({'id': spec.id, 'version': release.version}));
    _wipe(old);
    if (Directory(target).existsSync()) {
      try {
        Directory(target).renameSync(old);
      } on FileSystemException {
        throw UpdateError('O módulo instalado está em uso. Espere as conversões terminarem e tente de novo.');
      }
    }
    try {
      Directory(content).renameSync(target);
    } on FileSystemException catch (e) {
      // Devolve o antigo ao lugar: melhor a versão velha do que nenhuma.
      try {
        if (Directory(old).existsSync()) Directory(old).renameSync(target);
      } catch (_) {}
      throw UpdateError('Não foi possível gravar o módulo (${e.osError?.message ?? e.message}).');
    }
    _wipe(old);
  } on FileSystemException catch (e) {
    throw UpdateError('Não foi possível gravar o módulo (${e.osError?.message ?? e.message}). Há espaço em disco?');
  } finally {
    _wipe(zip);
    _wipe(fresh);
  }
}

/// Apaga um módulo instalado.
void removeModule(ModuleSpec spec) {
  final dir = Directory(moduleDir(spec.id));
  if (!dir.existsSync()) return;
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    throw UpdateError('O módulo está em uso. Espere as conversões terminarem e tente de novo.');
  }
}
