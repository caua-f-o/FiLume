import 'dart:math' as math;

// Medidas sobre a página: distância, perímetro e área, com escala (plantas e
// mapas). A ideia da ferramenta vem do módulo de medição do PdfCraft
// (https://github.com/storytold/pdfcraft, MIT OU Apache-2.0, © 2026 ArtCraft
// Team e colaboradores do PdfCraft); o código é novo.

enum MeasureUnit {
  mm('mm', 25.4 / 72),
  cm('cm', 2.54 / 72),
  m('m', 0.0254 / 72),
  inch('pol', 1 / 72),
  pt('pt', 1);

  const MeasureUnit(this.label, this.perPoint);
  final String label;

  /// Quantas unidades cabem em um ponto do PDF (1/72 de polegada).
  final double perPoint;
}

/// Escala do desenho: [paper] unidades no papel valem [real] unidades de verdade
/// (1:100 → paper 1, real 100).
class MeasureScale {
  const MeasureScale([this.paper = 1, this.real = 1]);
  final double paper, real;
  double get factor => paper <= 0 ? 1 : real / paper;
  bool get isIdentity => (factor - 1).abs() < 1e-9;

  /// Lê "1:100", "1/50" ou só "100".
  static MeasureScale? parse(String text) {
    final m = RegExp(r'^\s*(\d+(?:[.,]\d+)?)\s*(?:[:/]\s*(\d+(?:[.,]\d+)?))?\s*$').firstMatch(text);
    if (m == null) return null;
    double n(String s) => double.parse(s.replaceAll(',', '.'));
    final a = n(m[1]!);
    final b = m[2] == null ? null : n(m[2]!);
    if (a <= 0 || (b != null && b <= 0)) return null;
    return b == null ? MeasureScale(1, a) : MeasureScale(a, b);
  }

  @override
  String toString() {
    String f(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString().replaceAll('.', ',');
    return '${f(paper)}:${f(real)}';
  }
}

/// Comprimento do caminho que passa pelos [points] (em pontos do PDF).
double pathLength(List<(double, double)> points, {bool closed = false}) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += math.sqrt(math.pow(points[i].$1 - points[i - 1].$1, 2) + math.pow(points[i].$2 - points[i - 1].$2, 2));
  }
  if (closed && points.length > 2) {
    total += math.sqrt(math.pow(points.first.$1 - points.last.$1, 2) + math.pow(points.first.$2 - points.last.$2, 2));
  }
  return total;
}

/// Área do polígono formado pelos [points] (em pontos quadrados).
double polygonArea(List<(double, double)> points) {
  if (points.length < 3) return 0;
  var sum = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    sum += a.$1 * b.$2 - b.$1 * a.$2;
  }
  return sum.abs() / 2;
}

String _number(double v) {
  final digits = v.abs() >= 100 ? 1 : (v.abs() >= 1 ? 2 : 3);
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s.replaceAll('.', ',');
}

/// Comprimento em pontos → texto na unidade e escala escolhidas.
String formatLength(double points, MeasureUnit unit, [MeasureScale scale = const MeasureScale()]) =>
    '${_number(points * unit.perPoint * scale.factor)} ${unit.label}';

/// Área em pontos quadrados → texto na unidade e escala escolhidas.
String formatArea(double squarePoints, MeasureUnit unit, [MeasureScale scale = const MeasureScale()]) {
  final k = unit.perPoint * scale.factor;
  return '${_number(squarePoints * k * k)} ${unit.label}²';
}
