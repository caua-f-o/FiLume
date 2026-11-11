import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:path/path.dart' as p;

import 'audio.dart';
import 'compress.dart';
import 'convert.dart';
import 'crop.dart';
import 'ffmpeg.dart';
import 'image.dart';
import 'job.dart';
import 'merge.dart';
import 'mux.dart';
import 'pdf.dart';
import 'pdf_workspace.dart';
import 'prefs.dart';
import 'scan.dart';
import 'split.dart';
import 'streams.dart';
import 'trim.dart';

class InputItem {
  InputItem(this.path);
  final String path;
  MediaInfo? info;
  String? error;
}

const imageExts = ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'tif', 'tiff', 'gif'];

/// Lista de arquivos de um módulo.
class InputList {
  InputList(this._app, {required this.audioModule, this.docs = false, this.images = false});
  final AppState _app;

  /// No módulo de áudio basta ter uma faixa de áudio (vídeos também servem).
  final bool audioModule;

  /// Lista do módulo Documentos: aceita PDFs e imagens.
  final bool docs;

  /// Lista do módulo Imagem: só imagens.
  final bool images;
  final List<InputItem> items = [];
  InputItem? _selected;
  bool _probing = false;

  List<MediaInfo> get ready => [
        for (final i in items)
          if (i.info != null) i.info!,
      ];

  /// Arquivo usado nas prévias: o que foi clicado, ou o primeiro da lista.
  MediaInfo? get preview {
    if (_selected?.info != null && items.contains(_selected)) return _selected!.info;
    final r = ready;
    return r.isEmpty ? null : r.first;
  }

  void select(InputItem item) {
    _selected = item;
    _app.touch();
  }

  void addPaths(Iterable<String> paths) {
    for (final path in paths) {
      if (items.any((i) => i.path == path)) continue;
      if (!File(path).existsSync()) continue; // ignora pastas
      items.add(InputItem(path));
    }
    _app.touch();
    probePending();
  }

  void remove(InputItem item) {
    items.remove(item);
    _app.touch();
  }

  void clear() {
    items.clear();
    _app.touch();
  }

  /// Muda a ordem na lista (importa para unir).
  void move(InputItem item, int delta) {
    final i = items.indexOf(item), j = i + delta;
    if (i < 0 || j < 0 || j >= items.length) return;
    items
      ..removeAt(i)
      ..insert(j, item);
    _app.touch();
  }

  Future<void> probePending() async {
    final t = _app.tools;
    if (_probing || t == null || _app.toolsLoading) return;
    _probing = true;
    try {
      while (true) {
        final pending = items.where((i) => i.info == null && i.error == null).toList();
        if (pending.isEmpty) break;
        final item = pending.first;
        try {
          if (images) {
            final img = await t.probe(item.path);
            if (img.hasVideo && img.width > 0) {
              item.info = MediaInfo.image(img, size: await t.imageDisplaySize(item.path));
            } else {
              item.error = 'Não foi possível ler esta imagem.';
            }
            _app.touch();
            continue;
          }
          if (docs) {
            final ext = p.extension(item.path).toLowerCase();
            if (ext == '.pdf') {
              final pdf = _app.pdf;
              if (pdf == null) {
                item.error = 'As ferramentas de PDF não foram encontradas.';
              } else {
                item.info = await pdf.probe(item.path);
              }
            } else if (imageExts.contains(ext.replaceFirst('.', ''))) {
              final img = await t.probe(item.path);
              if (img.hasVideo && img.width > 0) {
                item.info = MediaInfo.image(img, size: await t.imageDisplaySize(item.path));
              } else {
                item.error = 'Não foi possível ler esta imagem.';
              }
            } else {
              item.error = 'Aqui entram PDFs e imagens.';
            }
            _app.touch();
            continue;
          }
          final info = await t.probe(item.path);
          if (audioModule && info.audioCount == 0) {
            item.error = 'Este arquivo não tem faixa de áudio.';
          } else if (!audioModule && !info.hasVideo) {
            item.error = 'Este arquivo não tem faixa de vídeo.';
          } else {
            item.info = info;
          }
        } catch (e) {
          item.error = e is FfError ? e.message : 'Não foi possível ler este arquivo.';
        }
        _app.touch();
      }
    } finally {
      _probing = false;
    }
  }
}

/// Fila de tarefas: roda uma por vez, para o uso de CPU/RAM/disco ficar
/// previsível mesmo com vídeos enormes.
class JobQueue extends ChangeNotifier {
  final List<Job> jobs = [];
  FfTools? tools;
  bool _pumping = false;
  Timer? _ticker;
  bool _dirty = false;

