import 'dart:io';

import 'package:dart_ass/dart_ass.dart';

/// Example: expand a line into multiple `\p1` shapes while preserving appearance.
///
/// This is useful when the line contains multiple tag layers (segments) and line breaks,
/// and you want each segment expanded independently without breaking the visual layout.
Future<void> main() async {
  final header = AssHeader(
    title: 'T',
    wrapStyle: 0,
    scaledBorderAndShadow: 'yes',
    yCbCrMatrix: 'TV.709',
    playResX: 1920,
    playResY: 1080,
  );

  final style = AssStyle(
    styleName: 'Romaji',
    // On Linux, FontCollector falls back to DejaVuSans if the requested face is missing.
    fontName: 'DejaVuSans',
    fontSize: 48,
    color1: AssColor.parse('FFFFFF'),
    color2: AssColor.parse('0000FF'),
    color3: AssColor.parse('000000'),
    color4: AssColor.parse('000000'),
    alpha1: AssAlpha.parse('00'),
    alpha2: AssAlpha.parse('00'),
    alpha3: AssAlpha.parse('00'),
    alpha4: AssAlpha.parse('00'),
    bold: false,
    italic: false,
    underline: false,
    strikeOut: false,
    scaleX: 100,
    scaleY: 100,
    spacing: 0,
    angle: 0,
    borderStyle: 1,
    outline: 2,
    shadow: 1,
    alignment: 2,
    marginL: 10,
    marginR: 10,
    marginV: 10,
    encoding: 1,
  );

  // A line similar to the one used in karaoke workflows: includes \pos, \N, and a font switch.
  final text = AssText.parse(
    r'{\k17\pos(850,370)}ho{\k20}u{\k36}ka{\k19}i {\k104}no {\k60\+fx}sh\Ni{\k24}n{\k20}fo{\k14}ni{\k17\-fx}i {\k39}ga {\k36\fnC059\b1}na{\k33}ri{\k28}hi{\k17}bi{\k21}i{\k292}te',
  )!;

  final dialog = AssDialog(
    layer: 10,
    startTime: AssTime(time: 0),
    endTime: AssTime(time: 2000),
    styleName: style.styleName,
    name: '',
    marginL: 0,
    marginR: 0,
    marginV: 0,
    effect: 'karaoke',
    text: text,
    header: header,
    commented: false,
    style: style,
  );

  final ass = Ass(filePath: '');
  ass.header = header;
  ass.styles = AssStyles(styles: [style]);
  ass.dialogs = AssDialogs(dialogs: [dialog]);

  await AssAutomation(ass).flow().selectAll().onShapeExpand(effect: 'shape', commentOriginal: false).run();

  final out = 'example/out_expand_segments.ass';
  await ass.toFile(out);
  stdout.writeln('Wrote: $out');
}

