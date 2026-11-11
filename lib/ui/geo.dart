import 'package:flutter/material.dart';

String _c(num x, num y, num r) => 'M${x - r} ${y}a$r $r 0 1 0 ${2 * r} 0a$r $r 0 1 0-${2 * r} 0z';

/// Detalhes geométricos ligados ao lugar onde aparecem: um traço simples,
/// num quadro 100×100. Mais de uma camada = cada uma mais apagada que a anterior.
final Map<String, List<String>> motifs = {
  'pages': ['M30 18h28l14 14v48H30zM58 18v14h14M18 32v60h42'],
  'video': ['M40 28l34 22-34 22zM10 12h10v10H10zM10 34h10v10H10zM10 56h10v10H10zM10 78h10v10H10z'],
  'audio': ['M10 62v18M26 42v38M42 22v58M58 46v34M74 32v48M90 56v24'],
  'image': ['M4 88l28-40 18 24 12-16 34 32z${_c(70, 22, 9)}'],
  'convert': ['M18 36h58l-14-14M82 64H24l14 14'],
  'compress': ['M8 8h84v84H8zM27 27h46v46H27zM43 43h14v14H43z'],
  'split': ['M10 20h32v60H10zM58 20h32v60H58zM50 6v88'],
  'merge': ['${_c(36, 50, 22)}${_c(64, 50, 22)}'],
  'lock': ['${_c(50, 36, 16)}M43 50l-7 36h28l-7-36'],
  'queue': ['M8 16h84M8 40h62M8 64h40M8 88h20'],
  'organize': ['M6 8h24v34H6zM38 8h24v34H38zM70 8h24v34H70zM6 54h24v34H6zM38 54h24v34H38zM70 54h24v34H70z'],
  // Faixa de tempo com as duas marcas de corte.
  'trim': ['M8 32h84v36H8zM32 18v64M68 18v64'],
  // Marcas de recorte.
  'crop': ['M26 6v68h68M6 26h68v68'],
  // Duas faixas entrando em um arquivo só.
  'mux': ['M8 28h34M8 72h34M42 28l18 22-18 22M60 50h32'],
  // Mesa de som: três controles deslizantes.
  'mix': ['M24 10v80M50 10v80M76 10v80M14 34h20M40 62h20M66 44h20'],
  // Um quadro pequeno dentro do grande, com a seta de esticar.
  'resize': ['M10 10h80v80H10zM10 50h40v40M56 44l22-22M62 22h16v16'],
  // Seta em arco.
  'rotate': ['M80 50a30 30 0 1 1-9-21M71 12v18H53'],
  // Pixels pequenos virando um quadro grande.
  'upscale': ['M8 62h14v14H8zM22 76h14v14H22zM44 8h48v48H44zM30 70l10-10M32 60h8v8'],
  // Ondas em volta do ponto onde o arquivo cai.
  'drop': [_c(50, 50, 25.5), _c(50, 50, 35.6), _c(50, 50, 46.6)],
};

/// Desenho de cada ferramenta, pelo rótulo.
const toolMotifs = <String, String>{
  'Comprimir': 'compress',
  'Dividir': 'split',
  'Converter': 'convert',
  'Cortar': 'trim',
  'Unir': 'merge',
  'Recortar': 'crop',
  'Mux': 'mux',
  'Mixar': 'mix',
  'Organizar': 'organize',
  'PDF → Imagens': 'image',
  'Imagens → PDF': 'pages',
  'Senha': 'lock',
  'Ampliar': 'upscale',
  'Redimensionar': 'resize',
  'Girar': 'rotate',
};

/// Desenho de cada módulo.
const moduleMotifs = <String, String>{'video': 'video', 'audio': 'audio', 'pdf': 'pages', 'image': 'image'};

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

final _parsed = <String, List<Path>>{};

class _MotifPainter extends CustomPainter {
  _MotifPainter(this.name, this.color);
  final String name;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final m = motifs[name];
    if (m == null) return;
    final paths = _parsed[name] ??= [for (final d in m) parseSvgPath(d)];
    canvas.save();
    canvas.scale(size.shortestSide / 100);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = paths.length > 1 ? 1.2 : 3;
    for (var i = 0; i < paths.length; i++) {
      stroke.color = color.withValues(alpha: color.a * (1 - 0.35 * i));
      canvas.drawPath(paths[i], stroke);
    }
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
