import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ffmpeg.dart' show FfError, uniquePath;
import 'job.dart';
import 'pdf.dart';
import 'signature.dart' show signerFromPkcs7;
import 'update.dart' show powershellEnv;

// Assinatura digital: conferir as assinaturas de um PDF e assinar com um
// certificado (arquivo .pfx/.p12 ou certificado instalado no Windows,
// inclusive os de cartão e token).
//
// O que é conferido e como o resultado é apresentado segue o módulo de
// assinatura do PdfCraft (https://github.com/storytold/pdfcraft, MIT OU
// Apache-2.0, © 2026 ArtCraft Team e colaboradores do PdfCraft). O código é
// novo: a estrutura do PDF é montada pelo qpdf e a criptografia fica com o
// próprio Windows (ou com o OpenSSL, fora dele).

/// Resultado da conferência de uma assinatura.
class SignatureCheck {
  SignatureCheck({
    required this.field,
    this.signer,
    this.issuer,
    this.signedAt,
    this.validFrom,
    this.validTo,
    this.intact,
    this.coversWholeFile = true,
    this.trusted,
    this.chainStatus,
    this.problem,
  });
  final String field;
  final String? signer, issuer, signedAt, validFrom, validTo;

  /// O conteúdo assinado confere com a assinatura? null = não deu para conferir.
  final bool? intact;

  /// Falso quando o arquivo recebeu algo depois desta assinatura.
  final bool coversWholeFile;

  /// O certificado é reconhecido por este computador? null = não conferido.
  final bool? trusted;
  final String? chainStatus, problem;

  /// Frase que resume a situação.
  String get verdict {
    if (intact == null) return problem ?? 'Não foi possível conferir esta assinatura.';
    if (intact == false) return 'Inválida: o conteúdo foi alterado depois de assinado, ou a assinatura está corrompida.';
    if (!coversWholeFile) return 'Íntegra, mas o arquivo recebeu acréscimos depois desta assinatura.';
    return 'Válida: o documento não foi alterado depois de assinado.';
  }

  String? get trustNote => switch (trusted) {
        null => null,
        true => 'O certificado é reconhecido por este computador.',
        false => 'O certificado não é reconhecido por este computador${chainStatus == null || chainStatus!.isEmpty ? '' : ' ($chainStatus)'}. '
            'Isso é comum em certificados de teste ou de autoridades que o Windows não traz instaladas.',
      };
}

/// Com o que assinar.
class SignIdentity {
  const SignIdentity.pfx(String path, String password)
      : pfxPath = path,
        pfxPassword = password,
        thumbprint = null;
  const SignIdentity.store(String thumb)
      : thumbprint = thumb,
        pfxPath = null,
        pfxPassword = null;
  final String? pfxPath, pfxPassword, thumbprint;
}

/// Certificado instalado no Windows que serve para assinar.
class StoreCert {
  StoreCert(this.name, this.issuer, this.validTo, this.thumbprint);
  final String name, issuer, validTo, thumbprint;
}

class _Verdict {
  bool? valid;
  bool? trusted;
  String? signer, issuer, signedAt, validFrom, validTo, chainStatus, error;
}

bool _ok(int code) => code == 0 || code == 3;

