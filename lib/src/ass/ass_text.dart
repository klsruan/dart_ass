import 'ass_color.dart';
import 'ass_alpha.dart';
import 'ass_tags.dart';

/// Parsing and serialization of ASS dialogue text and override tags.
///
/// The ASS "Text" field is a mix of:
/// - Plain text
/// - Override tag blocks: `{\\b1\\fs20...}`
///
/// This module parses the input into segments ([AssTextSegment]) where each
/// segment optionally carries an [AssOverrideTags] instance.
///
/// ## Notes
/// - Tags are generally case-insensitive.
/// - Karaoke has a special uppercase alias `\K`, which is mapped to `\kf`
///   (Aegisub treats them as identical).
/// - This parser is best-effort and aims to be robust for automation use-cases.
class AssText {
  List<AssTextSegment> segments;

  AssText({required this.segments});

  static AssText? parse(String tagsString) {
    final RegExp tagRegExp = RegExp(r'{\\[^}]+}');
    List<AssTextSegment> segments = [];
    int currentIndex = 0;

    Iterable<RegExpMatch> matches = tagRegExp.allMatches(tagsString);

    for (final match in matches) {
      if (match.start > currentIndex) {
        String precedingText = tagsString.substring(currentIndex, match.start);
        segments.add(AssTextSegment(text: precedingText));
      }

      String tagString = match.group(0)!;
      AssOverrideTags? overrideTags = AssOverrideTags.parse(tagString);

      currentIndex = match.end;

      int nextTagStart = tagsString.indexOf('{\\', currentIndex);
      String segmentText;
      if (nextTagStart == -1) {
        segmentText = tagsString.substring(currentIndex);
        currentIndex = tagsString.length;
      } else {
        segmentText = tagsString.substring(currentIndex, nextTagStart);
        currentIndex = nextTagStart;
      }

      segments.add(AssTextSegment(overrideTags: overrideTags, text: segmentText));
    }

    if (currentIndex < tagsString.length) {
      String remainingText = tagsString.substring(currentIndex);
      segments.add(AssTextSegment(text: remainingText));
    }

    return AssText(segments: segments);
  }

  String getAss() {
    return toString();
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    for (AssTextSegment segment in segments) {
      if (segment.overrideTags != null) {
        bff.write(segment.overrideTags!.getAss());
      }
      bff.write(segment.text);
    }
    return bff.toString();
  }
}

class AssTextSegment {
  /// Plain segment text (does not include `{...}`).
  String text;

  /// Override tags that apply to this segment (persistent in ASS semantics).
  AssOverrideTags? overrideTags;

  AssTextSegment({required this.text, this.overrideTags});
}

class AssOverrideTags {
  final List<AssTag> _assTagEntries = [];
  final List<AssTransformation> transformations = [];

  AssOverrideTags();

