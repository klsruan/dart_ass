import 'package:dart_ass/dart_ass.dart';

String srtData = '''1
00:00:00,000 --> 00:00:02,900
Testando o áudio testando o áudio

2
00:00:02,900 --> 00:00:05,800
testando legenda testando para ver se

3
00:00:05,800 --> 00:00:06,200
tá funcionando.''';


void main() async {
  Ass ass = convertSrtToAss(srtData);
  print(ass.toString());
}