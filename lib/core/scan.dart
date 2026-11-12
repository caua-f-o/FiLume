import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Digitalização feita pelo próprio FiLume, sem programas de terceiros:
///  - "wia": scanners com driver do Windows (USB, em geral), pela camada de
///    automação WIA que já vem no sistema;
///  - "escl": scanners e multifuncionais de rede (AirScan/eSCL), por HTTP.
class ScanDevice {
  const ScanDevice(this.driver, this.id, this.name);
  final String driver;

  /// WIA: identificador do aparelho. eSCL: endereço base (http://ip:porta/eSCL).
  final String id;
  final String name;
}

class ScanSettings {
  /// "wia" ou "escl".
  String driver = 'wia';
  String device = '';

  /// "auto" (o scanner decide: alimentador se tiver papel, senão vidro),
  /// "glass" (vidro) ou "feeder" (alimentador).
  String source = 'auto';

  /// Frente e verso no alimentador: cada lado vira uma página.
  bool duplex = false;
  int dpi = 300;

  /// "color", "gray" ou "bw".
  String color = 'color';

  /// Aparelhos já encontrados, para não procurar toda vez.
  final List<ScanDevice> known = [];

  List<ScanDevice> knownFor(String driver) => [
        for (final d in known)
          if (d.driver == driver) d,
      ];

  void remember(String driver, List<ScanDevice> list) {
    known
      ..removeWhere((d) => d.driver == driver)
      ..addAll(list);
  }

  Map<String, dynamic> toJson() => {
        'driver': driver,
        'device': device,
        'source': source,
        'duplex': duplex,
        'dpi': dpi,
        'color': color,
        'known': [
          for (final d in known) {'driver': d.driver, 'id': d.id, 'name': d.name},
        ],
      };

  void load(Map<String, dynamic> j) {
    String pick(String key, List<String> ok, String current) {
      final v = j[key];
      return v is String && ok.contains(v) ? v : current;
    }

    driver = pick('driver', const ['wia', 'escl'], driver);
    source = pick('source', const ['auto', 'glass', 'feeder'], source);
    color = pick('color', const ['color', 'gray', 'bw'], color);
    if (j['device'] is String) device = j['device'] as String;
    if (j['duplex'] is bool) duplex = j['duplex'] as bool;
    if (const [150, 200, 300, 600].contains(j['dpi'])) dpi = j['dpi'] as int;
    final k = j['known'];
    if (k is List) {
      known.clear();
      for (final e in k) {
        if (e is Map && e['driver'] is String && e['id'] is String && e['name'] is String) {
          known.add(ScanDevice(e['driver'] as String, e['id'] as String, e['name'] as String));
        }
      }
    }
  }
}

class ScanError implements Exception {
  ScanError(this.message, [this.details = '']);
  final String message;
  final String details;
  @override
  String toString() => details.isEmpty ? message : '$message\n$details';
}

/// Permite interromper uma digitalização em andamento.
class ScanCancel {
  bool canceled = false;
  void Function()? _stop;

  void cancel() {
    canceled = true;
    _stop?.call();
  }
}

class Scanner {
  /// Procura scanners: os instalados no Windows ("wia") ou os da rede ("escl").
  Future<List<ScanDevice>> devices(String driver) =>
      driver == 'escl' ? EsclScanner.discover() : WiaScanner.devices();

  /// Scanner de rede informado à mão (IP ou nome), quando a busca não acha.
  Future<ScanDevice> esclAt(String host) => EsclScanner.probe(host);

  /// Digitaliza; cada página pronta é avisada em [onPage] (arquivo de imagem)
  /// e todas voltam no fim, em ordem.
  Future<List<String>> scan(ScanSettings s, {void Function(String path)? onPage, ScanCancel? cancel}) async {
    final dir = await Directory.systemTemp.createTemp('filume_scan_');
    final pages = <String>[];
    void page(String path) {
      pages.add(path);
      onPage?.call(path);
    }

    try {
      if (s.driver == 'escl') {
        await EsclScanner.scan(s, dir.path, page, cancel ?? ScanCancel());
      } else {
        await WiaScanner.scan(s, dir.path, page, cancel ?? ScanCancel());
      }
    } catch (e) {
      // Páginas que já chegaram ficam; sem nenhuma, o erro sobe.
      if (pages.isEmpty) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
        if (cancel?.canceled ?? false) return pages;
        rethrow;
      }
    }
    if (pages.isEmpty && !(cancel?.canceled ?? false)) {
      throw ScanError('O scanner não devolveu nenhuma página. Confira se há papel e se ele está ligado.');
    }
    return pages;
  }
}

