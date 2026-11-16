import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'ffmpeg.dart';

/// Leitura de fotos HEIC/HEIF (iPhone e Android recentes).
///
/// O arquivo guarda a foto principal quase sempre cortada em ladrilhos (uma
/// grade de imagens pequenas), mais miniaturas e a rotação da câmera. O FFmpeg
/// entrega cada ladrilho como um vídeo separado; aqui a estrutura do arquivo é
/// lida para montar o comando que junta os ladrilhos, corta a sobra e aplica a
/// rotação, devolvendo a foto como ela aparece no celular.
class HeifInfo {
  HeifInfo({
    required this.primaryId,
    required this.width,
    required this.height,
    required this.transforms,
    this.rows = 1,
    this.cols = 1,
    this.tileIds = const [],
    this.tileWidth = 0,
    this.tileHeight = 0,
  });

  /// Item principal (a foto em si, ou a grade que a monta).
  final int primaryId;

  /// Tamanho da foto antes da rotação.
  final int width, height;

  /// Rotações e espelhamentos, na ordem em que devem ser aplicados
  /// (filtros do FFmpeg: transpose, hflip, vflip).
  final List<String> transforms;

  final int rows, cols;

  /// Itens dos ladrilhos, linha por linha. Vazio quando a foto é uma imagem só.
  final List<int> tileIds;
  final int tileWidth, tileHeight;

  bool get isGrid => tileIds.isNotEmpty;

  /// Tamanho como a foto aparece (com a rotação aplicada).
  (int, int) get displaySize {
    var w = width, h = height;
    for (final t in transforms) {
      if (t.startsWith('transpose')) (w, h) = (h, w);
    }
    return (w, h);
  }
}

class _Box {
  _Box(this.type, this.start, this.end);
  final String type;

  /// Início e fim do conteúdo (depois do cabeçalho).
  final int start, end;
}

class _Reader {
  _Reader(this.d);
  final ByteData d;

  int u8(int o) => d.getUint8(o);
  int u16(int o) => d.getUint16(o);
  int u32(int o) => d.getUint32(o);
  int uN(int o, int n) => switch (n) { 0 => 0, 1 => u8(o), 2 => u16(o), 4 => u32(o), 8 => d.getUint64(o), _ => throw const FormatException('campo') };
  String fourcc(int o) => latin1.decode([u8(o), u8(o + 1), u8(o + 2), u8(o + 3)]);

  List<_Box> boxes(int start, int end) {
    final out = <_Box>[];
    var o = start;
    while (o + 8 <= end) {
      var size = u32(o);
      final type = fourcc(o + 4);
      var head = 8;
      if (size == 1) {
        if (o + 16 > end) break;
        size = d.getUint64(o + 8);
        head = 16;
      } else if (size == 0) {
        size = end - o;
      }
      if (size < head || o + size > end) break;
      out.add(_Box(type, o + head, o + size));
      o += size;
    }
    return out;
  }
}

