import 'dart:io';
import 'dart:async';
import 'ass_color.dart';
import 'ass_alpha.dart';
import 'ass_time.dart';
import 'ass_text.dart';
import 'ass_struct.dart';
import '../version.dart';

class Ass {
  String filePath;

  AssHeader? header;
  AssGarbage? garbage;
  AssStyles? styles;
  AssDialogs? dialogs;

  Ass({required this.filePath});

  Future<void> parse() async {
    final File config = File(filePath);

    if (!await config.exists()) {
      throw Exception('File not found: $filePath');
    }

    List<String> lines = config.readAsLinesSync();

    final RegExp sectionRegExp = RegExp(r'^\[(.+)\]$');
    final RegExp titleExp = RegExp(r'^Title:\s*(.*)');
    final RegExp wrapStyleExp = RegExp(r'^WrapStyle:\s*(\d+)');
    final RegExp scaledBorderExp = RegExp(r'^ScaledBorderAndShadow:\s*(\w+)');
    final RegExp yCbCrMatrixExp = RegExp(r'^YCbCr Matrix:\s*(\w+)');
    final RegExp playResXExp = RegExp(r'^PlayResX:\s*(\d+)');
    final RegExp playResYExp = RegExp(r'^PlayResY:\s*(\d+)');
    final RegExp audioFileExp = RegExp(r'^Audio File:\s*(.*)');
    final RegExp videoFileExp = RegExp(r'^Video File:\s*(.*)');
    final RegExp videoARValueExp = RegExp(r'^Video AR Value:\s*(.*)');
    final RegExp videoZoomPercentExp = RegExp(r'^Video Zoom Percent:\s*(.*)');
    final RegExp videoZoomPositionExp = RegExp(r'^Video Zoom Position:\s*(.*)');
    final RegExp activeLineExp = RegExp(r'^Active Line:\s*(\d+)');

    List<AssStyle> stylesList = [];
    bool stylesHeaderParsed = false;

    List<AssDialog> eventsList = [];
    bool eventsHeaderParsed = false;

    String? currentSection;
    try {
      for (String line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith(';')) {
          continue;
        }
        final RegExpMatch? match = sectionRegExp.firstMatch(line);
        if (match != null) {
          currentSection = match.group(1);
          if (currentSection == 'Script Info' && header == null) {
            header = AssHeader(
              title: '',
              wrapStyle: 0,
              scaledBorderAndShadow: '',
              yCbCrMatrix: '',
              playResX: 0,
              playResY: 0,
            );
          }
          if (currentSection == 'Aegisub Project Garbage' && garbage == null) {
            garbage = AssGarbage();
          }
          continue;
        }

        switch (currentSection) {
          case 'Script Info':
            _parseScriptInfo(line, titleExp, wrapStyleExp, scaledBorderExp, yCbCrMatrixExp, playResXExp, playResYExp);
            break;
          case 'Aegisub Project Garbage':
            _parseAegisubGarbage(line, audioFileExp, videoFileExp, videoARValueExp, videoZoomPercentExp, videoZoomPositionExp, activeLineExp);
            break;
          case 'V4+ Styles':
            if (!stylesHeaderParsed) {
              if (line.startsWith('Format:')) {
                stylesHeaderParsed = true;
              }
            } else {
              if (line.startsWith('Style:')) {
                final style = _parseStyle(line);
                if (style != null) {
                  stylesList.add(style);
                }
              }
            }
            break;
          case 'Events':
            if (!eventsHeaderParsed) {
              if (line.startsWith('Format:')) {
                eventsHeaderParsed = true;
              }
            } else {
              if (line.startsWith('Dialogue:') || line.startsWith('Comment:')) {
                final event = _parseDialog(line, stylesList);
                if (event != null) {
                  eventsList.add(event);
                }
              }
            }
            break;
          default:
            // Ignore different sections
            continue;
        }
      }

      // Assign the structures
      if (header == null) {
        print('Warning: [Script Info] section not found or incomplete.');
      }
      if (garbage == null) {
        print('Warning: [Aegisub Project Garbage] section not found or incomplete.');
      }
      if (stylesList.isNotEmpty) {
        styles = AssStyles(styles: stylesList);
      }
      if (eventsList.isNotEmpty) {
        dialogs = AssDialogs(dialogs: eventsList);
      }
    } catch (e) {
      print('Error reading the file: $e');
      rethrow;
    }
  }

  void _parseScriptInfo(
    String line,
    RegExp titleExp,
    RegExp wrapStyleExp,
    RegExp scaledBorderExp,
    RegExp yCbCrMatrixExp,
    RegExp playResXExp,
    RegExp playResYExp,
  ) {
    if (header == null) return;

    final titleMatch = titleExp.firstMatch(line);
    if (titleMatch != null) {
      header!.title = titleMatch.group(1)!;
      return;
    }

    final wrapStyleMatch = wrapStyleExp.firstMatch(line);
    if (wrapStyleMatch != null) {
      header!.wrapStyle = int.parse(wrapStyleMatch.group(1)!);
      return;
    }

    final scaledBorderMatch = scaledBorderExp.firstMatch(line);
    if (scaledBorderMatch != null) {
      header!.scaledBorderAndShadow = scaledBorderMatch.group(1)!;
      return;
    }

    final yCbCrMatrixMatch = yCbCrMatrixExp.firstMatch(line);
    if (yCbCrMatrixMatch != null) {
      header!.yCbCrMatrix = yCbCrMatrixMatch.group(1)!;
      return;
    }

    final playResXMatch = playResXExp.firstMatch(line);
    if (playResXMatch != null) {
      header!.playResX = int.parse(playResXMatch.group(1)!);
      return;
    }

    final playResYMatch = playResYExp.firstMatch(line);
    if (playResYMatch != null) {
      header!.playResY = int.parse(playResYMatch.group(1)!);
      return;
    }
  }

  void _parseAegisubGarbage(
    String line,
    RegExp audioFileExp,
    RegExp videoFileExp,
    RegExp videoARValueExp,
    RegExp videoZoomPercentExp,
    RegExp videoZoomPositionExp,
    RegExp activeLineExp,
  ) {
    if (garbage == null) return;

    final audioMatch = audioFileExp.firstMatch(line);
    if (audioMatch != null) {
      garbage!.audioFilePath = audioMatch.group(1)!;
      return;
    }

    final videoFileMatch = videoFileExp.firstMatch(line);
    if (videoFileMatch != null) {
      garbage!.videoFilePath = videoFileMatch.group(1)!;
      return;
    }

    final videoARValueMatch = videoARValueExp.firstMatch(line);
    if (videoARValueMatch != null) {
      garbage!.videoARValue = videoARValueMatch.group(1)!;
      return;
    }

    final videoZoomPercentMatch = videoZoomPercentExp.firstMatch(line);
    if (videoZoomPercentMatch != null) {
      garbage!.videoZoomPercent = videoZoomPercentMatch.group(1)!;
      return;
    }

    final videoZoomPositionMatch = videoZoomPositionExp.firstMatch(line);
    if (videoZoomPositionMatch != null) {
      garbage!.videoZoomPosition = videoZoomPositionMatch.group(1)!;
      return;
    }

    final activeLineMatch = activeLineExp.firstMatch(line);
    if (activeLineMatch != null) {
      garbage!.activeLine = int.parse(activeLineMatch.group(1)!);
      return;
    }
  }

  AssStyle? _parseStyle(String line) {
    final parts = line.split(':')[1].split(',');
    if (parts.length < 23) {
      print('Warning: Incomplete style line: $line');
      return null;
    }
    try {
      return AssStyle(
        styleName: parts[0].trim(),
        fontName: parts[1].trim(),
        fontSize: double.parse(parts[2].trim()),
        color1: AssColor.parse(parts[3].trim().substring(2)),
        color2: AssColor.parse(parts[4].trim().substring(2)),
        color3: AssColor.parse(parts[5].trim().substring(2)),
        color4: AssColor.parse(parts[6].trim().substring(2)),
        alpha1: AssAlpha.parse(parts[3].trim().substring(2)),
        alpha2: AssAlpha.parse(parts[4].trim().substring(2)),
        alpha3: AssAlpha.parse(parts[5].trim().substring(2)),
        alpha4: AssAlpha.parse(parts[6].trim().substring(2)),
        bold: parts[7].trim() == '1',
        italic: parts[8].trim() == '1',
        underline: parts[9].trim() == '1',
        strikeOut: parts[10].trim() == '1',
        scaleX: double.parse(parts[11].trim()),
        scaleY: double.parse(parts[12].trim()),
        spacing: double.parse(parts[13].trim()),
        angle: double.parse(parts[14].trim()),
        borderStyle: int.parse(parts[15].trim()),
        outline: double.parse(parts[16].trim()),
        shadow: double.parse(parts[17].trim()),
        alignment: int.parse(parts[18].trim()),
        marginL: double.parse(parts[19].trim()),
        marginR: double.parse(parts[20].trim()),
        marginV: double.parse(parts[21].trim()),
        encoding: int.parse(parts[22].trim()),
      );
    } catch (e) {
      print('Error parsing style: $line\nError: $e');
      return null;
    }
  }

  AssDialog? _parseDialog(String dialogLine, List<AssStyle> stylesList) {
    final RegExp eventRegExp = RegExp(
      r'^(Dialogue|Comment):\s*(\d+),([^,]*),([^,]*),([^,]*),([^,]*),(\d+),(\d+),(\d+),([^,]*),(.*)$',
      multiLine: true,
    );

    final match = eventRegExp.firstMatch(dialogLine);
    if (match == null) {
      print('Warning: Unable to parse event line: $dialogLine');
      return null;
    }

    try {
      String eventType = match.group(1)!;
      int layer = int.parse(match.group(2)!);
      String start = match.group(3)!;
      String end = match.group(4)!;
      String style = match.group(5)!;
      String name = match.group(6)!;
      double marginL = double.parse(match.group(7)!);
      double marginR = double.parse(match.group(8)!);
      double marginV = double.parse(match.group(9)!);
      String effect = match.group(10)!;
      String text = match.group(11)!;

      // Parse the text
      AssText? assText = AssText.parse(text);
      assText ??= AssText(segments: [AssTextSegment(text: '')]);

      return AssDialog(
        commented: eventType == 'Comment',
        layer: layer,
        startTime: AssTime.parse(start),
        endTime: AssTime.parse(end),
        styleName: style,
        name: name,
        marginL: marginL,
        marginR: marginR,
        marginV: marginV,
        effect: effect,
        text: assText,
        header: header!,
        style: AssStyles(styles: stylesList).getStyleByName(style),
      );
    } catch (e) {
      print('Error parsing event: $dialogLine\nError: $e');
      return null;
    }
  }

  Future<void> toFile(String path) async {
    String raw = toString();
    File file = File(path);
    IOSink sink = file.openWrite();
    sink.write(raw);
    await sink.flush();
    await sink.close();
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    bff.writeln('[Script Info]');
    bff.writeln('; Script generated by Dart ASS $dartAssVersion');
    bff.writeln('; https://github.com/klsruan');
    if (header != null) {
      bff.writeln(header!.toString());
    }

    if (garbage != null) {
      bff.writeln(garbage!.toString());
    }

    if (styles != null) {
      bff.writeln(styles!.toString());
    }

    if (dialogs != null) {
      bff.writeln(dialogs!.toString());
    }

    return bff.toString();
  }
}