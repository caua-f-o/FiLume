import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

String _c(num x, num y, num r) => 'M${x - r} ${y}a$r $r 0 1 0 ${2 * r} 0a$r $r 0 1 0-${2 * r} 0z';

/// Detalhes geométricos ligados ao lugar onde aparecem. Cada um tem três
/// camadas num quadro 100×100: contorno, linhas de construção (tracejadas)
/// e uma parte preenchida.
final Map<String, (String, String, String)> motifs = {
  'pages': (
    'M34 14h30l16 16v52H34zM64 14v16h16',
    'M42 42h30M42 52h30M42 62h18M26 24v66h46M18 34v64h46',
    'M64 14l16 16H64z${_c(45, 72, 3)}',
  ),
  'video': (
    '${_c(50, 50, 34)}M4 8v84M96 8v84',
    '${_c(50, 50, 44)}M50 2v10M50 88v10',
    'M43 35l23 15-23 15z${[
      for (final x in [8, 85])
        for (final y in [14, 34, 59, 79]) 'M$x ${y}h7v7h-7z',
    ].join()}',
  ),
  'audio': (
    'M14 60v26M28 40v46M42 20v66M56 46v40M70 30v56M84 54v32',
    'M4 94h92M4 12q11.5-12 23 0t23 0t23 0t23 0',
    [_c(14, 52, 4), _c(28, 32, 4), _c(42, 12, 4), _c(56, 38, 4), _c(70, 22, 4), _c(84, 46, 4)].join(),
  ),
  'image': (
    'M8 14h84v72H8zM8 76l24-32 16 21 12-15 32 34',
    'M36 14v72M64 14v72M8 38h84M8 62h84M2 8h12M2 8v12M98 92H86M98 92V80',
    _c(72, 30, 8),
  ),
  'convert': (
    'M30 38h46l-12-12M70 62H24l12 12',
    'M4 20h20v30H4zM76 50h20v30H76zM50 6v20M50 74v20',
    '${_c(50, 50, 5)}M4 20h20v8H4zM76 50h20v8H76z',
  ),
  'compress': (
    'M8 8h84v84H8zM27 27h46v46H27z',
    'M8 8l19 19M92 8L73 27M8 92l19-19M92 92L73 73M50 0v27M50 73v27M0 50h27M73 50h27',
    'M40 40h20v20H40zM22 22h8v8h-8zM70 22h8v8h-8zM22 70h8v8h-8zM70 70h8v8h-8z',
  ),
  'split': (
    'M10 20h32v60H10zM58 20h32v60H58z',
    'M50 4v92M18 34h16M18 46h16M18 58h10M66 34h16M66 46h16M66 58h10',
    'M43 2h14l-7 9zM43 98h14l-7-9z',
  ),
  'merge': (
    '${_c(36, 50, 22)}${_c(64, 50, 22)}',
    'M2 50h96M50 10v80${_c(50, 50, 40)}',
    'M50 33a22 22 0 0 1 0 34a22 22 0 0 1 0-34z',
  ),
  'lock': (
    _c(50, 50, 40),
    '${_c(50, 50, 30)}M50 2v8M50 90v8M2 50h8M90 50h8',
    'M42 42a8 8 0 1 1 12 7l3 16H43l3-16a8 8 0 0 1-4-7z',
  ),
  'queue': (
    'M8 10h84v20H8zM8 40h62v20H8zM8 70h40v20H8z',
    'M97 6v90M76 50h16M54 80h38',
    'M8 10h52v20H8z${_c(84, 50, 3)}${_c(62, 80, 3)}',
  ),
  'organize': (
    'M6 8h24v34H6zM38 8h24v34H38zM70 8h24v34H70zM6 54h24v34H6zM70 54h24v34H70z',
    'M38 54h24v34H38zM50 60q4-22 30-14M74 40l7 6-8 4',
    'M38 8h24v34H38z',
  ),
  // Alvo da área de soltar arquivos: ondas e setas apontando para dentro.
  'drop': (
    '${_c(50, 50, 25.5)}M46.6 6.8l3.4 3.4 3.4-3.4M46.6 93.2l3.4-3.4 3.4 3.4M6.8 46.6l3.4 3.4-3.4 3.4M93.2 46.6l-3.4 3.4 3.4 3.4'
        'M24.2 24.2l2.5 2.5M75.8 24.2l-2.5 2.5M24.2 75.8l2.5-2.5M75.8 75.8l-2.5-2.5',
    '${_c(50, 50, 35.6)}${_c(50, 50, 45.8)}M50 14.4v6M50 79.6v6M14.4 50h6M79.6 50h6',
    '${_c(19.5, 19.5, 1.5)}${_c(80.5, 19.5, 1.5)}${_c(19.5, 80.5, 1.5)}${_c(80.5, 80.5, 1.5)}',
  ),
};

