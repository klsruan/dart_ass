import 'dart:io';

import 'package:dart_ass/dart_ass.dart';

bool _hasKaraokeTags(AssDialog dialog) {
  for (final seg in dialog.text.segments) {
    final t = seg.overrideTags;
    if (t == null) continue;
    if (t.getTagValue('k') != null) return true;
    if (t.getTagValue('kf') != null) return true;
    if (t.getTagValue('ko') != null) return true;
    if (t.getTagValue('kt') != null) return true;
  }
  return false;
}

/// Example: expand dialogue text into an ASS drawing (`\p1`) while attempting to
/// preserve appearance (pos/align/scale/rot/shear/perspective/shadow).
///
/// This uses `AssAutomation.flow().onShapeExpand(...)` and emits new `Effect=shape`
/// lines (commenting the original by default).
Future<void> main(List<String> args) async {
  final filePath = args.isEmpty ? 'example/test.ass' : args.first;

  final ass = Ass(filePath: filePath);
  await ass.parse();

  final dialogs = ass.dialogs?.dialogs ?? const [];
  if (dialogs.isEmpty) {
    stderr.writeln('No dialogs found.');
    exitCode = 1;
    return;
  }

  // Example choice: only expand karaoke-looking lines (because they often have
  // useful positioning tags / metrics).
  await AssAutomation(ass)
      .flow()
      .selectAll()
      .where((d, _) => _hasKaraokeTags(d))
      .onShapeExpand(effect: 'shape', commentOriginal: true)
      .run();

  final out = 'example/out_expand_shapes.ass';
  await ass.toFile(out);
  final generated = ass.dialogs?.dialogs.where((d) => d.effect == 'shape' && !d.commented).length ?? 0;
  stdout.writeln('Generated shape dialogs: $generated');
  stdout.writeln('Wrote: $out');
}
