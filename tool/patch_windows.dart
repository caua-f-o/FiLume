// Personaliza o runner do Windows gerado pelo `flutter create`:
// título, nome do .exe, tamanho mínimo da janela e ícone.
// Uso: dart run tool/patch_windows.dart
import 'dart:io';

void patch(String path, List<(Pattern, String)> edits) {
  final f = File(path);
  if (!f.existsSync()) {
    stderr.writeln('aviso: $path não existe');
    return;
  }
  var text = f.readAsStringSync();
  for (final (from, to) in edits) {
    if (!text.contains(from)) {
      stderr.writeln('aviso: padrão não encontrado em $path: $from');
      continue;
    }
    text = text.replaceFirst(from, to);
  }
  f.writeAsStringSync(text);
}

/// Roda um comando; devolve true se terminou bem.
bool sh(String exe, List<String> args) {
  try {
    final r = Process.runSync(exe, args, runInShell: Platform.isWindows);
    if (r.exitCode != 0) stderr.writeln('aviso: $exe ${args.join(' ')}\n${r.stderr}');
    return r.exitCode == 0;
  } catch (e) {
    stderr.writeln('aviso: não foi possível rodar $exe: $e');
    return false;
  }
}

void copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (e is Directory) {
      copyDir(e, Directory('${to.path}/$name'));
    } else if (e is File) {
      e.copySync('${to.path}/$name');
    }
  }
}

/// Baixa o qpdf e o Ghostscript (motores do módulo Documentos) e manda o
/// build copiá-los para a pasta "pdftools" ao lado do FiLume.exe.
/// Se algo falhar, o build continua: o app só avisa que o módulo está sem motor.
void bundlePdfTools() {
  if (!Platform.isWindows && Platform.environment['FILUME_FORCE_BUNDLE'] == null) return;
  final root = Directory('third_party/pdftools');
  final tmp = Directory('third_party/_dl');
  try {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);

    // qpdf: zip oficial (bin/qpdf.exe + DLLs).
    if (!File('${root.path}/qpdf/bin/qpdf.exe').existsSync()) {
      if (sh('gh', ['release', 'download', '-R', 'qpdf/qpdf', '-p', 'qpdf-*-msvc64.zip', '-D', tmp.path]) ||
          sh('curl', ['-fsSL', '-o', '${tmp.path}/qpdf-12.4.2-msvc64.zip',
            'https://github.com/qpdf/qpdf/releases/download/v12.4.2/qpdf-12.4.2-msvc64.zip'])) {
        final zip = tmp.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.zip'));
        Directory('${tmp.path}/qpdf').createSync();
        if (sh('7z', ['x', '-y', '-o${tmp.path}/qpdf', zip.path]) ||
            sh('tar', ['-xf', zip.path, '-C', '${tmp.path}/qpdf'])) {
          final bin = Directory('${tmp.path}/qpdf')
              .listSync(recursive: true)
              .whereType<Directory>()
              .firstWhere((d) => File('${d.path}/qpdf.exe').existsSync());
          copyDir(bin, Directory('${root.path}/qpdf/bin'));
          stdout.writeln('qpdf embutido.');
        }
      }
    }

    // Ghostscript: o instalador oficial é um pacote que o 7-Zip sabe abrir.
    if (!File('${root.path}/gs/bin/gswin64c.exe').existsSync()) {
      if (sh('gh', ['release', 'download', '-R', 'ArtifexSoftware/ghostpdl-downloads',
            '-p', 'gs*w64.exe', '-D', tmp.path]) ||
          sh('curl', ['-fsSL', '-o', '${tmp.path}/gs10080w64.exe',
            'https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10080/gs10080w64.exe'])) {
        final exe = tmp.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('w64.exe'));
        if (sh('7z', ['x', '-y', '-o${tmp.path}/gs', exe.path])) {
          for (final part in const ['bin', 'lib', 'Resource', 'iccprofiles']) {
            final d = Directory('${tmp.path}/gs/$part');
            if (d.existsSync()) copyDir(d, Directory('${root.path}/gs/$part'));
          }
          // Runtime do Visual C++ ao lado do executável, para rodar em qualquer PC.
          for (final dll in const ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll']) {
            final f = File('C:/Windows/System32/$dll');
            if (f.existsSync()) f.copySync('${root.path}/gs/bin/$dll');
          }
          stdout.writeln('Ghostscript embutido.');
        }
      }
    }
  } catch (e) {
    stderr.writeln('aviso: ferramentas de PDF não embutidas: $e');
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  // Regra de instalação: copia third_party/pdftools para junto do .exe.
  final cmake = File('windows/CMakeLists.txt');
  if (cmake.existsSync() && !cmake.readAsStringSync().contains('pdftools')) {
    cmake.writeAsStringSync('''

# FiLume: motores de PDF (qpdf + Ghostscript) ao lado do executável.
if(EXISTS "\${CMAKE_CURRENT_SOURCE_DIR}/../third_party/pdftools")
  install(DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}/../third_party/pdftools"
    DESTINATION "\${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
endif()
''', mode: FileMode.append);
  }
}