  /// Parses an override block like `{\\b1\\fs40\\pos(100,200)}`.
  ///
  /// Notes about tag-name parsing:
  /// - Most tags use the pattern `\\name<value>` or `\\name(<value>)`.
  /// - Some tags may embed a string value directly without parentheses,
  ///   e.g. `\\fnFontName` and `\\rStyleName`.
  ///
  /// This parser special-cases `\\fn` and `\\r` to avoid consuming the value
  /// into the tag name (e.g. incorrectly treating `\\fnC059` as a tag named
  /// `fnc`).
  static AssOverrideTags? parse(String entries) {
    if (entries.startsWith('{') && entries.endsWith('}')) {
      entries = entries.substring(1, entries.length - 1);
    }
    AssOverrideTags overrideTags = AssOverrideTags();
    int index = 0;
    while (index < entries.length) {
      while (index < entries.length && entries[index] != '\\') {
        index++;
      }
      if (index >= entries.length) {
        break;
      }
      index++;
      int tagNameStart = index;
      if (index < entries.length && RegExp(r'[a-zA-Z0-9]').hasMatch(entries[index])) {
        // ignore: no_leading_underscores_for_local_identifiers
        bool _isLetter(String ch) => RegExp(r'[a-zA-Z]').hasMatch(ch);
        // ignore: no_leading_underscores_for_local_identifiers
        bool _isDigit(String ch) => RegExp(r'[0-9]').hasMatch(ch);

        // Read the whole alnum token (this may include some of the value for tags
        // like \k17 or \fnFontName when the value is not parenthesized).
        int tokenEnd = index;
        while (tokenEnd < entries.length && RegExp(r'[a-zA-Z0-9]').hasMatch(entries[tokenEnd])) {
          tokenEnd++;
        }
        final token = entries.substring(tagNameStart, tokenEnd);
        index = tokenEnd;

        if (token.isEmpty) continue;

        String rawTagName = '';
        String initialValue = '';

        if (_isDigit(token[0])) {
          // Tags like \1c, \2a, ...
          if (token.length < 2 || !_isLetter(token[1])) return null;
          rawTagName = token.substring(0, 2);
          initialValue = token.substring(2);
        } else {
          // Special-cases:
          // - \fnFontName: value can start with letters, so avoid consuming it into the tag name.
          // - \rStyleName: same (reset style).
          final tokenLower = token.toLowerCase();
          if (tokenLower.startsWith('fn') && token.length >= 2) {
            rawTagName = token.substring(0, 2);
            initialValue = token.substring(2);
          } else if (tokenLower.startsWith('r') && token.isNotEmpty) {
            rawTagName = token.substring(0, 1);
            initialValue = token.substring(1);
          } else {
            // Default: tag name is the leading letters, remaining is initial value.
            int cut = 0;
            while (cut < token.length && _isLetter(token[cut])) {
              cut++;
            }
            rawTagName = token.substring(0, cut);
            initialValue = token.substring(cut);
          }
        }

        // ASS tags are generally case-insensitive, but karaoke uses an *uppercase*
        // \K tag which is distinct from lowercase \k and is an alias for \kf.
        //
        // Aegisub documents \K and \kf as identical.
        String tagName = rawTagName == 'K' ? 'kf' : rawTagName.toLowerCase();
        String tagValue = '';
        if (index < entries.length && entries[index] == '(') {
          int parenthesesCount = 1;
          index++; // Skip '('
          int valueStart = index;
          while (index < entries.length && parenthesesCount > 0) {
            if (entries[index] == '(') {
              parenthesesCount++;
            } else if (entries[index] == ')') {
              parenthesesCount--;
            }
            index++;
          }
          tagValue = (initialValue + entries.substring(valueStart, index - 1)).trim();
        } else {
          int valueStart = index;
          while (index < entries.length && entries[index] != '\\') {
            index++;
          }
          tagValue = (initialValue + entries.substring(valueStart, index)).trim();
        }
        if (tagName == 't') {
          AssTransformation? transformation = AssTransformation.parse('($tagValue)');
          if (transformation != null) {
            overrideTags.transformations.add(transformation);
          }
        } else {
          overrideTags.setTag(tagName, tagValue);
        }
      } else {

        index++;
      }
    }
    return overrideTags;
  }

  /// Retrieves the most recent value for a specific tag.
  String? getTagValue(String tag) {
    final t = tag.toLowerCase();
    for (int i = _assTagEntries.length - 1; i >= 0; i--) {
      if (_assTagEntries[i].tag.toLowerCase() == t) {
        final v = _assTagEntries[i].value;
        if (v == null) return '';
        return v.toString().trim();
      }
    }
    return null;
  }

  /// Retrieves the most recent value color tags.
  String? getColorAlphaValue(String tag) {
    for (int i = _assTagEntries.length - 1; i >= 0; i--) {
      if (_assTagEntries[i].tag.toLowerCase() == tag.toLowerCase()) {
        RegExpMatch? match = RegExp(r'&?[Hh]([0-9A-Fa-f]+)&?').firstMatch(_assTagEntries[i].value);
        if (match != null) {
          return match.group(1) ?? '';
        }
        return null;
      }
    }
    return null;
  }

  /// Sets or updates a tag with the provided value.
  void replaceTag(String tag, dynamic value) {
    final t = tag.toLowerCase();
    if (value == null || (value is String && value.trim().isEmpty)) {
      removeTag(t);
      return;
    }

    bool replaced = false;
    for (int i = _assTagEntries.length - 1; i >= 0; i--) {
      if (_assTagEntries[i].tag == t) {
        _assTagEntries[i] = AssTag(tag: t, value: value);
        replaced = true;
      }
    }
    if (!replaced) {
      _assTagEntries.add(AssTag(tag: t, value: value));
    }
  }

  /// Sets or updates a tag with the provided value.
  void setTag(String tag, String value) {
    _assTagEntries.add(AssTag(tag: tag.toLowerCase(), value: value));
  }

