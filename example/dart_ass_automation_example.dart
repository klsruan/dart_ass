import 'dart:io';
import 'package:dart_ass/dart_ass.dart';

Future<void> main() async {
  final ass = Ass(filePath: 'example/test.ass');
  await ass.parse();

  // Example 1: shift + replace + setTag (applies to the leading override block)
  final flow1 = AssAutomation(ass)
      .flow()
      .selectAll()
      .where((d, _) => d.styleName == 'Romaji')
      .shiftTime(250)
      .replaceText(RegExp(r'\\+fx'), '') // remove "\+fx" / "\-fx" from the raw text
      .replaceText(RegExp(r'\\-fx'), '')
      .ensureLeadingTags()
      .setTag('bord', '2') // `setTag` here is a Flow op (kept for compatibility)
      .setTag('shad', '0');

  final result1 = await flow1.run();
  stdout.writeln('Flow1 touched=${result1.dialogsTouched}');
  for (final l in result1.logs) {
    stdout.writeln('  $l');
  }

  // Example 2: insert a new line at the beginning
  final auto = AssAutomation(ass);

  final result2 = await auto.flow().prependDialog(auto.createDialog(
    startMs: 0,
    endMs: 1500,
    styleName: ass.styles!.styles.first.styleName,
    textAss: r'{\b1}Generated via automation',
  )).run();
  stdout.writeln('Flow2 touched=${result2.dialogsTouched}');

  // Write output
  final out = 'example/out_automation.ass';
  await ass.toFile(out);
  stdout.writeln('Wrote: $out');

  stdout.writeln('');
  stdout.writeln('Tip: see `example/dart_ass_automation_chars_example.dart` for char-by-char FX generation.');
}
