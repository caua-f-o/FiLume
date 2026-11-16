import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart';
import 'version.dart';

/// Atualização pelo GitHub: consulta as versões publicadas no repositório,
/// baixa o pacote e troca os arquivos da pasta do programa.
///
/// A única coisa que sai do computador é a consulta à lista de versões e o
/// download do pacote (github.com); nenhum arquivo ou dado do usuário é enviado.

const updateRepo = 'caua-f-o/FiLume';
const updateAsset = 'FiLume-windows-x64.zip';

/// Versão no formato 1.2.3 ou 1.2.3-beta.4, comparável.
class Version implements Comparable<Version> {
  Version(this.core, this.pre);
  final List<int> core;

  /// Partes depois do hífen ("beta", 4); vazio numa versão estável.
  final List<Object> pre;

  bool get isBeta => pre.isNotEmpty;

  static Version? parse(String text) {
    var t = text.trim();
    if (t.startsWith('v') || t.startsWith('V')) t = t.substring(1);
    final plus = t.indexOf('+');
    if (plus >= 0) t = t.substring(0, plus);
    final dash = t.indexOf('-');
    final head = dash < 0 ? t : t.substring(0, dash);
    final core = <int>[];
    for (final part in head.split('.')) {
      final n = int.tryParse(part);
      if (n == null || n < 0) return null;
      core.add(n);
    }
    if (core.isEmpty) return null;
    final pre = <Object>[
      if (dash >= 0)
        for (final part in t.substring(dash + 1).split('.'))
          if (part.isNotEmpty) int.tryParse(part) ?? part,
    ];
    return Version(core, pre);
  }

