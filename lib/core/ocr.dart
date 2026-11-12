import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// OCR (texto pesquisável). O reconhecimento usa o motor que já vem no
/// Windows 10/11 (Windows.Media.Ocr), chamado por um script do PowerShell;
/// a camada de texto invisível do PDF é escrita aqui mesmo.

class OcrWord {
  OcrWord(this.line, this.x, this.y, this.w, this.h, this.text);

  /// Índice da linha de texto na página.
  final int line;

  /// Caixa da palavra, em pixels da imagem (origem no canto de cima).
  final double x, y, w, h;
  final String text;
}

class OcrPage {
  OcrPage(this.width, this.height, this.words);

  /// Tamanho da imagem reconhecida, em pixels.
  final int width, height;
  final List<OcrWord> words;
}

class OcrError implements Exception {
  OcrError(this.message, [this.details = '']);
  final String message;
  final String details;
  @override
  String toString() => message;
}

/// Reconhece o texto de cada imagem, na ordem recebida.
typedef OcrFn = Future<List<OcrPage>> Function(List<String> images, void Function(int done)? onPage);

class WindowsOcr {
  static const _script = r'''
param([string]$List)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$inv = [System.Globalization.CultureInfo]::InvariantCulture
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
  function Await($op, [Type]$type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    $task.Result
  }
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if ($null -eq $engine) { "ERR`tnolang"; exit 3 }
  "LANG`t$($engine.RecognizerLanguage.LanguageTag)"
  $i = 0
  foreach ($path in [System.IO.File]::ReadAllLines($List)) {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    "P`t$i`t$($bitmap.PixelWidth)`t$($bitmap.PixelHeight)"
    $l = 0
    foreach ($line in $result.Lines) {
      foreach ($w in $line.Words) {
        $r = $w.BoundingRect
        "W`t$i`t$l`t$($r.X.ToString($inv))`t$($r.Y.ToString($inv))`t$($r.Width.ToString($inv))`t$($r.Height.ToString($inv))`t$($w.Text)"
      }
      $l++
    }
    $bitmap.Dispose()
    $stream.Dispose()
    $i++
  }
  exit 0
} catch {
  "ERR`t$($_.Exception.Message)"
  exit 1
}
''';

  /// Idioma usado na última leitura (ex.: "pt-BR").
  static String? language;

  static Future<List<OcrPage>> recognize(List<String> images, [void Function(int done)? onPage]) async {
    if (!Platform.isWindows) throw OcrError('O OCR usa o reconhecimento de texto do Windows 10/11.');
    if (images.isEmpty) return const [];
    final dir = await Directory.systemTemp.createTemp('filume_ocr_');
    try {
      final script = File(p.join(dir.path, 'ocr.ps1'));
      await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_script)]);
      final list = File(p.join(dir.path, 'lista.txt'));
      await list.writeAsString(images.join('\r\n'), encoding: utf8);
      final Process proc;
      try {
        proc = await Process.start('powershell.exe', [
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
          '-File', script.path, '-List', list.path,
        ]);
      } catch (e) {
        throw OcrError('Não foi possível iniciar o reconhecimento de texto do Windows.', '$e');
      }
      final sizes = <int, (int, int)>{};
      final words = <int, List<OcrWord>>{};
      String? err;
      final log = StringBuffer();
      final a = proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
        final f = line.split('\t');
        if (f[0] == 'P' && f.length >= 4) {
          final i = int.parse(f[1]);
          sizes[i] = (int.parse(f[2]), int.parse(f[3]));
          onPage?.call(i + 1);
        } else if (f[0] == 'W' && f.length >= 8) {
          final n = [for (var k = 3; k < 7; k++) double.tryParse(f[k]) ?? 0];
          (words[int.parse(f[1])] ??= []).add(OcrWord(int.parse(f[2]), n[0], n[1], n[2], n[3], f.sublist(7).join(' ')));
        } else if (f[0] == 'LANG' && f.length >= 2) {
          language = f[1];
        } else if (f[0] == 'ERR' && f.length >= 2) {
          err = f.sublist(1).join(' ');
        } else {
          log.writeln(line);
        }
      });
      final b = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(log.write);
      final code = await proc.exitCode;
      await Future.wait([a, b]);
      if (code != 0) {
        final raw = err ?? log.toString().trim();
        throw OcrError(
          raw == 'nolang'
              ? 'O Windows não tem nenhum idioma com reconhecimento de texto instalado. '
                  'Adicione um em Configurações > Hora e idioma > Idioma (recurso "Reconhecimento óptico de caracteres").'
              : 'O reconhecimento de texto do Windows falhou.',
          raw,
        );
      }
      return [
        for (var i = 0; i < images.length; i++)
          OcrPage(sizes[i]?.$1 ?? 0, sizes[i]?.$2 ?? 0, words[i] ?? const []),
      ];
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

