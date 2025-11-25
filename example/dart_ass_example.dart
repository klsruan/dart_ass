import 'package:dart_ass/dart_ass.dart';

void main() async {
  AssFont assFont = AssFont(
    styleName: 'Default',
    fontName: 'Arial',
    fontSize: 50,
    bold: true,
    italic: false,
    underline: true,
    strikeOut: true,
    scaleX: 100,
    scaleY: 100,
    spacing: 10,
  );
  await assFont.init();
  String? shape = assFont.getTextToShape('SAMPLE TEXT');
  if (shape != null) {
    print(shape);
  }
  // String? svg = assFont.getTextToSvg('SAMPLE TEXT');
  // if (svg != null) {
  //   print(svg);
  // }
}
