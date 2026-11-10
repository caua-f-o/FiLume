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
  stdout.writeln('Runner do Windows personalizado.');
}