  String _assValueToString(Object? value) {
    if (value == null) return '';
    if (value is bool) return value ? '1' : '0';
    return value.toString();
  }

  /// Adds a tag entry (append semantics).
  ///
  /// `setTag` historically meant "append a tag", not "replace an existing one".
  /// For clarity in templater-like usage, prefer calling `addTag(...)`.
  ///
  /// This accepts any value and converts it to a string using ASS-friendly rules:
  /// - `null` becomes an empty value (emits `\tag` with no value)
  /// - `bool` becomes `1`/`0`
  /// - everything else uses `toString()`
  void addTag(String tag, Object? value) => setTag(tag, _assValueToString(value));

  // Typed convenience helpers (thin wrappers over the typed getters/setters).
  //
  // These exist mainly for templater/automation code, where you want a clear
  // "set X" call instead of assigning the property directly.
  void setAlignment(int an) => alignmentCode = an;

  void setPos(AssTagPosition pos) => position = pos;

  void setOrg(AssTagPosition org) => originalPosition = org;

  void setMove(AssMove mv) => move = mv;

  void setClipRect(AssTagClipRect clip, {bool inverse = false}) {
    if (inverse) {
      iclipRect = clip;
    } else {
      clipRect = clip;
    }
  }

  void setClipVect(AssTagClipVect clip, {bool inverse = false}) {
    if (inverse) {
      iclipVect = clip;
    } else {
      clipVect = clip;
    }
  }

  void addTransform(AssTransformation tr) => transformations.add(tr);

  void setFad(int tInMs, int tOutMs) => setTag('fad', '$tInMs,$tOutMs');

  /// Appends a `\t(...)` transform built from typed tags.
  void addT({
    int? t1,
    int? t2,
    double? accel,
    required void Function(AssOverrideTags tags) build,
  }) {
    transformations.add(AssTransformation.build(t1: t1, t2: t2, accel: accel, build: build));
  }

  /// Removes all instances of a specific tag.
  void removeTag(String tag) {
    _assTagEntries.removeWhere((entry) => entry.tag == tag.toLowerCase());
  }

  bool get bold => getTagValue('b') == '1';
  set bold(bool value) => replaceTag('b', value ? '1' : '0');

  bool get italic => getTagValue('i') == '1';
  set italic(bool value) => replaceTag('i', value ? '1' : '0');

  bool get underline => getTagValue('u') == '1';
  set underline(bool value) => replaceTag('u', value ? '1' : '0');

  bool get strikeOut => getTagValue('s') == '1';
  set strikeOut(bool value) => replaceTag('s', value ? '1' : '0');

  String? get fontName => getTagValue('fn');
  set fontName(String? value) => replaceTag('fn', value ?? '');

  double? get fontSize {
    String? fs = getTagValue('fs');
    return fs != null ? double.tryParse(fs) : null;
  }
  set fontSize(double? value) => replaceTag('fs', value?.toString() ?? '');

  double? get fontSpacing {
    String? fsp = getTagValue('fsp');
    return fsp != null ? double.tryParse(fsp) : null;
  }
  set fontSpacing(double? value) => replaceTag('fsp', value?.toString() ?? '');

  double? get fontScaleX {
    String? fscx = getTagValue('fscx');
    return fscx != null ? double.tryParse(fscx) : null;
  }
  set fontScaleX(double? value) => replaceTag('fscx', value?.toString() ?? '');

  double? get fontScaleY {
    String? fscy = getTagValue('fscy');
    return fscy != null ? double.tryParse(fscy) : null;
  }
  set fontScaleY(double? value) => replaceTag('fscy', value?.toString() ?? '');

  AssColor? get primaryColor {
    String? c = getColorAlphaValue('c');
    String? c1 = getColorAlphaValue('1c');
    return c != null ? AssColor.parse(c) : (c1 != null ? AssColor.parse(c1) : null);
  }
  set primaryColor(AssColor? color) => replaceTag('c', color?.getAss() ?? '');

  AssColor? get secondaryColor =>
      getColorAlphaValue('2c') != null ? AssColor.parse(getColorAlphaValue('2c')!) : null;
  set secondaryColor(AssColor? color) =>
      replaceTag('2c', color?.getAss() ?? '');

