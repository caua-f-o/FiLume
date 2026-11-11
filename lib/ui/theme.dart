import 'package:flutter/material.dart';

import '../core/prefs.dart';

/// Verde-amarelado de vagalume: a cor padrão do FiLume.
const filumeSeed = Color(0xFFB4D43C);

/// Cor própria de cada módulo (modo "uma cor por ferramenta").
const moduleSeeds = <String, Color>{
  'home': filumeSeed,
  'pdf': Color(0xFF2C9C93),
  'video': filumeSeed,
  'audio': Color(0xFFE0A030),
  'image': Color(0xFFC060B0),
  'files': Color(0xFF4F86E0),
  'settings': filumeSeed,
};

/// Paletas do modo "Paleta Material".
const materialPalettes = <String, (String, Color)>{
  'violeta': ('Violeta', Color(0xFF6750A4)),
  'azul': ('Azul', Color(0xFF2B5EA7)),
  'agua': ('Verde-água', Color(0xFF006B5E)),
  'rosa': ('Rosa', Color(0xFFB0476B)),
  'laranja': ('Laranja', Color(0xFFB8621B)),
};

/// Cor-base do app inteiro (fora do modo por ferramenta).
Color appSeed(Prefs prefs) => switch (prefs.colorMode) {
      'system' => prefs.systemAccent == null ? filumeSeed : Color(prefs.systemAccent!),
      'material' => materialPalettes[prefs.palette]?.$2 ?? filumeSeed,
      _ => filumeSeed,
    };

/// Cor-base de um módulo, respeitando o modo de cores escolhido.
Color seedFor(Prefs prefs, String module) =>
    prefs.colorMode == 'tool' ? (moduleSeeds[module] ?? filumeSeed) : appSeed(prefs);

ThemeMode themeModeOf(Prefs prefs) => switch (prefs.theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

final _cache = <(int, Brightness), ThemeData>{};

ThemeData buildTheme(Color seed, Brightness brightness) {
  return _cache[(seed.toARGB32(), brightness)] ??= () {
    final cs = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll(
            const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ),
      // Atalhos e opções: fundo e texto com contraste garantido nos dois temas.
      chipTheme: ChipThemeData(
        backgroundColor: cs.surfaceContainerHighest,
        selectedColor: cs.secondaryContainer,
        disabledColor: cs.surfaceContainerHigh,
        side: BorderSide(color: cs.outlineVariant),
        labelStyle: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w500),
        secondaryLabelStyle: TextStyle(color: cs.onSecondaryContainer, fontWeight: FontWeight.w700),
        checkmarkColor: cs.onSecondaryContainer,
        iconTheme: IconThemeData(color: cs.onSurfaceVariant, size: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        surfaceTintColor: Colors.transparent,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 400),
      ),
    );
  }();
}

/// Aplica a cor de um módulo ao conteúdo (mantendo claro/escuro do app).
class ModuleTheme extends StatelessWidget {
  const ModuleTheme({super.key, required this.prefs, required this.module, required this.child});
  final Prefs prefs;
  final String module;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildTheme(seedFor(prefs, module), Theme.of(context).brightness),
      child: child,
    );
  }
}
