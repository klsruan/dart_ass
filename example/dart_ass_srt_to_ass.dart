import 'package:dart_ass/dart_ass.dart';

String srtData = '''1
00:00:00,000 --> 00:00:02,900
Testing the audio, testing the audio

2
00:00:02,900 --> 00:00:05,800
testing subtitles to see if

3
00:00:05,800 --> 00:00:06,200
it's working.''';

Future<void> main() async {
  final ass = convertSrtToAss(srtData);
  print(ass.toString());
}