// ------------------------------------------------------------------------ WIA

/// WIA pela camada de automação do Windows (objeto COM "WIA.DeviceManager"),
/// chamada por um script do PowerShell que o FiLume grava e executa.
class WiaScanner {
  static const _script = r'''
param([string]$Action, [string]$DeviceId = '', [string]$Source = 'auto', [int]$Duplex = 0, [int]$Dpi = 300, [string]$Color = 'color', [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Set-Prop($props, $id, $value) { try { $props.Item("$id").Value = $value } catch {} }
function Get-Prop($props, $id) { try { return $props.Item("$id").Value } catch { return $null } }
# Nos drivers novos (WIA 2) vidro e alimentador sao itens separados do aparelho.
function Find-Item($dev, $category, $pattern) {
  foreach ($it in $dev.Items) {
    $cat = Get-Prop $it.Properties 4125
    if ($cat -and ("$cat".ToUpper() -eq $category)) { return $it }
  }
  foreach ($it in $dev.Items) {
    $name = Get-Prop $it.Properties 4098
    if ($name -and ("$name" -match $pattern)) { return $it }
  }
  return $null
}
$jpeg = '{B96B3CAE-0728-11D3-9D7B-0000F81EF32E}'
$bmp = '{B96B3CAB-0728-11D3-9D7B-0000F81EF32E}'
$script:fmt = $jpeg
$script:n = 0
# Digitaliza pelo vidro (1 pagina) ou pelo alimentador (ate acabar o papel).
function Scan-Pages($dev, $feeder) {
  $item = $null
  if ($feeder) { $item = Find-Item $dev '{FE131934-F84C-42AD-8DA4-6129CDDD7288}' 'feed|adf' }
  else { $item = Find-Item $dev '{FB607B1F-43F3-488B-855B-FB703EC342A6}' 'flat|platen' }
  if ($null -eq $item) { $item = $dev.Items.Item(1) }
  # 3088 = origem do papel: 1 alimentador, 2 vidro, 4 frente e verso
  $select = 2
  if ($feeder) { $select = 1; if ($Duplex -eq 1) { $select = 5 } }
  Set-Prop $dev.Properties 3088 $select
  Set-Prop $item.Properties 3088 $select
  if ($feeder) { Set-Prop $dev.Properties 3096 1; Set-Prop $item.Properties 3096 1 }
  # Area de leitura, em milesimos de polegada
  $bedW = Get-Prop $item.Properties 6165
  $bedH = Get-Prop $item.Properties 6166
  if (-not ($bedW -and $bedH)) {
    $bedW = Get-Prop $dev.Properties $(if ($feeder) { 3076 } else { 3074 })
    $bedH = Get-Prop $dev.Properties $(if ($feeder) { 3077 } else { 3075 })
  }
  $got = 0
  while ($true) {
    $props = $item.Properties
    Set-Prop $props 6146 $(switch ($Color) { 'gray' { 2 } 'bw' { 4 } default { 1 } })
    Set-Prop $props 6147 $Dpi
    Set-Prop $props 6148 $Dpi
    Set-Prop $props 6149 0
    Set-Prop $props 6150 0
    if ($bedW -and $bedH) {
      Set-Prop $props 6151 ([int]($bedW * $Dpi / 1000))
      Set-Prop $props 6152 ([int]($bedH * $Dpi / 1000))
    }
    $img = $null
    try { $img = $item.Transfer($script:fmt) }
    catch {
      # Depois da primeira folha, erro no alimentador = acabou o papel.
      if ($got -gt 0 -and $feeder) { break }
      if ($script:fmt -eq $bmp) { throw }
      # Alguns drivers so entregam BMP.
      $script:fmt = $bmp
      $img = $item.Transfer($script:fmt)
    }
    $got++
    $script:n++
    $ext = $img.FileExtension
    if (-not $ext) { $ext = 'jpg' }
    $path = Join-Path $OutDir ('pagina_{0:D4}.{1}' -f $script:n, $ext.ToLower())
    $img.SaveFile($path)
    "PAGE`t$path"
    if (-not $feeder) { break }
  }
}
try {
  $dm = New-Object -ComObject WIA.DeviceManager
  if ($Action -eq 'list') {
    foreach ($info in $dm.DeviceInfos) {
      if ($info.Type -eq 1) { "DEV`t$($info.DeviceID)`t$($info.Properties.Item('Name').Value)" }
    }
    exit 0
  }
  $info = $null
  foreach ($i in $dm.DeviceInfos) { if ($i.DeviceID -eq $DeviceId) { $info = $i } }
  if ($null -eq $info) { "ERR`tgone"; exit 2 }
  $dev = $info.Connect()
  $caps = Get-Prop $dev.Properties 3086
  $feedItem = Find-Item $dev '{FE131934-F84C-42AD-8DA4-6129CDDD7288}' 'feed|adf'
  $hasFeeder = ($null -ne $feedItem) -or ($caps -and (($caps -band 1) -eq 1))
  if ($Source -eq 'feeder') {
    if (-not $hasFeeder) { "ERR`tnofeeder"; exit 4 }
    Scan-Pages $dev $true
  } elseif ($Source -eq 'auto' -and $hasFeeder) {
    # Automatico: tenta o alimentador; sem papel nele, vai de vidro.
    try { Scan-Pages $dev $true } catch { if ($script:n -eq 0) { $script:fmt = $jpeg; Scan-Pages $dev $false } }
  } else {
    Scan-Pages $dev $false
  }
  exit 0
} catch {
  "ERR`t$($_.Exception.Message)"
  exit 1
}
''';

