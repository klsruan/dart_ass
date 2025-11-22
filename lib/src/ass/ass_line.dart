import 'package:dart_ass/dart_ass.dart';
import 'ass_text.dart';
import 'ass_font.dart';

class AssChars {
  String text;
  double? width;
  double? height;

  AssChars({required this.text});

  @override
  String toString() {
    return text;
  }
}

class AssWords {
  String text;
  double? width;
  double? height;

  AssWords({required this.text});

  @override
  String toString() {
    return text;
  }
}

class AssLineBreaks {
  String text;
  double? width;
  double? height;

  AssLineBreaks({required this.text});

  @override
  String toString() {
    return text;
  }
}

class AssLineSegment {
  String text;
  AssTextSegment textSegment;
  AssStyle style;

  double? width;
  double? height;

  AssLineSegment({
    required this.text,
    required this.textSegment,
    required this.style,
  });

  static AssLineSegment? parse(AssTextSegment segment, AssStyle style) {
    AssLineSegment lineSegment = AssLineSegment(
      text: segment.toString(),
      textSegment: segment,
      style: style,
    );
    return lineSegment;
  }

  Future<void> extend({bool useTextData = true}) async {
    AssOverrideTags? overrideTags = textSegment.overrideTags;
    AssFont assFont;
    if (overrideTags != null && useTextData) {
      assFont = AssFont(
        styleName: style.styleName,
        fontName: overrideTags.fontName ?? style.fontName,
        fontSize: overrideTags.fontSize ?? style.fontSize,
        bold: overrideTags.bold ?? style.bold,
        italic: overrideTags.italic ?? style.italic,
        underline: overrideTags.underline ?? style.underline,
        strikeOut: overrideTags.strikeOut ?? style.strikeOut,
        scaleX: overrideTags.fontScaleX ?? style.scaleX,
        scaleY: overrideTags.fontScaleY ?? style.scaleY,
        spacing: overrideTags.fontSpacing ?? style.spacing,
      );
    } else {
      assFont = AssFont(
        styleName: style.styleName,
        fontName: style.fontName,
        fontSize: style.fontSize,
        bold: style.bold,
        italic: style.italic,
        underline: style.underline,
        strikeOut: style.strikeOut,
        scaleX: style.scaleX,
        scaleY: style.scaleY,
        spacing: style.spacing,
      );
    }
    await assFont.init();
    AssFontTextExtents? textExtents = assFont.textExtents(textSegment.text);
    if (textExtents != null) {
      width = textExtents.width;
      height = textExtents.height;
    }
  }

  @override
  String toString() {
    return text;
  }
}

class AssLine {
  AssStyle style;
  List<AssLineSegment> segments;

  static AssLine? parse(AssText text, AssStyle style) {
    List<AssLineSegment> lineSegments = [];
    for (AssTextSegment textSegment in text.segments) {
      AssLineSegment? segment = AssLineSegment.parse(textSegment, style);
      if (segment != null) {
        lineSegments.add(segment);
      }
    }
    return AssLine(segments: lineSegments, style: style);
  }

  Future extend({bool useTextData = true}) async {
    for (AssLineSegment segment in segments) {
      await segment.extend(useTextData: useTextData);
    }
  }

  AssLine({required this.segments, required this.style});

  @override
  String toString() {
    return "";
  }
}
