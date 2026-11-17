import 'dart:io';

import 'package:path/path.dart' as p;

/// O FiLume e o FiPDF são o mesmo programa com dois nomes: o executável
/// "FiPDF" (ou o antigo "FiLume PDF", ou a opção --pdf) abre o app de PDF.
bool isPdfApp(List<String> args) =>
    args.contains('--pdf') || p.basenameWithoutExtension(Platform.resolvedExecutable).toLowerCase().contains('pdf');

/// O FiLume Conversor segue a mesma ideia: executável "FiLume Conversor" (ou --converter).
bool isConverterApp(List<String> args) =>
    args.contains('--converter') || p.basenameWithoutExtension(Platform.resolvedExecutable).toLowerCase().contains('conversor');

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

/// Abre o FiPDF já com [files] na bandeja.
Future<bool> launchPdfApp(List<String> files) {
  // "FiLume PDF.exe" é o nome antigo, mantido no pacote para atalhos que já existem.
  for (final name in Platform.isWindows ? const ['FiPDF.exe', 'FiLume PDF.exe'] : const ['fipdf', 'filume_pdf']) {
    final exe = p.join(_exeDir, name);
    if (File(exe).existsSync()) return _start(exe, files);
  }
  // Sem o executável dedicado, o próprio programa abre em modo PDF.
  return _start(Platform.resolvedExecutable, ['--pdf', ...files]);
}

/// Abre o FiLume Conversor já com [files] na lista.
Future<bool> launchConverterApp([List<String> files = const []]) {
  final exe = p.join(_exeDir, Platform.isWindows ? 'FiLume Conversor.exe' : 'filume_conversor');
  return File(exe).existsSync() ? _start(exe, files) : _start(Platform.resolvedExecutable, ['--converter', ...files]);
}

/// Abre o FiLume principal (vídeo, áudio e imagem).
Future<bool> launchMainApp() async {
  for (final name in const ['FiLume.exe', 'filume.exe', 'filume']) {
    final exe = p.join(_exeDir, name);
    if (File(exe).existsSync()) return _start(exe, const []);
  }
  return false;
}