// ------------------------------------------------------- camada de texto (PDF)

/// Larguras da Helvetica (milésimos do tamanho) para os caracteres 32..126.
const _helv = [
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, //  !"#$%&'()*+,-./
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, // 0-9:;<=>?
  1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, // @A-O
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, // P-Z[\]^_
  333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, // `a-o
  556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, // p-z{|}~
];

/// Letras acentuadas (Latin-1) → letra-base, para estimar a largura.
const _base = 'AAAAAAACEEEEIIIIDNOOOOOxOUUUUYPsaaaaaaaceeeeiiiidnooooo/ouuuuypy';

/// Caracteres do Windows-1252 que não coincidem com o Unicode.
const _cp1252 = {
  0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
  0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
  0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
  0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
};

/// Converte para Windows-1252 (o que a fonte padrão do PDF entende) e mede.
(List<int>, int) _encode(String text) {
  final bytes = <int>[];
  var width = 0;
  for (final r in text.runes) {
    final int b;
    if (r >= 32 && r <= 126 || r >= 0xA0 && r <= 0xFF) {
      b = r;
    } else if (_cp1252.containsKey(r)) {
      b = _cp1252[r]!;
    } else {
      continue; // fora do alfabeto ocidental: fica de fora da camada de texto
    }
    bytes.add(b);
    if (b <= 126) {
      width += _helv[b - 32];
    } else if (b >= 0xC0) {
      final c = _base.codeUnitAt(b - 0xC0);
      width += _helv[c - 32];
    } else {
      width += 556;
    }
  }
  return (bytes, width);
}

String _n(double v) => v.toStringAsFixed(2);

/// Conteúdo (operadores PDF) da camada de texto de uma página de
/// [wPt]×[hPt] pontos, a partir do que o OCR leu na imagem dela.
String textLayerContent(OcrPage page, double wPt, double hPt, {bool visible = false}) {
  if (page.width <= 0 || page.height <= 0) return '';
  final sx = wPt / page.width, sy = hPt / page.height;
  final lines = <int, List<OcrWord>>{};
  for (final w in page.words) {
    (lines[w.line] ??= []).add(w);
  }
  final out = StringBuffer('BT\n${visible ? 0 : 3} Tr\n');
  for (final words in lines.values) {
    // Uma linha de base e um tamanho por linha, para a seleção ficar alinhada.
    var top = double.infinity, bottom = 0.0;
    for (final w in words) {
      if (w.y < top) top = w.y;
      if (w.y + w.h > bottom) bottom = w.y + w.h;
    }
    final lineH = (bottom - top) * sy;
    if (lineH <= 0.5) continue;
    final size = lineH * 0.92;
    final baseline = hPt - bottom * sy + lineH * 0.2;
    for (final w in words) {
      final (bytes, natural) = _encode(w.text);
      if (bytes.isEmpty || natural == 0) continue;
      // Estica ou aperta a palavra para ocupar a largura que ela tem na imagem.
      final tz = (w.w * sx) / (natural / 1000 * size) * 100;
      final hex = StringBuffer();
      for (final b in [...bytes, 32]) {
        hex.write(b.toRadixString(16).padLeft(2, '0'));
      }
      out.write('/F1 ${_n(size)} Tf ${_n(tz.clamp(10, 1000).toDouble())} Tz '
          '1 0 0 1 ${_n(w.x * sx)} ${_n(baseline)} Tm <$hex> Tj\n');
    }
  }
  out.write('ET\n');
  return out.toString();
}

/// Escreve um PDF só com a camada de texto: uma página por item de [pages]
/// (tamanho em pontos + conteúdo; conteúdo vazio = página em branco).
Future<void> writeTextLayerPdf(List<(double, double, String)> pages, String out) async {
  final b = BytesBuilder();
  final offsets = <int>[];
  void obj(String body) {
    offsets.add(b.length);
    b.add(latin1.encode('${offsets.length} 0 obj\n$body\nendobj\n'));
  }

  b.add(latin1.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'));
  final n = pages.length;
  // 1 catálogo, 2 páginas, 3 fonte; depois, por página: página e conteúdo.
  obj('<< /Type /Catalog /Pages 2 0 R >>');
  obj('<< /Type /Pages /Count $n /Kids [${[for (var i = 0; i < n; i++) '${4 + i * 2} 0 R'].join(' ')}] >>');
  obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
  for (final (w, h, content) in pages) {
    final id = offsets.length + 1;
    obj('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${_n(w)} ${_n(h)}] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents ${id + 1} 0 R >>');
    obj('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final xref = b.length;
  final s = StringBuffer('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    s.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  s.write('trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  b.add(latin1.encode(s.toString()));
  await File(out).writeAsBytes(b.takeBytes());
}