final _token = RegExp(r'[MmLlHhVvZzAaQqTt]|-?(?:\d+\.?\d*|\.\d+)');

/// Leitor mínimo de caminhos no formato SVG (só os comandos usados acima).
Path parseSvgPath(String d) {
  final path = Path();
  final tokens = _token.allMatches(d).map((m) => m.group(0)!).toList();
  var i = 0;
  var cmd = '';
  var cur = Offset.zero, start = Offset.zero;
  Offset? ctrl; // ponto de controle da última curva (para o comando T)
  double n() => double.parse(tokens[i++]);
  bool more() => i < tokens.length && !RegExp(r'^[A-Za-z]$').hasMatch(tokens[i]);
  while (i < tokens.length) {
    if (RegExp(r'^[A-Za-z]$').hasMatch(tokens[i])) cmd = tokens[i++];
    final rel = cmd == cmd.toLowerCase();
    Offset pt(double x, double y) => rel ? cur + Offset(x, y) : Offset(x, y);
    switch (cmd.toUpperCase()) {
      case 'M':
        cur = pt(n(), n());
        start = cur;
        path.moveTo(cur.dx, cur.dy);
        cmd = rel ? 'l' : 'L';
        ctrl = null;
      case 'L':
        cur = pt(n(), n());
        path.lineTo(cur.dx, cur.dy);
        ctrl = null;
      case 'H':
        final x = n();
        cur = Offset(rel ? cur.dx + x : x, cur.dy);
        path.lineTo(cur.dx, cur.dy);
        ctrl = null;
      case 'V':
        final y = n();
        cur = Offset(cur.dx, rel ? cur.dy + y : y);
        path.lineTo(cur.dx, cur.dy);
        ctrl = null;
      case 'Q':
        final c = pt(n(), n());
        final e = pt(n(), n());
        path.quadraticBezierTo(c.dx, c.dy, e.dx, e.dy);
        ctrl = c;
        cur = e;
      case 'T':
        final c = ctrl == null ? cur : cur * 2 - ctrl;
        final e = pt(n(), n());
        path.quadraticBezierTo(c.dx, c.dy, e.dx, e.dy);
        ctrl = c;
        cur = e;
      case 'A':
        final rx = n(), ry = n();
        n(); // rotação do eixo (não usada)
        final large = n() != 0, sweep = n() != 0;
        final e = pt(n(), n());
        path.arcToPoint(e, radius: Radius.elliptical(rx, ry), largeArc: large, clockwise: sweep);
        cur = e;
        ctrl = null;
      case 'Z':
        path.close();
        cur = start;
        ctrl = null;
      default:
        i++;
    }
    if (cmd.toUpperCase() == 'Z' && more()) break; // caminho malformado
  }
  return path;
}

Path _dashed(Path source, double on, double off) {
  final out = Path();
  for (final PathMetric m in source.computeMetrics()) {
    var d = 0.0;
    while (d < m.length) {
      out.addPath(m.extractPath(d, (d + on).clamp(0, m.length)), Offset.zero);
      d += on + off;
    }
  }
  return out;
}

final _parsed = <String, (Path, Path, Path)>{};

class _MotifPainter extends CustomPainter {
  _MotifPainter(this.name, this.color);
  final String name;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final m = motifs[name];
    if (m == null) return;
    final paths = _parsed[name] ??= (parseSvgPath(m.$1), _dashed(parseSvgPath(m.$2), 3, 4), parseSvgPath(m.$3));
    final s = size.shortestSide / 100;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    canvas.drawPath(paths.$2, stroke..strokeWidth = 1.5);
    canvas.drawPath(paths.$1, stroke..strokeWidth = 2.6);
    canvas.drawPath(paths.$3, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MotifPainter old) => old.name != name || old.color != color;
}

/// Desenho geométrico decorativo (ignorado por leitores de tela e pelo mouse).
class Motif extends StatelessWidget {
  const Motif(this.name, {super.key, required this.size, this.color});
  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary.withValues(alpha: 0.22);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: CustomPaint(size: Size.square(size), painter: _MotifPainter(name, c)),
      ),
    );
  }
}
