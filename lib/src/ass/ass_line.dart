import 'ass_struct.dart';
import 'ass_text.dart';
import 'ass_font.dart';
import 'ass_tags.dart';
import 'ass_time.dart';
import 'dart:math' as math;

/// Text-processing helpers for ASS dialogue lines.
///
/// This file provides:
/// - Splitting a dialogue text into tag blocks ([AssLineSegment])
/// - Splitting into line breaks (`\N`, `\n`) ([AssLineBreaks])
/// - Splitting into words ([AssWords]) and characters ([AssChars])
/// - Karaoke parsing ([AssKaraoke]) with layout-friendly metrics (x/left/center/right)
///
/// These structures are meant to be used by automation code (templater-like
/// workflows) as well as any custom rendering or analysis pipeline.
String _escapeAssText(String s) => s.replaceAll('{', r'\{').replaceAll('}', r'\}');

String _stripAssLineBreaksAndNormalizeSpaces(String s) => s
    .replaceAll(r'\N', '')
    .replaceAll(r'\n', '')
    .replaceAll('\n', '')
    .replaceAll(r'\h', ' ');

class AssTextStyleState {
  String fontName;
  double fontSize;
  bool bold;
  bool italic;
  bool underline;
  bool strikeOut;
  double scaleX;
  double scaleY;
  double spacing;

  AssTextStyleState({
    required this.fontName,
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strikeOut,
    required this.scaleX,
    required this.scaleY,
    required this.spacing,
  });