Future<ProcessResult> _ps(String script, List<String> args, {Map<String, String>? env, bool interactive = false}) async {
  final dir = await Directory.systemTemp.createTemp('filume_ps_');
  try {
    final f = File(p.join(dir.path, 'cmd.ps1'));
    // O bloco param(...) precisa ser a primeira coisa do script: a preparação vem depois dele.
    var body = script.trimLeft();
    var params = '';
    if (body.startsWith('param(')) {
      final end = body.indexOf('\n');
      params = '${body.substring(0, end)}\n';
      body = body.substring(end + 1);
    }
    await f.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('$params[Console]::OutputEncoding = [Text.Encoding]::UTF8\n\$ErrorActionPreference = "Stop"\n$body\n')]);
    return await Process.run(
      'powershell.exe',
      ['-NoProfile', if (!interactive) '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', f.path, ...args],
      environment: powershellEnv(env ?? const {}),
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

const _psSign = r'''
param([string]$Content, [string]$Out, [string]$Pfx, [string]$Thumb)
Add-Type -AssemblyName System.Security
$cert = $null
if ($Pfx) {
  try { $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Pfx, $env:FILUME_PFX_PASSWORD) }
  catch { Write-Output 'ERRO:senha'; exit 2 }
} else {
  $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $Thumb } | Select-Object -First 1
}
if (-not $cert) { Write-Output 'ERRO:nao-encontrado'; exit 2 }
if (-not $cert.HasPrivateKey) { Write-Output 'ERRO:sem-chave'; exit 2 }
$bytes = [IO.File]::ReadAllBytes($Content)
$last = $null
# Tenta mandar a cadeia junto; certificados soltos (de teste) vão sozinhos.
foreach ($include in 'ExcludeRoot', 'EndCertOnly') {
  try {
    $info = New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (, $bytes)
    $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $info, $true
    $signer = New-Object System.Security.Cryptography.Pkcs.CmsSigner -ArgumentList $cert
    $signer.IncludeOption = [System.Security.Cryptography.X509Certificates.X509IncludeOption]::$include
    $signer.DigestAlgorithm = New-Object System.Security.Cryptography.Oid -ArgumentList '2.16.840.1.101.3.4.2.1'
    [void]$signer.SignedAttributes.Add((New-Object System.Security.Cryptography.Pkcs.Pkcs9SigningTime))
    # $false: deixa o Windows pedir a senha do cartão ou token, se for o caso.
    $cms.ComputeSignature($signer, $false)
    [IO.File]::WriteAllBytes($Out, $cms.Encode())
    Write-Output ('OK:' + $cert.GetNameInfo('SimpleName', $false))
    exit 0
  } catch { $last = $_.Exception.Message }
}
Write-Output ('ERRO:' + $last)
exit 1
''';

const _psVerify = r'''
param([string]$Content, [string]$Sig)
Add-Type -AssemblyName System.Security
$r = @{ valid = $false; error = '' }
try {
  $info = New-Object System.Security.Cryptography.Pkcs.ContentInfo -ArgumentList (, [IO.File]::ReadAllBytes($Content))
  $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms -ArgumentList $info, $true
  $cms.Decode([IO.File]::ReadAllBytes($Sig))
  try { $cms.CheckSignature($true); $r.valid = $true } catch { $r.error = $_.Exception.Message }
  $si = $cms.SignerInfos[0]
  $c = $si.Certificate
  if ($c) {
    $r.signer = $c.GetNameInfo('SimpleName', $false)
    $r.issuer = $c.GetNameInfo('SimpleName', $true)
    $r.validFrom = $c.NotBefore.ToString('dd/MM/yyyy')
    $r.validTo = $c.NotAfter.ToString('dd/MM/yyyy')
    $when = $null
    foreach ($a in $si.SignedAttributes) {
      if ($a.Oid.Value -eq '1.2.840.113549.1.9.5') { $when = ([System.Security.Cryptography.Pkcs.Pkcs9SigningTime]$a.Values[0]).SigningTime.ToLocalTime() }
    }
    if ($when) { $r.signedAt = $when.ToString('dd/MM/yyyy HH:mm') }
    # A cadeia é conferida com o que está no arquivo e no computador, sem consultar a revogação na internet.
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    [void]$chain.ChainPolicy.ExtraStore.AddRange($cms.Certificates)
    if ($when) { $chain.ChainPolicy.VerificationTime = $when }
    $r.trusted = $chain.Build($c)
    $r.chainStatus = (($chain.ChainStatus | ForEach-Object { $_.Status.ToString() }) -join ', ')
  }
} catch { $r.error = $_.Exception.Message }
$r | ConvertTo-Json -Compress
''';

const _psList = r'''
$list = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } | ForEach-Object {
  @{ name = $_.GetNameInfo('SimpleName', $false); issuer = $_.GetNameInfo('SimpleName', $true); validTo = $_.NotAfter.ToString('dd/MM/yyyy'); thumb = $_.Thumbprint }
})
ConvertTo-Json -Compress -InputObject $list
''';

/// Certificados do Windows (do usuário) com chave para assinar. Fora do Windows, lista vazia.
Future<List<StoreCert>> listStoreCerts() async {
  if (!Platform.isWindows) return const [];
  try {
    final r = await _ps(_psList, const []).timeout(const Duration(seconds: 25));
    final j = jsonDecode(r.stdout.toString().trim());
    return [
      for (final c in (j is List ? j : [j]))
        if (c is Map && c['thumb'] is String) StoreCert('${c['name'] ?? '?'}', '${c['issuer'] ?? ''}', '${c['validTo'] ?? ''}', c['thumb'] as String),
    ];
  } catch (_) {
    return const [];
  }
}

Future<String> _openssl(List<String> args, {Map<String, String>? env}) async {
  final r = await Process.run('openssl', args, environment: env, stdoutEncoding: utf8, stderrEncoding: utf8);
  if (r.exitCode != 0) throw FfError('O OpenSSL não conseguiu concluir a operação.', r.stderr.toString());
  return r.stdout.toString();
}

/// Assina [content] (assinatura separada, CMS/PKCS#7) e devolve a assinatura em DER.
Future<(Uint8List, String)> _cmsSign(String content, SignIdentity id, String workDir) async {
  final out = p.join(workDir, 'assinatura.der');
  if (Platform.isWindows) {
    final r = await _ps(
      _psSign,
      ['-Content', content, '-Out', out, if (id.pfxPath != null) ...['-Pfx', id.pfxPath!] else ...['-Thumb', id.thumbprint!]],
      env: {if (id.pfxPassword != null) 'FILUME_PFX_PASSWORD': id.pfxPassword!},
      interactive: id.pfxPath == null,
    );
    final line = const LineSplitter().convert(r.stdout.toString()).where((l) => l.startsWith('OK:') || l.startsWith('ERRO:')).lastOrNull ?? '';
    if (line.startsWith('OK:') && File(out).existsSync()) return (File(out).readAsBytesSync(), line.substring(3));
    throw FfError(switch (line) {
      'ERRO:senha' => 'Não foi possível abrir o certificado: a senha está errada ou o arquivo não é um certificado válido.',
      'ERRO:nao-encontrado' => 'O certificado escolhido não foi encontrado neste computador.',
      'ERRO:sem-chave' => 'Este certificado não tem a chave privada, então não serve para assinar.',
      _ => 'O Windows não conseguiu assinar com este certificado.',
    }, '${line.startsWith('ERRO:') ? line.substring(5) : ''}\n${r.stderr}');
  }
  final pfx = id.pfxPath;
  if (pfx == null) throw FfError('Fora do Windows, a assinatura precisa de um arquivo de certificado (.pfx ou .p12).');
  final pem = p.join(workDir, 'certificado.pem');
  final env = {'FILUME_PFX_PASSWORD': id.pfxPassword ?? ''};
  try {
    try {
      await _openssl(['pkcs12', '-in', pfx, '-passin', 'env:FILUME_PFX_PASSWORD', '-nodes', '-out', pem], env: env);
    } on FfError catch (e) {
      throw FfError('Não foi possível abrir o certificado: a senha está errada ou o arquivo não é um certificado válido.', e.details);
    }
    await _openssl(['cms', '-sign', '-binary', '-in', content, '-signer', pem, '-inkey', pem, '-md', 'sha256', '-outform', 'DER', '-out', out]);
  } finally {
    try {
      File(pem).deleteSync();
    } catch (_) {}
  }
  final der = File(out).readAsBytesSync();
  return (der, signerFromPkcs7(der) ?? '');
}

Future<_Verdict> _cmsVerify(String content, String sig) async {
  final v = _Verdict();
  if (Platform.isWindows) {
    final r = await _ps(_psVerify, ['-Content', content, '-Sig', sig]);
    try {
      final j = jsonDecode(r.stdout.toString().trim().split('\n').last) as Map;
      v
        ..valid = j['valid'] == true
        ..error = '${j['error'] ?? ''}'
        ..signer = j['signer'] as String?
        ..issuer = j['issuer'] as String?
        ..signedAt = j['signedAt'] as String?
        ..validFrom = j['validFrom'] as String?
        ..validTo = j['validTo'] as String?
        ..trusted = j['trusted'] is bool ? j['trusted'] as bool : null
        ..chainStatus = j['chainStatus'] as String?;
      // Assinatura ilegível não é o mesmo que assinatura inválida.
      if (v.valid == false && v.signer == null) v.valid = null;
    } catch (_) {
      v.error = r.stderr.toString();
    }
    return v;
  }
  final r = await Process.run('openssl', ['cms', '-verify', '-binary', '-inform', 'DER', '-in', sig, '-content', content, '-noverify', '-out', Platform.isWindows ? 'NUL' : '/dev/null'],
      stdoutEncoding: utf8, stderrEncoding: utf8);
  final err = r.stderr.toString();
  // Sem OpenSSL, ou assinatura num formato que ele não lê: não conferido.
  v.valid = r.exitCode == 0 ? true : (err.contains('digest failure') || err.contains('Verification failure') ? false : null);
  v.error = r.exitCode == 0 ? '' : err;
  try {
    v.signer = signerFromPkcs7(File(sig).readAsBytesSync());
  } catch (_) {}
  return v;
}

/// Corta os zeros que sobram depois da assinatura (o espaço reservado é maior que ela).
Uint8List _trimDer(Uint8List d) {
  if (d.length < 2 || d[0] != 0x30) return d;
  var len = d[1], head = 2;
  if (len & 0x80 != 0) {
    final n = len & 0x7F;
    if (n == 0 || n > 4 || d.length < 2 + n) return d;
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | d[2 + i];
    }
    head = 2 + n;
  }
  return head + len <= d.length ? Uint8List.sublistView(d, 0, head + len) : d;
}

