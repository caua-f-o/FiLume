// Teste do comparador de PDFs: dart run tool/compare_test.dart
// Monta um documento, uma versão alterada (palavra trocada, carimbo, página
// inserida, página removida) e "digitalizações" das duas (com ruído, brilho e
// deslocamento diferentes), e confere o que o comparador encontra.
import 'dart:io';
import 'package:filume/core/compare.dart';
import 'package:filume/core/ffmpeg.dart';
import 'package:filume/core/job.dart';
import 'package:filume/core/ocr.dart';
import 'package:filume/core/pdf.dart';

String page(int n, {String word = 'quinhentos', bool stamp = false, String topic = 'contrato'}) {
  final s = StringBuffer('/Helvetica findfont 12 scalefont setfont\n');
  s.write('72 770 moveto (Documento de teste - secao $n sobre $topic) show\n');
  for (var l = 0; l < 30; l++) {
    final w = l == 12 ? word : 'duzentos';
    s.write('72 ${730 - l * 18} moveto (Clausula $n.$l: o $topic numero $n preve o valor de $w reais na linha $l.) show\n');
  }
  if (stamp) s.write('0.8 0 0 setrgbcolor 380 120 150 60 rectfill 1 setgray 395 142 moveto (APROVADO) show 0 setgray\n');
  s.write('showpage\n');
  return s.toString();
}