  AssColor? get outlineColor =>
      getColorAlphaValue('3c') != null ? AssColor.parse(getColorAlphaValue('3c')!) : null;
  set outlineColor(AssColor? color) =>
      replaceTag('3c', color?.getAss() ?? '');

  AssColor? get backColor =>
      getColorAlphaValue('4c') != null ? AssColor.parse(getColorAlphaValue('4c')!) : null;
  set backColor(AssColor? color) =>
      replaceTag('4c', color?.getAss() ?? '');

  AssAlpha? get mainAlpha => getColorAlphaValue('alpha') != null
      ? AssAlpha.parse(getColorAlphaValue('alpha')!)
      : null;
  set mainAlpha(AssAlpha? alpha) =>
      replaceTag('alpha', alpha?.getAss() ?? '');

  AssAlpha? get primaryAlpha => getColorAlphaValue('1a') != null
      ? AssAlpha.parse(getColorAlphaValue('1a')!)
      : null;
  set primaryAlpha(AssAlpha? alpha) =>
      replaceTag('1a', alpha?.getAss() ?? '');

  AssAlpha? get secondaryAlpha => getColorAlphaValue('2a') != null
      ? AssAlpha.parse(getColorAlphaValue('2a')!)
      : null;
  set secondaryAlpha(AssAlpha? alpha) =>
      replaceTag('2a', alpha?.getAss() ?? '');

  AssAlpha? get outlineAlpha => getColorAlphaValue('3a') != null
      ? AssAlpha.parse(getColorAlphaValue('3a')!)
      : null;
  set outlineAlpha(AssAlpha? alpha) =>
      replaceTag('3a', alpha?.getAss() ?? '');

  AssAlpha? get backAlpha => getColorAlphaValue('4a') != null
      ? AssAlpha.parse(getColorAlphaValue('4a')!)
      : null;
  set backAlpha(AssAlpha? alpha) =>
      replaceTag('4a', alpha?.getAss() ?? '');

  double? get borderSize {
    String? bord = getTagValue('bord');
    return bord != null ? double.tryParse(bord) : null;
  }

  set borderSize(double? value) => replaceTag('bord', value?.toString() ?? '');

  double? get borderEnhancement {
    String? be = getTagValue('be');
    return be != null ? double.tryParse(be) : null;
  }

  set borderEnhancement(double? value) =>
      replaceTag('be', value?.toString() ?? '');

  double? get shadowSize {
    String? shad = getTagValue('shad');
    return shad != null ? double.tryParse(shad) : null;
  }

  set shadowSize(double? value) => replaceTag('shad', value?.toString() ?? '');

  double? get xshadowSize {
    String? shad = getTagValue('xshad');
    return shad != null ? double.tryParse(shad) : null;
  }

  set xshadowSize(double? value) => replaceTag('xshad', value?.toString() ?? '');

  double? get yshadowSize {
    String? shad = getTagValue('yshad');
    return shad != null ? double.tryParse(shad) : null;
  }

  set yshadowSize(double? value) => replaceTag('yshad', value?.toString() ?? '');

  int? get alignmentCode =>
      getTagValue('an') != null ? int.tryParse(getTagValue('an')!) : null;
  set alignmentCode(int? value) => replaceTag('an', value?.toString() ?? '');

  AssTagPosition? get position => getTagValue('pos') != null
      ? AssTagPosition.parse(getTagValue('pos')!)
      : null;
  set position(AssTagPosition? pos) => replaceTag('pos', pos?.toString() ?? '');

  AssTagPosition? get originalPosition => getTagValue('org') != null
      ? AssTagPosition.parse(getTagValue('org')!)
      : null;
  set originalPosition(AssTagPosition? pos) =>
      replaceTag('org', pos?.toString() ?? '');

  AssMove? get move => getTagValue('move') != null
      ? AssMove.parse(getTagValue('move')!)
      : null;
  set move(AssMove? mv) => replaceTag('move', mv?.toString() ?? '');

  AssTagClipRect? get clipRect => getTagValue('clip') != null
      ? AssTagClipRect.parse(getTagValue('clip')!)
      : null;
  set clipRect(AssTagClipRect? clip) => replaceTag('clip', clip?.toString() ?? '');

  AssTagClipRect? get iclipRect => getTagValue('iclip') != null
      ? AssTagClipRect.parse(getTagValue('iclip')!)
      : null;
  set iclipRect(AssTagClipRect? iclip) => replaceTag('iclip', iclip?.toString() ?? '');