/// Lê a estrutura de um HEIC/HEIF. Devolve null se o arquivo não for um ou
/// estiver fora do que o FiLume entende.
HeifInfo? parseHeif(Uint8List bytes) {
  try {
    final r = _Reader(ByteData.sublistView(bytes));
    final top = r.boxes(0, bytes.length);
    final meta = top.where((b) => b.type == 'meta').firstOrNull;
    if (meta == null) return null;
    // "meta" é FullBox: 4 bytes de versão e flags antes dos filhos.
    final kids = r.boxes(meta.start + 4, meta.end);
    _Box? kid(String t) => kids.where((b) => b.type == t).firstOrNull;

    final pitm = kid('pitm');
    if (pitm == null) return null;
    final primary = r.u8(pitm.start) == 0 ? r.u16(pitm.start + 4) : r.u32(pitm.start + 4);

    // Tipo de cada item.
    final types = <int, String>{};
    final iinf = kid('iinf');
    if (iinf != null) {
      final v = r.u8(iinf.start);
      for (final e in r.boxes(iinf.start + (v == 0 ? 6 : 8), iinf.end)) {
        if (e.type != 'infe') continue;
        final ev = r.u8(e.start);
        if (ev == 2) {
          types[r.u16(e.start + 4)] = r.fourcc(e.start + 8);
        } else if (ev == 3) {
          types[r.u32(e.start + 4)] = r.fourcc(e.start + 10);
        }
      }
    }

    // Propriedades (tamanho, rotação, espelho) e a quem pertencem.
    final iprp = kid('iprp');
    if (iprp == null) return null;
    final iprpKids = r.boxes(iprp.start, iprp.end);
    final ipco = iprpKids.where((b) => b.type == 'ipco').firstOrNull;
    if (ipco == null) return null;
    final props = r.boxes(ipco.start, ipco.end);
    final assoc = <int, List<int>>{};
    for (final ipma in iprpKids.where((b) => b.type == 'ipma')) {
      final v = r.u8(ipma.start), wide = (r.u8(ipma.start + 3) & 1) != 0;
      final n = r.u32(ipma.start + 4);
      var o = ipma.start + 8;
      for (var i = 0; i < n; i++) {
        final id = v < 1 ? r.u16(o) : r.u32(o);
        o += v < 1 ? 2 : 4;
        final count = r.u8(o++);
        final list = assoc.putIfAbsent(id, () => []);
        for (var k = 0; k < count; k++) {
          if (wide) {
            list.add(r.u16(o) & 0x7FFF);
            o += 2;
          } else {
            list.add(r.u8(o++) & 0x7F);
          }
        }
      }
    }
    (int, int)? sizeOf(int id) {
      for (final i in assoc[id] ?? const <int>[]) {
        if (i < 1 || i > props.length) continue;
        final b = props[i - 1];
        if (b.type == 'ispe') return (r.u32(b.start + 4), r.u32(b.start + 8));
      }
      return null;
    }

    final transforms = <String>[];
    for (final i in assoc[primary] ?? const <int>[]) {
      if (i < 1 || i > props.length) continue;
      final b = props[i - 1];
      if (b.type == 'irot') {
        // Giro anti-horário em passos de 90°.
        switch (r.u8(b.start) & 3) {
          case 1:
            transforms.add('transpose=2');
          case 2:
            transforms.addAll(const ['hflip', 'vflip']);
          case 3:
            transforms.add('transpose=1');
        }
      } else if (b.type == 'imir') {
        transforms.add((r.u8(b.start) & 1) == 0 ? 'hflip' : 'vflip');
      }
    }

    final size = sizeOf(primary);
    if (types[primary] != 'grid') {
      if (size == null) return null;
      return HeifInfo(primaryId: primary, width: size.$1, height: size.$2, transforms: transforms);
    }

    // Grade: os ladrilhos são as referências "dimg" do item principal.
    final iref = kid('iref');
    if (iref == null) return null;
    final rv = r.u8(iref.start);
    final idSize = rv == 0 ? 2 : 4;
    var tiles = <int>[];
    for (final ref in r.boxes(iref.start + 4, iref.end)) {
      if (ref.type != 'dimg' || r.uN(ref.start, idSize) != primary) continue;
      final n = r.u16(ref.start + idSize);
      tiles = [for (var k = 0; k < n; k++) r.uN(ref.start + idSize + 2 + k * idSize, idSize)];
    }
    if (tiles.isEmpty) return null;

    // Linhas, colunas e tamanho final ficam no conteúdo do item da grade.
    final data = _itemData(r, kids, primary, bytes.length);
    if (data == null || data.$2 < 8) return null;
    final o = data.$1;
    final big = (r.u8(o + 1) & 1) != 0;
    final rows = r.u8(o + 2) + 1, cols = r.u8(o + 3) + 1;
    final w = big ? r.u32(o + 4) : r.u16(o + 4);
    final h = big ? r.u32(o + 8) : r.u16(o + 6);
    final tile = sizeOf(tiles.first);
    if (tile == null || rows * cols != tiles.length || w <= 0 || h <= 0) return null;
    return HeifInfo(
      primaryId: primary,
      width: w,
      height: h,
      transforms: transforms,
      rows: rows,
      cols: cols,
      tileIds: tiles,
      tileWidth: tile.$1,
      tileHeight: tile.$2,
    );
  } catch (_) {
    return null;
  }
}