  bool get busy => jobs.any((j) => !j.finished);

  /// Chamado quando uma tarefa termina com sucesso.
  void Function(Job job)? onDone;

  Job? get running {
    for (final j in jobs) {
      if (j.status == JobStatus.running) return j;
    }
    return null;
  }

  int get waiting => jobs.where((j) => j.status == JobStatus.queued).length;

  void addAll(Iterable<Job> items) {
    jobs.addAll(items);
    notifyListeners();
    _pump();
  }

  void cancel(Job job) {
    if (job.status == JobStatus.queued) {
      job
        ..status = JobStatus.canceled
        ..stage = 'Cancelado';
    } else if (job.status == JobStatus.running) {
      job.stage = 'Cancelando…';
      job.run?.cancel();
    }
    notifyListeners();
  }

  void remove(Job job) {
    if (!job.finished) return;
    jobs.remove(job);
    notifyListeners();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.finished);
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    final t = tools;
    if (t == null) return;
    _pumping = true;
    // A interface é atualizada no máximo ~5x por segundo, não a cada linha do FFmpeg.
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    });
    try {
      while (true) {
        final i = jobs.indexWhere((j) => j.status == JobStatus.queued);
        if (i < 0) break;
        await _runOne(jobs[i], t);
      }
    } finally {
      _ticker?.cancel();
      _pumping = false;
      notifyListeners();
    }
  }

  Future<void> _runOne(Job job, FfTools t) async {
    final run = FfRun();
    job
      ..run = run
      ..status = JobStatus.running
      ..stage = 'Iniciando'
      ..startedAt = DateTime.now();
    notifyListeners();
    final ctx = JobCtx(t, run, (progress, stage, speed) {
      if (run.canceled) return;
      job.progress = progress;
      if (stage != null) job.stage = stage;
      job.speed = speed;
      _dirty = true;
    });
    try {
      job.result = await job.body(ctx);
      job
        ..status = JobStatus.done
        ..progress = 1
        ..stage = 'Concluído';
      onDone?.call(job);
    } on JobCanceled {
      job
        ..status = JobStatus.canceled
        ..stage = 'Cancelado';
    } catch (e) {
      if (run.canceled) {
        job
          ..status = JobStatus.canceled
          ..stage = 'Cancelado';
      } else {
        job
          ..status = JobStatus.failed
          ..stage = 'Falhou'
          ..error = e.toString();
      }
    }
    job
      ..endedAt = DateTime.now()
      ..run = null;
    notifyListeners();
  }

  void cancelAll() {
    for (final j in jobs.where((j) => !j.finished).toList()) {
      cancel(j);
    }
  }
}

class AppState extends ChangeNotifier {
  FfTools? tools;
  bool toolsLoading = true;
  EncoderCaps caps = const EncoderCaps({});

  late final InputList video = InputList(this, audioModule: false);
  late final InputList audio = InputList(this, audioModule: true);
  late final InputList docs = InputList(this, audioModule: false, docs: true);
  late final InputList images = InputList(this, audioModule: false, images: true);

  // Módulo de imagem
  UpscalerTools? upscaler;
  final ImageConvertSettings imageConvert = ImageConvertSettings();
  final ImageCompressSettings imageCompress = ImageCompressSettings();
  final ImageResizeSettings imageResize = ImageResizeSettings();
  final ImageRotateSettings imageRotate = ImageRotateSettings();
  final UpscaleSettings upscale = UpscaleSettings();
  Set<String> get encoders => caps.usable;

  // Módulo de documentos
  PdfTools? pdf;
  final PdfCompressSettings pdfCompress = PdfCompressSettings();
  final PdfSplitSettings pdfSplit = PdfSplitSettings();
  final PdfConvertSettings pdfConvert = PdfConvertSettings();
  final PdfPasswordSettings pdfPassword = PdfPasswordSettings();
  final Organizer organizer = Organizer();

  /// Bandeja do PDF Estúdio: "tray" (miniaturas) ou "list" (só os arquivos).
  String trayView = 'tray';

  /// Largura das miniaturas da bandeja (o controle de zoom).
  double trayZoom = 148;
  ScanTools? scanner;
  final ScanSettings scan = ScanSettings();
  late final PdfThumbs thumbs = PdfThumbs(touch);
  String? outputDir;
  final CompressSettings compress = CompressSettings();
  final SplitSettings split = SplitSettings();
  final ConvertSettings convert = ConvertSettings();
  final TrimSettings trim = TrimSettings();
  final MergeSettings merge = MergeSettings();
  final CropSettings crop = CropSettings();
  final MuxSettings mux = MuxSettings();