  static String? _scriptPath;

  static Future<String> _ensureScript() async {
    final known = _scriptPath;
    if (known != null && File(known).existsSync()) return known;
    final dir = await Directory.systemTemp.createTemp('filume_wia_');
    final f = File(p.join(dir.path, 'wia.ps1'));
    // Com BOM, para o PowerShell 5 ler como UTF-8.
    await f.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_script)]);
    return _scriptPath = f.path;
  }

  static Future<List<String>> _args(List<String> rest) async => [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', await _ensureScript(), ...rest,
      ];

  /// Traduz os códigos de erro mais comuns do WIA.
  static ScanError _error(String raw) {
    final low = raw.toLowerCase();
    String msg;
    if (low.contains('nofeeder')) {
      msg = 'Este scanner não tem alimentador de folhas. Use "Vidro" ou "Automático".';
    } else if (low.contains('80210003')) {
      msg = 'Sem papel no alimentador.';
    } else if (low.contains('80210006')) {
      msg = 'O scanner está ocupado. Espere um pouco e tente de novo.';
    } else if (low.contains('80210005') || low.contains('gone')) {
      msg = 'O scanner está desligado ou desconectado.';
    } else if (low.contains('80210002')) {
      msg = 'Papel preso no scanner.';
    } else if (low.contains('80210016') || low.contains('80210001')) {
      msg = 'O scanner avisou um problema (tampa aberta ou erro geral). Confira o aparelho.';
    } else if (low.contains('80040154') || low.contains('wia.devicemanager')) {
      msg = 'O serviço de digitalização do Windows (WIA) não está disponível neste computador.';
    } else {
      msg = 'A digitalização não funcionou.';
    }
    return ScanError(msg, raw.trim());
  }

  static Future<List<ScanDevice>> devices() async {
    if (!Platform.isWindows) throw ScanError('Scanners USB (WIA) só funcionam no Windows. Tente "Rede".');
    final ProcessResult r;
    try {
      r = await Process.run('powershell.exe', await _args(['-Action', 'list']),
          stdoutEncoding: const Utf8Codec(allowMalformed: true), stderrEncoding: const Utf8Codec(allowMalformed: true));
    } catch (e) {
      throw ScanError('Não foi possível falar com o Windows para listar os scanners.', '$e');
    }
    final out = <ScanDevice>[];
    String? err;
    for (final line in const LineSplitter().convert(r.stdout.toString())) {
      final f = line.split('\t');
      if (f.length >= 3 && f[0] == 'DEV') out.add(ScanDevice('wia', f[1], f[2]));
      if (f.length >= 2 && f[0] == 'ERR') err = f.sublist(1).join(' ');
    }
    if (r.exitCode != 0 && out.isEmpty) throw _error(err ?? '${r.stdout}\n${r.stderr}');
    return out;
  }

  static Future<void> scan(ScanSettings s, String dir, void Function(String) onPage, ScanCancel cancel) async {
    if (!Platform.isWindows) throw ScanError('Scanners USB (WIA) só funcionam no Windows. Tente "Rede".');
    final proc = await Process.start(
      'powershell.exe',
      await _args([
        '-Action', 'scan', '-DeviceId', s.device, '-Source', s.source,
        '-Duplex', s.duplex && s.source != 'glass' ? '1' : '0',
        '-Dpi', '${s.dpi}', '-Color', s.color, '-OutDir', dir,
      ]),
    );
    cancel._stop = proc.kill;
    String? err;
    final log = StringBuffer();
    final a = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
      final f = line.split('\t');
      if (f.length >= 2 && f[0] == 'PAGE') {
        onPage(f[1]);
      } else if (f.length >= 2 && f[0] == 'ERR') {
        err = f.sublist(1).join(' ');
      } else {
        log.writeln(line);
      }
    });
    final b = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(log.write);
    final code = await proc.exitCode;
    await Future.wait([a, b]);
    cancel._stop = null;
    if (cancel.canceled) return;
    if (code != 0) throw _error(err ?? log.toString());
  }
}

