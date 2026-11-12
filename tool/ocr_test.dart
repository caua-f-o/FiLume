// Teste do OCR: dart run tool/ocr_test.dart
// Confere a camada de texto e, no Windows, lê de verdade uma imagem com texto.
import 'dart:io';
import 'package:filume/core/ocr.dart';

Future<void> main() async {
  var bad = 0;
  final page = OcrPage(1000, 1400, [OcrWord(0, 50, 60, 400, 60, 'Olá'), OcrWord(0, 480, 60, 200, 60, 'ação – “ok”')]);
  final content = textLayerContent(page, 360, 504);
  final ok = content.contains('3 Tr') && content.contains('<4f6ce120>') && content.contains('e7e36f') && content.contains('9620');
  print('${ok ? 'OK' : 'FALHA'} camada de texto (acentos em Windows-1252, texto invisível)');
  if (!ok) bad++;
  final dir = await Directory.systemTemp.createTemp('filume_ocrtest_');
  await writeTextLayerPdf([(360, 504, content), (612, 792, '')], '${dir.path}/t.pdf');
  final pdf = String.fromCharCodes(File('${dir.path}/t.pdf').readAsBytesSync());
  final ok2 = pdf.startsWith('%PDF-1.4') && pdf.contains('/Count 2') && pdf.trimRight().endsWith('%%EOF');
  print('${ok2 ? 'OK' : 'FALHA'} PDF da camada de texto');
  if (!ok2) bad++;
  if (Platform.isWindows) {
    final img = '${dir.path}\\texto.png';
    final draw = "Add-Type -AssemblyName System.Drawing; \$b = New-Object System.Drawing.Bitmap 1400,500; "
        "\$g = [System.Drawing.Graphics]::FromImage(\$b); \$g.Clear([System.Drawing.Color]::White); "
        "\$f = New-Object System.Drawing.Font 'Arial',48; "
        "\$g.DrawString('FiLume digitaliza recibos', \$f, [System.Drawing.Brushes]::Black, 60, 80); "
        "\$g.DrawString('Segunda linha de teste 2026', \$f, [System.Drawing.Brushes]::Black, 60, 260); "
        "\$b.Save('$img')";
    await Process.run('powershell.exe', ['-NoProfile', '-Command', draw]);
    try {
      final r = await WindowsOcr.recognize([img]);
      final text = r.first.words.map((w) => w.text).join(' ');
      final lines = r.first.words.map((w) => w.line).toSet().length;
      final good = text.toLowerCase().contains('recibos') && text.contains('2026') && lines == 2;
      print('${good ? 'OK' : 'FALHA'} OCR do Windows (${WindowsOcr.language}): "$text" em $lines linhas, imagem ${r.first.width}x${r.first.height}');
      if (!good) bad++;
      print(textLayerContent(r.first, 1400 * 72 / 200, 500 * 72 / 200).split('\n').take(4).join('\n'));
    } on OcrError catch (e) {
      print('OCR do Windows indisponível nesta máquina: ${e.message} | ${e.details}');
    }
  }
  dir.deleteSync(recursive: true);
  print(bad == 0 ? 'Tudo certo.' : '$bad problemas');
  exit(bad == 0 ? 0 : 1);
}