/// Embute o ampliador de imagens por IA (Real-ESRGAN ncnn-vulkan) e os modelos.
void bundleUpscaler() {
  if (!Platform.isWindows && Platform.environment['FILUME_FORCE_BUNDLE'] == null) return;
  final root = Directory('third_party/upscaler');
  final tmp = Directory('third_party/_dl_up');
  const zipName = 'realesrgan-ncnn-vulkan-20220424-windows.zip';
  try {
    if (!File('${root.path}/realesrgan-ncnn-vulkan.exe').existsSync()) {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      tmp.createSync(recursive: true);
      if (sh('curl', ['-fsSL', '-o', '${tmp.path}/$zipName',
            'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/$zipName']) ||
          sh('gh', ['release', 'download', 'v0.2.5.0', '-R', 'xinntao/Real-ESRGAN', '-p', zipName, '-D', tmp.path])) {
        Directory('${tmp.path}/x').createSync();
        if (sh('7z', ['x', '-y', '-o${tmp.path}/x', '${tmp.path}/$zipName']) ||
            sh('tar', ['-xf', '${tmp.path}/$zipName', '-C', '${tmp.path}/x'])) {
          final exe = Directory('${tmp.path}/x')
              .listSync(recursive: true)
              .whereType<File>()
              .firstWhere((f) => f.path.replaceAll('\\', '/').endsWith('/realesrgan-ncnn-vulkan.exe'));
          final src = exe.parent;
          root.createSync(recursive: true);
          exe.copySync('${root.path}/realesrgan-ncnn-vulkan.exe');
          // Só o necessário: o programa, a DLL do OpenMP e os modelos (sem os exemplos).
          final omp = File('${src.path}/vcomp140.dll');
          if (omp.existsSync()) omp.copySync('${root.path}/vcomp140.dll');
          copyDir(Directory('${src.path}/models'), Directory('${root.path}/models'));
          for (final dll in const ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll']) {
            final f = File('C:/Windows/System32/$dll');
            if (f.existsSync()) f.copySync('${root.path}/$dll');
          }
          stdout.writeln('Ampliador por IA embutido.');
        }
      }
    }
  } catch (e) {
    stderr.writeln('aviso: ampliador por IA não embutido: $e');
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  final cmake = File('windows/CMakeLists.txt');
  if (cmake.existsSync() && !cmake.readAsStringSync().contains('third_party/upscaler')) {
    cmake.writeAsStringSync('''

# FiLume: ampliador de imagens por IA ao lado do executável.
if(EXISTS "\${CMAKE_CURRENT_SOURCE_DIR}/../third_party/upscaler")
  install(DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}/../third_party/upscaler"
    DESTINATION "\${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
endif()
''', mode: FileMode.append);
  }
}

/// FiLume PDF: o mesmo executável com outro nome (o app decide o que abrir
/// pelo nome do arquivo). Uma cópia vai para a pasta do build.
void bundlePdfApp() {
  final cmake = File('windows/CMakeLists.txt');
  if (cmake.existsSync() && !cmake.readAsStringSync().contains('FiLume PDF.exe')) {
    cmake.writeAsStringSync('''

# FiLume PDF: cópia do executável com o nome do app de PDF.
install(PROGRAMS "\$<TARGET_FILE:\${BINARY_NAME}>"
  DESTINATION "\${CMAKE_INSTALL_PREFIX}" RENAME "FiLume PDF.exe" COMPONENT Runtime)
''', mode: FileMode.append);
  }
}

void main() {
  patch('windows/runner/main.cpp', [
    ('L"filume"', 'L"FiLume"'),
    ('Win32Window::Size size(1280, 720);', 'Win32Window::Size size(1320, 800);'),
  ]);
  final win = File('windows/runner/win32_window.cpp');
  if (win.existsSync() && !win.readAsStringSync().contains('WM_GETMINMAXINFO')) {
    patch(win.path, [
      (
        '    case WM_DESTROY:',
        '    case WM_GETMINMAXINFO: {\n'
            '      // FiLume: tamanho mínimo da janela (em DIPs, ajustado ao DPI).\n'
            '      const int dpi = static_cast<int>(GetDpiForWindow(hwnd));\n'
            '      auto info = reinterpret_cast<MINMAXINFO*>(lparam);\n'
            '      info->ptMinTrackSize.x = MulDiv(1020, dpi, 96);\n'
            '      info->ptMinTrackSize.y = MulDiv(640, dpi, 96);\n'
            '      return 0;\n'
            '    }\n'
            '    case WM_DESTROY:'
      ),
    ]);
  }
  patch('windows/runner/Runner.rc', [
    ('VALUE "FileDescription", "filume"', 'VALUE "FileDescription", "FiLume"'),
    ('VALUE "InternalName", "filume"', 'VALUE "InternalName", "FiLume"'),
    ('VALUE "OriginalFilename", "filume.exe"', 'VALUE "OriginalFilename", "FiLume.exe"'),
    ('VALUE "ProductName", "filume"', 'VALUE "ProductName", "FiLume"'),
  ]);
  patch('windows/CMakeLists.txt', [
    ('set(BINARY_NAME "filume")', 'set(BINARY_NAME "FiLume")'),
  ]);
  final icon = File('assets/app_icon.ico');
  if (icon.existsSync()) {
    icon.copySync('windows/runner/resources/app_icon.ico');
  }
  bundlePdfTools();
  bundleUpscaler();
  bundlePdfApp();
  stdout.writeln('Runner do Windows personalizado.');
}