  factory AssTextStyleState.fromStyle(AssStyle style) {
    return AssTextStyleState(
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

  AssTextStyleState copy() => AssTextStyleState(
        fontName: fontName,
        fontSize: fontSize,
        bold: bold,
        italic: italic,
        underline: underline,
        strikeOut: strikeOut,
        scaleX: scaleX,
        scaleY: scaleY,
        spacing: spacing,
      );

  /// Applies only tags that are explicitly present on [overrideTags].
  ///
  /// This is important because most tags in ASS are persistent, and we must not
  /// treat "missing tag" as "reset to default".
  void applyOverrideTags(
    AssOverrideTags overrideTags, {
    AssTextStyleState? resetTo,
  }) {
    final r = overrideTags.getTagValue('r');
    if (r != null) {
      // \r or \rStyleName; without a style resolver we can only reset to base.
      if (resetTo != null) {
        final base = resetTo.copy();
        fontName = base.fontName;
        fontSize = base.fontSize;
        bold = base.bold;
        italic = base.italic;
        underline = base.underline;
        strikeOut = base.strikeOut;
        scaleX = base.scaleX;
        scaleY = base.scaleY;
        spacing = base.spacing;
      }
    }

    final b = overrideTags.getTagValue('b');
    if (b != null) bold = b.trim() == '1';

    final i = overrideTags.getTagValue('i');
    if (i != null) italic = i.trim() == '1';

    final u = overrideTags.getTagValue('u');
    if (u != null) underline = u.trim() == '1';

    final s = overrideTags.getTagValue('s');
    if (s != null) strikeOut = s.trim() == '1';

    final fn = overrideTags.getTagValue('fn');
    if (fn != null) fontName = fn;

    final fs = overrideTags.getTagValue('fs');
    if (fs != null) {
      final v = double.tryParse(fs);
      if (v != null) fontSize = v;
    }

    final fsp = overrideTags.getTagValue('fsp');
    if (fsp != null) {
      final v = double.tryParse(fsp);
      if (v != null) spacing = v;
    }

    final fscx = overrideTags.getTagValue('fscx');
    if (fscx != null) {
      final v = double.tryParse(fscx);
      if (v != null) scaleX = v;
    }

    final fscy = overrideTags.getTagValue('fscy');
    if (fscy != null) {
      final v = double.tryParse(fscy);
      if (v != null) scaleY = v;
    }
  }

  String cacheKey(String styleName) {
    return [
      styleName,
      fontName,
      fontSize.toStringAsFixed(4),
      bold ? 'b1' : 'b0',
      italic ? 'i1' : 'i0',
      underline ? 'u1' : 'u0',
      strikeOut ? 's1' : 's0',
      scaleX.toStringAsFixed(4),
      scaleY.toStringAsFixed(4),
      spacing.toStringAsFixed(4),
    ].join('|');
  }
}

class _AssFontCache {
  final Map<String, AssFont> _fonts = {};

  Future<AssFont> getFont(String styleName, AssTextStyleState state) async {
    final key = state.cacheKey(styleName);
    final existing = _fonts[key];
    if (existing != null) return existing;

    final font = AssFont(
      styleName: styleName,
      fontName: state.fontName,
      fontSize: state.fontSize,
      bold: state.bold,
      italic: state.italic,
      underline: state.underline,
      strikeOut: state.strikeOut,
      scaleX: state.scaleX,
      scaleY: state.scaleY,
      spacing: state.spacing,
    );
    await font.init();
    _fonts[key] = font;
    return font;
  }
}

String _normalizeAssTextForMetrics(String text) {
  // ASS hard-space.
  return text
      .replaceAll(r'\h', ' ')
      // Line breaks are not rendered glyphs.
      .replaceAll(r'\N', '')
      .replaceAll(r'\n', '')
      .replaceAll('\n', '');
}

class AssKaraoke {
  /// Text of the karaoke block as it appears in the segment (may include spaces).
  String text;

  /// Full measured width of the segment.
  double? width;

  /// Measured height of the segment.
  double? height;

  /// Duration in milliseconds (`\k` value * 10).
  int? durationMs;

  /// Relative start offset (ms) from the line start.
  int? startOffsetMs;

  /// Relative end offset (ms) from the line start.
  int? endOffsetMs;

  /// Karaoke tag kind: `k`, `kf`, `ko` (or null).
  String? karaokeTag;

  /// Effective style state used for measuring the segment.
  AssTextStyleState? effectiveStyle;

  /// Global index across all karaoke blocks of the line (0-based).
  int? index;

  /// Visual line break index (0-based).
  int? lineIndex;

  /// X offset from the start of the visual line (includes pre-space).
  double? x;

  /// Left/center/right are computed for the "core" text (without pre/post spaces),
  /// similar to how karaskel treats `prespacewidth` and `postspacewidth`.
  double? left;
  double? center;
  double? right;

  /// Leading spaces (ASCII spaces/tabs) of the block text.
  String? prespace;

  /// Trailing spaces (ASCII spaces/tabs) of the block text.
  String? postspace;

  /// Block text without leading/trailing ASCII spaces/tabs.
  String? textSpaceStripped;

  /// Width of [prespace] in script pixels.
  double? prespaceWidth;

  /// Width of [postspace] in script pixels.
  double? postspaceWidth;

  /// Width of [textSpaceStripped] in script pixels.
  double? coreWidth;

  AssKaraoke({
    required this.text,
    this.durationMs,
    this.startOffsetMs,
    this.endOffsetMs,
    this.karaokeTag,
    this.effectiveStyle,
    this.index,
    this.lineIndex,
    this.x,
    this.left,
    this.center,
    this.right,
    this.prespace,
    this.postspace,
    this.textSpaceStripped,
    this.prespaceWidth,
    this.postspaceWidth,
    this.coreWidth,
  });

  @override
  String toString() {
    return text;
  }
}

class AssChars {
  /// Single character text.
  String text;
  double? width;
  double? height;
  /// Whether this character is whitespace (space/tab/etc).
  bool? isSpace;
  /// 0-based index across all chars returned by [AssLine.chars].
  int? index;
  /// Visual line break index (0-based).
  int? lineIndex;
  /// X offset from the start of the visual line.
  double? x;
  /// Left edge position of this glyph (relative to visual line start).
  double? left;
  /// Center position of this glyph (relative to visual line start).
  double? center;
  /// Right edge position of this glyph (relative to visual line start).
  double? right;
  AssTextStyleState? effectiveStyle;

  AssChars({
    required this.text,
    this.isSpace,
    this.index,
    this.lineIndex,
    this.x,
    this.left,
    this.center,
    this.right,
    this.effectiveStyle,
  });

  @override
  String toString() {
    return text;
  }
}

class AssWords {
  /// Word token, optionally including whitespace if `includeWhitespace=true`.
  String text;
  double? width;
  double? height;
  /// 0-based index across all words returned by [AssLine.words].
  int? index;
  /// Visual line break index (0-based).
  int? lineIndex;
  /// X offset from the start of the visual line.
  double? x;
  AssTextStyleState? effectiveStyle;

  AssWords({
    required this.text,
    this.index,
    this.lineIndex,
    this.x,
    this.effectiveStyle,
  });

  @override
  String toString() {
    return text;
  }
}

class AssLineBreaks {
  /// Concatenated plain text of this break (tags are stored in [segments]).
  String text;
  /// 0-based index of the break.
  int? index;
  /// Segments (tag blocks) inside this visual break.
  List<AssLineSegment> segments;
  double? width;
  double? height;

  AssLineBreaks({
    required this.text,
    required this.segments,
    this.index,
    this.width,
    this.height,
  });

  void computeSizeFromSegments() {
    double w = 0;
    double h = 0;
    for (final s in segments) {
      w += s.width ?? 0;
      h = (s.height ?? 0) > h ? (s.height ?? 0) : h;
    }
    width = w;
    height = h;
    text = segments.map((e) => e.text).join();
  }

  @override
  String toString() {
    return text;
  }
}

class AssLineSegment {
  /// Plain text portion of this segment (no `{...}` override block included).
  String text;

  /// Original parsed segment with its override tags.
  AssTextSegment textSegment;

  /// Base style of the dialog line.
  AssStyle style;

  double? width;
  double? height;
  /// Font ascent (if measurable).
  double? ascent;
  /// Font descent (if measurable).
  double? descent;

  /// Effective style state used to measure/render this segment.
  AssTextStyleState? effectiveStyle;

  AssLineSegment({
    required this.text,
    required this.textSegment,
    required this.style,
    this.effectiveStyle,
  });

  static AssLineSegment? parse(AssTextSegment segment, AssStyle style) {
    AssLineSegment lineSegment = AssLineSegment(
      text: segment.text,
      textSegment: segment,
      style: style,
    );
    return lineSegment;
  }

  Future<void> extend({bool useTextData = true}) async {
    // Backwards-compatible: measures using only this segment's own overrideTags.
    final state = AssTextStyleState.fromStyle(style);
    if (useTextData && textSegment.overrideTags != null) {
      state.applyOverrideTags(textSegment.overrideTags!, resetTo: AssTextStyleState.fromStyle(style));
    }
    final cache = _AssFontCache();
    await _extendWithStyleState(state, cache);
  }

  Future<void> _extendWithStyleState(
    AssTextStyleState state,
    _AssFontCache cache,
  ) async {
    effectiveStyle = state.copy();
    final font = await cache.getFont(style.styleName, state);
    final metrics = font.metrics();
    ascent = metrics?.ascent;
    descent = metrics?.descent;

    final extents = font.textExtents(_normalizeAssTextForMetrics(text));
    if (extents != null) {
      width = extents.width;
      height = extents.height;
    } else {
      width = 0;
      height = 0;
    }
  }

  @override
  String toString() {
    return text;
  }
}

class AssLine {
  /// Base style used for measurement defaults.
  AssStyle style;

  /// Tag-block segments across the original dialogue text.
  List<AssLineSegment> segments;

  /// Cached line breaks for this line, if computed.
  List<AssLineBreaks>? breaks;
  final _AssFontCache _fontCache = _AssFontCache();

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
    final base = AssTextStyleState.fromStyle(style);
    final state = base.copy();

    for (final segment in segments) {
      if (useTextData && segment.textSegment.overrideTags != null) {
        state.applyOverrideTags(segment.textSegment.overrideTags!, resetTo: base);
      }
      await segment._extendWithStyleState(state, _fontCache);
    }
  }

  /// Splits the line into visual line breaks using `\N`, `\n` or actual `\n`.
  ///
  /// The returned breaks contain segment pieces already measured (it calls
  /// [extend] if necessary).
  Future<List<AssLineBreaks>> lineBreaks({bool useTextData = true}) async {
    final base = AssTextStyleState.fromStyle(style);
    final state = base.copy();

    final List<AssLineBreaks> out = [];
    final List<AssLineSegment> current = [];

    // Tags to attach to the next emitted text piece (only for representation).
    AssOverrideTags? pendingOverrideForPiece;

    void flushBreak() {
      final br = AssLineBreaks(text: '', segments: List.of(current), index: out.length);
      br.computeSizeFromSegments();
      out.add(br);
      current.clear();
    }

    for (final original in segments) {
      final ot = original.textSegment.overrideTags;
      if (useTextData && ot != null) {
        state.applyOverrideTags(ot, resetTo: base);
        pendingOverrideForPiece = ot;
      }

      final text = original.text;
      int last = 0;
      final re = RegExp(r'(\\N|\\n|\n)');
      for (final m in re.allMatches(text)) {
        final part = text.substring(last, m.start);
        if (part.isNotEmpty) {
          final ts = AssTextSegment(text: part, overrideTags: pendingOverrideForPiece);
          pendingOverrideForPiece = null;
          final seg = AssLineSegment(text: part, textSegment: ts, style: style);
          await seg._extendWithStyleState(state, _fontCache);
          current.add(seg);
        }
        flushBreak();
        last = m.end;
      }
      final tail = text.substring(last);
      if (tail.isNotEmpty) {
        final ts = AssTextSegment(text: tail, overrideTags: pendingOverrideForPiece);
        pendingOverrideForPiece = null;
        final seg = AssLineSegment(text: tail, textSegment: ts, style: style);
        await seg._extendWithStyleState(state, _fontCache);
        current.add(seg);
      }
    }
    flushBreak();
    breaks = out;
    return out;
  }

  Future<List<AssWords>> words({
    bool useTextData = true,
    bool includeWhitespace = false,
  }) async {
    final lbs = await lineBreaks(useTextData: useTextData);

    final List<AssWords> out = [];
    int globalIndex = 0;

    for (final br in lbs) {
      double x = 0;
      for (final seg in br.segments) {
        final st = seg.effectiveStyle ?? AssTextStyleState.fromStyle(style);
        final str = seg.text;
        final re = RegExp(r'(\s+|\S+)');
        for (final m in re.allMatches(str)) {
          final token = m.group(0) ?? '';
          final isWs = token.trim().isEmpty;
          final font = await _fontCache.getFont(style.styleName, st);
          final ext = font.textExtents(_normalizeAssTextForMetrics(token));
          final w = ext?.width ?? 0;
          final h = ext?.height ?? 0;
          if (includeWhitespace || !isWs) {
            out.add(
              AssWords(
                text: token,
                index: globalIndex++,
                lineIndex: br.index,
                x: x,
                effectiveStyle: st,
              )
                ..width = w
                ..height = h,
            );
          }
          x += w;
        }
      }
    }

    return out;
  }

  Future<List<AssChars>> chars({
    bool useTextData = true,
    bool includeWhitespace = false,
  }) async {
    final lbs = await lineBreaks(useTextData: useTextData);

    final List<AssChars> out = [];
    int globalIndex = 0;

    for (final br in lbs) {
      double x = 0;
      for (final seg in br.segments) {
        final st = seg.effectiveStyle ?? AssTextStyleState.fromStyle(style);
        final font = await _fontCache.getFont(style.styleName, st);
        final normalized = _normalizeAssTextForMetrics(seg.text);
        for (final rune in normalized.runes) {
          final ch = String.fromCharCode(rune);
          final isWs = ch.trim().isEmpty;
          final ext = font.textExtents(ch);
          final w = ext?.width ?? 0;
          final h = ext?.height ?? 0;
          final l = x;
          final c = x + w * 0.5;
          final r = x + w;
          if (includeWhitespace || !isWs) {
            out.add(
              AssChars(
                text: ch,
                isSpace: isWs,
                index: globalIndex++,
                lineIndex: br.index,
                x: x,
                left: l,
                center: c,
                right: r,
                effectiveStyle: st,
              )
                ..width = w
                ..height = h,
            );
          }
          x += w;
        }
      }
    }

    return out;
  }

  /// Returns karaoke blocks with timing and layout metrics.
  ///
  /// This reads karaoke tags from override blocks:
  /// - `\k`, `\kf`, `\ko` and `\K` (alias of `\kf`)
  /// - `\kt` (absolute start offset in centiseconds)
  ///
  /// `\kt` is treated as a global karaoke-time cursor for the line: when present,
  /// it sets the current time position (in centiseconds) used by the next `\k`
  /// block. This can move the cursor forwards or backwards (overlaps are allowed),
  /// matching typical karaoke parsers.
  ///
  /// The returned items contain:
  /// - time offsets: [AssKaraoke.startOffsetMs] / [AssKaraoke.endOffsetMs]
  /// - measured widths/heights
  /// - core-text positioning metrics: [AssKaraoke.left]/[AssKaraoke.center]/[AssKaraoke.right]
  Future<List<AssKaraoke>> karaoke({bool useTextData = true}) async {
    final lbs = await lineBreaks(useTextData: useTextData);
    final List<AssKaraoke> out = [];

    int cursor = 0;
    int globalIndex = 0;
    for (final br in lbs) {
      double x = 0;
      AssKaraoke? current;
      AssTextStyleState? currentStyle;

      Future<void> recomputeCurrentSpacing() async {
        final k = current;
        final st = currentStyle;
        if (k == null || st == null) return;

        // More accurate karaoke metrics (karaskel-like):
        // measure pre/core/post spaces separately, and set left/center/right for core text only.
        final font = await _fontCache.getFont(style.styleName, st);
        final normalized = _normalizeAssTextForMetrics(k.text);
        final m = RegExp(r'^([ \t]*)(.*?)([ \t]*)$').firstMatch(normalized);
        final pre = m?.group(1) ?? '';
        final core = m?.group(2) ?? normalized;
        final post = m?.group(3) ?? '';

        final preW = pre.isEmpty ? 0.0 : (font.textExtents(pre)?.width ?? 0.0);
        final coreW = core.isEmpty ? 0.0 : (font.textExtents(core)?.width ?? 0.0);
        final postW = post.isEmpty ? 0.0 : (font.textExtents(post)?.width ?? 0.0);

        k.prespace = pre;
        k.postspace = post;
        k.textSpaceStripped = core;
        k.prespaceWidth = preW;
        k.postspaceWidth = postW;
        k.coreWidth = coreW;

        final kx = k.x ?? 0.0;
        k.left = kx + preW;
        k.center = kx + preW + coreW * 0.5;
        k.right = kx + preW + coreW;
      }

      for (final seg in br.segments) {
        final tags = seg.textSegment.overrideTags;
        final w = seg.width ?? 0;
        if (!useTextData) {
          // Without text data we cannot reliably identify karaoke blocks.
          // Still advance X by measured width so later blocks (if any) remain positioned.
          x += w;
          continue;
        }

        final ktRaw = tags?.getTagValue('kt');
        final ktCs = ktRaw != null ? int.tryParse(ktRaw.trim()) : null;
        final hasKt = ktCs != null;
        if (hasKt) {
          // \kt sets the karaoke cursor in centiseconds.
          cursor = ktCs * 10;
        }

        String? tagName;
        String? raw;
        raw = tags?.getTagValue('kf');
        if (raw != null) {
          tagName = 'kf';
        } else {
          raw = tags?.getTagValue('ko');
          if (raw != null) tagName = 'ko';
        }
        raw ??= tags?.getTagValue('k');
        tagName ??= raw != null ? 'k' : null;

        final cs = raw != null ? int.tryParse(raw.trim()) : null;
        final hasK = cs != null;
        if (!hasK && !hasKt) {
          // No karaoke tags in this segment. If we're currently inside a karaoke
          // unit (started by a previous \k/\kf/\ko), this text still belongs to
          // that same syllable and must be accounted for.
          if (current != null) {
            current.text += seg.text;
            current.width = (current.width ?? 0.0) + w;
            current.height = (current.height ?? 0.0) > (seg.height ?? 0.0) ? current.height : seg.height;
            // Advance by visual width.
            x += w;
            // Keep spacing metrics up to date (uses the style from the syllable start).
            await recomputeCurrentSpacing();
          } else {
            x += w;
          }
          continue;
        }

        // A new karaoke timing tag starts a new unit. The timing applies to the
        // text that follows, until the next karaoke timing tag.
        if (hasK) {
          final durMs = cs * 10;
          final start = cursor;
          final end = start + durMs;
          cursor = end;

          final st = seg.effectiveStyle ?? AssTextStyleState.fromStyle(style);
          final k = AssKaraoke(
            text: seg.text,
            durationMs: durMs,
            startOffsetMs: start,
            endOffsetMs: end,
            karaokeTag: tagName,
            effectiveStyle: seg.effectiveStyle,
            index: globalIndex++,
            lineIndex: br.index,
            x: x,
          )
            ..width = w
            ..height = seg.height;
          out.add(k);
          current = k;
          currentStyle = st;
          await recomputeCurrentSpacing();
          x += w;
        } else {
          // No `\k` in this segment. If a `\kt` tag was present, it has already
          // updated the global cursor. We still need to account for visible text
          // as continuation of the previous syllable when applicable.
          if (current != null) {
            current.text += seg.text;
            current.width = (current.width ?? 0.0) + w;
            current.height = (current.height ?? 0.0) > (seg.height ?? 0.0) ? current.height : seg.height;
            x += w;
            await recomputeCurrentSpacing();
          } else {
            x += w;
          }
        }
      }
    }

    return out;
  }

  AssLine({required this.segments, required this.style});

  @override
  String toString() {
    return segments.map((e) => e.text).join();
  }
}

/// Helpers to generate "FX lines" (extra Dialogue lines) from a source dialog.
///
/// This is inspired by Aegisub Automation (templater-like workflows), but keeps
/// the implementation inside the library so you can build your own automation
/// on top of it.
extension AssDialogFx on AssDialog {
  /// Returns a safe base override block (first tags block found) without karaoke tags.
  ///
  /// Useful when generating new lines from karaoke input so you don't carry `\k`
  /// into the generated output unless you explicitly want to.
  String baseTagsAssWithoutKaraoke() {
    final firstWithTags = text.segments.firstWhere(
      (s) => s.overrideTags != null,
      orElse: () => AssTextSegment(text: ''),
    );
    final tags = firstWithTags.overrideTags;
    if (tags == null) return '';
    final copy = AssOverrideTags.parse(tags.toString());
    if (copy == null) return '';
    for (final t in ['k', 'kf', 'ko', 'kt']) {
      copy.removeTag(t);
    }
    return copy.toString().isEmpty ? '' : copy.getAss();
  }