// ----------------------------------------------------------------------- eSCL

/// eSCL (AirScan): o scanner é um servidor HTTP na rede local. A busca usa
/// mDNS (serviços _uscan._tcp e _uscans._tcp); a digitalização é um POST com
/// as opções seguido de GETs que devolvem as páginas.
class EsclScanner {
  static const _services = ['_uscan._tcp.local', '_uscans._tcp.local'];

  // ---- mDNS

  /// Pergunta mDNS (PTR) para os serviços de scanner, pedindo resposta direta.
  static Uint8List buildQuery() {
    final b = BytesBuilder();
    b.add([0, 0, 0, 0, 0, _services.length, 0, 0, 0, 0, 0, 0]);
    for (final s in _services) {
      for (final label in s.split('.')) {
        b.addByte(label.length);
        b.add(ascii.encode(label));
      }
      b.add([0, 0, 12, 0x80, 1]); // fim do nome, tipo PTR, classe IN + "QU"
    }
    return b.toBytes();
  }

  static (String, int) _name(Uint8List d, int at) {
    final labels = <String>[];
    var pos = at, end = -1, jumps = 0;
    while (pos < d.length) {
      final len = d[pos];
      if (len == 0) {
        pos++;
        break;
      }
      if (len & 0xC0 == 0xC0) {
        if (pos + 1 >= d.length || ++jumps > 20) break;
        if (end < 0) end = pos + 2;
        pos = ((len & 0x3F) << 8) | d[pos + 1];
        continue;
      }
      if (pos + 1 + len > d.length) break;
      labels.add(utf8.decode(d.sublist(pos + 1, pos + 1 + len), allowMalformed: true));
      pos += 1 + len;
    }
    return (labels.join('.'), end < 0 ? pos : end);
  }