/// Posição e tamanho do conteúdo de um item (primeiro trecho), pelo "iloc".
(int, int)? _itemData(_Reader r, List<_Box> kids, int item, int fileLen) {
  final iloc = kids.where((b) => b.type == 'iloc').firstOrNull;
  if (iloc == null) return null;
  final idat = kids.where((b) => b.type == 'idat').firstOrNull;
  final v = r.u8(iloc.start);
  final offSize = r.u8(iloc.start + 4) >> 4, lenSize = r.u8(iloc.start + 4) & 15;
  final baseSize = r.u8(iloc.start + 5) >> 4, idxSize = v == 0 ? 0 : r.u8(iloc.start + 5) & 15;
  var o = iloc.start + 6;
  final count = v < 2 ? r.u16(o) : r.u32(o);
  o += v < 2 ? 2 : 4;
  for (var i = 0; i < count; i++) {
    final id = v < 2 ? r.u16(o) : r.u32(o);
    o += v < 2 ? 2 : 4;
    var method = 0;
    if (v == 1 || v == 2) {
      method = r.u16(o) & 15;
      o += 2;
    }
    o += 2; // data_reference_index
    final base = r.uN(o, baseSize);
    o += baseSize;
    final extents = r.u16(o);
    o += 2;
    (int, int)? first;
    for (var e = 0; e < extents; e++) {
      o += idxSize;
      final off = r.uN(o, offSize);
      o += offSize;
      final len = r.uN(o, lenSize);
      o += lenSize;
      first ??= (off, len);
    }
    if (id != item || first == null) continue;
    if (method == 1) {
      if (idat == null) return null;
      final start = idat.start + base + first.$1;
      final len = first.$2 == 0 ? idat.end - start : first.$2;
      return start + len <= idat.end ? (start, len) : null;
    }
    if (method != 0) return null;
    final start = base + first.$1;
    final len = first.$2 == 0 ? fileLen - start : first.$2;
    return start + len <= fileLen ? (start, len) : null;
  }
  return null;
}

bool isHeifPath(String path) {
  final l = path.toLowerCase();
  return l.endsWith('.heic') || l.endsWith('.heif') || l.endsWith('.hif');
}

