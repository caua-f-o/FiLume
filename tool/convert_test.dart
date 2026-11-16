// Teste do conversor universal (sem interface): dart run tool/convert_test.dart
// FILUME_REQUIRE_HEIC=1 exige que a leitura de HEIC com o FFmpeg funcione.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:filume/core/ffmpeg.dart';
import 'package:filume/core/heif.dart';
import 'package:filume/core/job.dart';
import 'package:filume/core/office.dart';
import 'package:filume/core/pdf.dart';
import 'package:filume/core/universal.dart';
import 'package:path/path.dart' as p;

var bad = 0;
void check(String label, bool ok, [String extra = '']) {
  print('${ok ? 'OK' : 'FALHA'} $label ${ok && extra.length > 90 ? '' : extra}');
  if (!ok) bad++;
}

late FfTools tools;
late ConvCaps caps;

Future<JobResult?> conv(String path, String ext, {UniversalSettings? s, MediaInfo? info, bool expectError = false, String? group}) async {
  final settings = s ?? UniversalSettings();
  final targets = targetsFor(path, caps, info: info);
  final to = targets.where((t) => t.ext == ext && (group == null || t.group == group)).firstOrNull;
  if (to == null) {
    check('${p.basename(path)} → $ext: formato oferecido', expectError, 'oferecidos: ${targets.map((t) => t.ext).join(',')}');
    return null;
  }
  final job = buildUniversalJob(path: path, to: to, settings: settings, caps: caps, info: info);
  try {
    final r = await job.body(JobCtx(tools, FfRun(), (_, __, ___) {}));
    if (expectError) check('${p.basename(path)} → $ext devia recusar', false);
    return r;
  } catch (e) {
    if (!expectError) check('${p.basename(path)} → $ext', false, e.toString().split('\n').take(8).join(' | '));
    return null;
  }
}

/// Cor (r, g, b) de um ponto da imagem, lida pelo FFmpeg.
Future<List<int>> pixel(String image, int x, int y) async {
  final r = await Process.run(tools.ffmpeg, [
    '-v', 'error', '-i', image, '-vf', 'crop=1:1:$x:$y', '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
  ], stdoutEncoding: null);
  final b = r.stdout as List<int>;
  return b.length >= 3 ? b.sublist(0, 3) : [-1, -1, -1];
}

bool near(List<int> c, int r, int g, int b) => (c[0] - r).abs() < 60 && (c[1] - g).abs() < 60 && (c[2] - b).abs() < 60;

/// ZIP mínimo (um arquivo, comprimido) para testar a leitura de docx.
Uint8List zip(String name, List<int> data) {
  final n = utf8.encode(name);
  final comp = ZLibEncoder(raw: true).convert(data);
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  crc ^= 0xFFFFFFFF;
  final b = BytesBuilder();
  void u16(int v) => b.add([v & 255, v >> 8]);
  void u32(int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  u32(0x04034b50); u16(20); u16(0); u16(8); u16(0); u16(0); u32(crc); u32(comp.length); u32(data.length); u16(n.length); u16(0);
  b.add(n); b.add(comp);
  final cd = b.length;
  u32(0x02014b50); u16(20); u16(20); u16(0); u16(8); u16(0); u16(0); u32(crc); u32(comp.length); u32(data.length);
  u16(n.length); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0);
  b.add(n);
  final end = b.length;
  u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(end - cd); u32(cd); u16(0);
  return b.toBytes();
}