  /// Generates one new `Dialogue` (Effect=`fx`) per character.
  ///
  /// This is intentionally "text-only": it does not require font/metrics, and it
  /// uses a simple `stepMs` cadence over the source line time.
  List<AssDialog> toCharFxDialogs({
    int stepMs = 35,
    int durMs = 300,
    int layerOffset = 10,
    bool includeSpaces = false,
    bool commentOriginal = true,
  }) {
    final start = startTime.time;
    final end = endTime.time;
    if (start == null || end == null) return const [];
    if (end <= start) return const [];
    if (stepMs <= 0) throw ArgumentError('stepMs must be > 0');
    if (durMs <= 0) throw ArgumentError('durMs must be > 0');

    final baseTagsAss = baseTagsAssWithoutKaraoke();
    final raw = text.segments.map((s) => s.text).join();
    final normalized = _stripAssLineBreaksAndNormalizeSpaces(raw);

    final out = <AssDialog>[];
    int charIndex = 0;

    for (final rune in normalized.runes) {
      final ch = String.fromCharCode(rune);
      final isSpace = ch.trim().isEmpty;
      if (!includeSpaces && isSpace) {
        charIndex++;
        continue;
      }

      final s = start + (charIndex * stepMs);
      var e = s + durMs;
      if (s >= end) break;
      if (e > end) e = end;
      if (e <= s) {
        charIndex++;
        continue;
      }

      final textAss = '$baseTagsAss${_escapeAssText(ch)}';
      out.add(
        AssDialog(
          layer: layer + layerOffset,
          startTime: AssTime(time: s),
          endTime: AssTime(time: e),
          styleName: styleName,
          name: name,
          marginL: marginL,
          marginR: marginR,
          marginV: marginV,
          effect: 'fx',
          text: AssText.parse(textAss) ?? AssText(segments: [AssTextSegment(text: textAss)]),
          header: header,
          commented: false,
          style: style,
        ),
      );

      charIndex++;
    }

    if (commentOriginal) {
      commented = true;
    }

    return out;
  }

