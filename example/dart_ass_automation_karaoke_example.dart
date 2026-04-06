import 'dart:io';
import 'package:dart_ass/dart_ass.dart';

Future<void> main(List<String> args) async {
  final filePath = args.isEmpty ? 'example/test.ass' : args.first;

  final ass = Ass(filePath: filePath);
  await ass.parse();

  // Example: keep only lines which look like karaoke.
  final result = await AssAutomation(ass)
      .flow()
      .selectAll()
      .whereKaraoke()
      // Required if you want `xf` and layout metrics inside the callback.
      .ensureMetrics(useTextData: true)
      .warmupFonts()
      .splitKaraokeFx(
        layerOffset: 10,
        commentOriginal: true,
        includeNonKaraokeSegments: false,
        mode: AssKaraokeSplitMode.syllables,
        onKaraokeEnv: (env) {
          // Example of a templater-like callback:
          // - retime inside the unit range (syllable)
          // - use `tf` and (when available) `xf`
          env.retime(AssRetimeMode.unit);

          // Position each unit using the precomputed absolute metrics.
          // (These metrics come from `ensureMetrics()` + layout via PlayRes/margins/\\an/\\pos.)
          // For drawings (\\p1), \\an7 (top-left) is the simplest alignment.
          final x = env.unit.absLeft ?? env.unit.absPosX ?? 0;
          final y = env.unit.absTop ?? env.unit.absPosY ?? 0;

          env.tags.setAlignment(7);
          env.tags.setPos(AssTagPosition(x, y));
          env.tags.addTag('fscx', '100');
          env.tags.addTag('fscy', '100');
          env.tags.addT(
            t1: 0,
            t2: (env.unitDurationMs * 0.5).round(),
            build: (t) {
              t.addTag('fscx', '200');
              t.addTag('fscy', '200');
            },
          );
          env.tags.addT(
            t1: (env.unitDurationMs * 0.5).round(),
            t2: env.unitDurationMs,
            build: (t) {
              t.addTag('fscx', '100');
              t.addTag('fscy', '100');
            },
          );
          env.tags.addTag('bord', '0');
          env.tags.addTag('shad', '0');
          env.tags.addTag('p', '1');

          // Text -> shape (ASS drawing). `getTextToShape` returns `m/l/b ...` commands.
          final text = env.unit.textSpaceStripped ?? env.unit.text;
          final font = env.shared.warmedFontForStyle(env.orgline.styleName);
          final shape = font?.getTextToShape(text) ?? '';

          env.line.text = AssText(
            segments: [
              AssTextSegment(
                text: shape,
                overrideTags: env.tags,
              ),
            ],
          );

          // Nested frame-by-frame (FBF) split inside the karaoke unit range.
          //
          // This emits multiple FX lines per karaoke unit (one per frame window),
          // using the current `env.line` as the base template for each frame.
          env.fbf(
            fps: 23.976,
            stepFrames: 1,
            layerOffset: 0,
            onFrameEnv: (fenv) {
              fenv.retime(AssRetimeMode.unit);

              // Example: spin over time.
              final t = fenv.unit.tf ?? 0;
              fenv.tags.addTag('frz', (t * 360).toStringAsFixed(2));

              fenv.addDialog();
            },
          );
        },
      )
      .run();

  stdout.writeln('Touched dialogs: ${result.dialogsTouched}');
  for (final l in result.logs) {
    stdout.writeln('  $l');
  }

  final out = 'example/out_kara_fx.ass';
  await ass.toFile(out);
  stdout.writeln('Wrote: $out');
}
