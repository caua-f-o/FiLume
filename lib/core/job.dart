import 'ffmpeg.dart';

enum JobStatus { queued, running, done, failed, canceled }

class JobResult {
  JobResult(this.summary, this.revealPath, {this.warning});
  final String summary;
  final String revealPath;
  final String? warning;
}

/// O que uma tarefa recebe para trabalhar e reportar progresso.
class JobCtx {
  JobCtx(this.tools, this.run, this._report);
  final FfTools tools;
  final FfRun run;
  final void Function(double progress, String? stage, String? speed) _report;

  void report(double progress, {String? stage, String? speed}) =>
      _report(progress.clamp(0.0, 1.0).toDouble(), stage, speed);
}

typedef JobBody = Future<JobResult> Function(JobCtx ctx);

class Job {
  Job({required this.title, required this.kind, required this.detail, required this.body});
  final String title;

  /// "Comprimir" ou "Dividir".
  final String kind;
  final String detail;
  final JobBody body;

  JobStatus status = JobStatus.queued;
  double progress = 0;
  String stage = 'Na fila';
  String? speed;
  DateTime? startedAt;
  DateTime? endedAt;
  JobResult? result;
  String? error;
  FfRun? run;

  bool get finished =>
      status == JobStatus.done || status == JobStatus.failed || status == JobStatus.canceled;

  Duration? get eta {
    if (status != JobStatus.running || startedAt == null || progress < 0.02) return null;
    final elapsed = DateTime.now().difference(startedAt!).inMilliseconds;
    return Duration(milliseconds: (elapsed * (1 - progress) / progress).round());
  }
}
