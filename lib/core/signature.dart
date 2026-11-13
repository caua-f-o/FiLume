import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Assinaturas digitais de um PDF. O FiLume identifica quem assinou e se o
/// arquivo mudou depois; ele não confere a validade criptográfica nem a
/// cadeia de certificados (isso é papel de um validador, como o do gov.br).
class PdfSignature {
  PdfSignature({
    required this.field,
    this.signer,
    this.date,
    this.reason,
    this.location,
    this.certification = false,
    this.coversWholeFile = true,
  });

  /// Nome do campo de assinatura no PDF.
  final String field;

  /// Quem assinou (do certificado ou do próprio campo), quando dá para ler.
  final String? signer;

  /// Data declarada na assinatura, já formatada (dd/mm/aaaa hh:mm).
  final String? date;
  final String? reason, location;

  /// Assinatura de certificação (o autor limita o que pode mudar depois).
  final bool certification;

  /// Falso quando o arquivo recebeu algo depois desta assinatura
  /// (outra assinatura, por exemplo).
  final bool coversWholeFile;

  String get summary => [
        signer ?? 'assinante não identificado',
        if (date != null) date!,
      ].join(' · ');
}

String? _text(Object? v) {
  if (v is! String) return null;
  final t = v.startsWith('u:') ? v.substring(2) : v;
  return t.trim().isEmpty ? null : t.trim();
}

/// "D:20261112191659-03'00'" → "12/11/2026 19:16".
String? formatPdfDate(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'D:(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?').firstMatch(raw);
  if (m == null) return null;
  final date = '${m[3] ?? '01'}/${m[2] ?? '01'}/${m[1]}';
  return m[4] == null ? date : '$date ${m[4]}:${m[5] ?? '00'}';
}

// ---- leitura mínima de DER, só para achar o nome de quem assinou

class _Tlv {
  _Tlv(this.tag, this.start, this.end);
  final int tag, start, end;
}

_Tlv? _read(Uint8List d, int pos, int limit) {
  if (pos + 2 > limit) return null;
  final tag = d[pos];
  var len = d[pos + 1];
  var at = pos + 2;
  if (len & 0x80 != 0) {
    final n = len & 0x7F;
    if (n == 0 || n > 4 || at + n > limit) return null; // comprimento indefinido: não lido
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | d[at + i];
    }
    at += n;
  }
  if (at + len > limit) return null;
  return _Tlv(tag, at, at + len);
}

List<_Tlv> _children(Uint8List d, _Tlv parent) {
  final out = <_Tlv>[];
  var pos = parent.start;
  while (pos < parent.end) {
    final t = _read(d, pos, parent.end);
    if (t == null) break;
    out.add(t);
    pos = t.end;
  }
  return out;
}

bool _same(Uint8List d, _Tlv a, _Tlv b) {
  if (a.end - a.start != b.end - b.start) return false;
  for (var i = 0; i < a.end - a.start; i++) {
    if (d[a.start + i] != d[b.start + i]) return false;
  }
  return true;
}

/// Nome comum (CN) dentro de um "Name" X.509.
String? _commonName(Uint8List d, _Tlv name) {
  String? cn;
  for (final set in _children(d, name)) {
    for (final pair in _children(d, set)) {
      final kv = _children(d, pair);
      if (kv.length < 2) continue;
      final oid = kv[0];
      if (oid.end - oid.start == 3 && d[oid.start] == 0x55 && d[oid.start + 1] == 4 && d[oid.start + 2] == 3) {
        final bytes = d.sublist(kv[1].start, kv[1].end);
        if (kv[1].tag == 0x1E) {
          cn = String.fromCharCodes([
            for (var i = 0; i + 1 < bytes.length; i += 2) (bytes[i] << 8) | bytes[i + 1],
          ]);
        } else {
          cn = kv[1].tag == 0x0C ? utf8.decode(bytes, allowMalformed: true) : latin1.decode(bytes);
        }
      }
    }
  }
  return cn;
}

