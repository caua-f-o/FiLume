import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'compress.dart';
import 'ffmpeg.dart';
import 'job.dart';
import 'split.dart';

class InputItem {
  InputItem(this.path);
  final String path;
  MediaInfo? info;
  String? error;
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

  final List<InputItem> inputs = [];
  String? outputDir;
  final CompressSettings compress = CompressSettings();
  final SplitSettings split = SplitSettings();
  final JobQueue queue = JobQueue();

  bool _probing = false;

  Future<void> init() async {
    toolsLoading = true;
    notifyListeners();
    tools = await FfTools.locate();
    queue.tools = tools;
    toolsLoading = false;
    notifyListeners();
    final t = tools;
    if (t == null) return;
    _probeNext();
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

  void addPaths(Iterable<String> paths) {
    for (final path in paths) {
      if (inputs.any((i) => i.path == path)) continue;
      if (!File(path).existsSync()) continue; // ignora pastas
      inputs.add(InputItem(path));
    }
    notifyListeners();
    _probeNext();
  }

  void removeInput(InputItem item) {
    inputs.remove(item);
    notifyListeners();
  }

  void clearInputs() {
    inputs.clear();
    notifyListeners();
  }

  List<MediaInfo> get readyInputs => [
        for (final i in inputs)
          if (i.info != null) i.info!,
      ];

  Future<void> _probeNext() async {
    final t = tools;
    if (_probing || t == null) return;
    _probing = true;
    try {
      while (true) {
        final pending = inputs.where((i) => i.info == null && i.error == null).toList();
        if (pending.isEmpty) break;
        final item = pending.first;
        try {
          item.info = await t.probe(item.path);
          if (!item.info!.hasVideo) {
            item
              ..info = null
              ..error = 'Este arquivo não tem faixa de vídeo.';
          }
        } catch (e) {
          item.error = e is FfError ? e.message : 'Não foi possível ler este arquivo.';
        }
        notifyListeners();
      }
    } finally {
      _probing = false;
    }
  }

  @override
  void dispose() {
    queue.cancelAll();
    super.dispose();
  }
}
