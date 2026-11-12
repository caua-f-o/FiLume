import 'dart:io';

import 'package:path/path.dart' as p;

/// O FiLume e o FiLume PDF são o mesmo programa com dois nomes: o executável
/// "FiLume PDF" (ou a opção --pdf) abre o app de PDF.
bool isPdfApp(List<String> args) =>
    args.contains('--pdf') || p.basenameWithoutExtension(Platform.resolvedExecutable).toLowerCase().contains('pdf');

/// Arquivos passados na linha de comando (o que não é opção).
List<String> fileArgs(List<String> args) => [
      for (final a in args)
        if (!a.startsWith('--')) a,
    ];

String get _exeDir => File(Platform.resolvedExecutable).parent.path;

Future<bool> _start(String exe, List<String> args) async {
  try {
    await Process.start(exe, args, mode: ProcessStartMode.detached);
    return true;
  } catch (_) {
    return false;
  }
}

/// Abre o FiLume PDF já com [files] na bandeja.
Future<bool> launchPdfApp(List<String> files) {
  final exe = p.join(_exeDir, Platform.isWindows ? 'FiLume PDF.exe' : 'filume_pdf');
  // Sem o executável dedicado, o próprio programa abre em modo PDF.
  return File(exe).existsSync() ? _start(exe, files) : _start(Platform.resolvedExecutable, ['--pdf', ...files]);
}

/// Abre o FiLume principal (vídeo, áudio e imagem).
Future<bool> launchMainApp() async {
  for (final name in const ['FiLume.exe', 'filume.exe', 'filume']) {
    final exe = p.join(_exeDir, name);
    if (File(exe).existsSync()) return _start(exe, const []);
  }
  return false;
}