  @override
  int compareTo(Version other) {
    for (var i = 0; i < core.length || i < other.core.length; i++) {
      final a = i < core.length ? core[i] : 0, b = i < other.core.length ? other.core[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    // Com o mesmo número, a estável vem depois da beta.
    if (pre.isEmpty || other.pre.isEmpty) return pre.isEmpty == other.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    for (var i = 0; i < pre.length || i < other.pre.length; i++) {
      if (i >= pre.length) return -1;
      if (i >= other.pre.length) return 1;
      final a = pre[i], b = other.pre[i];
      if (a is int && b is int) {
        if (a != b) return a.compareTo(b);
      } else if (a is int) {
        return -1;
      } else if (b is int) {
        return 1;
      } else {
        final c = (a as String).compareTo(b as String);
        if (c != 0) return c;
      }
    }
    return 0;
  }

  bool operator >(Version other) => compareTo(other) > 0;

  @override
  String toString() => '${core.join('.')}${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}

class ReleaseInfo {
  ReleaseInfo({
    required this.version,
    required this.notes,
    required this.pageUrl,
    required this.assetUrl,
    required this.assetSize,
    this.sha256,
  });
  final Version version;
  final String notes;
  final String pageUrl;
  final String assetUrl;
  final int assetSize;

  /// Resumo SHA-256 do pacote, quando o GitHub informa.
  final String? sha256;
}

class UpdateError implements Exception {
  UpdateError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Escolhe, na lista de releases do GitHub, a mais nova do canal pedido.
/// No canal beta entram as betas e as estáveis (a estável mais nova que a
/// última beta também é oferecida).
ReleaseInfo? pickRelease(List<dynamic> releases, {required bool beta}) {
  ReleaseInfo? best;
  for (final r in releases) {
    if (r is! Map || r['draft'] == true) continue;
    final v = Version.parse('${r['tag_name']}');
    if (v == null) continue;
    final pre = r['prerelease'] == true || v.isBeta;
    if (pre && !beta) continue;
    final assets = r['assets'];
    if (assets is! List) continue;
    final a = assets.whereType<Map>().where((a) => a['name'] == updateAsset && a['state'] != 'new').firstOrNull;
    final url = a?['browser_download_url'], size = a?['size'];
    if (a == null || url is! String || size is! int || size <= 0) continue;
    if (best != null && !(v > best.version)) continue;
    final digest = a['digest'];
    best = ReleaseInfo(
      version: v,
      notes: '${r['body'] ?? ''}'.trim(),
      pageUrl: '${r['html_url'] ?? 'https://github.com/$updateRepo/releases'}',
      assetUrl: url,
      assetSize: size,
      sha256: digest is String && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
    );
  }
  return best;
}

HttpClient updateHttpClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..userAgent = 'FiLume/$appVersion';

/// Consulta o repositório. [api] existe para os testes apontarem para outro lugar.
Future<ReleaseInfo?> fetchLatest({required bool beta, String? api}) async {
  final client = updateHttpClient();
  try {
    final req = await client.getUrl(Uri.parse(api ?? 'https://api.github.com/repos/$updateRepo/releases?per_page=40'));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    if (res.statusCode == 403 || res.statusCode == 429) {
      throw UpdateError('O GitHub limitou as consultas deste endereço por enquanto. Tente de novo mais tarde.');
    }
    if (res.statusCode != 200) throw UpdateError('O GitHub respondeu com erro ${res.statusCode}.');
    final list = jsonDecode(body);
    if (list is! List) throw UpdateError('Resposta inesperada do GitHub.');
    return pickRelease(list, beta: beta);
  } on UpdateError {
    rethrow;
  } on TimeoutException {
    throw UpdateError('O GitHub demorou demais para responder.');
  } on SocketException {
    throw UpdateError('Sem conexão com a internet (ou o GitHub está fora do ar).');
  } on HandshakeException {
    throw UpdateError('Não foi possível abrir uma conexão segura com o GitHub.');
  } on FormatException {
    throw UpdateError('Resposta inesperada do GitHub.');
  } on HttpException catch (e) {
    throw UpdateError('Falha ao consultar o GitHub: ${e.message}');
  } finally {
    client.close(force: true);
  }
}

/// SHA-256 calculado aos poucos (sem depender de pacote externo).
class Sha256 {
  static const _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
    0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
    0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  final _h = Uint32List.fromList(
      [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  final _block = Uint8List(64);
  final _w = Uint32List(64);
  int _fill = 0, _length = 0;

  void add(List<int> data) {
    _length += data.length;
    var i = 0;
    while (i < data.length) {
      final n = (64 - _fill < data.length - i) ? 64 - _fill : data.length - i;
      _block.setRange(_fill, _fill + n, data, i);
      _fill += n;
      i += n;
      if (_fill == 64) {
        _compress();
        _fill = 0;
      }
    }
  }

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

  void _compress() {
    final w = _w;
    for (var i = 0; i < 16; i++) {
      w[i] = (_block[i * 4] << 24) | (_block[i * 4 + 1] << 16) | (_block[i * 4 + 2] << 8) | _block[i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final a = w[i - 15], b = w[i - 2];
      final s0 = _rotr(a, 7) ^ _rotr(a, 18) ^ (a >> 3), s1 = _rotr(b, 17) ^ _rotr(b, 19) ^ (b >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = _h[0], b = _h[1], c = _h[2], d = _h[3], e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final t2 = (s0 + ((a & b) ^ (a & c) ^ (b & c))) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    _h[0] += a;
    _h[1] += b;
    _h[2] += c;
    _h[3] += d;
    _h[4] += e;
    _h[5] += f;
    _h[6] += g;
    _h[7] += h;
  }

  String close() {
    final bits = _length * 8;
    add([0x80]);
    while (_fill != 56) {
      add([0]);
    }
    add([for (var i = 7; i >= 0; i--) (bits >> (i * 8)) & 0xFF]);
    return [for (final v in _h) v.toRadixString(16).padLeft(8, '0')].join();
  }
}

/// Baixa o pacote de [release] para [file], conferindo o tamanho e, quando o
/// GitHub informa, o resumo SHA-256. [canceled] interrompe o download.
Future<void> downloadRelease(
  ReleaseInfo release,
  String file, {
  void Function(int received, int total)? onProgress,
  bool Function()? canceled,
}) async {
  final client = updateHttpClient();
  IOSink? sink;
  try {
    final req = await client.getUrl(Uri.parse(release.assetUrl));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw UpdateError('O download respondeu com erro ${res.statusCode}.');
    final total = res.contentLength > 0 ? res.contentLength : release.assetSize;
    final hash = Sha256();
    sink = File(file).openWrite();
    var received = 0;
    await for (final chunk in res.timeout(const Duration(seconds: 45))) {
      if (canceled?.call() ?? false) throw const JobCanceled();
      sink.add(chunk);
      hash.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.close();
    sink = null;
    if (received != release.assetSize) {
      throw UpdateError('O download veio incompleto ($received de ${release.assetSize} bytes). Tente de novo.');
    }
    final sum = hash.close();
    if (release.sha256 != null && sum != release.sha256) {
      throw UpdateError('O arquivo baixado não confere com o publicado no GitHub (resumo diferente). Nada foi instalado.');
    }
  } on TimeoutException {
    throw UpdateError('A conexão parou no meio do download. Tente de novo.');
  } on SocketException {
    throw UpdateError('A conexão caiu durante o download. Tente de novo.');
  } on HttpException catch (e) {
    throw UpdateError('Falha no download: ${e.message}');
  } finally {
    try {
      await sink?.close();
    } catch (_) {}
    client.close(force: true);
  }
}

/// Roda um trecho de PowerShell a partir de um arquivo temporário (com
/// "-Command" os argumentos viram parte do comando, e caminhos com espaço quebram).
Future<ProcessResult> runPowershell(String script, List<String> args) async {
  final dir = await Directory.systemTemp.createTemp('filume_ps_');
  try {
    final f = File(p.join(dir.path, 'cmd.ps1'));
    await f.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('[Console]::OutputEncoding = [Text.Encoding]::UTF8\n\$ErrorActionPreference = "Stop"\n$script\n')]);
    return await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', f.path, ...args],
        stdoutEncoding: utf8, stderrEncoding: utf8);
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// Pasta onde o programa está instalado.
String get installDir => File(Platform.resolvedExecutable).parent.path;

/// Dá para gravar na pasta do programa? (Em "Arquivos de Programas" não dá.)
bool canWriteInstallDir([String? dir]) {
  try {
    final f = File(p.join(dir ?? installDir, '.filume_teste_${pid}'));
    f.writeAsStringSync('x');
    f.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

/// Descompacta [zip] em [dest].
Future<void> unzipTo(String zip, String dest) async {
  await Directory(dest).create(recursive: true);
  ProcessResult? r;
  try {
    // O tar que vem no Windows 10/11 abre ZIP e é bem mais rápido que o PowerShell.
    r = await Process.run(Platform.isWindows ? p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', 'tar.exe') : 'unzip',
        Platform.isWindows ? ['-xf', zip, '-C', dest] : ['-q', '-o', zip, '-d', dest]);
  } catch (_) {}
  if (r == null || r.exitCode != 0) {
    if (!Platform.isWindows) throw UpdateError('Não foi possível descompactar o pacote: ${r?.stderr}');
    final ps = await runPowershell(r'Expand-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force', [zip, dest]);
    if (ps.exitCode != 0) throw UpdateError('Não foi possível descompactar o pacote baixado.');
  }
}

/// Descompacta o pacote em [dest] e devolve a pasta que contém o FiLume.exe.
Future<String> extractRelease(String zip, String dest) async {
  await unzipTo(zip, dest);
  String? root;
  bool has(String dir) => File(p.join(dir, 'FiLume.exe')).existsSync();
  if (has(dest)) {
    root = dest;
  } else {
    for (final e in Directory(dest).listSync()) {
      if (e is Directory && has(e.path)) root = e.path;
    }
  }
  if (root == null) throw UpdateError('O pacote baixado não tem o FiLume dentro. Nada foi instalado.');
  return root;
}

/// Script que troca os arquivos: espera os programas da pasta fecharem, copia
/// a versão nova por cima e reabre o programa. Com -Close, fecha por conta própria
/// os que continuarem abertos. Se algum arquivo estiver em uso
/// ou a cópia falhar, avisa e não deixa a instalação pela metade sem dizer.
const applyScript = r'''
param([string]$Source, [string]$Target, [string]$Relaunch, [string]$Log, [int]$Wait = 60, [switch]$Quiet, [switch]$Close, [int]$Grace = 6)
$ErrorActionPreference = 'Continue'
function Say($text) {
  Add-Content -LiteralPath $Log -Value "$(Get-Date -Format s) $text" -Encoding UTF8
}
function Tell($text) {
  Say $text
  if ($Quiet) { return }
  try { (New-Object -ComObject WScript.Shell).Popup($text, 0, 'FiLume', 48) | Out-Null } catch {}
}
# Caminhos curtos (C:\Users\FULANO~1\...) viram o caminho completo dos dois lados, para comparar com o dos programas abertos.
$kernel = $null
try {
  $sig = '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern int GetLongPathName(string path, System.Text.StringBuilder buffer, int size);'
  $kernel = Add-Type -MemberDefinition $sig -Name Kernel -Namespace FiLumeUpdate -PassThru
} catch {}
function Long([string]$path) {
  if ($kernel -eq $null -or -not $path) { return $path }
  try {
    $buffer = New-Object System.Text.StringBuilder 2048
    if ($kernel::GetLongPathName($path, $buffer, 2048) -gt 0) { return $buffer.ToString() }
  } catch {}
  return $path
}
$Target = Long $Target
$prefix = $Target.TrimEnd('\') + '\'
function Running {
  @(Get-Process | Where-Object { try { $_.Path -and ((Long $_.Path).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) } catch { $false } })
}
Say "Atualizando $Target a partir de $Source"
function WaitGone([int]$seconds) {
  for ($i = 0; $i -lt $seconds * 4; $i++) {
    if ((Running).Count -eq 0) { return $true }
    Start-Sleep -Milliseconds 250
  }
  return (Running).Count -eq 0
}
if ($Close) {
  # Quem pediu a atualização fecha sozinho; o resto (outros programas do FiLume e
  # ajudantes que tenham ficado para trás) é fechado aqui: primeiro com educação,
  # depois à força.
  if (-not (WaitGone $Grace)) {
    foreach ($proc in Running) {
      Say "Fechando $($proc.ProcessName) ($($proc.Id))"
      try { $proc.CloseMainWindow() | Out-Null } catch {}
    }
    if (-not (WaitGone 4)) {
      foreach ($proc in Running) {
        Say "Encerrando $($proc.ProcessName) ($($proc.Id))"
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { Say "Não deu para encerrar: $_" }
      }
    }
  }
}
WaitGone $Wait | Out-Null
$left = Running
if ($left.Count -gt 0) {
  $names = ($left | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '
  Tell "A atualização não foi instalada: ainda há programas do FiLume abertos ($names). Feche todos e tente de novo."
  exit 2
}
if (-not (Test-Path -LiteralPath (Join-Path $Source 'FiLume.exe'))) {
  Tell 'A atualização não foi instalada: o pacote baixado está incompleto.'
  exit 3
}
& robocopy.exe $Source $Target /E /R:8 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
$code = $LASTEXITCODE
Say "robocopy terminou com $code"
if ($code -ge 8) {
  Tell "A atualização parou no meio da cópia (código $code). A versão nova completa está em:`n$Source`nCopie o conteúdo dessa pasta para:`n$Target"
  exit 4
}
Say 'Atualização concluída'
if ($Relaunch -and (Test-Path -LiteralPath $Relaunch)) { Start-Process -FilePath $Relaunch -WorkingDirectory $Target }
try { Remove-Item -LiteralPath (Split-Path -Parent $Source) -Recurse -Force -ErrorAction SilentlyContinue } catch {}
exit 0
''';

/// Onde ficam o download e o registro da última atualização.
String get updateWorkDir => p.join(Directory.systemTemp.path, 'FiLume_atualizacao');

/// Dispara o script de troca (que roda sozinho depois que este programa fecha).
/// Quem chama deve encerrar o programa em seguida.
Future<void> launchApply(String source, {String? target, String? relaunch, bool closeOthers = true}) async {
  final dir = Directory(updateWorkDir)..createSync(recursive: true);
  final script = File(p.join(dir.path, 'aplicar.ps1'));
  await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(applyScript)]);
  await Process.start(
    'powershell.exe',
    [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path,
      '-Source', source,
      '-Target', target ?? installDir,
      '-Relaunch', relaunch ?? Platform.resolvedExecutable,
      '-Log', p.join(dir.path, 'atualizacao.log'),
      if (closeOthers) '-Close',
    ],
    mode: ProcessStartMode.detached,
  );
}
