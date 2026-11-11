// Teste das ferramentas de imagem (sem interface): dart run tool/image_test.dart <pasta de trabalho>
import 'dart:io';
import 'package:filume/core/ffmpeg.dart';
import 'package:filume/core/image.dart';
import 'package:filume/core/job.dart';

var ok = 0, fail = 0, refused = 0;

Future<String?> runJob(FfTools tools, Job job, {bool expectError = false}) async {
  final ctx = JobCtx(tools, FfRun(), (p, stage, speed) {});
  try {
    final r = await job.body(ctx);
    final i = await tools.probe(r.revealPath);
    print('${expectError ? 'DEVIA RECUSAR' : 'OK'} ${job.kind} [${job.detail}] ${r.summary} -> ${i.width}x${i.height} ${i.pixFmt} ${File(r.revealPath).lengthSync()}B ${r.revealPath.split('/').last}');
    expectError ? fail++ : ok++;
    return r.revealPath;
  } catch (e) {
    print('${expectError ? 'RECUSA ok' : 'FALHA'} ${job.kind} [${job.detail}]: ${e.toString().split('\n').take(expectError ? 1 : 6).join(' | ')}');
    expectError ? refused++ : fail++;
    return null;
  }
}

Future<void> main(List<String> a) async {
  final dir = a[0];
  final tools = (await FfTools.locate())!;
  final enc = await tools.detectEncoders();
  print('encoders: $enc');
  final out = '$dir/out';
  // Imagens de teste geradas pelo próprio FFmpeg.
  await Directory(dir).create(recursive: true);
  Future<void> gen(List<String> args) async {
    final r = await Process.run(tools.ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', ...args]);
    if (r.exitCode != 0) print('gerar: ${r.stderr}');
  }

  await gen(['-i', 'testsrc2=s=1280x852,noise=alls=12', '-frames:v', '1', '-q:v', '2', '$dir/photo.jpg']);
  await gen(['-i', "testsrc2=s=300x200,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lt(X,150),255,80)'", '-frames:v', '1', '$dir/alpha.png']);
  await gen(['-i', 'testsrc=s=301x199', '-frames:v', '1', '$dir/odd.bmp']);
  await gen(['-i', 'testsrc=s=120x90:r=5:d=1', '$dir/anim.gif']);
  final photo = MediaInfo.image(await tools.probe('$dir/photo.jpg'));
  final alpha = MediaInfo.image(await tools.probe('$dir/alpha.png'));
  final odd = MediaInfo.image(await tools.probe('$dir/odd.bmp'));
  final gif = MediaInfo.image(await tools.probe('$dir/anim.gif'));
  print('alpha? photo=${imageHasAlpha(photo)} alpha=${imageHasAlpha(alpha)} (${alpha.pixFmt}) gif=${gif.pixFmt}');
  for (final f in ImgFormat.values.where((f) => f.available(enc))) {
    for (final src in [photo, alpha, odd, gif]) {
      await runJob(tools, buildImageConvertJob(src, ImageConvertSettings()..format = f..quality = 80, out, enc));
    }
  }
  // compressão
  await runJob(tools, buildImageCompressJob(photo, ImageCompressSettings()..quality = 60, out, enc));
  await runJob(tools, buildImageCompressJob(alpha, ImageCompressSettings(), out, enc));
  for (final f in [null, ImgFormat.webp, ImgFormat.avif]) {
    await runJob(tools, buildImageCompressJob(photo, ImageCompressSettings()..mode = ImageCompressMode.targetSize..targetKb = 40..format = f, out, enc));
  }
  await runJob(tools, buildImageCompressJob(photo, ImageCompressSettings()..mode = ImageCompressMode.percent..percent = 30, out, enc));
  await runJob(tools, buildImageCompressJob(odd, ImageCompressSettings()..mode = ImageCompressMode.percent..percent = 10, out, enc));
  await runJob(tools, buildImageCompressJob(photo, ImageCompressSettings()..mode = ImageCompressMode.targetSize..targetKb = 1, out, enc), expectError: true);
  await runJob(tools, buildImageCompressJob(photo, ImageCompressSettings()..mode = ImageCompressMode.targetSize..targetKb = 99999, out, enc), expectError: true);
  await runJob(tools, buildImageCompressJob(alpha, ImageCompressSettings()..mode = ImageCompressMode.targetSize..targetKb = 5, out, enc), expectError: true);
  // redimensionar
  for (final m in ResizeMode.values) {
    await runJob(tools, buildImageResizeJob(photo, ImageResizeSettings()..mode = m..percent = 25..pixels = 333, out, enc));
  }
  await runJob(tools, buildImageResizeJob(alpha, ImageResizeSettings()..mode = ResizeMode.width..pixels = 100, out, enc));
  await runJob(tools, buildImageResizeJob(photo, ImageResizeSettings()..mode = ResizeMode.percent..percent = 5000, out, enc), expectError: true);
  // girar
  for (final op in RotateOp.values) {
    await runJob(tools, buildImageRotateJob(odd, op, out, enc));
  }
  // ampliar (sem IA)
  for (final e in [UpscaleEngine.classic, UpscaleEngine.pixel]) {
    for (final f in [2, 3, 4]) {
      await runJob(tools, buildUpscaleJob(alpha, UpscaleSettings()..engine = e..factor = f, out, enc, null));
    }
  }
  await runJob(tools, buildUpscaleJob(photo, UpscaleSettings()..engine = UpscaleEngine.classic..factor = 2..format = ImgFormat.jpg, out, enc, null));
  await runJob(tools, buildUpscaleJob(photo, UpscaleSettings()..engine = UpscaleEngine.ai, out, enc, null), expectError: true);
  if (File('$dir/exif.jpg').existsSync()) {
    final ex = MediaInfo.image(await tools.probe('$dir/exif.jpg'), size: await tools.imageDisplaySize('$dir/exif.jpg'));
    print('exif: ${ex.width}x${ex.height}');
    await runJob(tools, buildImageConvertJob(ex, ImageConvertSettings()..format = ImgFormat.png, out, enc));
    await runJob(tools, buildImageResizeJob(ex, ImageResizeSettings()..mode = ResizeMode.percent..percent = 50, out, enc));
  }
  // IA: só informa (depende de placa de vídeo com Vulkan na máquina).
  final up = UpscalerTools.locate();
  print('ampliador por IA: ${up?.exe ?? 'não encontrado'}');
  if (up != null) {
    final okBefore = ok, failBefore = fail;
    for (final m in UpscaleModel.values) {
      await runJob(tools, buildUpscaleJob(alpha, UpscaleSettings()..model = m..factor = 2, out, enc, up));
    }
    print('IA: ${ok - okBefore} funcionaram, ${fail - failBefore} não (sem Vulkan é o esperado em servidores)');
    fail = failBefore;
  }
  print('\n$ok OK, $fail falhas, $refused recusas esperadas');
}
