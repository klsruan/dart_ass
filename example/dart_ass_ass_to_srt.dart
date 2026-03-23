import 'dart:io';
import 'package:dart_ass/dart_ass.dart';

String assData = '''[Script Info]
Title: Example
ScriptType: v4.00+
WrapStyle: 0
ScaledBorderAndShadow: yes
YCbCr Matrix: TV.709
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:02.90,Default,,10,10,10,,Primeira linha\\Nsegunda linha
Dialogue: 0,0:00:02.90,0:00:05.80,Default,,10,10,10,,Testando conversao
''';

void main() async {
  final tempAssPath = 'example_tmp.ass';
  await File(tempAssPath).writeAsString(assData);

  final srtFromFile = await convertAssFileToSrt(tempAssPath);
  print(srtFromFile);

  final ass = Ass(filePath: tempAssPath);
  await ass.parse();

  final srt = convertAssToSrt(ass);

  print(srt);
}