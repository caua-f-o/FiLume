/// 1 MB = 1024² bytes em todo o app, igual ao Explorer do Windows.
const int bytesPerMb = 1024 * 1024;

String _dec(double v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');

/// Tamanho legível (base 1024, igual ao Explorer do Windows).
String fmtBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final digits = i == 0 ? 0 : (v < 10 ? 2 : (v < 100 ? 1 : 0));
  return '${_dec(v, digits)} ${units[i]}';
}

String fmtDuration(double seconds) {
  if (seconds.isNaN || seconds.isInfinite || seconds < 0) seconds = 0;
  final t = seconds.round();
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, s = t % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Como [fmtDuration], mas com décimos de segundo quando existem (ex.: 1:05,4).
String fmtDurationPrecise(double seconds) {
  if (seconds.isNaN || seconds.isInfinite || seconds < 0) seconds = 0;
  final tenths = (seconds * 10).round();
  if (tenths % 10 == 0) return fmtDuration(tenths / 10);
  final whole = tenths ~/ 10;
  final h = whole ~/ 3600, m = (whole % 3600) ~/ 60, s = whole % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${h > 0 ? '$h:${two(m)}' : '$m'}:${two(s)},${tenths % 10}';
}

String fmtBitrate(int bps) =>
    bps >= 1000000 ? '${_dec(bps / 1e6, 1)} Mb/s' : '${(bps / 1000).round()} kb/s';

String fmtPercent(double fraction) => '${(fraction * 100).round()}%';

/// Aceita "90", "1:30", "1:02:03" (e vírgula decimal). Retorna segundos.
double? parseDuration(String input) {
  final parts = input.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var total = 0.0;
  for (final p in parts) {
    final v = double.tryParse(p.trim().replaceAll(',', '.'));
    if (v == null || v < 0) return null;
    total = total * 60 + v;
  }
  return total;
}

double? parseNumber(String input) {
  final v = double.tryParse(input.trim().replaceAll(',', '.'));
  return (v == null || v.isNaN || v.isInfinite) ? null : v;
}
