import 'dart:io';
import 'ass/ass.dart';
import 'ass/ass_alpha.dart';
import 'ass/ass_color.dart';
import 'ass/ass_struct.dart';
import 'ass/ass_text.dart';
import 'ass/ass_time.dart';

/// Converts SRT content to an [Ass] object using the library structures.
Ass convertSrtToAss(
  String srtContent, {
  String filePath = '',
  String title = 'Converted from SRT',
  int playResX = 1920,
  int playResY = 1080,
  String styleName = 'Default',
  String fontName = 'Arial',
  double fontSize = 48,
}) {
  final ass = Ass(filePath: filePath);

  final header = AssHeader(
    title: title,
    wrapStyle: 0,
    scaledBorderAndShadow: 'yes',
    yCbCrMatrix: 'TV.709',
    playResX: playResX,
    playResY: playResY,
  );

  final defaultStyle = AssStyle(
    styleName: styleName,
    fontName: fontName,
    fontSize: fontSize,
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

  final dialogs = <AssDialog>[];
  final normalized = srtContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final blocks = normalized
      .trim()
      .split(RegExp(r'\n{2,}'))
      .where((block) => block.trim().isNotEmpty);

  final timeExp = RegExp(
    r'^(\d{2}:\d{2}:\d{2},\d{1,3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{1,3})$',
  );

  for (final block in blocks) {
    final lines = block
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      continue;
    }

    int timeLineIndex = -1;
    RegExpMatch? timeMatch;

    for (int i = 0; i < lines.length; i++) {
      final match = timeExp.firstMatch(lines[i].trim());
      if (match != null) {
        timeLineIndex = i;
        timeMatch = match;
        break;
      }
    }

    if (timeLineIndex == -1 || timeMatch == null) {
      continue;
    }

    final startMs = _parseSrtTimeToMs(timeMatch.group(1)!);
    final endMs = _parseSrtTimeToMs(timeMatch.group(2)!);
    final textLines = lines.skip(timeLineIndex + 1).toList();
    if (textLines.isEmpty) {
      continue;
    }

    final escapedText = textLines
        .join(r'\N')
        .replaceAll('{', r'\{')
        .replaceAll('}', r'\}');

    dialogs.add(
      AssDialog(
        layer: 0,
        startTime: AssTime(time: startMs),
        endTime: AssTime(time: endMs),
        styleName: defaultStyle.styleName,
        name: '',
        marginL: defaultStyle.marginL,
        marginR: defaultStyle.marginR,
        marginV: defaultStyle.marginV,
        effect: '',
        text: AssText(segments: [AssTextSegment(text: escapedText)]),
        header: header,
        commented: false,
        style: defaultStyle,
      ),
    );
  }

  ass.header = header;
  ass.styles = AssStyles(styles: [defaultStyle]);
  ass.dialogs = AssDialogs(dialogs: dialogs);

  return ass;
}

/// Reads an `.srt` file and returns the converted [Ass] object.
Future<Ass> convertSrtFileToAss(
  String srtPath, {
  String? assFilePath,
  String title = 'Converted from SRT',
  int playResX = 1920,
  int playResY = 1080,
  String styleName = 'Default',
  String fontName = 'Arial',
  double fontSize = 48,
}) async {
  final srtFile = File(srtPath);
  if (!await srtFile.exists()) {
    throw Exception('File not found: $srtPath');
  }

  final content = await srtFile.readAsString();
  return convertSrtToAss(
    content,
    filePath: assFilePath ?? srtPath,
    title: title,
    playResX: playResX,
    playResY: playResY,
    styleName: styleName,
    fontName: fontName,
    fontSize: fontSize,
  );
}

/// Converts an [Ass] object to SRT content.
String convertAssToSrt(
  Ass ass, {
  bool includeComments = false,
}) {
  final dialogs = ass.dialogs?.dialogs ?? <AssDialog>[];
  final visibleDialogs = dialogs.where((dialog) => includeComments || !dialog.commented).toList();

  final buffer = StringBuffer();
  int index = 1;

  for (final dialog in visibleDialogs) {
    final startMs = dialog.startTime.time;
    final endMs = dialog.endTime.time;
    if (startMs == null || endMs == null) {
      continue;
    }

    final text = dialog.text.segments
        .map((segment) => segment.text)
        .join()
        .replaceAll(r'\N', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\h', ' ');

    buffer.writeln(index);
    buffer.writeln('${_formatMsToSrtTime(startMs)} --> ${_formatMsToSrtTime(endMs)}');
    buffer.writeln(text);
    buffer.writeln();
    index++;
  }

  return buffer.toString().trimRight();
}

/// Reads an `.ass` file and returns SRT content.
Future<String> convertAssFileToSrt(
  String assPath, {
  bool includeComments = false,
}) async {
  final assFile = File(assPath);
  if (!await assFile.exists()) {
    throw Exception('File not found: $assPath');
  }

  final ass = Ass(filePath: assPath);
  await ass.parse();
  return convertAssToSrt(ass, includeComments: includeComments);
}

int _parseSrtTimeToMs(String value) {
  final match = RegExp(r'^(\d{2}):(\d{2}):(\d{2}),(\d{1,3})$').firstMatch(value.trim());
  if (match == null) {
    throw FormatException('Invalid SRT time format: $value');
  }

  final hours = int.parse(match.group(1)!);
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  final msRaw = match.group(4)!;
  final milliseconds = int.parse(msRaw.padRight(3, '0'));

  return (hours * 3600000) + (minutes * 60000) + (seconds * 1000) + milliseconds;
}

String _formatMsToSrtTime(int ms) {
  if (ms < 0) {
    throw FormatException('The millisecond value must be non-negative.');
  }

  final hours = ms ~/ 3600000;
  final minutes = (ms % 3600000) ~/ 60000;
  final seconds = (ms % 60000) ~/ 1000;
  final milliseconds = ms % 1000;

  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')},'
      '${milliseconds.toString().padLeft(3, '0')}';
}
