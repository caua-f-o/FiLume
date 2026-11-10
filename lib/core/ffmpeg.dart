import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _utf8 = Utf8Codec(allowMalformed: true);

class FfError implements Exception {
  FfError(this.message, [this.details = '']);
  final String message;
  final String details;
  @override
  String toString() => details.trim().isEmpty ? message : '$message\n${details.trim()}';
}

class JobCanceled implements Exception {
  const JobCanceled();
}

/// Metadados de um vídeo (lidos pelo ffprobe, sem carregar o arquivo).
class MediaInfo {
  MediaInfo({
    required this.path,
    required this.sizeBytes,
    required this.duration,
    required this.startTime,
    required this.bitrate,
    required this.videoIndex,
    required this.vCodec,
    required this.width,
    required this.height,
    required this.fps,
    required this.audioCount,
    required this.aCodec,
    required this.audioBitrate,
  });

  final String path;
  final int sizeBytes;
  final double duration;
  final double startTime;
  final int bitrate;
  final int? videoIndex;
  final String? vCodec;
  final int width;
  final int height;
  final double fps;
  final int audioCount;
  final String? aCodec;

  /// Soma do bitrate de todas as faixas de áudio (0 se desconhecido).
  final int audioBitrate;

  bool get hasVideo => videoIndex != null;
}

double _num(dynamic v) => v == null ? 0 : (double.tryParse(v.toString()) ?? 0);

double _rate(dynamic v) {
  final s = (v ?? '').toString();
  final parts = s.split('/');
  if (parts.length == 2) {
    final a = double.tryParse(parts[0]) ?? 0, b = double.tryParse(parts[1]) ?? 0;
    return b == 0 ? 0 : a / b;
  }
  return double.tryParse(s) ?? 0;
}

class FfTools {
  FfTools(this.ffmpeg, this.ffprobe);
  final String ffmpeg;
  final String ffprobe;

  /// Procura ffmpeg/ffprobe junto do executável (pasta do app, ./ffmpeg, ./bin)
  /// e, por último, no PATH do sistema.
  static Future<FfTools?> locate() async {
    final ext = Platform.isWindows ? '.exe' : '';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final dirs = <String>[
      // Permite apontar para outro FFmpeg sem mexer na pasta do app.
      if (Platform.environment['FILUME_FFMPEG_DIR'] case final String custom) custom,
      p.join(exeDir, 'ffmpeg'),
      p.join(exeDir, 'ffmpeg', 'bin'),
      exeDir,
      p.join(exeDir, 'bin'),
      Directory.current.path,
      p.join(Directory.current.path, 'ffmpeg'),
    ];
    for (final d in dirs) {
      final f = p.join(d, 'ffmpeg$ext'), pr = p.join(d, 'ffprobe$ext');
      if (File(f).existsSync() && File(pr).existsSync()) return FfTools(f, pr);
    }
    try {
      final a = await Process.run('ffmpeg', ['-version']);
      final b = await Process.run('ffprobe', ['-version']);
      if (a.exitCode == 0 && b.exitCode == 0) return FfTools('ffmpeg', 'ffprobe');
    } catch (_) {}
    return null;
  }

  Future<MediaInfo> probe(String path) async {
    final r = await Process.run(
      ffprobe,
      ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', path],
      stdoutEncoding: _utf8,
      stderrEncoding: _utf8,
    );
    if (r.exitCode != 0) {
      throw FfError('Não foi possível ler este arquivo.', r.stderr.toString());
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(r.stdout.toString()) as Map<String, dynamic>;
    } catch (_) {
      throw FfError('Resposta inesperada do ffprobe.');
    }
    final fmt = (j['format'] as Map<String, dynamic>?) ?? const {};
    final streams = ((j['streams'] as List?) ?? const []).cast<Map<String, dynamic>>();

    Map<String, dynamic>? video;
    var audioCount = 0, audioBitrate = 0;
    String? aCodec;
    for (final s in streams) {
      final type = s['codec_type'];
      if (type == 'video') {
        final disp = (s['disposition'] as Map<String, dynamic>?) ?? const {};
        if (video == null && disp['attached_pic'] != 1) video = s;
      } else if (type == 'audio') {
        audioCount++;
        aCodec ??= s['codec_name']?.toString();
        audioBitrate += _num(s['bit_rate']).round();
      }
    }

    var duration = _num(fmt['duration']);
    if (duration <= 0 && video != null) duration = _num(video['duration']);
    var size = _num(fmt['size']).round();
    if (size <= 0) {
      try {
        size = File(path).lengthSync();
      } catch (_) {}
    }
    var bitrate = _num(fmt['bit_rate']).round();
    if (bitrate <= 0 && duration > 0) bitrate = (size * 8 / duration).round();
    var fps = video == null ? 0.0 : _rate(video['avg_frame_rate']);
    if (video != null && (fps <= 0 || fps > 1000)) fps = _rate(video['r_frame_rate']);

    return MediaInfo(
      path: path,
      sizeBytes: size,
      duration: duration,
      startTime: _num(fmt['start_time']),
      bitrate: bitrate,
      videoIndex: video == null ? null : _num(video['index']).round(),
      vCodec: video?['codec_name']?.toString(),
      width: video == null ? 0 : _num(video['width']).round(),
      height: video == null ? 0 : _num(video['height']).round(),
      fps: fps,
      audioCount: audioCount,
      aCodec: aCodec,
      audioBitrate: audioBitrate,
    );
  }

