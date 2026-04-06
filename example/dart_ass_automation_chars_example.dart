import 'dart:io';
import 'package:dart_ass/dart_ass.dart';

Future<void> main(List<String> args) async {
  final filePath = args.isEmpty ? 'example/test.ass' : args.first;

  final ass = Ass(filePath: filePath);
  await ass.parse();

  // Example: keep only "karaoke-like" lines.
  final result = await AssAutomation(ass)
      .flow()
      .selectAll()
      .whereKaraoke()
      // Required to populate per-character metrics (x/height/lineIndex).
      .ensureMetrics(useTextData: true)
      .splitCharsFx(
        // In proportional mode, the full line duration is divided evenly across
        // all emitted characters (stepMs/durMs are ignored).
        timeMode: AssSplitTimeMode.proportional,
        stepMs: 35,
        durMs: 300,
        layerOffset: 10,
        commentOriginal: true,
        includeSpaces: true,
        onCharEnv: (env) {
          // Position each character with \\pos(x,y) using the unit absolute fields.
          final x = env.unit.absPosX ?? 0;
          final y = env.unit.absPosY ?? 0;

          env.tags.setPos(AssTagPosition(x, y));
          env.tags.addTag('bord', '2');

          env.addDialog();
        },
      )
      .run();

  stdout.writeln('Touched dialogs: ${result.dialogsTouched}');
  for (final l in result.logs) {
    stdout.writeln('  $l');
  }

  final out = 'example/out_chars_fx.ass';
  await ass.toFile(out);
  stdout.writeln('Wrote: $out');
  stdout.writeln('Tip: for karaoke FX, see `example/dart_ass_automation_karaoke_example.dart`.');
}