  // Módulo de áudio
  final AudioOutSettings audioOut = AudioOutSettings();
  final AudioCompressSettings audioCompress = AudioCompressSettings();
  final SplitSettings audioSplit = SplitSettings()..sizeMb = 25;
  final AudioMergeSettings audioMerge = AudioMergeSettings();
  final MixSettings mix = MixSettings();

  /// No PDF Estúdio: true = ferramenta aberta; false = tela de entrada.
  bool pdfOpen = false;

  /// Ferramenta aberta em cada módulo (lembrada ao trocar de módulo).
  final Map<String, int> toolIndex = {};

  /// Muda quando um campo de texto precisa ser recriado com um valor novo.
  int fieldRevision = 0;

  /// Qualidade usada pelas ferramentas que precisam recodificar.
  final ReencodeSettings reencode = ReencodeSettings();
  String? muxAudioError;

  Directory? _thumbDir;
  final Map<String, Future<String?>> _thumbs = {};
  final JobQueue queue = JobQueue();
  final Prefs prefs = Prefs();

  Future<void> init() async {
    queue.onDone = (job) {
      final r = job.result;
      if (r == null) return;
      prefs.addRecent(Recent(title: job.title, detail: r.summary, path: r.revealPath, module: job.module));
    };
    toolsLoading = true;
    notifyListeners();
    tools = await FfTools.locate();
    pdf = await PdfTools.locate();
    upscaler = UpscalerTools.locate();
    scanner = ScanTools.locate();
    queue.tools = tools;
    toolsLoading = false;
    notifyListeners();
    final t = tools;
    if (t == null) return;
    video.probePending();
    audio.probePending();
    docs.probePending();
    images.probePending();
    caps = EncoderCaps(await t.detectEncoders());
    if (!caps.supports(compress.codec)) {
      for (final c in VCodec.values) {
        if (caps.supports(c)) {
          compress
            ..codec = c
            ..crf = c.defaultCrf;
          break;
        }
      }
    }
    if (caps.cpuFor(compress.codec) == null) compress.useGpu = true;
    notifyListeners();
  }

  /// Avisa a interface depois de mexer em [compress], [split] ou [outputDir].
  void touch() => notifyListeners();

  /// Lê o arquivo de áudio escolhido para o mux.
  Future<void> setMuxAudio(String? path) async {
    mux.audio = null;
    muxAudioError = null;
    final t = tools;
    if (path != null && t != null) {
      try {
        final info = await t.probe(path);
        if (info.audioCount == 0) {
          muxAudioError = '"${p.basename(path)}" não tem faixa de áudio.';
        } else {
          mux.audio = info;
        }
      } catch (_) {
        muxAudioError = 'Não foi possível ler "${p.basename(path)}".';
      }
    }
    notifyListeners();
  }

  /// Miniatura (um quadro pequeno) para a prévia do recorte. Fica em cache.
  Future<String?> thumbnail(MediaInfo info) => _thumbs[info.path] ??= _makeThumb(info);

  Future<String?> _makeThumb(MediaInfo info) async {
    final t = tools;
    if (t == null) return null;
    try {
      final dir = _thumbDir ??= await Directory.systemTemp.createTemp('filume_thumb_');
      final out = p.join(dir.path, '${_thumbs.length}_${DateTime.now().microsecondsSinceEpoch}.jpg');
      final r = await Process.run(t.ffmpeg, [
        '-hide_banner', '-nostdin', '-v', 'error', '-y',
        '-ss', (info.duration * 0.3).toStringAsFixed(2),
        '-i', info.path,
        '-map', '0:${info.videoIndex}',
        '-frames:v', '1', '-vf', 'scale=640:-2', '-q:v', '5',
        out,
      ]).timeout(const Duration(seconds: 30));
      return r.exitCode == 0 && File(out).existsSync() ? out : null;
    } catch (_) {
      return null;
    }
  }

  void cleanup() {
    thumbs.dispose();
    try {
      _thumbDir?.deleteSync(recursive: true);
    } catch (_) {}
    _thumbDir = null;
    _thumbs.clear();
  }

  @override
  void dispose() {
    queue.cancelAll();
    cleanup();
    super.dispose();
  }
}
