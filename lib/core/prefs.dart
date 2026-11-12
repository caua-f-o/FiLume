import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Um arquivo feito recentemente (aparece na tela inicial).
class Recent {
  Recent({required this.title, required this.detail, required this.path, required this.module});
  final String title;
  final String detail;

  /// Arquivo ou pasta do resultado (para "abrir pasta").
  final String path;

  /// Módulo que gerou: "video", "audio", "pdf"…
  final String module;

  String get tag {
    final ext = p.extension(title).replaceFirst('.', '').toUpperCase();
    return ext.isEmpty || ext.length > 4 ? module.toUpperCase().substring(0, 3) : ext;
  }

  Map<String, dynamic> toJson() => {'title': title, 'detail': detail, 'path': path, 'module': module};

  static Recent? fromJson(dynamic j) {
    if (j is! Map) return null;
    final t = j['title'], d = j['detail'], pa = j['path'], m = j['module'];
    if (t is! String || d is! String || pa is! String || m is! String) return null;
    return Recent(title: t, detail: d, path: pa, module: m);
  }
}

/// Preferências do app e lista de recentes, guardadas em um JSON na pasta
/// de dados do usuário (nada sai do computador).
class Prefs extends ChangeNotifier {
  /// "system" | "light" | "dark"
  String theme = 'system';

  /// "tool" (uma cor por ferramenta) | "static" (padrão FiLume) |
  /// "system" (cor de destaque do Windows) | "material" (paleta escolhida)
  String colorMode = 'tool';
  String palette = 'violeta';

  /// "home" | "last" | "pdf"
  String startPage = 'home';
  String lastPage = 'home';
  bool keepRecents = true;
  final List<Recent> recents = [];

  /// FiLume PDF: pastas favoritas para salvar e a última usada.
  final List<String> pdfFolders = [];
  String? pdfLastDir;

  /// FiLume PDF: OCR ligado (texto pesquisável ao salvar).
  bool ocr = true;

  /// Opções de digitalização e scanners já encontrados (ver ScanSettings).
  Map<String, dynamic> scan = {};

  /// Cor de destaque do Windows (0xAARRGGBB), se foi possível ler.
  int? systemAccent;

  static const maxRecents = 12;

  File? get _file {
    final env = Platform.environment;
    final base = env['APPDATA'] ?? env['XDG_CONFIG_HOME'] ?? (env['HOME'] == null ? null : p.join(env['HOME']!, '.config'));
    return base == null ? null : File(p.join(base, 'FiLume', 'settings.json'));
  }

  Future<void> load() async {
    try {
      final f = _file;
      if (f != null && f.existsSync()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) {
          String pick(String key, List<String> ok, String def) {
            final v = j[key];
            return v is String && ok.contains(v) ? v : def;
          }

          theme = pick('theme', const ['system', 'light', 'dark'], theme);
          colorMode = pick('colorMode', const ['tool', 'static', 'system', 'material'], colorMode);
          palette = pick('palette', const ['violeta', 'azul', 'agua', 'rosa', 'laranja'], palette);
          startPage = pick('startPage', const ['home', 'last'], startPage);
          final lp = j['lastPage'];
          if (lp is String) lastPage = lp;
          final kr = j['keepRecents'];
          if (kr is bool) keepRecents = kr;
          final pf = j['pdfFolders'];
          if (pf is List) {
            pdfFolders
              ..clear()
              ..addAll(pf.whereType<String>());
          }
          final pl = j['pdfLastDir'];
          if (pl is String) pdfLastDir = pl;
          if (j['ocr'] is bool) ocr = j['ocr'] as bool;
          final sc = j['scan'];
          if (sc is Map) scan = sc.cast<String, dynamic>();
          final rs = j['recents'];
          if (rs is List) {
            recents
              ..clear()
              ..addAll(rs.map(Recent.fromJson).whereType<Recent>().take(maxRecents));
          }
        }
      }
    } catch (_) {
      // Arquivo ilegível: segue com os padrões.
    }
    systemAccent = await _readAccent();
    notifyListeners();
  }

  Future<void> save() async {
    try {
      final f = _file;
      if (f == null) return;
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'theme': theme,
        'colorMode': colorMode,
        'palette': palette,
        'startPage': startPage,
        'lastPage': lastPage,
        'keepRecents': keepRecents,
        'pdfFolders': pdfFolders,
        'ocr': ocr,
        if (scan.isNotEmpty) 'scan': scan,
        if (pdfLastDir != null) 'pdfLastDir': pdfLastDir,
        'recents': [for (final r in recents) r.toJson()],
      }));
    } catch (_) {}
  }

  /// Aplica uma mudança, avisa a interface e grava.
  void update(void Function() change) {
    change();
    notifyListeners();
    save();
  }

  void addRecent(Recent r) {
    if (!keepRecents) return;
    recents
      ..removeWhere((e) => e.path == r.path && e.title == r.title)
      ..insert(0, r);
    if (recents.length > maxRecents) recents.removeRange(maxRecents, recents.length);
    notifyListeners();
    save();
  }

  void clearRecents() => update(recents.clear);

  /// Lê a cor de destaque do Windows no registro (formato 0xAABBGGRR).
  static Future<int?> _readAccent() async {
    if (!Platform.isWindows) return null;
    try {
      final r = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\DWM',
        '/v',
        'AccentColor',
      ]).timeout(const Duration(seconds: 3));
      if (r.exitCode != 0) return null;
      final m = RegExp(r'0x([0-9a-fA-F]{8})').firstMatch(r.stdout.toString());
      if (m == null) return null;
      final abgr = int.parse(m.group(1)!, radix: 16);
      final b = (abgr >> 16) & 0xFF, g = (abgr >> 8) & 0xFF, red = abgr & 0xFF;
      return 0xFF000000 | (red << 16) | (g << 8) | b;
    } catch (_) {
      return null;
    }
  }
}
