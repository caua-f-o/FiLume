// Teste da tarja e dos formulários (sem interface): dart run tool/pdf_tools_test.dart
// Precisa do PDFium (FILUME_PDFIUM) e do qpdf (FILUME_PDF_DIR).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:filume/core/editor.dart' show RenderedPage;
import 'package:filume/core/ffmpeg.dart';
import 'package:filume/core/job.dart';
import 'package:filume/core/pdf.dart';
import 'package:filume/core/measure.dart';
import 'package:filume/core/pdf_clean.dart';
import 'package:filume/core/pdf_forms.dart';
import 'package:filume/core/pdf_inspect.dart';
import 'package:filume/core/pdf_sign.dart';
import 'package:filume/core/pdfium.dart';
import 'package:filume/core/redact_job.dart';
import 'package:filume/core/update.dart' show powershellEnv;
import 'package:path/path.dart' as p;

var bad = 0;
void check(String label, bool ok, [String extra = '']) {
  print('${ok ? 'OK' : 'FALHA'} $label ${ok ? '' : extra}');
  if (!ok) bad++;
}

Future<void> main() async {
  final fx = p.join('tool', 'fixtures', 'pdf');
  final tools = await PdfTools.locate();
  final pdf = Pdfium.load();
  if (tools == null || pdf == null) {
    final must = Platform.environment['FILUME_REQUIRE_PDFIUM'] == '1';
    print('${must ? 'FALHA' : 'AVISO'}: sem ${tools == null ? 'qpdf' : 'PDFium'}; a tarja e os formulários não foram testados.');
    exit(must ? 1 : 0);
  }
  final d = (await Directory.systemTemp.createTemp('filume_pdftools_')).path;
  final ff = await FfTools.locate();

  /// Tudo o que há no arquivo, com os fluxos descomprimidos, para procurar sobras.
  Future<String> rawBytes(String file) async {
    final out = '$d/qdf_${p.basename(file)}';
    await Process.run(tools.qpdf, ['--qdf', '--object-streams=disable', file, out]);
    return latin1.decode(File(out).readAsBytesSync());
  }

  Future<JobResult> run(Job job) async => job.body(JobCtx(ff!, FfRun(), (_, __, ___) {}));

  // ================================================================== tarja
  final src = p.join(fx, 'tarja.pdf');
  final b = PdfiumBackend.open(src, pdf);
  final cpf = b.findText(0, '123.456.789-00');
  check('busca acha o CPF na linha', cpf.length == 1 && cpf.first.boxes.length == 1 && cpf.first.boxes.first.width > 60 && cpf.first.boxes.first.width < 110,
      '${cpf.map((h) => h.boxes)}');
  check('busca não diferencia maiúsculas', b.findText(0, 'segredo-alfa').length == 1 && b.findText(0, 'não existe').isEmpty);
  final beta = b.findText(1, 'SEGREDO-BETA');
  final gama = b.findText(2, 'SEGREDO-GAMA');
  check('busca funciona em página girada e em texto invisível', beta.length == 1 && gama.length == 1);
  final (rw, rh) = b.pageSize(1);
  check('página girada: o trecho vira uma caixa só, em pé na tela', rw > rh && beta.first.boxes.length == 1 && beta.first.boxes.first.width < beta.first.boxes.first.height,
      '$rw x $rh ${beta.first.boxes}');
  b.close();

  final marks = <int, List<Area>>{
    0: [...cpf.first.boxes, ...PdfiumBackend.open(src, pdf).let((x) => x.findText(0, 'SEGREDO-ALFA').first.boxes, close: true), const Area(172, 220, 272, 320)],
    1: beta.first.boxes,
    2: gama.first.boxes,
  };
  RedactReport? rep;
  final res = await run(buildRedactJob(src, marks, '$d/saida', 'tarjado', tools, onReport: (r) => rep = r));
  final out = res.revealPath;
  final after = PdfiumBackend.open(out, pdf);
  final t0 = after.chars(0).map((c) => String.fromCharCode(c.code)).join();
  check('o CPF e o segredo saíram do texto da página', !t0.contains('123.456') && !t0.contains('SEGREDO-ALFA'), t0);
  check('a linha inteira (sem tarja) continua sendo texto', t0.contains('Linha que fica inteira'), t0);
  check('o resto da linha tarjada virou imagem, não texto', !t0.contains('Maria Souza') && (rep?.patches ?? 0) >= 1, t0);
  final t1 = after.chars(1).map((c) => String.fromCharCode(c.code)).join();
  final t2 = after.chars(2).map((c) => String.fromCharCode(c.code)).join();
  check('página girada e página digitalizada também foram limpas', !t1.contains('SEGREDO-BETA') && !t2.contains('SEGREDO-GAMA'), '$t1 | $t2');
  check('conferência: nada sob as tarjas', after.leaks(marks).isEmpty);

  // Visual: tarja preta onde havia o CPF; o nome ao lado continua aparecendo.
  final shot = after.render(0, 2);
  int px(double x, double y) {
    final i = ((y * 2).round() * shot.width + (x * 2).round()) * 4;
    return shot.bgra[i] + shot.bgra[i + 1] + shot.bgra[i + 2];
  }

  final c = cpf.first.boxes.first;
  check('a tarja está pintada de preto', px((c.l + c.r) / 2, (c.t + c.b) / 2) < 30, '${px((c.l + c.r) / 2, (c.t + c.b) / 2)}');
  var ink = 0;
  for (var x = 72.0; x < c.l - 4; x += 0.5) {
    for (var y = c.t + 1; y < c.b - 1; y += 0.5) {
      if (px(x, y) < 300) ink++;
    }
  }
  check('o texto à esquerda da tarja continua visível', ink > 80, '$ink pontos escuros');
  // Imagem: a metade azul (direita) foi tarjada; a vermelha fica.
  check('imagem: a parte de fora da tarja continua (vermelho)', () {
    final i = ((270 * 2) * shot.width + (120 * 2)) * 4;
    return shot.bgra[i + 2] > 200 && shot.bgra[i] < 60;
  }(), 'BGR em (120,270): ${shot.bgra.sublist(((270 * 2) * shot.width + (120 * 2)) * 4, ((270 * 2) * shot.width + (120 * 2)) * 4 + 4)}; em (120,225): ${shot.bgra.sublist(((225 * 2) * shot.width + (120 * 2)) * 4, ((225 * 2) * shot.width + (120 * 2)) * 4 + 4)}');
  check('imagem: a parte tarjada ficou preta', px(222, 270) < 30);
  after.close();

  if (Platform.environment['FILUME_KEEP'] case final String k) File(out).copySync(k);
  final bytes = await rawBytes(out);
  check('nada do CPF sobrou em lugar nenhum do arquivo (link, comentário, metadados)',
      !bytes.contains('123.456.789-00') && !bytes.contains('exemplo.com') && !bytes.contains('Cart'), _around(bytes, ['123.456.789-00', 'exemplo.com', 'Cart']));
  check('o link que estava sob a tarja foi removido', (rep?.annotations ?? 0) >= 1, '${rep?.annotations}');
  check('imagens sob tarja foram refeitas (as originais saem do arquivo)', (rep?.images ?? 0) >= 2, '${rep?.images}');
  check('avisa que um comentário em outro ponto da página ainda cita o texto tarjado', (res.warning ?? '').contains('ainda aparece em 1 outro lugar'), '${res.warning}');
  check('relatório guarda o texto removido', rep!.removedText.toString().contains('123.456.789-00'));

  // Sem limpar metadados, o título fica.
  final keep = await run(buildRedactJob(src, {1: beta.first.boxes}, '$d/saida', 'com_meta', tools, scrub: false));
  check('metadados só saem quando pedido', (await rawBytes(keep.revealPath)).contains('Ficha de Maria Souza'));

  // ============================================================ formulários
  final fsrc = p.join(fx, 'formulario.pdf');
  final form = await readForm(tools, fsrc);
  String kinds() => form.fields.map((f) => '${f.name}:${f.kind.name}').join(' ');
  check('lê os campos e os tipos',
      kinds() == 'nome:text cidade:text obs:multiline aceito:checkbox turno:combo curso:list pagamento:radio codigo:text', kinds());
  PdfField f(String n) => form.fields.firstWhere((x) => x.name == n);
  check('lê valores, opções e somente-leitura',
      f('cidade').value == 'Canoas' && f('turno').value == 'Manhã' && f('turno').options.join(',') == 'Manhã,Tarde,Noite' && f('aceito').value == '' &&
          f('codigo').readOnly && !f('codigo').fillable && f('pagamento').options.join(',') == 'pix,boleto' && f('pagamento').value == '',
      '${f('turno').options} ${f('pagamento').options} ${f('codigo').readOnly}');
  check('PDF sem formulário devolve lista vazia', (await readForm(tools, src)).isEmpty);

  final radio = f('pagamento').options.last;
  final values = {'nome': 'José da Conceição', 'obs': 'Linha um\nLinha dois', 'aceito': '1', 'turno': 'Noite', 'curso': 'Direito', 'pagamento': radio, 'codigo': 'X'};
  final filled = '$d/preenchido.pdf';
  await fillForm(tools, fsrc, filled, form, values);
  final back = await readForm(tools, filled);
  PdfField g(String n) => back.fields.firstWhere((x) => x.name == n);
  check('preenche e relê os valores',
      g('nome').value == 'José da Conceição' && g('obs').value == 'Linha um\nLinha dois' && g('aceito').value == '1' && g('turno').value == 'Noite' &&
          g('curso').value == 'Direito' && g('pagamento').value == radio && g('cidade').value == 'Canoas',
      back.fields.map((x) => '${x.name}=${jsonEncode(x.value)}').join(' '));
  check('campo somente-leitura não é alterado', g('codigo').value == 'A-001');
  int dark(RenderedPage s, double l, double t, double r, double btm) {
    var n = 0;
    for (var y = (t * 2).round(); y < (btm * 2).round(); y++) {
      for (var x = (l * 2).round(); x < (r * 2).round(); x++) {
        final i = (y * s.width + x) * 4;
        if (s.bgra[i] + s.bgra[i + 1] + s.bgra[i + 2] < 300) n++;
      }
    }
    return n;
  }


  final flat = '$d/achatado.pdf';
  await fillForm(tools, fsrc, flat, form, values, flatten: true);
  check('achatar: não sobram campos', (await readForm(tools, flat)).isEmpty);
  final lb = PdfiumBackend.open(flat, pdf);
  final lt = lb.chars(0).map((c) => String.fromCharCode(c.code)).join();
  check('achatar: os valores viram texto da página', lt.contains('José da Conceição') && lt.contains('Noite') && lt.contains('Canoas'), lt);
  final fshot = lb.render(0, 2);
  check('achatar: o valor aparece desenhado no lugar do campo', dark(fshot, 142, 106, 418, 122) > 150, '${dark(fshot, 142, 106, 418, 122)}');
  check('achatar: a caixa marcada aparece marcada', dark(fshot, 181, 237, 193, 249) > 20, '${dark(fshot, 181, 237, 193, 249)}');
  check('achatar: só a opção escolhida fica marcada', dark(fshot, 241, 367, 253, 379) > dark(fshot, 161, 367, 173, 379) + 10,
      '${dark(fshot, 161, 367, 173, 379)} x ${dark(fshot, 241, 367, 253, 379)}');
  lb.close();

  try {
    await fillForm(tools, fsrc, '$d/x.pdf', form, {'curso': 'Medicina'});
    check('opção que não existe é recusada', false);
  } on FfError {
    check('opção que não existe é recusada', true);
  }
  await fillForm(tools, fsrc, '$d/limpo.pdf', form, {'cidade': '', 'aceito': ''});
  final cleared = await readForm(tools, '$d/limpo.pdf');
  check('dá para esvaziar um campo', cleared.fields.firstWhere((x) => x.name == 'cidade').value == '');

  // ============================================================ comentários
  final nb = PdfiumBackend.open(src, pdf);
  final before = nb.notes(0);
  check('lê os comentários que já existem (sem contar links)', before.length == 1 && before.first.kind == NoteKind.note && before.first.text.contains('SEGREDO-ALFA'),
      before.map((n) => '${n.typeName}:${n.text}').join(' | '));
  check('com all, links também aparecem', nb.notes(0, all: true).any((n) => n.typeName == 'Link'));
  final line = nb.findText(0, 'Linha que fica inteira').first.boxes;
  nb.addNote(0, NoteKind.highlight, line, text: 'Atenção: revisão', author: 'Cauã', when: DateTime.utc(2026, 11, 16, 12, 30));
  nb.addNote(0, NoteKind.note, [const Area(400, 300, 420, 320)], text: 'Nota solta', author: 'Cauã');
  nb.addNote(1, NoteKind.underline, nb.findText(1, 'SEGREDO-BETA').first.boxes, color: 0xFFE53935);
  nb.save('$d/comentado.pdf');
  nb.close();
  final nc = PdfiumBackend.open('$d/comentado.pdf', pdf);
  final after0 = nc.notes(0), after1 = nc.notes(1);
  final hl = after0.where((n) => n.kind == NoteKind.highlight).firstOrNull;
  check('comentários novos são gravados com texto, autor e data',
      after0.length == 3 && hl != null && hl.text == 'Atenção: revisão' && hl.author == 'Cauã' && hl.date == '16/11/2026 12:30' && after1.length == 1,
      after0.map((n) => '${n.typeName}:${n.text}:${n.author}:${n.date}').join(' | '));
  check('o marca-texto fica sobre o trecho marcado', hl != null && (hl.area.l - line.first.l).abs() < 2 && (hl.area.t - line.first.t).abs() < 2, '${hl?.area} x ${line.first}');
  check('em página girada o sublinhado fica sobre o texto',
      (after1.first.area.l - nc.findText(1, 'SEGREDO-BETA').first.boxes.first.l).abs() < 2, '${after1.first.area}');
  final hshot = nc.render(0, 2);
  final hi = (((line.first.t + line.first.b) / 2 * 2).round() * hshot.width + ((line.first.l + 3) * 2).round()) * 4;
  check('o marca-texto aparece amarelo na página', hshot.bgra[hi + 2] > 200 && hshot.bgra[hi] < 160, '${hshot.bgra.sublist(hi, hi + 3)}');
  final rows = nc.lineBoxes(0, const Area(60, 85, 540, 140));
  check('arrastar sobre duas linhas dá uma caixa por linha', rows.length == 2 && rows.first.t < rows.last.t && rows.first.width > 200, '$rows');
  check('área sem texto não dá caixa nenhuma', nc.lineBoxes(0, const Area(300, 600, 500, 700)).isEmpty);
  final txt = notesAsText('teste.pdf', [...after0, ...after1]);
  check('lista de comentários em texto', txt.contains('Página 1') && txt.contains('Página 2') && txt.contains('Marca-texto (Cauã, 16/11/2026 12:30): Atenção: revisão'), txt);
  final gone = nc.removeNotes(0, [for (final n in after0) if (n.kind != NoteKind.highlight) n.index]);
  nc.save('$d/menos.pdf');
  nc.close();
  final nd = PdfiumBackend.open('$d/menos.pdf', pdf);
  check('remover tira só os escolhidos', gone == 2 && nd.notes(0).length == 1 && nd.notes(0).first.kind == NoteKind.highlight);
  nd.close();

  // ================================================================ medidas
  check('distância: 72 pontos = 1 polegada = 25,4 mm', formatLength(72, MeasureUnit.mm) == '25,4 mm' && formatLength(72, MeasureUnit.inch) == '1 pol');
  check('escala 1:100 em metros', formatLength(72 / 2.54, MeasureUnit.m, const MeasureScale(1, 100)) == '1 m');
  check('lê a escala digitada', MeasureScale.parse('1:50')?.factor == 50 && MeasureScale.parse(' 2 / 1 ')?.factor == 0.5 && MeasureScale.parse('100')?.factor == 100 &&
      MeasureScale.parse('abc') == null && MeasureScale.parse('1:0') == null);
  final sq = [(0.0, 0.0), (72.0, 0.0), (72.0, 72.0), (0.0, 72.0)];
  check('área e perímetro de um quadrado de 1 polegada',
      formatArea(polygonArea(sq), MeasureUnit.inch) == '1 pol²' && formatLength(pathLength(sq, closed: true), MeasureUnit.inch) == '4 pol' &&
          formatArea(polygonArea(sq), MeasureUnit.cm) == '6,45 cm²',
      '${formatArea(polygonArea(sq), MeasureUnit.cm)} ${formatLength(pathLength(sq, closed: true), MeasureUnit.inch)}');
  check('área não depende do sentido do desenho', polygonArea(sq.reversed.toList()) == polygonArea(sq) && polygonArea(sq.sublist(0, 2)) == 0);

  // ============================================================ verificação
  final plain = await inspectPdf(tools, src, pdfium: pdf);
  PdfCheck ck(PdfInspection r, String id) => r.checks.firstWhere((c) => c.id == id);
  check('PDF comum: sem tags, sem idioma, fonte não embutida',
      ck(plain, 'tags').level == CheckLevel.fail && ck(plain, 'lang').level == CheckLevel.fail && ck(plain, 'fonts').level == CheckLevel.fail &&
          ck(plain, 'fonts').detail.contains('Helvetica') && plain.declaredPdfA == null && plain.pages == 3,
      plain.checks.map((c) => '${c.id}=${c.level.name}').join(' '));
  check('PDF comum: tem título e nenhuma página sem texto', ck(plain, 'title').level != CheckLevel.fail && ck(plain, 'text').level == CheckLevel.ok,
      '${ck(plain, 'title').detail} | ${ck(plain, 'text').detail}');
  final good = await inspectPdf(tools, p.join(fx, 'acessivel.pdf'), pdfium: pdf);
  check('PDF/A marcado: reconhece a declaração, as tags, o idioma e as fontes',
      good.declaredPdfA == 'PDF/A-2b' && ck(good, 'tags').level == CheckLevel.ok && ck(good, 'lang').level == CheckLevel.ok && ck(good, 'fonts').level == CheckLevel.ok &&
          ck(good, 'xmp').level == CheckLevel.ok && ck(good, 'color').level == CheckLevel.ok && ck(good, 'title').level == CheckLevel.ok,
      '${good.declaredPdfA} ${good.checks.map((c) => '${c.id}=${c.level.name}').join(' ')}');
  check('PDF/A marcado: nenhuma falha', good.checks.every((c) => c.level != CheckLevel.fail), good.checks.where((c) => c.level == CheckLevel.fail).map((c) => c.detail).join(' | '));
  final formCheck = await inspectPdf(tools, fsrc, pdfium: pdf);
  check('formulário: avisa dos campos sem descrição', ck(formCheck, 'fields').level == CheckLevel.warn, ck(formCheck, 'fields').detail);
  final rep2 = inspectionAsText(plain);
  check('relatório em texto', rep2.contains('[falta] Estrutura marcada') && rep2.contains('Como resolver') && rep2.contains('não uma certificação'));

  // ================================================================= limpar
  final dirty = p.join(fx, 'sujo.pdf');
  final dbytes = await rawBytes(dirty);
  const secrets = ['Titulo-secreto', 'Autor-secreto', 'script-secreto', 'conteudo-do-anexo-solto', 'conteudo-do-anexo-na-pagina', 'dado-privado-secreto'];
  check('o arquivo de teste tem mesmo a bagagem escondida', secrets.every(dbytes.contains) && dbytes.contains('Marcador-secreto') && dbytes.contains('comentario-secreto'),
      secrets.where((x) => !dbytes.contains(x)).join(','));
  final crep = await cleanPdf(tools, dirty, '$d/limpo_padrao.pdf');
  final cb = await rawBytes('$d/limpo_padrao.pdf');
  check('limpeza padrão: saem dados de autoria, script, anexos e dados privados', secrets.every((x) => !cb.contains(x)), secrets.where(cb.contains).join(','));
  check('limpeza padrão: comentários e marcadores ficam', cb.contains('comentario-secreto') && cb.contains('Marcador-secreto'));
  check('limpeza padrão: conta o que tirou', crep.metadata > 0 && crep.scripts == 1 && crep.attachments == 2 && crep.extras == 1 && crep.comments == 0, crep.summary);
  final crep2 = await cleanPdf(tools, dirty, '$d/limpo_tudo.pdf', const CleanOptions(comments: true, bookmarks: true));
  final cb2 = await rawBytes('$d/limpo_tudo.pdf');
  check('limpeza completa: comentários e marcadores também saem, o link fica',
      !cb2.contains('comentario-secreto') && !cb2.contains('Marcador-secreto') && cb2.contains('exemplo.com/fica') && crep2.comments == 2 && crep2.bookmarks == 1, crep2.summary);
  final cl = PdfiumBackend.open('$d/limpo_tudo.pdf', pdf);
  check('o texto da página não muda', cl.chars(0).map((c) => String.fromCharCode(c.code)).join().contains('Documento com bagagem escondida') && cl.notes(0).isEmpty);
  cl.close();
  final crep3 = await cleanPdf(tools, '$d/limpo_tudo.pdf', '$d/limpo_de_novo.pdf', const CleanOptions(comments: true, bookmarks: true));
  check('arquivo já limpo: nada a remover', crep3.total == 0 && crep3.summary.contains('nada'), crep3.summary);

  // ============================================== marcadores ao organizar/unir
  Future<List<String>> outline(String file) async {
    final r = await Process.run(tools.qpdf, ['--json=2', '--json-key=outlines', file], stdoutEncoding: utf8);
    final out = <String>[];
    void walk(List l, String pre) {
      for (final o in l) {
        out.add('$pre${o['title']}@${o['destpageposfrom1']}');
        walk(o['kids'] as List, '$pre>');
      }
    }

    walk((jsonDecode(r.stdout as String) as Map)['outlines'] as List, '');
    return out;
  }

  final mk = p.join(fx, 'marcadores.pdf');
  final mkInfo = await tools.probe(mk);
  final org = await run(buildPdfOrganizeJob([PageRef(mkInfo, 3), PageRef(mkInfo, 1, 90), PageRef(mkInfo, 2)], '$d/org', tools));
  final o1 = await outline(org.revealPath);
  check('organizar leva os marcadores para as páginas novas e tira os de páginas que saíram',
      o1.join(' | ') == 'Capítulo 2@1 | Capítulo 1@2 | >Seção 1.1@3', o1.join(' | '));
  final merged = await run(buildPdfMergeJob([await tools.probe(src), mkInfo], '$d/uniao', tools));
  final o2 = await outline(merged.revealPath);
  check('unir mantém os marcadores, deslocados pelas páginas do primeiro arquivo',
      o2.first == 'Capítulo 1@4' && o2.last == 'Fim@8' && o2.length == 5, o2.join(' | '));
  final noMk = await run(buildPdfOrganizeJob([PageRef(await tools.probe(fsrc), 1)], '$d/org2', tools));
  check('documento sem marcadores continua sem', (await outline(noMk.revealPath)).isEmpty);

  // ============================================================= assinatura
  // Certificado de teste criado na hora (nada de chave guardada no repositório).
  final pfx = '$d/teste.pfx';
  String? thumb;
  var haveCert = false;
  if (Platform.isWindows) {
    final r = await Process.run(environment: powershellEnv(), includeParentEnvironment: false, 'powershell.exe', [
      '-NoProfile', '-NonInteractive', '-Command',
      "\$c = New-SelfSignedCertificate -Subject 'CN=José da Silva Teste' -CertStoreLocation Cert:\\CurrentUser\\My -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 -NotAfter (Get-Date).AddDays(2); "
          "\$pw = ConvertTo-SecureString 'segredo' -AsPlainText -Force; Export-PfxCertificate -Cert \$c -FilePath '$pfx' -Password \$pw | Out-Null; Write-Output \$c.Thumbprint",
    ]);
    thumb = r.stdout.toString().trim().split('\n').last.trim();
    haveCert = File(pfx).existsSync() && thumb.length >= 40;
    if (!haveCert) print('certificado de teste: ${r.stdout}\n${r.stderr}');
  } else {
    try {
      final k = await Process.run('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', '$d/k.pem', '-out', '$d/c.pem', '-days', '2', '-utf8', '-subj', '/CN=José da Silva Teste']);
      final e = await Process.run('openssl', ['pkcs12', '-export', '-inkey', '$d/k.pem', '-in', '$d/c.pem', '-out', pfx, '-passout', 'pass:segredo']);
      haveCert = k.exitCode == 0 && e.exitCode == 0;
    } catch (_) {}
  }
  if (!haveCert) {
    final must = Platform.environment['FILUME_REQUIRE_PDFIUM'] == '1';
    check('certificado de teste para a assinatura', !must, 'não deu para criar');
    if (!must) print('AVISO: sem certificado de teste; a assinatura não foi testada.');
  } else {
    check('PDF sem assinatura: lista vazia', (await verifySignatures(tools, src)).isEmpty);
    final signed = '$d/assinado.pdf';
    final who = await signPdf(tools, src, signed, SignIdentity.pfx(pfx, 'segredo'), reason: 'Aprovação', location: 'Canoas');
    final sc = await verifySignatures(tools, signed);
    check('assina e a conferência dá válida', sc.length == 1 && sc.first.intact == true && sc.first.coversWholeFile && sc.first.verdict.startsWith('Válida'),
        sc.map((c) => '${c.intact} ${c.coversWholeFile} ${c.problem}').join(' | '));
    check('o nome de quem assinou vem do certificado, com acento', who == 'José da Silva Teste' && sc.first.signer == 'José da Silva Teste', '$who / ${sc.firstOrNull?.signer}');
    if (Platform.isWindows) {
      check('certificado de teste: íntegra, mas não reconhecida pelo computador', sc.first.trusted == false && sc.first.signedAt != null && sc.first.validTo != null,
          '${sc.first.trusted} ${sc.first.chainStatus} ${sc.first.signedAt}');
    }
    final sb2 = PdfiumBackend.open(signed, pdf);
    check('o arquivo assinado abre e mantém as páginas e o texto', sb2.pageCount == 3 && sb2.chars(0).map((c) => String.fromCharCode(c.code)).join().contains('Maria Souza'));
    sb2.close();
    final sbytes = File(signed).readAsBytesSync();
    final raw = latin1.decode(sbytes);
    final open2 = await rawBytes(signed);
    check('o carimbo visível e o motivo estão no arquivo', open2.contains('Assinado digitalmente por') && open2.contains('Jos\\351 da Silva Teste') && raw.contains('/Reason'));
    if (Platform.environment['FILUME_KEEP'] case final String k) File(signed).copySync('$k.assinado.pdf');
    // Conferência por outro programa, quando há um à mão.
    try {
      final ps = await Process.run('pdfsig', ['-nocert', signed]);
      if (ps.exitCode == 0 || ps.stdout.toString().contains('Signature')) {
        check('outro validador (pdfsig) confirma a assinatura', ps.stdout.toString().contains('Signature is Valid') && ps.stdout.toString().contains('Total document signed'),
            ps.stdout.toString());
      }
    } catch (_) {}

    // Mexer no conteúdo depois de assinar tem de aparecer.
    final at = raw.indexOf('/Reason');
    final hacked = Uint8List.fromList(sbytes);
    final target = raw.indexOf('Canoas');
    hacked[target] = 0x58; // "Xanoas"
    File('$d/adulterado.pdf').writeAsBytesSync(hacked);
    final bad1 = await verifySignatures(tools, '$d/adulterado.pdf');
    check('arquivo adulterado: assinatura inválida', at > 0 && bad1.length == 1 && bad1.first.intact == false && bad1.first.verdict.startsWith('Inválida'),
        bad1.map((c) => '${c.intact} ${c.problem}').join(' | '));
    // Acréscimo depois da assinatura (o conteúdo assinado continua igual).
    File('$d/acrescido.pdf').writeAsBytesSync([...sbytes, ...latin1.encode('\n% algo a mais\n')]);
    final grown = await verifySignatures(tools, '$d/acrescido.pdf');
    check('acréscimo depois de assinar é apontado', grown.length == 1 && grown.first.intact == true && !grown.first.coversWholeFile && grown.first.verdict.contains('acréscimos'),
        grown.map((c) => '${c.intact} ${c.coversWholeFile}').join(' | '));

    try {
      await signPdf(tools, src, '$d/x.pdf', SignIdentity.pfx(pfx, 'errada'));
      check('senha errada do certificado é recusada', false);
    } on FfError catch (e) {
      check('senha errada do certificado é recusada', e.message.contains('senha') && !File('$d/x.pdf').existsSync(), e.message);
    }
    // Sem carimbo, e num PDF que já tem formulário.
    await signPdf(tools, fsrc, '$d/form_assinado.pdf', SignIdentity.pfx(pfx, 'segredo'), visible: false);
    final fs = await verifySignatures(tools, '$d/form_assinado.pdf');
    final ff2 = await readForm(tools, '$d/form_assinado.pdf');
    check('assina um PDF com formulário sem estragar os campos', fs.length == 1 && fs.first.intact == true && ff2.fields.where((x) => x.kind != FieldKind.signature).length == 8 &&
        ff2.fields.any((x) => x.kind == FieldKind.signature), '${fs.map((c) => c.intact)} ${ff2.fields.map((x) => x.name)}');
    final job = await run(buildSignJob(tools, src, '$d/saida', 'pelo_job', SignIdentity.pfx(pfx, 'segredo')));
    check('a tarefa de assinar confere antes de entregar', job.summary.contains('José da Silva Teste') && File(job.revealPath).existsSync());
    if (thumb != null) {
      final store = await listStoreCerts();
      check('lista os certificados do Windows que servem para assinar', store.any((c) => c.thumbprint == thumb && c.name == 'José da Silva Teste'), store.map((c) => c.name).join(','));
      await signPdf(tools, src, '$d/pelo_windows.pdf', SignIdentity.store(thumb));
      final ws = await verifySignatures(tools, '$d/pelo_windows.pdf');
      check('assina com um certificado instalado no Windows', ws.length == 1 && ws.first.intact == true, ws.map((c) => '${c.intact} ${c.problem}').join(' | '));
      await Process.run(environment: powershellEnv(), includeParentEnvironment: false, 'powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', "Remove-Item 'Cert:\\CurrentUser\\My\\$thumb' -ErrorAction SilentlyContinue"]);
    }
  }

  try {
    Directory(d).deleteSync(recursive: true);
  } catch (_) {}
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}

String _around(String s, List<String> needles) {
  for (final n in needles) {
    final i = s.indexOf(n);
    if (i >= 0) return '…${s.substring((i - 120).clamp(0, s.length), (i + 80).clamp(0, s.length))}…';
  }
  return '';
}

extension on PdfiumBackend {
  T let<T>(T Function(PdfiumBackend) f, {bool close = false}) {
    try {
      return f(this);
    } finally {
      if (close) this.close();
    }
  }
}