  AssTagClipVect? get clipVect => getTagValue('clip') != null
      ? AssTagClipVect.parse(getTagValue('clip')!)
      : null;
  set clipVect(AssTagClipVect? clip) => replaceTag('clip', clip?.toString() ?? '');

  AssTagClipVect? get iclipVect => getTagValue('iclip') != null
      ? AssTagClipVect.parse(getTagValue('iclip')!)
      : null;
  set iclipVect(AssTagClipVect? iclip) => replaceTag('iclip', iclip?.toString() ?? '');

  String getAss() {
    return "{${toString()}}";
  }

  /// Serializes the OverrideTags back to a tag string.
  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    for (AssTag tagEntry in _assTagEntries) {
      bff.write(tagEntry.toString());
    }
    for (AssTransformation transformation in transformations) {
      bff.write(transformation.getAss());
    }
    return bff.toString();
  }

}

class AssTransformation {
  /// Optional start time (ms) for the `\t(...)` transform.
  int? t1;
  /// Optional end time (ms) for the `\t(...)` transform.
  int? t2;
  /// Acceleration for the `\t(...)` transform.
  double? accel;
  /// Styles/tags to apply inside the transform.
  AssOverrideTags styles;

  AssTransformation({
    this.t1,
    this.t2,
    this.accel,
    required this.styles,
  });

  /// Convenience builder for a `\t(...)` transformation.
  ///
  /// Example:
  /// ```dart
  /// tags.addT(t1: 0, t2: 250, accel: 1.5, build: (t) {
  ///   t.addTag('fscx', '150');
  ///   t.addTag('fscy', '150');
  /// });
  /// ```
  static AssTransformation build({
    int? t1,
    int? t2,
    double? accel,
    required void Function(AssOverrideTags tags) build,
  }) {
    final styles = AssOverrideTags();
    build(styles);
    return AssTransformation(t1: t1, t2: t2, accel: accel, styles: styles);
  }

  static AssTransformation? parse(String value) {
    value = value.trim();
    if (value.startsWith('(') && value.endsWith(')')) {
      value = value.substring(1, value.length - 1).trim();
    }

    List<String> parts = splitArgs(value);
    int index = 0;

    int? t1;
    int? t2;
    double? accel;
    AssOverrideTags styles = AssOverrideTags();

    if (parts.length >= 4 && int.tryParse(parts[0].trim()) != null) {
      t1 = int.tryParse(parts[index++].trim());
      t2 = int.tryParse(parts[index++].trim());
      accel = double.tryParse(parts[index++].trim());
    } else if (parts.length >= 3 && int.tryParse(parts[0].trim()) != null) {
      t1 = int.tryParse(parts[index++].trim());
      t2 = int.tryParse(parts[index++].trim());
    } else if (parts.length >= 2 && double.tryParse(parts[0].trim()) != null) {
      accel = double.tryParse(parts[index++].trim());
    }

    accel ??= 1.0;

    String remainingStyles = parts.sublist(index).join('\\');
    styles = AssOverrideTags.parse(remainingStyles)!;

    return AssTransformation(
      t1: t1,
      t2: t2,
      accel: accel,
      styles: styles,
    );
  }

  String getAss() {
    StringBuffer bff = StringBuffer();
    bff.write('\\t(');
    if (t1 != null && t2 != null) {
      if (accel != null) {
        bff.write('$t1,$t2,$accel,');
      } else {
        bff.write('$t1,$t2,');
      }
    } else if (accel != null && accel != 1.0) {
      bff.write('$accel,');
    }
    String stylesString = styles.toString();
    if (stylesString.startsWith('{') && stylesString.endsWith('}')) {
      stylesString = stylesString.substring(1, stylesString.length - 1);
    }
    bff.write(stylesString);
    bff.write(')');
    return bff.toString();
  }

  static List<String> splitArgs(String value) {
    List<String> args = [];
    int index = 0;
    int start = 0;
    int parenthesesCount = 0;
    while (index < value.length) {
      if (value[index] == ',' && parenthesesCount == 0) {
        args.add(value.substring(start, index).trim());
        start = index + 1;
      } else if (value[index] == '(') {
        parenthesesCount++;
      } else if (value[index] == ')') {
        parenthesesCount--;
      }
      index++;
    }
    if (start < value.length) {
      args.add(value.substring(start).trim());
    }
    return args;
  }
}
