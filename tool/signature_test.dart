// Teste das assinaturas digitais: dart run tool/signature_test.dart [pasta]
// Usa os PDFs de tool/fixtures/assinatura (assinados com um certificado de
// teste, sem o campo /Name: o nome vem do certificado).
import 'dart:io';
import 'package:filume/core/ffmpeg.dart';
import 'package:filume/core/job.dart';
import 'package:filume/core/pdf.dart';

Future<void> main(List<String> a) async {
  final d = a.isNotEmpty ? a[0] : 'tool/fixtures/assinatura';
  final tools = (await FfTools.locate())!;
  final pdf = (await PdfTools.locate())!;
  var bad = 0;
  void check(String label, bool ok, [String extra = '']) {
    print('${ok ? 'OK' : 'FALHA'} $label $extra');
    if (!ok) bad++;
  }

  final plain = await pdf.probe('$d/plain.pdf');
  final one = await pdf.probe('$d/signed.pdf');
  final two = await pdf.probe('$d/signed2.pdf');
  final cert = await pdf.probe('$d/certified.pdf');
  check('PDF comum: nenhuma assinatura', plain.signatures.isEmpty);
  final s = one.signatures;
  check('1 assinatura lida', s.length == 1 && s[0].signer == 'Fulano de Tal' && s[0].reason == 'Aprovo o documento' && s[0].date != null && s[0].coversWholeFile && !s[0].certification,
      s.map((x) => '${x.summary} | ${x.reason} | ${x.location}').join());
  check('2 assinaturas: a primeira não cobre o arquivo todo', two.signatures.length == 2 && two.signatures.where((x) => x.coversWholeFile).length == 1);
  check('certificação reconhecida', cert.signatures.length == 1 && cert.signatures[0].certification);

  List<PageRef> all(MediaInfo m) => [for (var i = 1; i <= m.pages; i++) PageRef(m, i)];
  Future<JobResult> run(List<PageRef> pg, TrayOp op, String name, {bool attach = false, String pw = ''}) => buildTrayJob(
          pages: pg, op: op, outDir: '$d/out', name: name, tools: pdf, attachSigned: attach, password: pw, compress: PdfCompressSettings())
      .body(JobCtx(tools, FfRun(), (p, st, sp) {}));
  Future<int> attachments(String f, [String pw = '']) async {
    final r = await Process.run(pdf.qpdf, [if (pw.isNotEmpty) '--password=$pw', '--list-attachments', f]);
    return r.stdout.toString().trim().split('\n').where((l) => l.contains('->')).length;
  }

  check('intocado em Organizar mantém a assinatura', trayKeepsSignature(all(one), TrayOp.save) && !trayKeepsSignature(all(one), TrayOp.compress));
  var r = await run(all(one), TrayOp.save, 'igual');
  final same = File(r.revealPath).readAsBytesSync().length == File(one.path).lengthSync() && (await pdf.probe(r.revealPath)).signatures.length == 1;
  check('cópia idêntica, assinatura intacta', same && r.warning!.contains('preservada'), r.warning ?? '');
  final moved = all(one).reversed.toList();
  check('páginas reordenadas: não mantém', !trayKeepsSignature(moved, TrayOp.save));
  r = await run(moved, TrayOp.save, 'mexido', attach: true);
  check('alterado com anexo', await attachments(r.revealPath) == 1 && r.warning!.contains('anexado'), r.warning ?? '');
  r = await run(moved, TrayOp.save, 'mexido sem anexo');
  check('alterado sem anexo', await attachments(r.revealPath) == 0 && r.warning!.contains('não vale'));
  r = await run(all(one), TrayOp.compress, 'leve', attach: true);
  check('comprimido com anexo', await attachments(r.revealPath) == 1, r.summary);
  r = await run(all(one), TrayOp.protect, 'secreto', attach: true, pw: 'abc');
  final enc = await pdf.probe(r.revealPath);
  check('protegido com anexo, ainda com senha', enc.encrypted && await attachments(r.revealPath, 'abc') == 1);
  r = await run([...all(one), ...all(two)], TrayOp.save, 'dois', attach: true);
  check('dois originais anexados', await attachments(r.revealPath) == 2);
  r = await run(all(plain), TrayOp.save, 'comum', attach: true);
  check('PDF comum: sem aviso nem anexo', r.warning == null && await attachments(r.revealPath) == 0);
  // O anexo é o original, byte a byte?
  final ex = await Process.run(pdf.qpdf, ['--show-attachment=original assinado - signed.pdf', '$d/out/mexido.pdf'], stdoutEncoding: null);
  check('anexo idêntico ao original', (ex.stdout as List<int>).length == File(one.path).lengthSync());
  try {
    Directory('$d/out').deleteSync(recursive: true);
  } catch (_) {}
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