String _plain(dynamic v) => v is String ? (v.startsWith('u:') ? v.substring(2) : v) : '';

/// Confere todas as assinaturas digitais de [file].
Future<List<SignatureCheck>> verifySignatures(PdfTools tools, String file) async {
  final r = await Process.run(tools.qpdf, ['--json=2', '--json-stream-data=none', '--json-key=acroform', '--json-key=qpdf', file],
      stdoutEncoding: const Utf8Codec(allowMalformed: true), stderrEncoding: utf8);
  if (!_ok(r.exitCode)) {
    final err = r.stderr.toString();
    throw FfError(err.contains('password') ? '"${p.basename(file)}" é protegido por senha. Remova a senha antes (ferramenta Senha).' : 'Não foi possível ler "${p.basename(file)}".', err);
  }
  final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  final objects = ((j['qpdf'] as List)[1] as Map).cast<String, dynamic>();
  final fields = (j['acroform'] as Map?)?['fields'] as List? ?? const [];
  final bytes = await File(file).readAsBytes();
  final out = <SignatureCheck>[];
  final work = await Directory.systemTemp.createTemp('filume_assin_');
  try {
    for (final f in fields) {
      if (f is! Map || f['fieldtype'] != '/Sig') continue;
      final name = '${f['fullname'] ?? 'Assinatura'}';
      var v = f['value'];
      if (v is String && v.endsWith(' R')) v = (objects['obj:$v'] as Map?)?['value'];
      if (v is! Map) continue; // campo de assinatura ainda em branco
      final range = v['/ByteRange'];
      final sub = '${v['/SubFilter'] ?? ''}';
      final declared = _plain(v['/Name']);
      if (range is! List || range.length != 4 || range.any((x) => x is! int)) {
        out.add(SignatureCheck(field: name, signer: declared.isEmpty ? null : declared, problem: 'A assinatura não diz que parte do arquivo ela cobre.'));
        continue;
      }
      final a = range[0] as int, b = range[1] as int, c = range[2] as int, d = range[3] as int;
      if (a < 0 || b < 0 || c < a + b || d < 0 || c + d > bytes.length) {
        out.add(SignatureCheck(field: name, signer: declared.isEmpty ? null : declared, intact: false, problem: 'A área assinada não cabe no arquivo.'));
        continue;
      }
      final covers = c + d >= bytes.length;
      // Entre as duas partes assinadas fica a própria assinatura, em hexadecimal.
      final hex = latin1.decode(bytes.sublist(a + b, c)).replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
      final der = _trimDer(Uint8List.fromList([for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]));
      if (sub != '/adbe.pkcs7.detached' && sub != '/ETSI.CAdES.detached') {
        out.add(SignatureCheck(
          field: name,
          signer: signerFromPkcs7(der) ?? (declared.isEmpty ? null : declared),
          coversWholeFile: covers,
          problem: 'Esta assinatura usa um formato antigo (${sub.replaceFirst('/', '')}) que o FiPDF ainda não confere.',
        ));
        continue;
      }
      final content = File(p.join(work.path, 'conteudo_${out.length}.bin'));
      final sink = content.openSync(mode: FileMode.write);
      sink.writeFromSync(bytes, a, a + b);
      sink.writeFromSync(bytes, c, c + d);
      sink.closeSync();
      final sig = File(p.join(work.path, 'assinatura_${out.length}.der'))..writeAsBytesSync(der);
      final res = await _cmsVerify(content.path, sig.path);
      out.add(SignatureCheck(
        field: name,
        signer: res.signer ?? signerFromPkcs7(der) ?? (declared.isEmpty ? null : declared),
        issuer: res.issuer,
        signedAt: res.signedAt,
        validFrom: res.validFrom,
        validTo: res.validTo,
        intact: res.valid,
        coversWholeFile: covers,
        trusted: res.trusted,
        chainStatus: res.chainStatus,
        problem: res.valid == null ? 'Não foi possível conferir esta assinatura neste computador.' : null,
      ));
    }
  } finally {
    try {
      await work.delete(recursive: true);
    } catch (_) {}
  }
  return out;
}

