import 'dart:io';
import 'package:dart_ass/dart_ass.dart';

Future<void> main(List<String> args) async {
  final filePath = args.isEmpty ? 'example/test.ass' : args.first;

  final ass = Ass(filePath: filePath);
  await ass.parse();

  // Example: generate one Effect=fx line per word.
  final result = await AssAutomation(ass)
      .flow()
      .selectAll()
      .ensureMetrics(useTextData: true)
      .splitWordsFx(
        // In proportional mode, the full line duration is divided evenly across
        // all emitted words (stepMs/durMs are ignored).
        timeMode: AssSplitTimeMode.proportional,
        stepMs: 120,
        durMs: 600,
        layerOffset: 10,
        commentOriginal: true,
        includeSpaces: false,
        onWordEnv: (env) {
          env.retime(AssRetimeMode.unit);
          env.tags.setPos(AssTagPosition(env.unit.absPosX ?? 0, env.unit.absPosY ?? 0));
          env.addDialog();
        },
      )
      .run();

  stdout.writeln('Touched dialogs: ${result.dialogsTouched}');
  for (final l in result.logs) {
    stdout.writeln('  $l');
  }

  final out = 'example/out_words_fx.ass';
  await ass.toFile(out);
  stdout.writeln('Wrote: $out');
}
