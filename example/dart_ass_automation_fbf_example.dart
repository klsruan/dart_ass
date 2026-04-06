import 'dart:io';
import 'package:dart_ass/dart_ass.dart';

Future<void> main(List<String> args) async {
  final filePath = args.isEmpty ? 'example/test.ass' : args.first;

  final ass = Ass(filePath: filePath);
  await ass.parse();

  // Frame-by-frame (FBF): generates one Effect=fx line per frame (or per N frames)
  // inside the time range of each selected dialogue line.
  //
  // Note: this can generate A LOT of lines. To reduce output,
  // increase `stepFrames` (e.g. 2, 3, 4...).
  final result = await AssAutomation(ass)
      .flow()
      .selectAll()
      // Optional: keep only karaoke lines.
      .whereKaraoke()
      .splitLineFbfFx(
        fps: 23.976,
        stepFrames: 1,
        layerOffset: 10,
        commentOriginal: true,
        onFrameEnv: (env) {
          // Each env.unit represents a frame window clamped to the original line time range.
          env.retime(AssRetimeMode.unit);

          // Example: apply a rotation based on the time fraction.
          final t = env.unit.tf ?? 0;
          env.tags.addTag('frz', (t * 360).toStringAsFixed(2));

          env.addDialog();
        },
      )
      .run();

  stdout.writeln('Touched dialogs: ${result.dialogsTouched}');
  for (final l in result.logs) {
    stdout.writeln('  $l');
  }

  final out = 'example/out_fbf_fx.ass';
  await ass.toFile(out);
  stdout.writeln('Wrote: $out');
}
