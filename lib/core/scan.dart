import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Digitalização por scanner, usando o motor de linha de comando do NAPS2
/// (que fala com drivers TWAIN e WIA). Só existe no Windows.
class ScanTools {
  ScanTools(this.exe);
  final String exe;

  static ScanTools? locate() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final roots = <String>[
      if (Platform.environment['FILUME_SCANNER_DIR'] case final String custom) custom,
      p.join(exeDir, 'scanner'),
      p.join(Directory.current.path, 'third_party', 'scanner'),
    ];
    for (final r in roots) {
      final exe = p.join(r, 'NAPS2.Console.exe');
      if (File(exe).existsSync()) return ScanTools(exe);
    }
    return null;
  }

  /// Nomes dos scanners que o driver enxerga.
  Future<List<String>> devices(String driver) async {
    final r = await Process.run(exe, ['--listdevices', '--driver', driver],
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true));
    if (r.exitCode != 0) {
      throw ScanError('Não foi possível listar os scanners.', '${r.stdout}\n${r.stderr}'.trim());
    }
    return [
      for (final line in const LineSplitter().convert(r.stdout.toString()))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  /// Digitaliza e devolve as páginas (uma imagem JPG por página), em ordem.
  Future<List<String>> scan(ScanSettings s, {void Function(Process proc)? onStart}) async {
    final dir = await Directory.systemTemp.createTemp('filume_scan_');
    final proc = await Process.start(exe, [
      '-o', p.join(dir.path, r'pagina_$(nnnn).jpg'),
      '--noprofile',
      '--driver', s.driver,
      '--device', s.device,
      '--source', s.source,
      '--dpi', '${s.dpi}',
      '--bitdepth', s.color,
      '--jpegquality', '90',
      '-f',
    ]);
    onStart?.call(proc);
    final out = StringBuffer();
    final a = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach(out.write);
    final b = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(out.write);
    final code = await proc.exitCode;
    await Future.wait([a, b]);
    final pages = dir.listSync().whereType<File>().map((f) => f.path).where((f) => f.toLowerCase().endsWith('.jpg')).toList()
      ..sort();
    if (pages.isEmpty) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      final log = out.toString().trim();
      throw ScanError(
        code == 0 && log.isEmpty
            ? 'O scanner não devolveu nenhuma página. Confira se há papel e se ele está ligado.'
            : 'A digitalização não funcionou.',
        log,
      );
    }
    return pages;
  }
}

class ScanSettings {
  /// "twain" ou "wia".
  String driver = 'twain';
  String device = '';

  /// "glass" (vidro), "feeder" (alimentador) ou "duplex" (frente e verso).
  String source = 'glass';
  int dpi = 300;

  /// "color", "gray" ou "bw".
  String color = 'color';
}

class ScanError implements Exception {
  ScanError(this.message, [this.details = '']);
  final String message;
  final String details;
  @override
  String toString() => details.isEmpty ? message : '$message\n$details';
}