Future<void> main() async {
  final tools = (await FfTools.locate())!;
  final pdf = (await PdfTools.locate())!;
  final dir = await Directory.systemTemp.createTemp('filume_cmptest_');
  final d = dir.path;
  JobCtx ctx() => JobCtx(tools, FfRun(), (p, s, sp) {});
  var bad = 0;
  void check(String label, bool ok, [String extra = '']) {
    print('${ok ? 'OK' : 'FALHA'} $label $extra');
    if (!ok) bad++;
  }

  Future<MediaInfo> make(String name, List<String> pages) async {
    File('$d/$name.ps').writeAsStringSync(pages.join());
    final r = await Process.run(pdf.gs!, ['-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=pdfwrite', '-sOutputFile=$d/$name.pdf', '$d/$name.ps']);
    if (r.exitCode != 0) throw 'gs: ${r.stderr}';
    return pdf.probe('$d/$name.pdf');
  }

  // Original: 5 páginas. Novo: p2 com palavra trocada, p3 com carimbo, uma página
  // nova depois da 3, e sem a página 5.
  final a = await make('original', [for (var i = 1; i <= 5; i++) page(i)]);
  final b = await make('novo', [
    page(1),
    page(2, word: 'novecentos'),
    page(3, stamp: true),
    page(9, topic: 'aditivo'),
    page(4),
  ]);
  var r = await comparePdfs(ctx(), pdf, a, b);
  String shape(CompareResult r) => r.pairs.map((x) => '${x.a ?? '-'}:${x.b ?? '-'}${x.status.name[0]}').join(' ');
  check('emparelhamento com página inserida e removida', shape(r) == '1:1e 2:2c 3:3c -:4a 4:5e 5:-r', shape(r));
  final p2 = r.pairs[1], p3 = r.pairs[2];
  check('palavra trocada: texto', p2.text.length == 1 && p2.text[0].removed == 'quinhentos' && p2.text[0].added == 'novecentos',
      p2.text.map((t) => '[${t.before}] -${t.removed} +${t.added} [${t.after}]').join(' | '));
  // A linha 12 fica em y = 730 - 12*18 = 514 pt de 792 → fração ~0,35 do topo.
  bool near(DiffRegion g, double y) => g.y - 0.02 <= y && g.y + g.h + 0.02 >= y;
  check('palavra trocada: marcada no lugar certo', p2.regions.length == 1 && near(p2.regions[0], 0.345) && p2.regions[0].h < 0.06 && p2.changed < 0.01,
      p2.regions.map((g) => 'y ${g.y.toStringAsFixed(3)} h ${g.h.toStringAsFixed(3)} x ${g.x.toStringAsFixed(2)} w ${g.w.toStringAsFixed(2)}').join(' | '));
  check('carimbo: marcado, texto novo listado', p3.regions.length == 1 && near(p3.regions[0], 0.81) && p3.text.any((t) => t.added.contains('APROVADO')),
      '${p3.regions.length} regiões');
  check('resumo', r.summary == '2 páginas alteradas · 1 adicionada · 1 removida', r.summary);
  check('imagens de visualização existem', r.pairs.every((x) => (x.imageA == null || File(x.imageA!).existsSync()) && (x.imageB == null || File(x.imageB!).existsSync())));

  // Relatório
  final rep = await buildCompareReportJob(r, '$d/out', 'relatorio').body(ctx());
  final info = await pdf.probe(rep.revealPath);
  final chk = await Process.run(pdf.qpdf, ['--check', rep.revealPath]);
  check('relatório em PDF válido', chk.exitCode == 0 && info.pages == 1 + 4 + 2, '${info.pages} páginas · ${rep.summary}');
  final gsr = await Process.run(pdf.gs!, ['-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=nullpage', rep.revealPath]);
  check('relatório abre sem erros no Ghostscript', gsr.exitCode == 0 && !'${gsr.stdout}${gsr.stderr}'.toLowerCase().contains('error'), '${gsr.stdout}${gsr.stderr}'.trim());
  final dirA = r.dir;
  r.dispose();
  check('temporários da comparação apagados', !Directory(dirA).existsSync());

  // Iguais
  r = await comparePdfs(ctx(), pdf, a, a);
  check('arquivo contra ele mesmo: idêntico', r.identical && r.pairs.length == 5);
  r.dispose();

  // "Digitalizações": cada versão vira imagens com ruído; a nova ainda sai
  // deslocada ~1,5 mm e mais escura, como numa segunda passada no scanner.
  Future<MediaInfo> scan(MediaInfo src, String name, String vf) async {
    await Process.run(pdf.gs!, ['-q', '-dNOPAUSE', '-dBATCH', '-sDEVICE=png16m', '-r150', '-sOutputFile=$d/${name}_%d.png', src.path]);
    final imgs = <MediaInfo>[];
    for (var i = 1; i <= src.pages; i++) {
      final jpg = '$d/${name}_s$i.jpg';
      final pr = await Process.run(tools.ffmpeg, ['-v', 'error', '-y', '-i', '$d/${name}_$i.png', '-vf', vf, '-q:v', '4', jpg]);
      if (pr.exitCode != 0) throw 'ffmpeg: ${pr.stderr}';
      imgs.add(MediaInfo.image(await tools.probe(jpg), size: await tools.imageDisplaySize(jpg)));
    }
    final job = await buildTrayJob(pages: [for (final i in imgs) PageRef(i, 1)], op: TrayOp.save, outDir: d, name: name, tools: pdf).body(ctx());
    return pdf.probe(job.revealPath);
  }

  final sa = await scan(a, 'scanA', 'noise=alls=7:allf=t');
  final sb = await scan(b, 'scanB', 'pad=iw+20:ih+20:11:8:white,crop=iw-20:ih-20:0:0,noise=alls=9:allf=t,eq=brightness=-0.05:contrast=0.93');
  r = await comparePdfs(ctx(), pdf, sa, sa);
  check('digitalização contra ela mesma: idêntica', r.identical);
  r.dispose();
  final sa2 = await scan(a, 'scanA2', 'pad=iw+20:ih+20:6:13:white,crop=iw-20:ih-20:0:0,noise=alls=10:allf=t,eq=brightness=0.03');
  r = await comparePdfs(ctx(), pdf, sa, sa2);
  check('mesma folha digitalizada duas vezes (ruído, brilho, deslocamento): sem diferenças', r.identical,
      r.pairs.map((x) => '${x.status.name[0]}${x.regions.length}:${(x.changed * 100).toStringAsFixed(2)}%').join(' '));
  r.dispose();
  // Sem OCR (como fora do Windows): o emparelhamento é só visual, então compara as 3 primeiras páginas.
  final sa3 = await pdf.probe((await buildTrayJob(pages: [for (var i = 1; i <= 3; i++) PageRef(sa, i)], op: TrayOp.save, outDir: d, name: 'sa3', tools: pdf).body(ctx())).revealPath);
  final sb3 = await pdf.probe((await buildTrayJob(pages: [for (var i = 1; i <= 3; i++) PageRef(sb, i)], op: TrayOp.save, outDir: d, name: 'sb3', tools: pdf).body(ctx())).revealPath);
  r = await comparePdfs(ctx(), pdf, sa3, sb3);
  final s2 = r.pairs[1], s3 = r.pairs[2];
  check('digitalizações: página igual passa', r.pairs[0].status == PairStatus.equal, '${r.pairs[0].regions.length} regiões');
  check('digitalizações: palavra trocada achada', s2.status == PairStatus.changed && s2.regions.isNotEmpty && s2.regions.length <= 3 && s2.regions.any((g) => near(g, 0.345)),
      s2.regions.map((g) => 'y ${g.y.toStringAsFixed(3)} h ${g.h.toStringAsFixed(3)}').join(' | '));
  check('digitalizações: carimbo achado', s3.status == PairStatus.changed && s3.regions.any((g) => near(g, 0.81)), '${s3.regions.length} regiões');
  check('digitalizações: modo tolerante, com aviso de OCR', s2.tolerant && r.note != null);
  r.dispose();

  // Com "OCR" (de mentira: devolve o texto certo de cada página): emparelha pelo texto e lista as palavras.
  List<String> lines(String ps) => [for (final m in RegExp(r'\(([^)]*)\) show').allMatches(ps)) m.group(1)!];
  final textA = [for (var i = 1; i <= 5; i++) lines(page(i))];
  final textB = [lines(page(1)), lines(page(2, word: 'novecentos')), lines(page(3, stamp: true)), lines(page(9, topic: 'aditivo')), lines(page(4))];
  Future<List<OcrPage>> fake(List<String> imgs, void Function(int)? on) async => [
        for (final f in imgs)
          () {
            final m = RegExp(r'v([ab])(\d+)\.jpg$').firstMatch(f)!;
            final src = (m[1] == 'a' ? textA : textB)[int.parse(m[2]!) - 1];
            return OcrPage(1000, 1400, [
              for (var l = 0; l < src.length; l++)
                for (final w in src[l].split(' ')) OcrWord(l, 0, l * 20.0, 10, 10, w),
            ]);
          }(),
      ];
  r = await comparePdfs(ctx(), pdf, sa, sb, ocr: fake);
  check('digitalizações com OCR: emparelhamento completo', shape(r) == '1:1e 2:2c 3:3c -:4a 4:5e 5:-r', shape(r));
  check('digitalizações com OCR: palavra trocada listada', r.pairs[1].ocrText && r.pairs[1].text.any((t) => t.removed.contains('quinhentos') && t.added.contains('novecentos')));
  r.dispose();

  // Imagem solta contra imagem solta
  final ia = MediaInfo.image(await tools.probe('$d/scanA_s2.jpg'), size: await tools.imageDisplaySize('$d/scanA_s2.jpg'));
  final ib = MediaInfo.image(await tools.probe('$d/scanB_s2.jpg'), size: await tools.imageDisplaySize('$d/scanB_s2.jpg'));
  r = await comparePdfs(ctx(), pdf, ia, ib);
  check('duas imagens (JPG) comparadas direto', r.pairs.length == 1 && r.pairs[0].status == PairStatus.changed);
  r.dispose();

  // Modo exato forçado numa digitalização acusa o ruído (é o esperado)
  r = await comparePdfs(ctx(), pdf, sa3, sb3, tolerance: CompareTolerance.exact);
  check('modo exato em digitalização acusa tudo', r.pairs.every((x) => x.status == PairStatus.changed));
  r.dispose();

  // Texto: casos de borda do diff
  final t = diffWords('a b c d e'.split(' '), 'a x c e f'.split(' '));
  check('diff de palavras', t.length == 1 && t[0].before == 'a' && t[0].removed == 'b c d e' && t[0].added == 'x c e f',
      t.map((x) => '-${x.removed} +${x.added}').join(' | '));
  check('diff de OCR ignora pontuação e caixa', diffWords(['Valor:', 'R\$', '10,00.'], ['valor', 'R\$', '10,00'], loose: true).isEmpty);

  dir.deleteSync(recursive: true);
  final left = Directory.systemTemp.listSync().where((e) => e.path.contains('filume_cmp_')).length;
  check('nenhum temporário sobrando', left == 0);
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
