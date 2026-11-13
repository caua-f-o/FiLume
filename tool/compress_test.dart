// Teste do compressor de PDF (níveis e opções avançadas):
//   dart run tool/compress_test.dart
// Monta um "documento escaneado" de texto e um PDF de fotos e comprime os dois.
import 'dart:io';
import 'package:filume/core/ffmpeg.dart';
import 'package:filume/core/job.dart';
import 'package:filume/core/pdf.dart';

Future<void> main() async {
  final tools = (await FfTools.locate())!;
  final pdf = (await PdfTools.locate())!;
  final dir = await Directory.systemTemp.createTemp('filume_comptest_');
  final d = dir.path;
  JobCtx ctx() => JobCtx(tools, FfRun(), (p, s, sp) {});
  var bad = 0;
  void check(String label, bool ok, [String extra = '']) {
    print('${ok ? 'OK' : 'FALHA'} $label $extra');
    if (!ok) bad++;
  }

  // Texto "escaneado": páginas de texto viram JPEG colorido de 200 dpi e voltam a ser PDF.
  final ps = StringBuffer('/Helvetica findfont 11 scalefont setfont\n');
  for (var pg = 1; pg <= 4; pg++) {
    for (var l = 0; l < 55; l++) {
      ps.write('60 ${780 - l * 13} moveto (Linha $l da pagina $pg: o FiLume comprime documentos escaneados sem perder a leitura.) show\n');
    }
    ps.write('showpage\n');
  }
  File('$d/texto.ps').writeAsStringSync(ps.toString());
  await Process.run(pdf.gs!, ['-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=jpeg', '-dJPEGQ=92', '-r200', '-sOutputFile=$d/s_%d.jpg', '$d/texto.ps']);
  await Process.run(tools.ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=s=1654x2339', '-frames:v', '3', '$d/f_%d.png']);
  Future<MediaInfo> build(String name, List<String> files) async {
    final imgs = [for (final f in files) MediaInfo.image(await tools.probe(f), size: await tools.imageDisplaySize(f))];
    final r = await buildTrayJob(pages: [for (final i in imgs) PageRef(i, 1)], op: TrayOp.save, outDir: d, name: name, tools: pdf, jpegQ: 1).body(ctx());
    return pdf.probe(r.revealPath);
  }

  final scan = await build('escaneado', [for (var i = 1; i <= 4; i++) '$d/s_$i.jpg']);
  final photos = await build('fotos', [for (var i = 1; i <= 3; i++) '$d/f_$i.png']);
  print('escaneado: ${scan.sizeBytes ~/ 1024} KB · fotos: ${photos.sizeBytes ~/ 1024} KB');

  Future<(int, JobResult)?> run(String label, MediaInfo info, PdfCompressSettings s, {bool fail = false}) async {
    try {
      final r = await buildPdfCompressJob(info, s, '$d/out', pdf).body(ctx());
      final out = await pdf.probe(r.revealPath);
      final size = File(r.revealPath).lengthSync();
      check(label, !fail && out.pages == info.pages, '${r.summary}${r.warning == null ? '' : ' | ${r.warning}'}');
      return (size, r);
    } catch (e) {
      check(label, fail, e.toString().split('\n').first);
      return null;
    }
  }

  final base = await run('nível equilibrado', scan, PdfCompressSettings());
  final strong = await run('nível máximo', scan, PdfCompressSettings()..level = PdfLevel.max);
  check('máximo < equilibrado', strong!.$1 < base!.$1);
  final hi = await run('qualidade muito alta, 150 dpi', scan, PdfCompressSettings()..dpi = 150..quality = 90);
  final lo = await run('qualidade mínima, 150 dpi', scan, PdfCompressSettings()..dpi = 150..quality = 25);
  check('qualidade menor = arquivo menor', lo!.$1 < hi!.$1);
  final mono = await run('preto e branco puro', scan, PdfCompressSettings()..mono = true);
  // Em 300 dpi (nítido), tem de sair bem menor que o equilibrado (150 dpi) e que o máximo (72 dpi).
  check('preto e branco: menos de 1/3 do equilibrado e menor que o máximo', mono!.$1 * 3 < base.$1 && mono.$1 < strong.$1,
      '${mono.$1 ~/ 1024} KB contra ${base.$1 ~/ 1024} KB e ${strong.$1 ~/ 1024} KB');
  // A página em preto e branco precisa continuar legível: papel branco, letras pretas.
  await Process.run(pdf.gs!, ['-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=pgmraw', '-r20', '-dFirstPage=1', '-dLastPage=1', '-sOutputFile=$d/m.pgm', mono.$2.revealPath]);
  final px = File('$d/m.pgm').readAsBytesSync();
  final body = px.sublist(px.length - 150 * 200);
  final mean = body.reduce((a, b) => a + b) / body.length;
  check('preto e branco: fundo branco com texto', mean > 170 && mean < 252, '(brilho médio ${mean.round()})');
  final target = photos.sizeBytes ~/ 6;
  final t = await run('tamanho-alvo (1/6 do original)', photos, PdfCompressSettings()..targetMb = target / 1048576);
  check('coube no alvo', t!.$1 <= target && t.$2.warning == null, '${t.$1 ~/ 1024} KB ≤ ${target ~/ 1024} KB');
  final loose = await run('alvo folgado mantém qualidade', photos, PdfCompressSettings()..targetMb = photos.sizeBytes * 0.9 / 1048576);
  check('alvo folgado sai maior que o apertado', loose!.$1 > t.$1);
  final tiny = await run('alvo impossível: menor possível com aviso', photos, PdfCompressSettings()..targetMb = 0.001);
  check('aviso de alvo não atingido', tiny!.$2.warning != null);
  await run('alvo + preto e branco', scan, PdfCompressSettings()..targetMb = 0.2..mono = true);
  await run('já comprimido é recusado', await pdf.probe(mono.$2.revealPath), PdfCompressSettings()..level = PdfLevel.light, fail: true);
  dir.deleteSync(recursive: true);
  final left = Directory.systemTemp.listSync().where((e) => e.path.contains('filume_comp_')).length;
  check('temporários limpos', left == 0);
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