Future<void> main() async {
  tools = (await FfTools.locate())!;
  final pdf = await PdfTools.locate();
  caps = await ConvCaps.detect(tools, pdf);
  print('office: ${caps.office.any ? caps.office.label : 'nenhum'} · heic(gravar): ${caps.heicEncode} · jxl: ${caps.jxl} · gs: ${pdf?.gs != null}');
  final dir = await Directory.systemTemp.createTemp('filume_convtest_');
  final d = dir.path;
  Future<void> gen(List<String> args) async {
    final r = await Process.run(tools.ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', ...args]);
    if (r.exitCode != 0) print('gerar: ${r.stderr}');
  }

  // ---------------------------------------------------------------- tipos
  check('tipos pela extensão', kindOf('a.HEIC') == FileKind.image && kindOf('b.docx') == FileKind.doc && kindOf('c.mkv') == FileKind.video &&
      kindOf('d.flac') == FileKind.audio && kindOf('e.xlsx') == FileKind.sheet && kindOf('f.zip') == null);
  check('não oferece o próprio formato (imagem)', !targetsFor('a.jpeg', caps).any((t) => t.ext == 'jpg') && targetsFor('a.png', caps).any((t) => t.ext == 'jpg'));
  final none = ConvCaps();
  check('sem pacote de escritório: só o que é embutido',
      targetsFor('a.docx', none).map((t) => t.ext).join() == 'txt' && targetsFor('a.txt', none).map((t) => t.ext).join() == 'pdf' &&
          targetsFor('a.xlsx', none).isEmpty && missingNote('a.xlsx', none) != null);

  // -------------------------------------------------------------- imagens
  await gen(['-i', "testsrc2=s=300x200,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lt(X,150),255,80)'", '-frames:v', '1', '$d/alpha.png']);
  await gen(['-i', 'testsrc2=s=1280x852', '-frames:v', '1', '-q:v', '2', '$d/foto.jpg']);
  await gen(['-i', 'testsrc=s=121x91:r=5:d=1', '$d/anim.gif']);
  final alpha = await tools.probe('$d/alpha.png');
  final foto = await tools.probe('$d/foto.jpg');
  for (final ext in targetsFor('$d/alpha.png', caps).map((t) => t.ext).where((e) => e != 'heic' && e != 'ico')) {
    final r = await conv('$d/alpha.png', ext, info: alpha);
    if (r == null) continue;
    if (ext == 'pdf') {
      check('imagem → pdf', File(r.revealPath).readAsBytesSync().take(5).join(',') == '37,80,68,70,45');
    } else {
      final i = await tools.probe(r.revealPath);
      check('imagem → $ext', i.width == 300 && i.height == 200, '${i.width}x${i.height}');
    }
  }
  final small = await conv('$d/foto.jpg', 'png', info: foto, s: UniversalSettings()..imageMaxSide = 640);
  if (small != null) {
    final i = await tools.probe(small.revealPath);
    check('imagem: limite de tamanho mantém a proporção', i.width == 640 && (i.height - 426).abs() <= 1, '${i.width}x${i.height}');
  }
  final ico = await conv('$d/foto.jpg', 'ico', info: foto);
  if (ico != null) {
    final i = await tools.probe(ico.revealPath);
    check('ícone cabe em 256', i.width == 256 && i.height <= 256, '${i.width}x${i.height}');
  }
  final merged = buildImagesPdfJob([('$d/foto.jpg', foto), ('$d/alpha.png', alpha)], UniversalSettings()..outDir = '$d/junto');
  try {
    final r = await merged.body(JobCtx(tools, FfRun(), (_, __, ___) {}));
    final n = pdf == null ? 2 : (await pdf.probe(r.revealPath)).pages;
    check('várias imagens → um PDF', n == 2, '$n páginas');
  } catch (e) {
    check('várias imagens → um PDF', false, '$e');
  }
  final gif = await tools.probe('$d/anim.gif');
  final gifMp4 = await conv('$d/anim.gif', 'mp4', info: gif);
  if (gifMp4 != null) {
    final i = await tools.probe(gifMp4.revealPath);
    check('GIF animado → MP4 (lados pares)', i.vCodec == 'h264' && i.width == 120 && i.height == 90, '${i.vCodec} ${i.width}x${i.height}');
  }

  // ----------------------------------------------------------------- HEIC
  final fx = p.join('tool', 'fixtures', 'heic');
  final grid = parseHeif(File(p.join(fx, 'grade.heic')).readAsBytesSync());
  check('HEIC em grade: estrutura', grid != null && grid.isGrid && grid.rows == 2 && grid.cols == 3 && grid.width == 180 && grid.height == 120 &&
      grid.tileWidth == 64 && grid.displaySize == (120, 180) && grid.transforms.join() == 'transpose=2',
      grid == null ? 'não leu' : '${grid.rows}x${grid.cols} ${grid.width}x${grid.height} ${grid.transforms}');
  final single = parseHeif(File(p.join(fx, 'simples.heic')).readAsBytesSync());
  check('HEIC simples: estrutura', single != null && !single.isGrid && single.width == 128 && single.displaySize == (64, 128) && single.transforms.join() == 'transpose=1');
  check('arquivo que não é HEIC', parseHeif(File('$d/foto.jpg').readAsBytesSync()) == null && parseHeif(Uint8List(0)) == null);
  final args = heifDecodeArgs('x.heic', grid!, {for (var i = 1; i <= 6; i++) i: i - 1, 7: 6});
  check('HEIC em grade: comando monta, corta e gira',
      args != null && args.last.contains('xstack=inputs=6:layout=0_0|64_0|128_0|0_64|64_64|128_64') && args.last.contains('crop=180:120:0:0,transpose=2[out]'),
      '${args?.last}');
  final ver = RegExp(r'ffmpeg version n?(\d+)').firstMatch((await Process.run(tools.ffmpeg, ['-version'])).stdout.toString());
  final major = int.tryParse(ver?[1] ?? '') ?? 99;
  final must = Platform.environment['FILUME_REQUIRE_HEIC'] == '1';
  if (major < 7 && !must) {
    print('AVISO: este FFmpeg ($major) não lê HEIC; a conversão de HEIC não rodou aqui.');
  } else {
    final g = await conv(p.join(fx, 'grade.heic'), 'png', s: UniversalSettings()..outDir = '$d/heic');
    if (g != null) {
      final i = await tools.probe(g.revealPath);
      // Antes de girar: vermelho | verde em cima, azul | amarelo embaixo. Girada 90° anti-horário.
      final tl = await pixel(g.revealPath, 20, 20), tr = await pixel(g.revealPath, 100, 20);
      final bl = await pixel(g.revealPath, 20, 160), br = await pixel(g.revealPath, 100, 160);
      check('HEIC em grade → PNG: tamanho, corte e rotação',
          i.width == 120 && i.height == 180 && near(tl, 0, 255, 0) && near(tr, 255, 255, 0) && near(bl, 255, 0, 0) && near(br, 0, 0, 255),
          '${i.width}x${i.height} $tl $tr $bl $br');
    }
    final sgl = await conv(p.join(fx, 'simples.heic'), 'jpg', s: UniversalSettings()..outDir = '$d/heic');
    if (sgl != null) {
      final i = await tools.probe(sgl.revealPath);
      final top = await pixel(sgl.revealPath, 32, 20), bottom = await pixel(sgl.revealPath, 32, 100);
      check('HEIC simples → JPG: rotação', i.width == 64 && i.height == 128 && near(top, 255, 0, 0) && near(bottom, 0, 0, 255), '${i.width}x${i.height} $top $bottom');
      if (!(i.width == 64 && i.height == 128)) {
        final st = await heifStreams(tools, p.join(fx, 'simples.heic'));
        print('DIAG simples: primaryId=${single?.primaryId} fluxos=$st');
        final a = heifDecodeArgs(p.join(fx, 'simples.heic'), single!, st);
        print('DIAG args=$a');
        if (a != null) {
          final r = await Process.run(tools.ffmpeg, [...a, '-map', '[out]', '-frames:v', '1', '-c:v', 'png', '-update', '1', '-y', '$d/diag.png']);
          final di = await tools.probe('$d/diag.png');
          print('DIAG ffmpeg exit=${r.exitCode} saída=${di.width}x${di.height}');
          final fl = File('$d/heic/${p.basenameWithoutExtension(sgl.revealPath)}.jpg');
          print('DIAG revealPath=${sgl.revealPath} existe=${fl.existsSync()}');
        }
      }
    }
    final hp = await conv(p.join(fx, 'grade.heic'), 'pdf', s: UniversalSettings()..outDir = '$d/heic');
    check('HEIC → PDF', hp != null && File(hp.revealPath).lengthSync() > 500);
  }
  if (caps.heicEncode) {
    final h = await conv('$d/foto.jpg', 'heic', info: foto);
    final info = h == null ? null : parseHeif(File(h.revealPath).readAsBytesSync());
    check('JPG → HEIC (codificador do Windows)', info != null && info.displaySize == (1280, 852), '${info?.displaySize}');
  } else {
    print('AVISO: este computador não grava HEIC (sem o codificador HEVC do Windows); a opção fica escondida.');
  }

  // -------------------------------------------------------- vídeo e áudio
  await gen(['-i', 'testsrc2=s=640x360:r=30:d=3', '-f', 'lavfi', '-i', 'sine=d=3', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '$d/video.mp4']);
  final video = await tools.probe('$d/video.mp4');
  for (final (ext, codec) in [('mkv', 'h264'), ('mov', 'h264'), ('avi', 'mpeg4'), ('gif', 'gif')]) {
    final r = await conv('$d/video.mp4', ext, info: video);
    if (r == null) continue;
    final i = await tools.probe(r.revealPath);
    check('vídeo → $ext', i.vCodec == codec && (ext == 'gif' ? i.width == 480 : i.width == 640), '${i.vCodec} ${i.width}x${i.height}');
  }
  if (targetsFor('$d/video.mp4', caps).any((t) => t.ext == 'webm')) {
    final r = await conv('$d/video.mp4', 'webm', info: video);
    if (r != null) {
      final i = await tools.probe(r.revealPath);
      check('vídeo → webm', (i.vCodec == 'av1' || i.vCodec == 'vp9') && i.audioCount == 1, '${i.vCodec}');
    }
  }
  final v240 = await conv('$d/video.mp4', 'mp4', info: video, s: UniversalSettings()..videoMaxHeight = 240);
  if (v240 != null) {
    final i = await tools.probe(v240.revealPath);
    check('vídeo: reduzir resolução', i.height == 240 && p.basename(v240.revealPath) == 'video_convertido.mp4', '${i.width}x${i.height} ${p.basename(v240.revealPath)}');
  }
  for (final ext in ['mp3', 'flac']) {
    final r = await conv('$d/video.mp4', ext, info: video, group: 'Só o áudio');
    if (r == null) continue;
    final i = await tools.probe(r.revealPath);
    check('vídeo → $ext (só o áudio)', i.audioCount == 1 && i.videoIndex == null && (i.duration - 3).abs() < 0.3, '${i.aCodec} ${i.duration}');
  }
  await gen(['-i', 'sine=d=2:f=440', '-ac', '2', '$d/som.wav']);
  final som = await tools.probe('$d/som.wav');
  for (final t in targetsFor('$d/som.wav', caps)) {
    final r = await conv('$d/som.wav', t.ext, info: som);
    if (r == null) continue;
    final i = await tools.probe(r.revealPath);
    check('áudio → ${t.ext}', i.audioCount == 1 && (i.duration - 2).abs() < 0.3, '${i.aCodec} ${i.duration}');
  }
  final mudo = '$d/mudo.mp4';
  await gen(['-i', 'testsrc2=s=320x240:r=10:d=1', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', mudo]);
  final mudoInfo = await tools.probe(mudo);
  check('vídeo sem som não oferece "só o áudio"', !targetsFor(mudo, caps, info: mudoInfo).any((t) => t.group == 'Só o áudio'));

  // -------------------------------------------------------------- legendas
  File('$d/leg.srt').writeAsBytesSync(latin1.encode('1\r\n00:00:01,000 --> 00:00:02,500\r\nOlá, você está aí?\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nAção!\r\n'));
  final vtt = await conv('$d/leg.srt', 'vtt');
  if (vtt != null) {
    final text = File(vtt.revealPath).readAsStringSync();
    check('legenda antiga (Windows-1252) → WebVTT com acentos', text.startsWith('WEBVTT') && text.contains('Olá, você está aí?') && text.contains('00:01.000 --> 00:02.500'), text);
  }
  final ass = await conv('$d/leg.srt', 'ass');
  check('legenda → ASS', ass != null && File(ass.revealPath).readAsStringSync().contains('Ação!'));

  // ------------------------------------------------------ texto e documentos
  final long = [for (var i = 1; i <= 150; i++) 'Linha $i: ação, coração e pão de queijo — “aspas” (parênteses) \\ barra.'].join('\n');
  File('$d/nota.txt').writeAsStringSync('$long\n${'palavra ' * 40}\n日本語');
  final missing = await writeTextPdf(readTextFile('$d/nota.txt'), '$d/nota_direto.pdf');
  check('texto → PDF: caracteres fora da fonte contados', missing == 3, '$missing');
  if (pdf != null) {
    final info = await pdf.probe('$d/nota_direto.pdf');
    final chk = await Process.run(pdf.qpdf, ['--check', '$d/nota_direto.pdf']);
    check('texto → PDF: arquivo válido, 3 páginas', info.pages == 3 && chk.exitCode == 0, '${info.pages} páginas, qpdf ${chk.exitCode} ${chk.stderr}');
    if (pdf.gs != null) {
      final t = await conv('$d/nota_direto.pdf', 'txt', info: info);
      final text = t == null ? '' : File(t.revealPath).readAsStringSync();
      check('PDF → texto traz os acentos de volta', text.contains('Linha 150: ação, coração e pão de queijo') && text.contains('(parênteses) \\ barra'), text.length > 300 ? text.substring(0, 300) : text);
      final imgs = await conv('$d/nota_direto.pdf', 'jpg', info: info, s: UniversalSettings()..pdfDpi = 60);
      check('PDF de 3 páginas → pasta com 3 imagens', imgs != null && Directory(imgs.revealPath).listSync().length == 3, '${imgs?.revealPath}');
      final one = '$d/uma.pdf';
      await writeTextPdf('Uma página só.', one);
      final img = await conv(one, 'png', info: await pdf.probe(one), s: UniversalSettings()..pdfDpi = 60);
      check('PDF de 1 página → um arquivo', img != null && File(img.revealPath).existsSync() && img.revealPath.endsWith('uma.png'), '${img?.revealPath}');
    }
  }
  final docx = zip('word/document.xml', utf8.encode(
      '<?xml version="1.0"?><w:document><w:body><w:p><w:r><w:t>Primeiro parágrafo: ação &amp; reação.</w:t></w:r></w:p>'
      '<w:p><w:r><w:t xml:space="preserve">Segundo </w:t><w:tab/><w:t>com tabulação</w:t><w:br/><w:t>e quebra.</w:t></w:r></w:p></w:body></w:document>'));
  File('$d/carta.docx').writeAsBytesSync(docx);
  check('docx → texto (leitura embutida)', docxText(docx) == 'Primeiro parágrafo: ação & reação.\nSegundo \tcom tabulação\ne quebra.\n', jsonEncode(docxText(docx)));
  final odt = zip('content.xml', utf8.encode(
      '<office:document-content><office:body><office:text><text:h>Título</text:h><text:p>Olá<text:s text:c="3"/>mundo<text:tab/>fim &lt;ok&gt;</text:p></office:text></office:body></office:document-content>'));
  check('odt → texto (leitura embutida)', odtText(odt) == 'Título\nOlá   mundo\tfim <ok>\n', jsonEncode(odtText(odt)));
  // Sem pacote de escritório, as conversões embutidas têm de funcionar sozinhas.
  final saved = caps;
  caps = ConvCaps(encoders: saved.encoders, pdf: saved.pdf);
  final viaTxt = await conv('$d/carta.docx', 'txt', s: UniversalSettings()..outDir = '$d/embutido');
  check('docx → txt sem pacote de escritório', viaTxt != null && File(viaTxt.revealPath).readAsStringSync().contains('ação & reação'));
  final viaPdf = await conv('$d/nota.txt', 'pdf', s: UniversalSettings()..outDir = '$d/embutido');
  check('txt → pdf sem pacote de escritório (avisa dos caracteres trocados)', viaPdf != null && viaPdf.warning != null && File(viaPdf.revealPath).lengthSync() > 1000);
  await conv('$d/carta.docx', 'pdf', expectError: true);
  caps = saved;

  if (caps.office.any) {
    File('$d/tabela.csv').writeAsStringSync('nome,valor\nmaçã,3\npão,5\n');
    File('$d/oficio.txt').writeAsStringSync('Primeiro parágrafo: ação e reação.\n\nSegundo parágrafo.\n');
    final made = await conv('$d/oficio.txt', 'docx');
    final real = made?.revealPath ?? '';
    check('txt → docx (${caps.office.label})', made != null && (docxText(File(real).readAsBytesSync()) ?? '').contains('ação e reação'));
    final dPdf = made == null ? null : await conv(real, 'pdf', s: UniversalSettings()..outDir = '$d/office');
    if (dPdf != null && pdf != null) {
      final info = await pdf.probe(dPdf.revealPath);
      check('docx → PDF', info.pages == 1);
      final back = await conv(dPdf.revealPath, 'docx', info: info);
      final text = back == null ? null : docxText(File(back.revealPath).readAsBytesSync());
      check('PDF → docx', text != null && text.contains('Primeiro'), '${text?.length}');
    }
    for (final ext in made == null ? const <String>[] : ['odt', 'rtf', 'txt', 'html']) {
      final r = await conv(real, ext, s: UniversalSettings()..outDir = '$d/office');
      check('docx → $ext', r != null && File(r.revealPath).lengthSync() > 20);
    }
    final x = await conv('$d/tabela.csv', 'xlsx');
    check('csv → xlsx', x != null && zipEntry(File(x.revealPath).readAsBytesSync(), 'xl/workbook.xml') != null);
    if (x != null) {
      final c = await conv(x.revealPath, 'csv', s: UniversalSettings()..outDir = '$d/office');
      check('xlsx → csv mantém acentos', c != null && File(c.revealPath).readAsStringSync().contains('maçã'), c == null ? '' : File(c.revealPath).readAsStringSync());
      final xp = await conv(x.revealPath, 'pdf', s: UniversalSettings()..outDir = '$d/office');
      check('xlsx → PDF', xp != null && File(xp.revealPath).lengthSync() > 500);
    }
  } else {
    print('AVISO: sem LibreOffice nem Microsoft Office aqui; as conversões de documentos de escritório não rodaram.');
  }

  dir.deleteSync(recursive: true);
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