  /// Lê uma resposta mDNS e devolve os scanners anunciados nela.
  /// [from] é o endereço de quem respondeu (usado se não vier registro A).
  static List<ScanDevice> parseResponse(Uint8List d, String from) {
    if (d.length < 12) return const [];
    final counts = [for (var i = 4; i < 12; i += 2) (d[i] << 8) | d[i + 1]];
    var pos = 12;
    for (var q = 0; q < counts[0]; q++) {
      pos = _name(d, pos).$2 + 4;
    }
    final instances = <String>{};
    final srv = <String, (String, int)>{};
    final txt = <String, Map<String, String>>{};
    final hosts = <String, String>{};
    final total = counts[1] + counts[2] + counts[3];
    for (var r = 0; r < total && pos + 10 <= d.length; r++) {
      final (name, next) = _name(d, pos);
      pos = next;
      if (pos + 10 > d.length) break;
      final type = (d[pos] << 8) | d[pos + 1];
      final len = (d[pos + 8] << 8) | d[pos + 9];
      final data = pos + 10;
      pos = data + len;
      if (pos > d.length) break;
      final key = name.toLowerCase();
      if (type == 12 && _services.contains(key)) {
        instances.add(_name(d, data).$1);
      } else if (type == 33 && len > 6) {
        srv[key] = (_name(d, data + 6).$1, (d[data + 4] << 8) | d[data + 5]);
      } else if (type == 16) {
        final m = <String, String>{};
        var t = data;
        while (t < data + len) {
          final l = d[t];
          final kv = utf8.decode(d.sublist(t + 1, (t + 1 + l).clamp(0, d.length)), allowMalformed: true);
          final eq = kv.indexOf('=');
          if (eq > 0) m[kv.substring(0, eq).toLowerCase()] = kv.substring(eq + 1);
          t += 1 + l;
        }
        txt[key] = m;
      } else if (type == 1 && len == 4) {
        hosts[key] = d.sublist(data, data + 4).join('.');
      }
    }
    final out = <ScanDevice>[];
    for (final inst in instances) {
      final key = inst.toLowerCase();
      final s = srv[key];
      if (s == null) continue;
      final ip = hosts[s.$1.toLowerCase()] ?? from;
      final t = txt[key] ?? const {};
      final root = (t['rs'] ?? 'eSCL').replaceAll(RegExp(r'^/+|/+$'), '');
      final scheme = key.contains('_uscans.') ? 'https' : 'http';
      final label = t['ty'] ?? inst.split('._').first;
      out.add(ScanDevice('escl', '$scheme://$ip:${s.$2}/$root', label));
    }
    return out;
  }

  /// Procura scanners na rede local por alguns segundos.
  static Future<List<ScanDevice>> discover({Duration wait = const Duration(milliseconds: 2500)}) async {
    final found = <String, ScanDevice>{};
    final sockets = <RawDatagramSocket>[];
    final query = buildQuery();
    final group = InternetAddress('224.0.0.251');
    Future<void> open(InternetAddress addr) async {
      try {
        final s = await RawDatagramSocket.bind(addr, 0);
        s.multicastHops = 1;
        s.listen((e) {
          if (e != RawSocketEvent.read) return;
          final dg = s.receive();
          if (dg == null) return;
          try {
            for (final dev in parseResponse(dg.data, dg.address.address)) {
              // http ganha de https para o mesmo aparelho (certificados de scanner são caseiros).
              final k = dev.name;
              if (!found.containsKey(k) || dev.id.startsWith('http://')) found[k] = dev;
            }
          } catch (_) {}
        });
        s.send(query, group, 5353);
        sockets.add(s);
      } catch (_) {}
    }

    try {
      final nets = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final n in nets) {
        for (final a in n.addresses) {
          await open(a);
        }
      }
    } catch (_) {}
    if (sockets.isEmpty) await open(InternetAddress.anyIPv4);
    // Repete a pergunta uma vez: pacotes UDP se perdem.
    await Future<void>.delayed(wait ~/ 2);
    for (final s in sockets) {
      try {
        s.send(query, group, 5353);
      } catch (_) {}
    }
    await Future<void>.delayed(wait ~/ 2);
    for (final s in sockets) {
      s.close();
    }
    return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  // ---- HTTP

  static HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    // Scanners usam certificado próprio; o endereço é da rede local.
    ..badCertificateCallback = (cert, host, port) => true;