/// Quem assinou, a partir do bloco PKCS#7 da assinatura.
String? signerFromPkcs7(Uint8List d) {
  try {
    final info = _read(d, 0, d.length);
    if (info == null) return null;
    final top = _children(d, info);
    if (top.length < 2) return null;
    final signed = _children(d, top[1]).first;
    final parts = _children(d, signed);
    final certs = <(_Tlv serial, _Tlv issuer, _Tlv subject)>[];
    _Tlv? signers;
    for (final part in parts) {
      if (part.tag == 0xA0) {
        for (final cert in _children(d, part)) {
          final tbs = _children(d, _children(d, cert).first);
          final o = tbs.isNotEmpty && tbs.first.tag == 0xA0 ? 1 : 0;
          if (tbs.length >= o + 5) certs.add((tbs[o], tbs[o + 2], tbs[o + 4]));
        }
      } else if (part.tag == 0x31) {
        signers = part; // o último SET é o de assinantes
      }
    }
    if (certs.isEmpty) return null;
    // O certificado do assinante é o que o SignerInfo aponta pelo número de série…
    if (signers != null) {
      final si = _children(d, signers);
      if (si.isNotEmpty) {
        final fields = _children(d, si.first);
        if (fields.length >= 2 && fields[1].tag == 0x30) {
          final sid = _children(d, fields[1]);
          if (sid.length >= 2) {
            for (final c in certs) {
              if (_same(d, c.$1, sid[1]) && _same(d, c.$2, sid[0])) return _clean(_commonName(d, c.$3));
            }
          }
        }
      }
    }
    // …ou, na falta, o que não emitiu nenhum outro (a ponta da cadeia).
    for (final c in certs) {
      if (!certs.any((o) => !identical(o, c) && _same(d, o.$2, c.$3))) return _clean(_commonName(d, c.$3));
    }
    return _clean(_commonName(d, certs.first.$3));
  } catch (_) {
    return null;
  }
}

/// Certificados ICP-Brasil trazem "NOME:CPF"; o número fica de fora.
String? _clean(String? cn) {
  if (cn == null) return null;
  final name = cn.replaceFirst(RegExp(r':\d[\d.\-/]*$'), '').trim();
  return name.isEmpty ? null : name;
}

Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Future<Map<String, dynamic>?> _json(String qpdf, List<String> args) async {
  final r = await Process.run(qpdf, args, stdoutEncoding: const Utf8Codec(allowMalformed: true));
  if (r.exitCode != 0 && r.exitCode != 3) return null;
  try {
    return jsonDecode(r.stdout as String) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// Lê as assinaturas digitais de [path] (lista vazia se não houver).
Future<List<PdfSignature>> readSignatures(String qpdf, String path) async {
  final form = await _json(qpdf, ['--json=2', '--json-key=acroform', path]);
  final fields = (form?['acroform'] as Map?)?['fields'];
  if (fields is! List) return const [];
  final refs = <String, String>{}; // "24 0 R" → nome do campo
  final inline = <String, Map>{};
  for (final f in fields) {
    if (f is! Map || f['fieldtype'] != '/Sig') continue;
    final name = (f['fullname'] ?? f['partialname'] ?? 'Assinatura').toString();
    final v = f['value'];
    if (v is String && RegExp(r'^\d+ \d+ R$').hasMatch(v)) {
      refs[v] = name;
    } else if (v is Map) {
      inline[name] = v;
    }
  }
  if (refs.isEmpty && inline.isEmpty) return const [];
  final dicts = <String, Map>{...inline};
  if (refs.isNotEmpty) {
    final objs = await _json(qpdf, [
      '--json=2', '--json-key=qpdf',
      for (final r in refs.keys) '--json-object=${r.split(' ')[0]},${r.split(' ')[1]}',
      path,
    ]);
    final list = objs?['qpdf'];
    if (list is List && list.length > 1 && list[1] is Map) {
      for (final e in (list[1] as Map).entries) {
        final ref = e.key.toString().replaceFirst('obj:', '');
        final value = e.value is Map ? (e.value as Map)['value'] : null;
        if (refs.containsKey(ref) && value is Map) dicts[refs[ref]!] = value;
      }
    }
    // Campo assinado cujo conteúdo não deu para ler: ainda conta como assinatura.
    for (final name in refs.values) {
      dicts.putIfAbsent(name, () => const {});
    }
  }
  final size = File(path).lengthSync();
  final out = <PdfSignature>[];
  for (final e in dicts.entries) {
    final d = e.value;
    String? signer;
    final contents = d['/Contents'];
    if (contents is String && contents.startsWith('b:')) {
      signer = signerFromPkcs7(_hex(contents.substring(2)));
    }
    final range = d['/ByteRange'];
    var whole = true;
    if (range is List && range.length == 4 && range.every((x) => x is int)) {
      whole = (range[2] as int) + (range[3] as int) >= size;
    }
    out.add(PdfSignature(
      field: e.key,
      signer: signer ?? _text(d['/Name']),
      date: formatPdfDate(_text(d['/M'])),
      reason: _text(d['/Reason']),
      location: _text(d['/Location']),
      certification: d['/Reference'].toString().contains('DocMDP'),
      coversWholeFile: whole,
    ));
  }
  return out;
}