/// Espaço reservado para a assinatura, em bytes (a cadeia de certificados vai junto).
const _sigRoom = 16384;
const _rangeHolder = '/ByteRange [ 0 9999999999 9999999999 9999999999 ]';

String _winAnsiLiteral(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    if (r == 0x28 || r == 0x29 || r == 0x5C) {
      sb.write('\\${String.fromCharCode(r)}');
    } else if (r >= 32 && r < 127) {
      sb.writeCharCode(r);
    } else if (r >= 160 && r <= 255) {
      sb.write('\\${r.toRadixString(8).padLeft(3, '0')}');
    } else {
      sb.write('?');
    }
  }
  return sb.toString();
}

String _pdfDate(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final off = t.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final m = off.inMinutes.abs();
  return "D:${t.year}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}$sign${two(m ~/ 60)}'${two(m % 60)}'";
}

int _find(Uint8List hay, List<int> needle, [int from = 0]) {
  outer:
  for (var i = from; i + needle.length <= hay.length; i++) {
    for (var k = 0; k < needle.length; k++) {
      if (hay[i + k] != needle[k]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Assina [file] e grava em [out]. Com [visible], a última página ganha um
/// carimbo com o nome e a data no canto de baixo.
///
/// O arquivo é regravado antes de assinar; assinaturas que ele já tinha deixam
/// de valer (quem chama deve avisar).
Future<String> signPdf(
  PdfTools tools,
  String file,
  String out,
  SignIdentity id, {
  String reason = '',
  String location = '',
  bool visible = true,
  DateTime? when,
}) async {
  final now = when ?? DateTime.now();
  final r = await Process.run(tools.qpdf, ['--json=2', '--json-stream-data=none', '--json-key=qpdf', '--json-key=pages', '--json-key=encrypt', file],
      stdoutEncoding: const Utf8Codec(allowMalformed: true), stderrEncoding: utf8);
  if (!_ok(r.exitCode)) {
    final err = r.stderr.toString();
    throw FfError(err.contains('password') ? '"${p.basename(file)}" é protegido por senha. Remova a senha antes (ferramenta Senha).' : 'Não foi possível ler "${p.basename(file)}".', err);
  }
  final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  if ((j['encrypt'] as Map?)?['encrypted'] == true) throw FfError('Este PDF é protegido. Remova a proteção antes de assinar (ferramenta Senha).');
  final q = j['qpdf'] as List;
  final header = (q[0] as Map).cast<String, dynamic>();
  final objects = (q[1] as Map).cast<String, dynamic>();
  final pages = j['pages'] as List? ?? const [];
  if (pages.isEmpty) throw FfError('O PDF não tem páginas.');
  Map<String, dynamic> copy(String ref) {
    final o = objects['obj:$ref'];
    if (o is! Map || o['value'] is! Map) throw FfError('O PDF tem uma estrutura que não deu para assinar.');
    return (jsonDecode(jsonEncode(o['value'])) as Map).cast<String, dynamic>();
  }

  final rootRef = ((objects['trailer'] as Map)['value'] as Map)['/Root'] as String;
  final pageRef = (pages.last as Map)['object'] as String;
  final root = copy(rootRef), page = copy(pageRef);
  final base = (header['maxobjectid'] as num).toInt();
  final sigRef = '${base + 1} 0 R', fieldRef = '${base + 2} 0 R', apRef = '${base + 3} 0 R';
  final changed = <String, dynamic>{};

  // Nome do campo que ainda não existe no formulário.
  final taken = <String>{};
  void names(dynamic v) {
    if (v is Map) {
      if (v['/T'] is String) taken.add(_plain(v['/T']));
      v.values.forEach(names);
    } else if (v is List) {
      v.forEach(names);
    }
  }

  names(objects);
  var n = 1;
  while (taken.contains('Assinatura$n')) {
    n++;
  }

  // O nome de quem assina só é conhecido depois de abrir o certificado; o
  // carimbo é escrito com o que o certificado disser.
  final work = await Directory.systemTemp.createTemp('filume_assinar_');
  try {
    // 1ª passada: assina um conteúdo qualquer só para abrir o certificado e saber o nome.
    final probe = File(p.join(work.path, 'sonda.bin'))..writeAsBytesSync([0]);
    final (_, who) = await _cmsSign(probe.path, id, work.path);
    final signer = who.trim().isEmpty ? 'Assinante' : who.trim();

    changed['obj:$sigRef'] = {
      'value': {
        '/Type': '/Sig',
        '/Filter': '/Adobe.PPKLite',
        '/SubFilter': '/adbe.pkcs7.detached',
        '/M': 'u:${_pdfDate(now)}',
        '/Name': 'u:$signer',
        if (reason.trim().isNotEmpty) '/Reason': 'u:${reason.trim()}',
        if (location.trim().isNotEmpty) '/Location': 'u:${location.trim()}',
        '/ByteRange': [0, 9999999999, 9999999999, 9999999999],
        '/Contents': 'b:${'00' * _sigRoom}',
      },
    };
    List<num> rect = [0, 0, 0, 0];
    if (visible) {
      final box = (page['/CropBox'] ?? page['/MediaBox'] ?? (pages.last as Map)['mediabox']) as dynamic;
      var l = 0.0, b = 0.0, rr = 595.0;
      if (box is List && box.length == 4 && box.every((x) => x is num)) {
        l = (box[0] as num).toDouble();
        b = (box[1] as num).toDouble();
        rr = (box[2] as num).toDouble();
      }
      const w = 210.0, h = 46.0, margin = 24.0;
      rect = [rr - margin - w, b + margin, rr - margin, b + margin + h];
      if (rect[0] < l) rect = [l + 4, b + margin, l + 4 + w, b + margin + h];
      String two(int v) => v.toString().padLeft(2, '0');
      final date = '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}';
      final shown = signer.length > 38 ? '${signer.substring(0, 37)}…' : signer;
      final ap = '0.97 0.97 0.99 rg 0.35 0.38 0.55 RG 0.8 w 0.4 0.4 ${w - 0.8} ${h - 0.8} re B '
          'BT 0.2 0.22 0.35 rg /F1 7.5 Tf 8 ${h - 13} Td (Assinado digitalmente por) Tj ET '
          'BT 0.08 0.08 0.12 rg /F2 10 Tf 8 ${h - 26} Td (${_winAnsiLiteral(shown)}) Tj ET '
          'BT 0.2 0.22 0.35 rg /F1 7.5 Tf 8 8 Td (${_winAnsiLiteral(date)}) Tj ET';
      Map<String, String> font(String base) => {'/Type': '/Font', '/Subtype': '/Type1', '/BaseFont': base, '/Encoding': '/WinAnsiEncoding'};
      changed['obj:$apRef'] = {
        'stream': {
          'dict': {
            '/Type': '/XObject',
            '/Subtype': '/Form',
            '/BBox': [0, 0, w, h],
            '/Resources': {
              '/Font': {'/F1': font('/Helvetica'), '/F2': font('/Helvetica-Bold')},
            },
          },
          'data': base64.encode(latin1.encode(ap)),
        },
      };
    }
    changed['obj:$fieldRef'] = {
      'value': {
        '/Type': '/Annot',
        '/Subtype': '/Widget',
        '/FT': '/Sig',
        '/T': 'u:Assinatura$n',
        '/V': sigRef,
        '/Rect': rect,
        '/F': 132,
        '/P': pageRef,
        if (visible) '/AP': {'/N': apRef},
      },
    };
    // A anotação entra na página…
    final annots = page['/Annots'];
    if (annots is String) {
      final list = objects['obj:$annots'];
      final cur = list is Map && list['value'] is List ? [...(list['value'] as List)] : <dynamic>[];
      changed['obj:$annots'] = {'value': [...cur, fieldRef]};
    } else {
      page['/Annots'] = [...(annots is List ? annots : const []), fieldRef];
      changed['obj:$pageRef'] = {'value': page};
    }
    // …e o campo, no formulário do documento.
    final acro = root['/AcroForm'];
    Map<String, dynamic> form;
    if (acro is String) {
      form = copy(acro);
      changed['obj:$acro'] = {'value': form};
    } else {
      form = acro is Map ? acro.cast<String, dynamic>() : <String, dynamic>{};
      root['/AcroForm'] = form;
      changed['obj:$rootRef'] = {'value': root};
    }
    final fieldsNow = form['/Fields'];
    if (fieldsNow is String) {
      final list = objects['obj:$fieldsNow'];
      final cur = list is Map && list['value'] is List ? [...(list['value'] as List)] : <dynamic>[];
      changed['obj:$fieldsNow'] = {'value': [...cur, fieldRef]};
    } else {
      form['/Fields'] = [...(fieldsNow is List ? fieldsNow : const []), fieldRef];
    }
    form['/SigFlags'] = 3;

    header['maxobjectid'] = base + 3;
    final upd = File(p.join(work.path, 'assinatura.json'));
    await upd.writeAsString(jsonEncode({
      'qpdf': [header, changed],
    }));
    final shaped = p.join(work.path, 'pronto.pdf');
    final w = await Process.run(tools.qpdf, [file, '--update-from-json=${upd.path}', '--object-streams=disable', shaped], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (!_ok(w.exitCode) || !File(shaped).existsSync()) throw FfError('Não foi possível preparar o PDF para a assinatura.', w.stderr.toString());

    final bytes = await File(shaped).readAsBytes();
    final holder = latin1.encode('<${'0' * (_sigRoom * 2)}>');
    final cStart = _find(bytes, holder);
    final rStart = _find(bytes, latin1.encode(_rangeHolder));
    if (cStart < 0 || rStart < 0 || _find(bytes, holder, cStart + 1) >= 0) {
      throw FfError('Não foi possível localizar o espaço da assinatura no arquivo.');
    }
    final cEnd = cStart + holder.length;
    final range = '/ByteRange [0 $cStart $cEnd ${bytes.length - cEnd}';
    final padded = '${range.padRight(_rangeHolder.length - 1)}]';
    if (padded.length != _rangeHolder.length) throw FfError('O arquivo é grande demais para o espaço reservado à assinatura.');
    bytes.setAll(rStart, latin1.encode(padded));

    final content = File(p.join(work.path, 'conteudo.bin'));
    final sink = content.openSync(mode: FileMode.write);
    sink.writeFromSync(bytes, 0, cStart);
    sink.writeFromSync(bytes, cEnd, bytes.length);
    sink.closeSync();
    final (der, _) = await _cmsSign(content.path, id, work.path);
    if (der.length > _sigRoom) throw FfError('A assinatura ficou maior que o espaço reservado (${der.length} bytes).');
    final hex = StringBuffer();
    for (final b in der) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    bytes.setAll(cStart + 1, latin1.encode(hex.toString().padRight(_sigRoom * 2, '0')));
    await File(out).writeAsBytes(bytes, flush: true);
    return signer;
  } finally {
    try {
      await work.delete(recursive: true);
    } catch (_) {}
  }
}

/// Tarefa que assina e confere o resultado antes de entregar.
Job buildSignJob(PdfTools tools, String file, String outDir, String name, SignIdentity id, {String reason = '', String location = '', bool visible = true}) => Job(
      title: '$name.pdf',
      kind: 'Assinar',
      detail: p.basename(file),
      body: (ctx) async {
        ctx.report(0.2, stage: 'Assinando');
        await Directory(outDir).create(recursive: true);
        final out = uniquePath(p.join(outDir, '$name.pdf'));
        final String signer;
        try {
          signer = await signPdf(tools, file, out, id, reason: reason, location: location, visible: visible);
          ctx.report(0.8, stage: 'Conferindo');
          final checks = await verifySignatures(tools, out);
          final mine = checks.lastOrNull;
          if (mine == null || mine.intact == false || !mine.coversWholeFile) {
            throw FfError('A assinatura foi gravada, mas não passou na conferência. Nada foi entregue.');
          }
        } catch (_) {
          try {
            File(out).deleteSync();
          } catch (_) {}
          rethrow;
        }
        return JobResult('Assinado por $signer', out);
      },
    );