  /// Generates one new `Dialogue` (Effect=`fx`) per karaoke block.
  ///
  /// Supported tags: `\k`, `\kf`, `\ko`, `\K` (alias of `\kf`), `\kt`.
  ///
  /// Notes:
  /// - `\kt` sets the global karaoke cursor (centiseconds) used by the next `\k` block.
  /// - Without `\kt`, offsets are sequential (cursor-like) as in `\k`.
  List<AssDialog> toKaraokeFxDialogs({
    int layerOffset = 10,
    bool includeNonKaraokeSegments = false,
    bool commentOriginal = true,
  }) {
    final start = startTime.time;
    final end = endTime.time;
    if (start == null || end == null) return const [];
    if (end <= start) return const [];

    final baseTagsAss = baseTagsAssWithoutKaraoke();

    int cursor = 0; // ms, relative to the line start
    final out = <AssDialog>[];

    // Collect blocks in a single pass (text-only, no metrics).
    final blocks = <({int startOffset, int endOffset, String text})>[];
    ({int startOffset, int endOffset, String text})? current;
    bool sawAnyKaraoke = false;
    final fullTextBff = StringBuffer();

    for (final seg in text.segments) {
      final segText = _stripAssLineBreaksAndNormalizeSpaces(seg.text);
      if (segText.isEmpty) continue;
      fullTextBff.write(segText);

      final tags = seg.overrideTags;
      int? ktCs;
      int? kCs;

      if (tags != null) {
        final ktRaw = tags.getTagValue('kt');
        ktCs = ktRaw != null ? int.tryParse(ktRaw.trim()) : null;
        if (ktCs != null) {
          cursor = ktCs * 10;
        }

        String? raw;
        raw = tags.getTagValue('kf');
        raw ??= tags.getTagValue('ko');
        raw ??= tags.getTagValue('k');
        kCs = raw != null ? int.tryParse(raw.trim()) : null;
      }

      if (kCs != null) {
        sawAnyKaraoke = true;
        final durMs = kCs * 10;
        if (durMs <= 0) continue;
        final startOffset = cursor;
        final endOffset = startOffset + durMs;
        cursor = endOffset;
        final b = (startOffset: startOffset, endOffset: endOffset, text: segText);
        blocks.add(b);
        current = b;
      } else {
        // Continuation text (no karaoke timing tag). If we're currently inside a
        // karaoke block, this text still belongs to that same block.
        if (current != null) {
          current = (
            startOffset: current.startOffset,
            endOffset: current.endOffset,
            text: current.text + segText,
          );
          blocks[blocks.length - 1] = current;
        }
      }
    }

    if (!sawAnyKaraoke) {
      if (!includeNonKaraokeSegments) return const [];
      final textAss = '$baseTagsAss${_escapeAssText(fullTextBff.toString())}';
      out.add(
        AssDialog(
          layer: layer + layerOffset,
          startTime: AssTime(time: start),
          endTime: AssTime(time: end),
          styleName: styleName,
          name: name,
          marginL: marginL,
          marginR: marginR,
          marginV: marginV,
          effect: 'fx',
          text: AssText.parse(textAss) ?? AssText(segments: [AssTextSegment(text: textAss)]),
          header: header,
          commented: false,
          style: style,
        ),
      );
    } else {
      for (final b in blocks) {
        final absStart = start + b.startOffset;
        if (absStart >= end) continue;
        var absEnd = start + b.endOffset;
        if (absEnd > end) absEnd = end;
        if (absEnd <= absStart) continue;

        final textAss = '$baseTagsAss${_escapeAssText(b.text)}';
        out.add(
          AssDialog(
            layer: layer + layerOffset,
            startTime: AssTime(time: absStart),
            endTime: AssTime(time: absEnd),
            styleName: styleName,
            name: name,
            marginL: marginL,
            marginR: marginR,
            marginV: marginV,
            effect: 'fx',
            text: AssText.parse(textAss) ?? AssText(segments: [AssTextSegment(text: textAss)]),
            header: header,
            commented: false,
            style: style,
          ),
        );
      }
    }

    if (commentOriginal) {
      commented = true;
    }

    return out;
  }
}
