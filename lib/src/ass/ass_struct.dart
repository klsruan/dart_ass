import 'ass_color.dart';
import 'ass_alpha.dart';
import 'ass_time.dart';
import 'ass_text.dart';
import 'ass_line.dart';

class AssHeader {
  String title;
  int wrapStyle;
  String scaledBorderAndShadow;
  String yCbCrMatrix;
  int playResX;
  int playResY;

  AssHeader({
    required this.title,
    required this.wrapStyle,
    required this.scaledBorderAndShadow,
    required this.yCbCrMatrix,
    required this.playResX,
    required this.playResY,
  });

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    bff.writeln("Title: $title");
    bff.writeln("ScriptType: v4.00+");
    bff.writeln("WrapStyle: $wrapStyle");
    bff.writeln("ScaledBorderAndShadow: $scaledBorderAndShadow");
    bff.writeln("YCbCr Matrix: $yCbCrMatrix");
    bff.writeln("PlayResX: $playResX");
    bff.writeln("PlayResY: $playResY");
    return bff.toString();
  }
}

class AssGarbage {
  String? audioFilePath;
  String? videoFilePath;
  String? videoARValue;
  String? videoZoomPercent;
  String? videoZoomPosition;
  int? activeLine;

  AssGarbage({
    this.audioFilePath,
    this.videoFilePath,
    this.videoARValue,
    this.videoZoomPercent,
    this.videoZoomPosition,
    this.activeLine,
  });

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    bff.writeln("[Aegisub Project Garbage]");
    if (audioFilePath != null) {
      bff.writeln("Audio File: $audioFilePath");
    }
    if (videoFilePath != null) {
      bff.writeln("Video File: $videoFilePath");
    }
    if (videoARValue != null) {
      bff.writeln("Video AR Value: $videoARValue");
    }
    if (videoZoomPercent != null) {
      bff.writeln("Video Zoom Percent: $videoZoomPercent");
    }
    if (videoZoomPosition != null) {
      bff.writeln("Video Zoom Position: $videoZoomPosition");
    }
    if (activeLine != null) {
      bff.writeln("Active Line: $activeLine");
    }
    return bff.toString();
  }
}


class AssStyle {
  String styleName;
  String fontName;
  double fontSize;
  AssColor color1;
  AssColor color2;
  AssColor color3;
  AssColor color4;
  AssAlpha alpha1;
  AssAlpha alpha2;
  AssAlpha alpha3;
  AssAlpha alpha4;
  bool bold;
  bool italic;
  bool underline;
  bool strikeOut;
  double scaleX;
  double scaleY;
  double spacing;
  double angle;
  int borderStyle;
  double outline;
  double shadow;
  int alignment;
  double marginL;
  double marginR;
  double marginV;
  int encoding;

  AssStyle({
    required this.styleName,
    required this.fontName,
    required this.fontSize,
    required this.color1,
    required this.color2,
    required this.color3,
    required this.color4,
    required this.alpha1,
    required this.alpha2,
    required this.alpha3,
    required this.alpha4,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strikeOut,
    required this.scaleX,
    required this.scaleY,
    required this.spacing,
    required this.angle,
    required this.borderStyle,
    required this.outline,
    required this.shadow,
    required this.alignment,
    required this.marginL,
    required this.marginR,
    required this.marginV,
    required this.encoding,
  });

  @override
  String toString() {
    String c1 = '&H${alpha1.toString() + color1.toString()}';
    String c2 = '&H${alpha2.toString() + color2.toString()}';
    String c3 = '&H${alpha3.toString() + color3.toString()}';
    String c4 = '&H${alpha4.toString() + color4.toString()}';
    return "Style: $styleName,$fontName,${fontSize.round()},$c1,$c2,$c3,$c4,${bold ? '1' : '0'},${italic ? '1' : '0'},${underline ? '1' : '0'},${strikeOut ? '1' : '0'},${scaleX.round()},${scaleY.round()},${spacing.round()},${angle.round()},$borderStyle,${outline.round()},${shadow.round()},$alignment,${marginL.round()},${marginR.round()},${marginV.round()},$encoding";
  }
}

class AssStyles {
  List<AssStyle> styles;

  AssStyles({required this.styles});

  AssStyle getStyleByName(name) {
    return styles.firstWhere((style) => style.styleName == name);
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    bff.writeln("[V4+ Styles]");
    bff.writeln(
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding");
    for (var style in styles) {
      bff.writeln(style.toString());
    }
    return bff.toString();
  }
}

class AssDialog {
  int layer;
  AssTime startTime;
  AssTime endTime;
  String styleName;
  String name;
  double marginL;
  double marginR;
  double marginV;
  String effect;
  AssText text;
  bool commented;
  AssHeader header;
  AssStyle style;
  AssLine? line;

  AssDialog({
    required this.layer,
    required this.startTime,
    required this.endTime,
    required this.styleName,
    required this.name,
    required this.marginL,
    required this.marginR,
    required this.marginV,
    required this.effect,
    required this.text,
    required this.header,
    required this.commented,
    required this.style
  });

  Future extend(bool useTextData) async {
    line = AssLine.parse(text, style);
    if (line != null) {
      await line!.extend(useTextData: useTextData);
    }
  }

  @override
  String toString() {
    return "${commented ? 'Comment' : 'Dialogue'}: $layer,${startTime.toString()},${endTime.toString()},$style,$name,${marginL.round()},${marginR.round()},${marginV.round()},$effect,$text";
  }
}

class AssDialogs {
  List<AssDialog> dialogs;

  AssDialogs({required this.dialogs});

  Future extend(bool useTextData) async {
    for (AssDialog dialog in dialogs) {
      await dialog.extend(useTextData);
    }
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    bff.writeln("[Events]");
    bff.writeln("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text");
    for (var dialog in dialogs) {
      bff.writeln(dialog.toString());
    }
    return bff.toString();
  }
}