  /// Descobre quais encoders realmente funcionam nesta máquina. Os de GPU são
  /// testados com um encode minúsculo, porque constar na lista do FFmpeg não
  /// significa que o hardware/driver existe.
  Future<Set<String>> detectEncoders() async {
    const cpu = ['libx264', 'libx265', 'libsvtav1'];
    const gpu = [
      'h264_nvenc', 'hevc_nvenc', 'av1_nvenc',
      'h264_qsv', 'hevc_qsv', 'av1_qsv',
      'h264_amf', 'hevc_amf', 'av1_amf',
    ];
    final usable = <String>{};
    String listed;
    try {
      final r = await Process.run(ffmpeg, ['-hide_banner', '-encoders'],
          stdoutEncoding: _utf8, stderrEncoding: _utf8);
      listed = r.stdout.toString();
    } catch (_) {
      return usable;
    }
    bool has(String name) => RegExp('\\s${RegExp.escape(name)}\\s').hasMatch(listed);
    usable.addAll(cpu.where(has));
    await Future.wait(gpu.where(has).map((name) async {
      try {
        final r = await Process.run(ffmpeg, [
          '-hide_banner', '-v', 'error', '-nostdin',
          '-f', 'lavfi', '-i', 'color=c=black:s=640x360:r=30:d=0.2',
          '-frames:v', '3', '-pix_fmt', 'yuv420p', '-c:v', name, '-f', 'null', '-',
        ]).timeout(const Duration(seconds: 20));
        if (r.exitCode == 0) usable.add(name);
      } catch (_) {}
    }));
    return usable;
  }
}

/// Executa processos do FFmpeg em streaming: nada de saída fica acumulado em
/// memória além das últimas linhas de erro (para diagnóstico).
class FfRun {
  Process? _proc;
  bool canceled = false;
  final List<String> errorTail = [];

  Future<int> exec(
    String exe,
    List<String> args, {
    String? workingDirectory,
    void Function(String line)? onStdoutLine,
  }) async {
    if (canceled) throw const JobCanceled();
    final proc = await Process.start(exe, args, workingDirectory: workingDirectory);
    _proc = proc;
    if (canceled) proc.kill();
    final errDone = proc.stderr
        .transform(_utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      errorTail.add(line);
      if (errorTail.length > 25) errorTail.removeAt(0);
    }).asFuture<void>();
    final outDone = proc.stdout
        .transform(_utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => onStdoutLine?.call(line))
        .asFuture<void>();
    final code = await proc.exitCode;
    await Future.wait([errDone, outDone]).catchError((_) => const <void>[]);
    _proc = null;
    if (canceled) throw const JobCanceled();
    return code;
  }

  /// Roda o ffmpeg com `-progress` e devolve o tempo já processado.
  Future<void> ffmpeg(
    FfTools tools,
    List<String> args, {
    String? workingDirectory,
    void Function(double outSeconds, String? speed)? onProgress,
  }) async {
    String? speed;
    final code = await exec(
      tools.ffmpeg,
      ['-hide_banner', '-nostdin', '-y', '-v', 'error', '-nostats', '-progress', 'pipe:1', ...args],
      workingDirectory: workingDirectory,
      onStdoutLine: (line) {
        final i = line.indexOf('=');
        if (i <= 0) return;
        final key = line.substring(0, i), value = line.substring(i + 1).trim();
        if (key == 'speed') {
          speed = value == 'N/A' ? null : value;
        } else if (key == 'out_time_us' || key == 'out_time_ms') {
          final us = int.tryParse(value);
          if (us != null && us >= 0) onProgress?.call(us / 1e6, speed);
        }
      },
    );
    if (code != 0) {
      throw FfError('O FFmpeg terminou com erro (código $code).', errorTail.join('\n'));
    }
  }

  void cancel() {
    canceled = true;
    _proc?.kill();
  }
}

/// Caminho que ainda não existe: "nome.ext", "nome (2).ext", ...
String uniquePath(String path, {bool directory = false}) {
  bool exists(String c) => directory ? Directory(c).existsSync() : File(c).existsSync();
  if (!exists(path) && !(directory ? File(path).existsSync() : Directory(path).existsSync())) {
    return path;
  }
  final dir = p.dirname(path);
  final ext = directory ? '' : p.extension(path);
  final base = directory ? p.basename(path) : p.basenameWithoutExtension(path);
  for (var n = 2;; n++) {
    final c = p.join(dir, '$base ($n)$ext');
    if (!File(c).existsSync() && !Directory(c).existsSync()) return c;
  }
}

/// Mostra o arquivo/pasta no gerenciador de arquivos do sistema.
Future<void> revealInFileManager(String path) async {
  try {
    final isDir = FileSystemEntity.isDirectorySync(path);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', isDir ? [path] : ['/select,', path],
          mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', isDir ? [path] : ['-R', path], mode: ProcessStartMode.detached);
    } else {
      await Process.start('xdg-open', [isDir ? path : p.dirname(path)],
          mode: ProcessStartMode.detached);
    }
  } catch (_) {}
}