  /// Confere se há um scanner eSCL em [host] ("192.168.0.20", "impressora.local:8080"…).
  static Future<ScanDevice> probe(String host) async {
    var h = host.trim().replaceAll(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/.*$'), '');
    if (h.isEmpty) throw ScanError('Digite o endereço (IP) do scanner.');
    final tries = h.contains(':')
        ? ['http://$h', 'https://$h']
        : ['http://$h:80', 'http://$h:8080', 'https://$h:443', 'http://$h:9095'];
    final client = _client();
    try {
      for (final base in tries) {
        try {
          final req = await client.getUrl(Uri.parse('$base/eSCL/ScannerCapabilities'));
          final res = await req.close().timeout(const Duration(seconds: 6));
          final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
          if (res.statusCode == 200 && body.contains('ScannerCapabilities')) {
            final m = RegExp(r'<[\w:]*MakeAndModel>([^<]+)<').firstMatch(body);
            return ScanDevice('escl', '$base/eSCL', m?.group(1)?.trim() ?? h);
          }
        } catch (_) {}
      }
    } finally {
      client.close(force: true);
    }
    throw ScanError('Não achei um scanner de rede em "$h". Confira o endereço e se o aparelho está ligado '
        'e na mesma rede. (Ele precisa aceitar AirScan/eSCL.)');
  }

  static String? _section(String xml, String tag) =>
      RegExp('<(?:\\w+:)?$tag>([\\s\\S]*?)</(?:\\w+:)?$tag>').firstMatch(xml)?.group(1);

  static List<String> _values(String xml, String tag) =>
      [for (final m in RegExp('<(?:\\w+:)?$tag>([^<]+)<').allMatches(xml)) m.group(1)!.trim()];

  /// Pedido de digitalização. Com [caps] (o XML de capacidades do scanner),
  /// resolução, cor, formato e área são ajustados ao que ele aceita.
  static String settingsXml(ScanSettings s, {required bool feeder, String caps = '', bool regions = true, bool bare = false}) {
    final duplex = feeder && s.duplex;
    final part = (feeder
            ? (duplex ? _section(caps, 'AdfDuplexInputCaps') : null) ?? _section(caps, 'AdfSimplexInputCaps')
            : _section(caps, 'PlatenInputCaps')) ??
        caps;
    // Resolução: a mais próxima da pedida entre as que o scanner oferece.
    var dpi = s.dpi;
    final offered = [for (final v in _values(part, 'XResolution')) int.tryParse(v)].whereType<int>().toList();
    if (offered.isNotEmpty) {
      dpi = offered.reduce((a, b) => (a - s.dpi).abs() <= (b - s.dpi).abs() ? a : b);
    }
    // Preto e branco puro raramente é aceito junto com JPEG; vai em tons de cinza.
    var mode = s.color == 'color' ? 'RGB24' : 'Grayscale8';
    final modes = _values(part, 'ColorMode');
    if (modes.isNotEmpty && !modes.contains(mode)) {
      mode = const ['RGB24', 'Grayscale8', 'BlackAndWhite1'].firstWhere(modes.contains, orElse: () => modes.first);
    }
    final formats = [..._values(part, 'DocumentFormat'), ..._values(part, 'DocumentFormatExt')];
    final format = formats.isEmpty || formats.contains('image/jpeg')
        ? 'image/jpeg'
        : (formats.contains('application/pdf') ? 'application/pdf' : formats.first);
    final maxW = int.tryParse(_values(part, 'MaxWidth').firstOrNull ?? '');
    final maxH = int.tryParse(_values(part, 'MaxHeight').firstOrNull ?? '');
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" '
        'xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">'
        '<pwg:Version>2.0</pwg:Version>'
        '${regions && maxW != null && maxH != null ? '<pwg:ScanRegions><pwg:ScanRegion>'
            '<pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>'
            '<pwg:Height>$maxH</pwg:Height><pwg:Width>$maxW</pwg:Width>'
            '<pwg:XOffset>0</pwg:XOffset><pwg:YOffset>0</pwg:YOffset>'
            '</pwg:ScanRegion></pwg:ScanRegions>' : ''}'
        '<pwg:InputSource>${feeder ? 'Feeder' : 'Platen'}</pwg:InputSource>'
        '<scan:ColorMode>$mode</scan:ColorMode>'
        '<pwg:DocumentFormat>$format</pwg:DocumentFormat>'
        '${!bare && (caps.isEmpty || caps.contains('DocumentFormatExt')) ? '<scan:DocumentFormatExt>$format</scan:DocumentFormatExt>' : ''}'
        '<scan:XResolution>$dpi</scan:XResolution>'
        '<scan:YResolution>$dpi</scan:YResolution>'
        '${feeder && (duplex || !bare) ? '<scan:Duplex>$duplex</scan:Duplex>' : ''}'
        '</scan:ScanSettings>';
  }

