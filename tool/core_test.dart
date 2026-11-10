// Teste de fumaça do núcleo (sem interface): dart run tool/core_test.dart <video>
import 'dart:io';
import 'package:filume/core/compress.dart';
import 'package:filume/core/ffmpeg.dart';
import 'package:filume/core/job.dart';
import 'package:filume/core/split.dart';

Future<void> runJob(FfTools tools, Job job) async {
  final run = FfRun();
  var last = -1;
  final ctx = JobCtx(tools, run, (p, stage, speed) {
    final pc = (p * 10).floor();
    if (pc != last) { last = pc; stdout.write(' ${(p * 100).round()}%[$stage]'); }
  });
  try {
    final r = await job.body(ctx);
    print('\nOK ${job.kind} ${job.detail}: ${r.summary} -> ${r.revealPath} ${r.warning ?? ''}');
  } catch (e) {
    print('\nFALHA ${job.kind} ${job.detail}: $e');
  }
}

Future<void> main(List<String> a) async {
  final tools = (await FfTools.locate())!;
  final caps = EncoderCaps(await tools.detectEncoders());
  print('encoders: ${caps.usable}');
  final info = await tools.probe(a[0]);
  print('dur=${info.duration} size=${info.sizeBytes} ${info.width}x${info.height} fps=${info.fps} v=${info.vCodec} a=${info.aCodec} x${info.audioCount} abr=${info.audioBitrate} start=${info.startTime}');
  final out = a[1];
  final only = a.length > 2 ? a[2] : 'all';
  if (only == 'all' || only == 'split') {
    for (final mb in [1.0, 3.0]) {
      await runJob(tools, buildSplitJob(info, SplitSettings()..mode = SplitMode.size..sizeMb = mb, out));
    }
    await runJob(tools, buildSplitJob(info, SplitSettings()..mode = SplitMode.duration..seconds = 7, out));
    await runJob(tools, buildSplitJob(info, SplitSettings()..mode = SplitMode.parts..parts = 3, out));
    await runJob(tools, buildSplitJob(info, SplitSettings()..mode = SplitMode.size..sizeMb = 9999, out));
  }
  if (only == 'all' || only == 'compress') {
    for (final c in VCodec.values) {
      await runJob(tools, buildCompressJob(info, CompressSettings()..codec = c..crf = c.defaultCrf + 6..speed = Speed.fast, out, caps));
      await runJob(tools, buildCompressJob(info, CompressSettings()..codec = c..mode = CompressMode.targetSize..targetMb = 1.5..speed = Speed.fast..eco = true..maxHeight = 240..maxFps = 24, out, caps));
    }
    await runJob(tools, buildCompressJob(info, CompressSettings()..mode = CompressMode.percent..percent = 40..audio = AudioMode.copy..container = OutContainer.mkv, out, caps));
    await runJob(tools, buildCompressJob(info, CompressSettings()..mode = CompressMode.targetSize..targetMb = 0.05, out, caps));
  }
}