/// Lê só o começo do arquivo (onde fica a estrutura) para não carregar a foto inteira.
Future<HeifInfo?> readHeif(String path) async {
  try {
    final f = File(path);
    final len = await f.length();
    final raf = await f.open();
    try {
      // A estrutura costuma caber nos primeiros KB; a grade pode apontar para
      // o fim do arquivo, então arquivos comuns (até 64 MB) são lidos inteiros.
      final bytes = await raf.read(len <= 64 * 1024 * 1024 ? len : 4 * 1024 * 1024);
      return parseHeif(bytes);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}

/// Argumentos do FFmpeg (da entrada até o rótulo `[out]`) que montam a foto.
/// [streamOfItem] diz em que fluxo do FFmpeg está cada item do arquivo.
List<String>? heifDecodeArgs(String path, HeifInfo info, Map<int, int> streamOfItem) {
  final tail = [
    if (info.isGrid && (info.cols * info.tileWidth != info.width || info.rows * info.tileHeight != info.height))
      'crop=${info.width}:${info.height}:0:0',
    ...info.transforms,
  ];
  String chain(String src) => '$src${tail.isEmpty ? 'null' : tail.join(',')}[out]';
  if (!info.isGrid) {
    final s = streamOfItem[info.primaryId];
    if (s == null) return null;
    return ['-noautorotate', '-display_rotation', '0', '-i', path, '-filter_complex', chain('[0:$s]')];
  }
  final ins = StringBuffer();
  final layout = <String>[];
  for (var i = 0; i < info.tileIds.length; i++) {
    final s = streamOfItem[info.tileIds[i]];
    if (s == null) return null;
    ins.write('[0:$s]');
    layout.add('${(i % info.cols) * info.tileWidth}_${(i ~/ info.cols) * info.tileHeight}');
  }
  if (info.tileIds.length == 1) {
    return ['-noautorotate', '-display_rotation', '0', '-i', path, '-filter_complex', chain(ins.toString())];
  }
  return [
    '-noautorotate', '-display_rotation', '0', '-i', path,
    '-filter_complex',
    '${ins}xstack=inputs=${info.tileIds.length}:layout=${layout.join('|')}[grid];${chain('[grid]')}',
  ];
}

/// Em que fluxo do FFmpeg está cada item (o FFmpeg usa o número do item como
/// identificador do fluxo).
Future<Map<int, int>> heifStreams(FfTools tools, String path) async {
  final r = await Process.run(
    tools.ffprobe,
    ['-v', 'error', '-show_entries', 'stream=index,id', '-of', 'json', path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final map = <int, int>{};
  if (r.exitCode != 0) return map;
  try {
    final streams = (jsonDecode(r.stdout.toString()) as Map)['streams'];
    if (streams is! List) return map;
    for (final s in streams) {
      if (s is! Map) continue;
      final idx = s['index'], id = s['id'];
      if (idx is! int) continue;
      final item = id is int ? id : (id is String ? int.tryParse(id.replaceFirst('0x', ''), radix: id.startsWith('0x') ? 16 : 10) : null);
      if (item != null) map[item] = idx;
    }
  } catch (_) {}
  return map;
}

/// Tamanho de uma imagem PNG (lido do cabeçalho).
(int, int)? pngSize(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final h = raf.readSync(24);
      if (h.length < 24 || h[1] != 0x50 || h[2] != 0x4E || h[3] != 0x47) return null;
      final d = ByteData.sublistView(h);
      return (d.getUint32(16), d.getUint32(20));
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// Converte a foto HEIC em PNG, em [outPng]. Tenta com o FFmpeg (montando os
/// ladrilhos) e, se não der certo, com o decodificador do Windows.
Future<void> decodeHeif(FfTools tools, FfRun run, String path, String outPng) async {
  final info = await readHeif(path);
  String? why;
  if (info != null) {
    final args = heifDecodeArgs(path, info, await heifStreams(tools, path));
    if (args != null) {
      try {
        await run.ffmpeg(tools, [...args, '-map', '[out]', '-frames:v', '1', '-c:v', 'png', '-update', '1', outPng]);
        // Só vale se saiu do tamanho que o arquivo diz ter.
        if (pngSize(outPng) == info.displaySize) return;
        why = 'a imagem montada saiu com tamanho diferente do esperado';
      } on JobCanceled {
        rethrow;
      } catch (e) {
        why = e.toString();
      }
    } else {
      why = 'este FFmpeg não separa os pedaços da foto';
    }
  } else {
    why = 'estrutura do arquivo não reconhecida';
  }
  if (Platform.isWindows && await _wicDecode(run, path, outPng)) return;
  throw FfError(
    'Não foi possível abrir esta foto HEIC/HEIF.',
    '$why. O decodificador do Windows também não abriu: para ele, é preciso ter as '
        '"Extensões de Imagem HEIF" e "Extensões de Vídeo HEVC" da Microsoft Store.',
  );
}

/// Decodificador de imagens do Windows (usa as extensões HEIF/HEVC instaladas).
Future<bool> _wicDecode(FfRun run, String path, String outPng) async {
  const script = r'''
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore
$in = [IO.File]::OpenRead($args[0])
try {
  $dec = [Windows.Media.Imaging.BitmapDecoder]::Create($in, 'PreservePixelFormat', 'OnLoad')
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($dec.Frames[0]))
  $out = [IO.File]::Create($args[1])
  try { $enc.Save($out) } finally { $out.Close() }
} finally { $in.Close() }
''';
  try {
    final dir = await Directory.systemTemp.createTemp('filume_wic_');
    try {
      final ps = File('${dir.path}${Platform.pathSeparator}heif.ps1')..writeAsStringSync(script);
      final code = await run.exec('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps.path, path, outPng]);
      return code == 0 && pngSize(outPng) != null;
    } finally {
      await dir.delete(recursive: true);
    }
  } on JobCanceled {
    rethrow;
  } catch (_) {
    return false;
  }
}