  static Future<String> _get(HttpClient client, String url) async {
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      return res.statusCode == 200 ? body : '';
    } catch (_) {
      return '';
    }
  }

  /// Estado do trabalho [job] segundo o ScannerStatus: (JobState, motivos).
  static (String, String) _jobState(String status, Uri job) {
    final id = job.pathSegments.lastWhere((e) => e.isNotEmpty, orElse: () => '');
    for (final m in RegExp(r'<(?:\w+:)?JobInfo>([\s\S]*?)</(?:\w+:)?JobInfo>').allMatches(status)) {
      final block = m.group(1)!;
      if (id.isNotEmpty && block.contains(id)) {
        return (_values(block, 'JobState').firstOrNull ?? '', _values(block, 'JobStateReason').join(', '));
      }
    }
    return ('', '');
  }

  static Future<void> _delete(Uri job) async {
    final c = _client();
    try {
      final req = await c.deleteUrl(job).timeout(const Duration(seconds: 3));
      await (await req.close().timeout(const Duration(seconds: 3))).drain<void>();
    } catch (_) {}
    c.close(force: true);
  }

  static Future<void> scan(ScanSettings s, String dir, void Function(String) onPage, ScanCancel cancel) async {
    final base = s.device;
    final client = _client();
    Uri? job;
    var feeder = false;
    // Passo a passo da conversa com o scanner; vai junto com o erro, se houver.
    final log = <String>[];
    String details() => log.join('\n');
    cancel._stop = () => client.close(force: true);
    try {
      // O que o scanner oferece e como está o alimentador agora.
      final caps = await _get(client, '$base/ScannerCapabilities');
      var adfState = _values(await _get(client, '$base/ScannerStatus'), 'AdfState').firstOrNull ?? '';
      final hasAdf = caps.isEmpty || _section(caps, 'Adf') != null;
      log.add('Scanner: ${_values(caps, 'MakeAndModel').firstOrNull ?? '?'} · eSCL ${_values(caps, 'Version').firstOrNull ?? '?'} · '
          'alimentador: ${caps.isEmpty ? 'capacidades não lidas' : (hasAdf ? 'sim' : 'não')} · '
          'frente e verso: ${_section(caps, 'AdfDuplexInputCaps') != null ? 'sim' : 'não'} · AdfState: ${adfState.isEmpty ? '(não informa)' : adfState}');
      if (cancel.canceled) return;
      if (s.source == 'feeder' && !hasAdf) {
        throw ScanError('Este scanner não tem alimentador de folhas. Use "Vidro" ou "Automático".', details());
      }
      // O estado do alimentador só decide no automático: há scanners que
      // informam "vazio" com papel, então no modo Alimentador a tentativa é feita de qualquer jeito.
      feeder = s.source == 'feeder' || (s.source == 'auto' && hasAdf && adfState == 'ScannerAdfLoaded');
      if (feeder && s.duplex && caps.isNotEmpty && _section(caps, 'AdfDuplexInputCaps') == null) {
        throw ScanError('Este scanner não faz frente e verso sozinho. Desmarque "Frente e verso".', details());
      }
      // Formas do pedido, da mais completa à mais simples: cada aparelho tem suas manias.
      final variants = <(String, bool, bool)>[
        ('completo', true, false),
        ('sem área', false, false),
        if (feeder) ('mínimo', false, true),
      ];
      var n = 0;
      var refused = 0;
      for (var v = 0; v < variants.length && n == 0 && !cancel.canceled; v++) {
        final (label, regions, bare) = variants[v];
        final xml = settingsXml(s, feeder: feeder, caps: caps, regions: regions, bare: bare);
        if (v > 0 && xml == settingsXml(s, feeder: feeder, caps: caps, regions: variants[v - 1].$2, bare: variants[v - 1].$3)) {
          continue; // igual ao pedido anterior: não adianta repetir
        }
        final HttpClientResponse created;
        try {
          final req = await client.postUrl(Uri.parse('$base/ScanJobs'));
          req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
          req.write(xml);
          created = await req.close().timeout(const Duration(seconds: 30));
        } catch (e) {
          if (cancel.canceled) return;
          log.add('Pedido $label: sem resposta ($e)');
          throw ScanError('Não consegui falar com o scanner de rede. Ele está ligado e na mesma rede?', details());
        }
        final reply = await created.transform(const Utf8Decoder(allowMalformed: true)).join();
        final loc = created.headers.value(HttpHeaders.locationHeader);
        log.add('Pedido $label (${feeder ? 'Feeder' : 'Platen'}): HTTP ${created.statusCode}'
            '${reply.trim().isEmpty ? '' : ' ${reply.trim().replaceAll(RegExp(r'\s+'), ' ')}'}');
        if (created.statusCode == 409 || created.statusCode == 400) {
          refused++;
          continue;
        }
        if (created.statusCode == 503) {
          throw ScanError('O scanner está ocupado. Espere um pouco e tente de novo.', details());
        }
        if (created.statusCode != 201 || loc == null) {
          throw ScanError('O scanner não aceitou o pedido de digitalização.', details());
        }
        final current = job = Uri.parse('$base/').resolve(loc);
        final next = Uri.parse('${current.toString().replaceAll(RegExp(r'/+$'), '')}/NextDocument');
        var busy = 0, early = 0;
        // Quantas vezes insistir quando a 1ª página "não existe" e o scanner não explica.
        final patience = v == 0 ? 8 : 2;
        while (!cancel.canceled && n < 500) {
          final req = await client.getUrl(next);
          final res = await req.close().timeout(const Duration(minutes: 3));
          final code = res.statusCode;
          if (code == 200) {
            n++;
            busy = 0;
            final type = res.headers.contentType?.subType ?? 'jpeg';
            final ext = type.contains('png') ? 'png' : (type.contains('pdf') ? 'pdf' : 'jpg');
            final path = p.join(dir, 'pagina_${n.toString().padLeft(4, '0')}.$ext');
            await res.pipe(File(path).openWrite());
            onPage(path);
            if (!feeder) break;
            continue;
          }
          await res.drain<void>();
          if (code == 503 && busy < 90) {
            // Ainda lendo a folha: espera e pergunta de novo.
            busy++;
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
          if (n > 0) break; // depois de alguma página, qualquer "não" é o fim do papel
          // Nenhuma página ainda: antes de desistir, pergunta ao scanner como está o trabalho.
          // Alguns respondem 404 enquanto ainda puxam a primeira folha.
          final status = await _get(client, '$base/ScannerStatus');
          final (state, reasons) = _jobState(status, current);
          adfState = _values(status, 'AdfState').firstOrNull ?? adfState;
          if (early == 0) {
            log.add('1ª página: HTTP $code · trabalho: ${state.isEmpty ? '(não informa)' : state}'
                '${reasons.isEmpty ? '' : ' ($reasons)'} · AdfState: ${adfState.isEmpty ? '(não informa)' : adfState}');
          }
          early++;
          final working = state == 'Pending' || state == 'Processing' || adfState == 'ScannerAdfProcessing';
          final over = state == 'Completed' || state == 'Aborted' || state == 'Canceled';
          if (working && early < 60) {
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
          if (!over && early < (adfState == 'ScannerAdfEmpty' ? 3 : patience)) {
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
          log.add('Desisti deste pedido depois de $early ${early == 1 ? 'tentativa' : 'tentativas'}.');
          break;
        }
        if (n == 0 && !cancel.canceled) {
          await _delete(current);
          job = null;
        }
      }
      if (n == 0 && !cancel.canceled) {
        final String msg;
        if (refused == variants.length) {
          msg = 'O scanner recusou essas opções. Tente outra resolução, cor ou origem do papel.';
        } else if (!feeder) {
          msg = 'O scanner não entregou a página.';
        } else if (adfState == 'ScannerAdfEmpty') {
          msg = 'O scanner informa que não há papel no alimentador. Empurre as folhas até o fim, '
              'até ele reconhecer o papel, e tente de novo.';
        } else if (adfState.contains('Jam')) {
          msg = 'Papel preso no alimentador.';
        } else if (adfState.contains('Open')) {
          msg = 'A tampa do alimentador está aberta.';
        } else {
          msg = 'O scanner não entregou nenhuma página pelo alimentador.';
        }
        throw ScanError(msg, details());
      }
    } on ScanError {
      rethrow;
    } catch (e) {
      if (cancel.canceled) return;
      log.add('$e');
      throw ScanError('A conexão com o scanner caiu durante a digitalização.', details());
    } finally {
      cancel._stop = null;
      if (cancel.canceled && job != null) await _delete(job); // avisa o scanner para largar o trabalho
      client.close(force: true);
    }
  }
}
