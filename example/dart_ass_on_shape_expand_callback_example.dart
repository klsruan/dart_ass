import 'dart:io';

import 'package:dart_ass/dart_ass.dart';

/// Example: use `onShapeExpandEnv` to tweak generated shapes before emitting.
///
/// This demonstrates how to:
/// - run `onShapeExpand()`
/// - edit `env.unit.paths` (vector points)
/// - sync `env.line.text` after changes
Future<void> main(List<String> args) async {
  final filePath = args.isEmpty ? 'example/test.ass' : args.first;

  final ass = Ass(filePath: filePath);
  await ass.parse();

  await AssAutomation(ass)
      .flow()
      .selectAll()
      // Shape expansion uses FreeType, so it may take a moment on the first run.
      .onShapeExpand(
        effect: 'shape',
        commentOriginal: true,
        onShapeExpandEnv: (env) {
          // Simple tweak: move every point by (+10,+0) script pixels.
          env.unit.paths.move(10, 0);
          env.syncLineTextFromPaths();
          env.addDialog();
        },
      )
      .run();

  final out = 'example/out_shape_expand_callback.ass';
  await ass.toFile(out);
  stdout.writeln('Wrote: $out');
}

