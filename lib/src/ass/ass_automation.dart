import 'dart:collection';
import 'dart:math' as math;

import 'ass.dart';
import 'ass_font.dart';
import 'ass_line.dart';
import 'ass_path.dart';
import 'ass_struct.dart';
import 'ass_tags.dart';
import 'ass_text.dart';
import 'ass_time.dart';

/// A small automation framework inspired by Aegisub Automation.
///
/// The core idea is:
/// 1) Select a set of dialogs (`selectAll()`, `where(...)`, `whereKaraoke()`)
/// 2) Apply a chain of operations (`shiftTime`, `replaceText`, `setTag`, ...)
/// 3) Optionally generate new "FX" lines (`splitCharsFx`, `splitKaraokeFx`)
///
/// All flows are async, because some operations may need metrics (FFI/font).
///
/// This file intentionally does **not** try to implement Aegisub's full scripting
/// runtime. Instead it provides a clean, composable API in Dart which can be
/// used to build templater-like features.
///
/// ## Example
/// ```dart
/// final result = await AssAutomation(ass)
///   .flow()
///   .selectAll()
///   .whereKaraoke()
///   .splitKaraokeFx(onKaraokeEnv: (env) {
///     env.retime(AssRetimeMode.unit);
///     final tags = env.unit.ensureLeadingTags(env.line);
///     tags.setTag('fad', '50,50');
///     env.emit.emit(env.line);
///   })
///   .run();
/// ```
typedef AssDialogPredicate = bool Function(AssDialog dialog, int index);
typedef AssDialogMapper = AssDialog Function(AssDialog dialog, int index);
typedef AssTextMapper = String Function(String text, AssDialog dialog, int index);

typedef AssCharFxEnvCallback = void Function(AssCharTemplateEnv env);
typedef AssWordFxEnvCallback = void Function(AssWordTemplateEnv env);
typedef AssKaraokeFxEnvCallback = void Function(AssKaraokeTemplateEnv env);
typedef AssFrameFxEnvCallback = void Function(AssFrameTemplateEnv env);
typedef AssShapeExpandEnvCallback = void Function(AssShapeExpandTemplateEnv env);

/// How a split operation should allocate time ranges for generated units.
enum AssSplitTimeMode {
  /// Uses `stepMs`/`durMs` per unit index (legacy behavior).
  indexStep,

  /// Allocates unit time windows proportionally to the original line duration.
  ///
  /// For `N` units, unit `i` gets:
  /// - start = lineStart + round(i / N * lineDuration)
  /// - end   = lineStart + round((i+1) / N * lineDuration)
  ///
  /// This guarantees full coverage of the original range (unless the line has
  /// zero duration).
  proportional,
}

/// A unit with absolute timing boundaries.
///
/// This lets template environments expose common time helpers (midpoint, fraction, etc.)
/// regardless of whether the unit is a char, karaoke block, or frame window.
abstract class AssTimedUnit {
  int get absStartMs;
  int get absEndMs;
}

enum AssBasePosSource {
  /// Obtained from an explicit `\pos(x,y)` tag.
  pos,
  /// Obtained from a `\move(x1,y1,...)` tag (uses the start point).
  move,
  /// Derived from `PlayRes + \an + margins`.
  derived,
}

class AssBasePos {
  final AssTagPosition pos;
  final AssBasePosSource source;
  const AssBasePos({required this.pos, required this.source});
}

enum AssTagScope {
  /// Ensures a leading override block and edits only that block.
  leading,

  /// Applies to every segment that already has override tags.
  ///
  /// This does not automatically create tags blocks on each segment.
  existingSegmentsOnly,

  /// Applies to every segment, creating an override-tags block when missing.
  allSegments,
}

/// How `splitKaraokeFx` should group karaoke timing blocks.
enum AssKaraokeSplitMode {
  /// Emits one unit per karaoke timing tag block (`\k/\kf/\ko`).
  ///
  /// This is the most direct mapping of ASS karaoke markup.
  blocks,

  /// Emits one unit per "syllable", merging extra highlight blocks which begin
  /// with `#`/`＃` (karaskel-like multi-highlight).
  ///
  /// The merged unit exposes all highlight windows in [AssKaraokeUnit.highlights].
  syllables,
}

/// Where generated dialogs (typically `Effect=fx`) are inserted.
enum AssGeneratedOutputPlacement {
  /// Inserts generated dialogs right after their source dialog (current behavior).
  afterSource,

  /// Appends all generated dialogs to the end of the file.
  appendToEnd,

  /// Prepends all generated dialogs to the start of the file.
  prependToStart,

  /// Inserts all generated dialogs at a fixed index.
  insertAtIndex,
}

class AssGeneratedOutputStrategy {
  final AssGeneratedOutputPlacement placement;
  final int? index;

  const AssGeneratedOutputStrategy._(this.placement, {this.index});

  const AssGeneratedOutputStrategy.afterSource() : this._(AssGeneratedOutputPlacement.afterSource);
  const AssGeneratedOutputStrategy.appendToEnd() : this._(AssGeneratedOutputPlacement.appendToEnd);
  const AssGeneratedOutputStrategy.prependToStart() : this._(AssGeneratedOutputPlacement.prependToStart);
  const AssGeneratedOutputStrategy.insertAt(int index) : this._(AssGeneratedOutputPlacement.insertAtIndex, index: index);
}

class AssAutomationResult {
  /// The mutated ASS document.
  final Ass ass;

  /// Operation logs produced during the run.
  final List<String> logs;

  /// Count of distinct dialogs mutated in place.
  ///
  /// This does not include purely inserted/removed dialogs.
  final int dialogsTouched;

  AssAutomationResult({
    required this.ass,
    required this.logs,
    required this.dialogsTouched,
  });
}

class AssAutomationContext {
  /// The in-memory ASS document being mutated.
  final Ass ass;

  /// Shared resources for operations/callbacks (fonts, caches, etc.).
  final AssAutomationShared shared;

  /// Human-readable operation logs produced during `run()`.
  final List<String> logs = [];

  // Selection = indices in ass.dialogs!.dialogs
  /// Selected dialog indices within `ass.dialogs!.dialogs`.
  final Set<int> selection = {};

  /// Distinct dialogs mutated in place (not counting pure inserts/removes).
  ///
  /// This is intentionally de-duplicated across ops: if the same dialog is
  /// modified multiple times in a flow, it still counts as 1 touched dialog.
  final Set<AssDialog> _touchedDialogs = HashSet.identity();

  AssAutomationContext(this.ass, {AssAutomationShared? shared}) : shared = shared ?? AssAutomationShared();

  AssDialogs ensureDialogs() {
    ass.dialogs ??= AssDialogs(dialogs: []);
    return ass.dialogs!;
  }

  AssStyles ensureStyles() {
    if (ass.styles == null || ass.styles!.styles.isEmpty) {
      throw StateError('ASS has no styles loaded.');
    }
    return ass.styles!;
  }

  AssHeader ensureHeader() {
    if (ass.header == null) {
      throw StateError('ASS has no header loaded.');
    }
    return ass.header!;
  }

  AssStyle styleByName(String styleName) {
    final styles = ensureStyles();
    return styles.getStyleByName(styleName);
  }

  void log(String message) => logs.add(message);

  int get dialogsTouched => _touchedDialogs.length;

  void touchDialog(AssDialog dialog) => _touchedDialogs.add(dialog);
}

/// An automation operation.
///
/// All automation is async to support metric extraction and other IO/FFI
/// interactions. Pure in-memory ops should still implement this and simply
/// return a completed future.
abstract class AssAutomationOp {
  const AssAutomationOp();

  /// Apply this operation, mutating [AssAutomationContext.ass] in place.
  Future<void> apply(AssAutomationContext ctx);
}

class AssFxEmitter {
  final List<AssDialog> _out;
  AssFxEmitter(this._out);

  /// Emits a new dialog line (typically Effect=`fx`) produced by an operation.
  void emit(AssDialog dialog) => _out.add(dialog);

  /// Creates another emitter which appends to the same output list.
  ///
  /// Useful for nested generators (e.g. `env.fbf(...)` inside karaoke/char callbacks).
  AssFxEmitter share() => AssFxEmitter(_out);
}

enum AssRetimeMode {
  /// Retime relative to the full original line.
  line,
  /// Zero-length segment at the line start.
  preline,
  /// Zero-length segment at the line end.
  postline,
  /// Retime to the current unit time range (char/karaoke block).
  unit,
  /// Zero-length segment at unit start.
  preunit,
  /// Zero-length segment at unit end.
  postunit,
  /// From line start to unit start.
  start2unit,
  /// From unit end to line end.
  unit2end,
  /// Absolute times (requires `absStartMs/absEndMs`).
  abs,
  /// Adds deltas to the current `env.line` times.
  delta,
  /// Clamps the current `env.line` times inside the original line.
  clamp,
}

class AssTemplateUtil {
  /// Linear interpolation between [v0] and [v1] by [t] (0..1).
  double lerp(double t, double v0, double v1) => (v1 * t) + (v0 * (1 - t));

  double clamp(double v, double min, double max) => v < min ? min : (v > max ? max : v);

  /// Remaps [v] from `[in0,in1]` to `[out0,out1]`.
  double remap(double v, double in0, double in1, double out0, double out1, {bool clampOutput = false}) {
    if (in1 == in0) return out0;
    final t = (v - in0) / (in1 - in0);
    final out = lerp(t, out0, out1);
    return clampOutput ? clamp(out, math.min(out0, out1), math.max(out0, out1)) : out;
  }

  /// Applies an ASS-style acceleration curve (similar to `\t(...,accel,...)`).
  ///
  /// `accel=1` is linear. Higher values bias towards the end, lower towards the start.
  double accel(double t, double accel) {
    if (accel <= 0) return t;
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    if (accel == 1) return t;
    return math.pow(t, accel).toDouble();
  }

  double easeInQuad(double t) => t * t;
  double easeOutQuad(double t) => 1 - (1 - t) * (1 - t);
  double easeInOutQuad(double t) => t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2).toDouble() / 2;

  double easeInCubic(double t) => t * t * t;
  double easeOutCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();
  double easeInOutCubic(double t) => t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;

  double smoothstep(double edge0, double edge1, double x) {
    final t = clamp((x - edge0) / (edge1 - edge0), 0, 1);
    return t * t * (3 - 2 * t);
  }

  /// Computes the position of a `\move(...)` at a given time (ms) relative to the line start.
  AssTagPosition movePosAt(int relMs, AssMove mv, int lineDurationMs) {
    final t1 = mv.t1 ?? 0;
    final t2 = mv.t2 ?? lineDurationMs;
    if (t2 <= t1) return AssTagPosition(mv.x2, mv.y2);
    if (relMs <= t1) return AssTagPosition(mv.x1, mv.y1);
    if (relMs >= t2) return AssTagPosition(mv.x2, mv.y2);
    final t = (relMs - t1) / (t2 - t1);
    final x = lerp(t, mv.x1, mv.x2);
    final y = lerp(t, mv.y1, mv.y2);
    return AssTagPosition(x, y);
  }

  /// A `\fad(tIn,tOut)` visibility factor at [relMs] (0..1).
  ///
  /// This ignores existing alpha tags and only provides the envelope.
  double fadFactorAt(int relMs, int lineDurationMs, {required int tInMs, required int tOutMs}) {
    if (lineDurationMs <= 0) return 1;
    final t = clamp(relMs.toDouble(), 0, lineDurationMs.toDouble());
    final fin = tInMs <= 0 ? 1.0 : clamp(t / tInMs, 0, 1);
    final fout = tOutMs <= 0 ? 1.0 : clamp((lineDurationMs - t) / tOutMs, 0, 1);
    return math.min(fin, fout);
  }

  /// Returns 0..1 based on `field` (`left|center|right`) within `objs`.
  double xf<T>(
    T obj,
    List<T> objs, {
    String field = 'center',
    double Function(T o)? get,
  }) {
    if (objs.isEmpty) return 0;
    double? getField(T o) {
      if (get != null) return get(o);
      final dynamic d = o;
      switch (field) {
        case 'left':
          return d.left as double?;
        case 'right':
          return d.right as double?;
        default:
          return d.center as double?;
      }
    }

    final x = getField(obj);
    final x0 = getField(objs.first);
    final x1 = getField(objs.last);
    if (x == null || x0 == null || x1 == null) return 0;
    if (x1 == x0) return 0;
    return (x - x0) / (x1 - x0);
  }

  String ftoa(num n, {int digits = 2}) {
    if (digits < 0) throw ArgumentError('digits must be >= 0');
    if (n == n.roundToDouble()) return n.toString();
    if (digits == 0) return n.round().toString();
    var s = n.toStringAsFixed(digits);
    // Trim trailing zeros after decimal point.
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      s = s.replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  /// Random helpers (non-cryptographic).
  final math.Random rand = math.Random();

  int randSign() => rand.nextBool() ? 1 : -1;

  bool randBool([double p = 0.5]) => rand.nextDouble() < p;

  T randItem<T>(List<T> items) => items[rand.nextInt(items.length)];
}

/// Reusable resources for automation flows.
///
/// This is intended to avoid repeating boilerplate like "warm up FreeType fonts"
/// in every example/script.
///
/// Typical usage:
/// ```dart
/// final shared = AssAutomationShared();
/// await AssAutomation(ass).flow(shared: shared).selectAll().warmupFonts().run();
/// shared.dispose();
/// ```
class AssAutomationShared {
  final Map<String, AssFont> _fontsByStyleName = {};
  final Map<String, AssFont> _fontsByKey = {};

  String _fontKeyForState(AssTextStyleState s) {
    return [
      s.fontName,
      s.fontSize.toStringAsFixed(4),
      s.bold ? '1' : '0',
      s.italic ? '1' : '0',
      s.underline ? '1' : '0',
      s.strikeOut ? '1' : '0',
      s.scaleX.toStringAsFixed(4),
      s.scaleY.toStringAsFixed(4),
      s.spacing.toStringAsFixed(4),
    ].join('|');
  }

  /// Runs [fn] with a temporary [AssAutomationShared] and disposes it afterwards.
  ///
  /// This is useful when you want to avoid manual `dispose()` calls.
  static Future<T> using<T>(Future<T> Function(AssAutomationShared shared) fn) async {
    final shared = AssAutomationShared();
    try {
      return await fn(shared);
    } finally {
      shared.dispose();
    }
  }

  /// Returns a warmed font if present, otherwise `null`.
  ///
  /// Useful inside synchronous callbacks (e.g. `onKaraokeEnv`) where you can't
  /// `await` font initialization.
  AssFont? warmedFontForStyle(String styleName) => _fontsByStyleName[styleName];

  /// Returns a warmed font for an effective style state if present, otherwise `null`.
  ///
  /// This is primarily useful for shape/metrics generation when a line uses
  /// leading override tags like `\fn`, `\fs`, etc.
  AssFont? warmedFontForTextState(AssTextStyleState state) {
    final key = _fontKeyForState(state);
    return _fontsByKey[key];
  }

  /// Returns a cached [AssFont] for [styleName], initializing it if needed.
  Future<AssFont> fontForStyle(Ass ass, String styleName) async {
    final existing = _fontsByStyleName[styleName];
    if (existing != null) return existing;
    final styles = ass.styles;
    if (styles == null) throw StateError('ASS has no styles loaded.');
    final style = styles.getStyleByName(styleName);
    final font = AssFont(
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
    await font.init();
    _fontsByStyleName[styleName] = font;
    // Also cache by full state key so shape expansion can reuse it.
    final stateKey = _fontKeyForState(AssTextStyleState.fromStyle(style));
    _fontsByKey[stateKey] ??= font;
    return font;
  }

  /// Returns a cached [AssFont] for an effective style [state], initializing it if needed.
  ///
  /// This is useful when you need the effective font (after applying override tags)
  /// instead of the base style from the script.
  Future<AssFont> fontForTextState({
    required String styleName,
    required AssTextStyleState state,
  }) async {
    final key = _fontKeyForState(state);
    final existing = _fontsByKey[key];
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
    _fontsByKey[key] = font;
    return font;
  }

  /// Warms up fonts for the provided [styleNames].
  Future<void> warmupFonts(Ass ass, Iterable<String> styleNames) async {
    for (final styleName in styleNames) {
      await fontForStyle(ass, styleName);
    }
  }

  /// Disposes any initialized FreeType resources.
  void dispose() {
    final disposed = HashSet<AssFont>.identity();

    for (final f in _fontsByStyleName.values) {
      if (disposed.add(f)) f.dispose();
    }
    _fontsByStyleName.clear();

    for (final f in _fontsByKey.values) {
      if (disposed.add(f)) f.dispose();
    }
    _fontsByKey.clear();
  }
}

abstract class _AssTemplateEnvBase<TUnit extends AssTimedUnit> {
  /// Utility helpers to build templater-like behaviors (lerp/xf/ftoa).
  final AssTemplateUtil util = AssTemplateUtil();

  /// Shared resources (fonts, caches, etc.) for this flow run.
  final AssAutomationShared shared;

  /// A best-effort base position for the original line.
  ///
  /// This is derived from `\pos`, `\move`, or `PlayRes + \an + margins`.
  /// It is also used as a fallback when metrics are not available.
  final AssBasePos basePos;

  /// The original dialog line (input).
  final AssDialog orgline;

  /// Index of [orgline] within `ass.dialogs!.dialogs`.
  final int sourceIndex;

  /// All generated units for this operation (chars or karaoke blocks).
  final List<TUnit> units;

  /// Current unit being processed.
  final TUnit unit;

  /// The default output line built for this unit. Mutate it and emit it.
  final AssDialog line;

  /// Use to output one or more lines for this unit.
  final AssFxEmitter emit;

  _AssTemplateEnvBase({
    required this.shared,
    required this.basePos,
    required this.orgline,
    required this.sourceIndex,
    required this.units,
    required this.unit,
    required this.line,
    required this.emit,
  });

  /// Emits a dialog line.
  ///
  /// If [dialog] is omitted, emits the current [line] from this environment.
  void addDialog([AssDialog? dialog]) => emit.emit(dialog ?? line);

  /// Convenience getter for the leading override tags of [line].
  ///
  /// This ensures there is a first segment with an override-tags block and
  /// returns it. It's equivalent to calling:
  ///
  /// `final tags = env.unit.ensureLeadingTags(env.line);`
  AssOverrideTags get tags => _ensureLeadingOverrideTags(line.text);

  int get orgStartMs => orgline.startTime.time ?? 0;
  int get orgEndMs => orgline.endTime.time ?? orgStartMs;
  int get orgDurationMs => orgEndMs - orgStartMs;

  int get unitStartMs => unit.absStartMs;
  int get unitEndMs => unit.absEndMs;
  int get unitDurationMs => unitEndMs - unitStartMs;
  int get unitMidMs => unitStartMs + (unitDurationMs ~/ 2);

  /// Midpoint of the current unit relative to the original line start.
  int get unitMidRelMs => unitMidMs - orgStartMs;

  /// Updates `line.startTime/endTime` based on a retime mode.
  void retime(
    AssRetimeMode mode, {
    int startOffsetMs = 0,
    int endOffsetMs = 0,
    int? absStartMs,
    int? absEndMs,
  });

  void relayer(int newLayer) {
    line.layer = newLayer;
  }

  void _mutateTags(AssTagScope scope, void Function(AssOverrideTags tags) fn) {
    switch (scope) {
      case AssTagScope.leading:
        fn(_ensureLeadingOverrideTags(line.text));
        return;
      case AssTagScope.existingSegmentsOnly:
        for (final s in line.text.segments) {
          final t = s.overrideTags;
          if (t == null) continue;
          fn(t);
        }
        return;
      case AssTagScope.allSegments:
        for (final s in line.text.segments) {
          s.overrideTags ??= AssOverrideTags();
          fn(s.overrideTags!);
        }
        return;
    }
  }

  /// Evaluates `\move(...)` at the current unit midpoint and bakes it into `\pos(...)`.
  ///
  /// This is mainly useful inside FBF callbacks, where you want each emitted
  /// frame-window to have a stable `\pos` rather than a live `\move`.
  void bakeMoveToPosAtMid({AssTagScope scope = AssTagScope.leading, bool removeMoveTag = true}) {
    _mutateTags(scope, (t) {
      final mv = t.move;
      if (mv == null) return;
      final relMs = unitMidRelMs;
      final pos = util.movePosAt(relMs, mv, orgDurationMs);
      t.position = pos;
      if (removeMoveTag) t.removeTag('move');
    });
  }

  /// Subdivides the current unit into frame-by-frame sub-units and emits FX lines.
  ///
  /// This is meant to be called inside split callbacks (e.g. `onKaraokeEnv`,
  /// `onCharEnv`, etc.), to further subdivide the unit time range.
  ///
  /// The generated frame lines are based on the current [line] (it is cloned for
  /// each frame window). If [onFrameEnv] is null, each cloned line is emitted as-is.
  void fbf({
    required double fps,
    int stepFrames = 1,
    int layerOffset = 0,
    AssFrameFxEnvCallback? onFrameEnv,
  }) {
    if (fps <= 0) throw ArgumentError('fps must be > 0');
    if (stepFrames <= 0) throw ArgumentError('stepFrames must be >= 1');

    final frameMs = 1000.0 / fps;
    int frameFromMs(int ms) => (ms / frameMs).floor();
    int msFromFrame(int frame) => (frame * frameMs).round();

    final uS = unit.absStartMs;
    final uE = unit.absEndMs;
    if (uE <= uS) return;

    final firstFrame = frameFromMs(uS);
    final lastFrameExclusive = (uE / frameMs).ceil();
    final totalFrames = (lastFrameExclusive - firstFrame).clamp(0, 1 << 30);
    if (totalFrames <= 0) return;

    String baseTagsAssForFrame() {
      final t = _ensureLeadingOverrideTags(line.text);
      final s = t.toString();
      if (s.isEmpty) return '';
      return t.getAss();
    }

    final outUnits = <AssFrameUnit>[];
    final outEmitter = emit.share();

    // Clone base line text once as ASS, so per-frame clones are cheap.
    final baseAssText = line.text.getAss();

    int si = 0;
    for (int f = firstFrame; f < lastFrameExclusive; f += stepFrames) {
      final f2 = (f + stepFrames) > lastFrameExclusive ? lastFrameExclusive : (f + stepFrames);

      var absStart = msFromFrame(f);
      var absEnd = msFromFrame(f2);

      if (absStart < uS) absStart = uS;
      if (absEnd > uE) absEnd = uE;
      if (absEnd <= absStart) continue;

      final mid = absStart + ((absEnd - absStart) ~/ 2);

      final fx = AssDialog(
        layer: line.layer + layerOffset,
        startTime: AssTime(time: absStart),
        endTime: AssTime(time: absEnd),
        styleName: line.styleName,
        name: line.name,
        marginL: line.marginL,
        marginR: line.marginR,
        marginV: line.marginV,
        effect: line.effect,
        text: AssText.parse(baseAssText) ?? AssText(segments: [AssTextSegment(text: baseAssText)]),
        header: line.header,
        commented: false,
        style: line.style,
      );

      outUnits.add(
        AssFrameUnit(
          source: orgline,
          sourceIndex: sourceIndex,
          stepIndex: si,
          frameStart: f,
          frameEnd: f2,
          frameCount: totalFrames,
          fps: fps,
          absStartMs: absStart,
          absEndMs: absEnd,
          midMs: mid,
          baseTagsAss: baseTagsAssForFrame(),
          defaultDialog: fx,
        ),
      );
      si++;
    }

    for (int ui = 0; ui < outUnits.length; ui++) {
      final u = outUnits[ui];
      u.tf = outUnits.length <= 1 ? 0 : ui / (outUnits.length - 1);
    }

    for (final u in outUnits) {
      if (onFrameEnv != null) {
        onFrameEnv!(
          AssFrameTemplateEnv(
            shared: shared,
            basePos: basePos,
            orgline: orgline,
            sourceIndex: sourceIndex,
            units: outUnits,
            unit: u,
            line: u.defaultDialog,
            emit: outEmitter,
          ),
        );
      } else {
        outEmitter.emit(u.defaultDialog);
      }
    }
  }
}

class AssCharTemplateEnv extends _AssTemplateEnvBase<AssCharUnit> {
  AssCharTemplateEnv({
    required super.shared,
    required super.basePos,
    required super.orgline,
    required super.sourceIndex,
    required super.units,
    required super.unit,
    required super.line,
    required super.emit,
  });

  @override
  void retime(
    AssRetimeMode mode, {
    int startOffsetMs = 0,
    int endOffsetMs = 0,
    int? absStartMs,
    int? absEndMs,
  }) {
    final orgS = orgStartMs;
    final orgE = orgEndMs;
    final uS = unit.absStartMs;
    final uE = unit.absEndMs;

    int s;
    int e;
    switch (mode) {
      case AssRetimeMode.abs:
        if (absStartMs == null || absEndMs == null) {
          throw ArgumentError('absStartMs/absEndMs required for AssRetimeMode.abs');
        }
        s = absStartMs;
        e = absEndMs;
        break;
      case AssRetimeMode.delta:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs + startOffsetMs;
        e = ce + endOffsetMs;
        break;
      case AssRetimeMode.clamp:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs.clamp(orgS + startOffsetMs, orgE).toInt();
        e = ce.clamp(orgS, orgE + endOffsetMs).toInt();
        break;
      case AssRetimeMode.preline:
        s = orgS;
        e = orgS;
        break;
      case AssRetimeMode.postline:
        s = orgE;
        e = orgE;
        break;
      case AssRetimeMode.unit:
        s = uS;
        e = uE;
        break;
      case AssRetimeMode.preunit:
        s = uS;
        e = uS;
        break;
      case AssRetimeMode.postunit:
        s = uE;
        e = uE;
        break;
      case AssRetimeMode.start2unit:
        s = orgS;
        e = uS;
        break;
      case AssRetimeMode.unit2end:
        s = uE;
        e = orgE;
        break;
      case AssRetimeMode.line:
      default:
        s = orgS;
        e = orgE;
        break;
    }

    if (mode != AssRetimeMode.abs && mode != AssRetimeMode.delta && mode != AssRetimeMode.clamp) {
      s += startOffsetMs;
      e += endOffsetMs;
    }

    if (e < s) e = s;
    line.startTime.time = s;
    line.endTime.time = e;
  }
}

class AssWordTemplateEnv extends _AssTemplateEnvBase<AssWordUnit> {
  AssWordTemplateEnv({
    required super.shared,
    required super.basePos,
    required super.orgline,
    required super.sourceIndex,
    required super.units,
    required super.unit,
    required super.line,
    required super.emit,
  });

  @override
  void retime(
    AssRetimeMode mode, {
    int startOffsetMs = 0,
    int endOffsetMs = 0,
    int? absStartMs,
    int? absEndMs,
  }) {
    final orgS = orgStartMs;
    final orgE = orgEndMs;
    final uS = unit.absStartMs;
    final uE = unit.absEndMs;

    int s;
    int e;
    switch (mode) {
      case AssRetimeMode.abs:
        if (absStartMs == null || absEndMs == null) {
          throw ArgumentError('absStartMs/absEndMs required for AssRetimeMode.abs');
        }
        s = absStartMs;
        e = absEndMs;
        break;
      case AssRetimeMode.delta:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs + startOffsetMs;
        e = ce + endOffsetMs;
        break;
      case AssRetimeMode.clamp:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs.clamp(orgS + startOffsetMs, orgE).toInt();
        e = ce.clamp(orgS, orgE + endOffsetMs).toInt();
        break;
      case AssRetimeMode.preline:
        s = orgS;
        e = orgS;
        break;
      case AssRetimeMode.postline:
        s = orgE;
        e = orgE;
        break;
      case AssRetimeMode.unit:
        s = uS;
        e = uE;
        break;
      case AssRetimeMode.preunit:
        s = uS;
        e = uS;
        break;
      case AssRetimeMode.postunit:
        s = uE;
        e = uE;
        break;
      case AssRetimeMode.start2unit:
        s = orgS;
        e = uS;
        break;
      case AssRetimeMode.unit2end:
        s = uE;
        e = orgE;
        break;
      // case AssRetimeMode.line:
      default:
        s = orgS;
        e = orgE;
        break;
    }

    if (mode != AssRetimeMode.abs && mode != AssRetimeMode.delta && mode != AssRetimeMode.clamp) {
      s += startOffsetMs;
      e += endOffsetMs;
    }

    if (e < s) e = s;
    line.startTime.time = s;
    line.endTime.time = e;
  }
}

class AssKaraokeTemplateEnv extends _AssTemplateEnvBase<AssKaraokeUnit> {
  AssKaraokeTemplateEnv({
    required super.shared,
    required super.basePos,
    required super.orgline,
    required super.sourceIndex,
    required super.units,
    required super.unit,
    required super.line,
    required super.emit,
  });

  @override
  void retime(
    AssRetimeMode mode, {
    int startOffsetMs = 0,
    int endOffsetMs = 0,
    int? absStartMs,
    int? absEndMs,
  }) {
    final orgS = orgStartMs;
    final orgE = orgEndMs;
    final uS = unit.absStartMs;
    final uE = unit.absEndMs;

    int s;
    int e;
    switch (mode) {
      case AssRetimeMode.abs:
        if (absStartMs == null || absEndMs == null) {
          throw ArgumentError('absStartMs/absEndMs required for AssRetimeMode.abs');
        }
        s = absStartMs;
        e = absEndMs;
        break;
      case AssRetimeMode.delta:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs + startOffsetMs;
        e = ce + endOffsetMs;
        break;
      case AssRetimeMode.clamp:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs.clamp(orgS + startOffsetMs, orgE).toInt();
        e = ce.clamp(orgS, orgE + endOffsetMs).toInt();
        break;
      case AssRetimeMode.preline:
        s = orgS;
        e = orgS;
        break;
      case AssRetimeMode.postline:
        s = orgE;
        e = orgE;
        break;
      case AssRetimeMode.unit:
        s = uS;
        e = uE;
        break;
      case AssRetimeMode.preunit:
        s = uS;
        e = uS;
        break;
      case AssRetimeMode.postunit:
        s = uE;
        e = uE;
        break;
      case AssRetimeMode.start2unit:
        s = orgS;
        e = uS;
        break;
      case AssRetimeMode.unit2end:
        s = uE;
        e = orgE;
        break;
      // case AssRetimeMode.line:
      default:
        s = orgS;
        e = orgE;
        break;
    }

    if (mode != AssRetimeMode.abs && mode != AssRetimeMode.delta && mode != AssRetimeMode.clamp) {
      s += startOffsetMs;
      e += endOffsetMs;
    }

    if (e < s) e = s;
    line.startTime.time = s;
    line.endTime.time = e;
  }
}

/// A frame-by-frame environment (FBF) for templater-like effects.
///
/// This resembles Aegisub's "frame by frame" workflows: the unit time range is
/// computed from `fps` and `stepFrames`, then clamped to the original line.
class AssFrameTemplateEnv extends _AssTemplateEnvBase<AssFrameUnit> {
  AssFrameTemplateEnv({
    required super.shared,
    required super.basePos,
    required super.orgline,
    required super.sourceIndex,
    required super.units,
    required super.unit,
    required super.line,
    required super.emit,
  });

  @override
  void retime(
    AssRetimeMode mode, {
    int startOffsetMs = 0,
    int endOffsetMs = 0,
    int? absStartMs,
    int? absEndMs,
  }) {
    final orgS = orgStartMs;
    final orgE = orgEndMs;
    final uS = unit.absStartMs;
    final uE = unit.absEndMs;

    int s;
    int e;
    switch (mode) {
      case AssRetimeMode.abs:
        if (absStartMs == null || absEndMs == null) {
          throw ArgumentError('absStartMs/absEndMs required for AssRetimeMode.abs');
        }
        s = absStartMs;
        e = absEndMs;
        break;
      case AssRetimeMode.delta:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs + startOffsetMs;
        e = ce + endOffsetMs;
        break;
      case AssRetimeMode.clamp:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs.clamp(orgS + startOffsetMs, orgE).toInt();
        e = ce.clamp(orgS, orgE + endOffsetMs).toInt();
        break;
      case AssRetimeMode.preline:
        s = orgS;
        e = orgS;
        break;
      case AssRetimeMode.postline:
        s = orgE;
        e = orgE;
        break;
      case AssRetimeMode.unit:
        s = uS;
        e = uE;
        break;
      case AssRetimeMode.preunit:
        s = uS;
        e = uS;
        break;
      case AssRetimeMode.postunit:
        s = uE;
        e = uE;
        break;
      case AssRetimeMode.start2unit:
        s = orgS;
        e = uS;
        break;
      case AssRetimeMode.unit2end:
        s = uE;
        e = orgE;
        break;
      case AssRetimeMode.line:
      // default:
        s = orgS;
        e = orgE;
        break;
    }

    if (mode != AssRetimeMode.abs && mode != AssRetimeMode.delta && mode != AssRetimeMode.clamp) {
      s += startOffsetMs;
      e += endOffsetMs;
    }

    if (e < s) e = s;
    line.startTime.time = s;
    line.endTime.time = e;
  }
}

/// Environment for shape-expansion (text → `\p` drawing) operations.
///
/// A shape-expand unit represents the whole source dialog, and `env.line` is the
/// default output dialog containing the expanded drawing. You can mutate the
/// generated [AssPaths] via `env.unit.paths` before emitting the line.
class AssShapeExpandTemplateEnv extends _AssTemplateEnvBase<AssShapeExpandUnit> {
  AssShapeExpandTemplateEnv({
    required super.shared,
    required super.basePos,
    required super.orgline,
    required super.sourceIndex,
    required super.units,
    required super.unit,
    required super.line,
    required super.emit,
  });

  /// Updates `line.text` to use the current `unit.paths` as the `\p` drawing.
  ///
  /// This is useful if you mutate `env.unit.paths` and want the emitted dialog to
  /// reflect the updated shape.
  void syncLineTextFromPaths({AssOverrideTags? overrideTags}) {
    final t = overrideTags ?? tags;
    line.text = AssText(
      segments: [
        AssTextSegment(
          text: unit.paths.toString(),
          overrideTags: t,
        ),
      ],
    );
  }

  @override
  void retime(
    AssRetimeMode mode, {
    int startOffsetMs = 0,
    int endOffsetMs = 0,
    int? absStartMs,
    int? absEndMs,
  }) {
    final orgS = orgStartMs;
    final orgE = orgEndMs;
    final uS = unit.absStartMs;
    final uE = unit.absEndMs;

    int s;
    int e;
    switch (mode) {
      case AssRetimeMode.abs:
        if (absStartMs == null || absEndMs == null) {
          throw ArgumentError('absStartMs/absEndMs required for AssRetimeMode.abs');
        }
        s = absStartMs;
        e = absEndMs;
        break;
      case AssRetimeMode.delta:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs + startOffsetMs;
        e = ce + endOffsetMs;
        break;
      case AssRetimeMode.clamp:
        final cs = line.startTime.time ?? orgS;
        final ce = line.endTime.time ?? orgE;
        s = cs.clamp(orgS + startOffsetMs, orgE).toInt();
        e = ce.clamp(orgS, orgE + endOffsetMs).toInt();
        break;
      case AssRetimeMode.preline:
        s = orgS;
        e = orgS;
        break;
      case AssRetimeMode.postline:
        s = orgE;
        e = orgE;
        break;
      case AssRetimeMode.unit:
        s = uS;
        e = uE;
        break;
      case AssRetimeMode.preunit:
        s = uS;
        e = uS;
        break;
      case AssRetimeMode.postunit:
        s = uE;
        e = uE;
        break;
      case AssRetimeMode.start2unit:
        s = orgS;
        e = uS;
        break;
      case AssRetimeMode.unit2end:
        s = uE;
        e = orgE;
        break;
      case AssRetimeMode.line:
      // default:
        s = orgS;
        e = orgE;
        break;
    }

    if (mode != AssRetimeMode.abs && mode != AssRetimeMode.delta && mode != AssRetimeMode.clamp) {
      s += startOffsetMs;
      e += endOffsetMs;
    }

    if (e < s) e = s;
    line.startTime.time = s;
    line.endTime.time = e;
  }
}

AssOverrideTags _ensureLeadingOverrideTags(AssText text) {
  if (text.segments.isEmpty) {
    text.segments.add(AssTextSegment(text: '', overrideTags: AssOverrideTags()));
  }
  final first = text.segments.first;
  first.overrideTags ??= AssOverrideTags();
  return first.overrideTags!;
}

String _escapeAssText(String s) => s.replaceAll('{', r'\{').replaceAll('}', r'\}');

String _normalizeTextForFx(String s) => s
    .replaceAll(r'\N', '')
    .replaceAll(r'\n', '')
    .replaceAll('\n', '')
    .replaceAll(r'\h', ' ');

List<String> _splitAssLineBreaks(String s) {
  // Splits on \N, \n and literal newlines.
  final out = <String>[];
  final buf = StringBuffer();

  int i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == '\n') {
      out.add(buf.toString());
      buf.clear();
      i++;
      continue;
    }
    if (ch == '\\' && i + 1 < s.length) {
      final n = s[i + 1];
      if (n == 'N' || n == 'n') {
        out.add(buf.toString());
        buf.clear();
        i += 2;
        continue;
      }
    }
    buf.write(ch);
    i++;
  }
  out.add(buf.toString());
  return out;
}

AssOverrideTags? _leadingOverrideTagsOrNull(AssDialog dialog) {
  for (final seg in dialog.text.segments) {
    final t = seg.overrideTags;
    if (t != null) return t;
  }
  return null;
}

double? _parseTagDouble(AssOverrideTags? tags, String name) {
  if (tags == null) return null;
  final raw = tags.getTagValue(name);
  if (raw == null) return null;
  return double.tryParse(raw.trim());
}

int? _parseTagInt(AssOverrideTags? tags, String name) {
  if (tags == null) return null;
  final raw = tags.getTagValue(name);
  if (raw == null) return null;
  return int.tryParse(raw.trim());
}

void _reallocateAssPathsByAn({
  required AssPaths paths,
  required int an,
}) {
  final bb = paths.boundingBox();
  final w = bb.width;
  final h = bb.height;

  double ax;
  switch (an) {
    case 1:
    case 4:
    case 7:
      ax = bb.left;
      break;
    case 2:
    case 5:
    case 8:
      ax = bb.left + w * 0.5;
      break;
    case 3:
    case 6:
    case 9:
      ax = bb.right;
      break;
    default:
      ax = bb.left + w * 0.5;
      break;
  }

  double ay;
  switch (an) {
    case 7:
    case 8:
    case 9:
      ay = bb.top;
      break;
    case 4:
    case 5:
    case 6:
      ay = bb.top + h * 0.5;
      break;
    case 1:
    case 2:
    case 3:
      ay = bb.bottom;
      break;
    default:
      ay = bb.bottom;
      break;
  }

  paths.move(-ax, -ay);
}

void _expandAssPathsAppearance({
  required AssPaths paths,
  required int an,
  required AssTagPosition pos,
  required AssTagPosition org,
  required double fax,
  required double fay,
  required double frx,
  required double fry,
  required double frz,
  required double scaleX,
  required double scaleY,
  required double xshad,
  required double yshad,
  required double heightUnscaled,
}) {
  const dist = 312.5;

  final asc = switch (an) {
    1 || 2 || 3 => heightUnscaled,
    4 || 5 || 6 => heightUnscaled * 0.5,
    _ => 0.0,
  };

  final frxRad = frx * math.pi / 180.0;
  final fryRad = fry * math.pi / 180.0;
  final frzRad = frz * math.pi / 180.0;

  final sxr = -math.sin(frxRad);
  final cxr = math.cos(frxRad);
  final syr = math.sin(fryRad);
  final cyr = math.cos(fryRad);
  final szr = -math.sin(frzRad);
  final czr = math.cos(frzRad);

  // Shear scaling compensation.
  final effSx = scaleX == 0 ? 1.0 : scaleX;
  final effSy = scaleY == 0 ? 1.0 : scaleY;
  final fax2 = fax * (effSx / effSy);
  final fay2 = fay * (effSy / effSx);

  final x1 = <double>[
    1.0,
    fax2,
    pos.x - org.x + xshad + asc * fax2,
  ];
  final y1 = <double>[
    fay2,
    1.0,
    pos.y - org.y + yshad,
  ];

  final offsX = org.x - pos.x - xshad;
  final offsY = org.y - pos.y - yshad;

  final a = List<double>.filled(3, 0);
  final b = List<double>.filled(3, 0);
  final c = List<double>.filled(3, 0);

  for (int i = 0; i < 3; i++) {
    final x2 = x1[i] * czr - y1[i] * szr;
    final y2 = x1[i] * szr + y1[i] * czr;

    final y3 = y2 * cxr;
    final z3 = y2 * sxr;

    final x4 = x2 * cyr - z3 * syr;
    double z4 = x2 * syr + z3 * cyr;
    if (i == 2) z4 += dist;

    a[i] = z4 * offsX + x4 * dist;
    b[i] = z4 * offsY + y3 * dist;
    c[i] = z4;
  }

  paths.mapPoints((x, y) {
    final spx = x * effSx;
    final spy = y * effSy;

    final xx = (a[0] * spx) + (a[1] * spy) + a[2];
    final yy = (b[0] * spx) + (b[1] * spy) + b[2];
    final zz = (c[0] * spx) + (c[1] * spy) + c[2];

    final w = 1.0 / math.max(zz, 0.1);
    return (xx * w, yy * w);
  });
}

int _msToAssCsFloor(int ms) => ms ~/ 10;
int _msToAssCsRound(int ms) => (ms + 5) ~/ 10;
int _assCsToMs(int cs) => cs * 10;

String _baseTagsAssWithoutKaraoke(AssDialog dialog) {
  final firstWithTags = dialog.text.segments.firstWhere(
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

bool _dialogHasAnyKaraokeTags(AssDialog dialog) {
  for (final seg in dialog.text.segments) {
    final tags = seg.overrideTags;
    if (tags == null) continue;
    if (tags.getTagValue('k') != null) return true;
    if (tags.getTagValue('kf') != null) return true;
    if (tags.getTagValue('ko') != null) return true;
    if (tags.getTagValue('kt') != null) return true;
  }
  return false;
}

int _effectiveAlignForDialog(AssDialog dialog) {
  for (final seg in dialog.text.segments) {
    final tags = seg.overrideTags;
    if (tags == null) continue;
    final raw = tags.getTagValue('an');
    if (raw == null) continue;
    final v = int.tryParse(raw.trim());
    if (v != null && v >= 1 && v <= 9) return v;
  }
  final v = dialog.style.alignment;
  if (v >= 1 && v <= 9) return v;
  return 2;
}

double _effectiveMarginL(AssDialog d) => d.marginL > 0 ? d.marginL : d.style.marginL;
double _effectiveMarginR(AssDialog d) => d.marginR > 0 ? d.marginR : d.style.marginR;
double _effectiveMarginV(AssDialog d) => d.marginV > 0 ? d.marginV : d.style.marginV;

/// Best-effort base `\pos(x,y)` for a dialog.
///
/// Order of precedence:
/// 1) explicit `\pos` on any segment
/// 2) `\move(x1,y1,...)` on any segment (uses the start point)
/// 3) fallback derived from script resolution, alignment and margins (karaskel-like)
AssBasePos _effectiveBasePosForDialog(AssDialog dialog) {
  for (final seg in dialog.text.segments) {
    final t = seg.overrideTags;
    if (t == null) continue;
    final p = t.position;
    if (p != null) return AssBasePos(pos: p, source: AssBasePosSource.pos);
    final mv = t.move;
    if (mv != null) {
      return AssBasePos(
        pos: AssTagPosition(mv.x1, mv.y1),
        source: AssBasePosSource.move,
      );
    }
  }

  final header = dialog.header;
  final resX = header.playResX.toDouble();
  final resY = header.playResY.toDouble();
  final align = _effectiveAlignForDialog(dialog);
  final mL = _effectiveMarginL(dialog);
  final mR = _effectiveMarginR(dialog);
  final mV = _effectiveMarginV(dialog);

  final double x;
  switch (align) {
    case 1:
    case 4:
    case 7:
      x = mL;
      break;
    case 2:
    case 5:
    case 8:
      x = (resX - mR + mL) / 2;
      break;
    case 3:
    case 6:
    case 9:
    default:
      x = resX - mR;
      break;
  }

  final double y;
  switch (align) {
    case 7:
    case 8:
    case 9:
      y = mV;
      break;
    case 4:
    case 5:
    case 6:
      y = resY / 2;
      break;
    case 1:
    case 2:
    case 3:
    default:
      y = resY - mV;
      break;
  }

  return AssBasePos(pos: AssTagPosition(x, y), source: AssBasePosSource.derived);
}

double _breakLeftForWidth({
  required double breakWidth,
  required int align,
  required double resX,
  required double marginL,
  required double marginR,
}) {
  switch (align) {
    case 1:
    case 4:
    case 7:
      return marginL;
    case 2:
    case 5:
    case 8:
      return (resX - marginL - marginR - breakWidth) / 2 + marginL;
    case 3:
    case 6:
    case 9:
      return resX - marginR - breakWidth;
  }
  return marginL;
}

class _AssBreakLayout {
  final double left;
  final double center;
  final double right;
  final double top;
  final double middle;
  final double bottom;
  final double width;
  final double height;

  const _AssBreakLayout({
    required this.left,
    required this.center,
    required this.right,
    required this.top,
    required this.middle,
    required this.bottom,
    required this.width,
    required this.height,
  });
}

String _ftoa(num n, {int digits = 2}) {
  if (digits < 0) digits = 0;
  if (n == n.roundToDouble()) return n.toString();
  var s = n.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

void _applyEffectiveStyleOverrides({
  required AssOverrideTags tags,
  required AssStyle base,
  required Object? effectiveStyle,
}) {
  if (effectiveStyle == null) return;
  final dynamic st = effectiveStyle;

  // Font name
  try {
    final String fn = st.fontName as String;
    if (fn.isNotEmpty && fn != base.fontName) {
      tags.replaceTag('fn', fn);
    }
  } catch (_) {}

  // Font size
  try {
    final num fs = st.fontSize as num;
    if (fs != base.fontSize) {
      tags.replaceTag('fs', _ftoa(fs));
    }
  } catch (_) {}

  // Bold/italic/underline/strikeout
  try {
    final bool b = st.bold as bool;
    if (b != base.bold) tags.replaceTag('b', b ? '1' : '0');
  } catch (_) {}
  try {
    final bool it = st.italic as bool;
    if (it != base.italic) tags.replaceTag('i', it ? '1' : '0');
  } catch (_) {}
  try {
    final bool u = st.underline as bool;
    if (u != base.underline) tags.replaceTag('u', u ? '1' : '0');
  } catch (_) {}
  try {
    final bool so = st.strikeOut as bool;
    if (so != base.strikeOut) tags.replaceTag('s', so ? '1' : '0');
  } catch (_) {}

  // Scale + spacing
  try {
    final num sx = st.scaleX as num;
    if (sx != base.scaleX) tags.replaceTag('fscx', _ftoa(sx));
  } catch (_) {}
  try {
    final num sy = st.scaleY as num;
    if (sy != base.scaleY) tags.replaceTag('fscy', _ftoa(sy));
  } catch (_) {}
  try {
    final num sp = st.spacing as num;
    if (sp != base.spacing) tags.replaceTag('fsp', _ftoa(sp));
  } catch (_) {}
}

class _AssKaraokeRawBlock {
  final String text; // normalized for FX (no line breaks)
  final String? karaokeTag;
  final int durMs;
  final int startOffsetMs;
  final int endOffsetMs;
  final int absStartMs;
  final int absEndMs;
  final Object? effectiveStyle;

  // Fixed metrics (may be null).
  final double? width;
  final double? height;
  final String? prespace;
  final String? postspace;
  final String? textSpaceStripped;
  final double? prespaceWidth;
  final double? postspaceWidth;
  final double? coreWidth;
  final int? lineIndex;
  final double? x;
  final double? left;
  final double? center;
  final double? right;

  const _AssKaraokeRawBlock({
    required this.text,
    required this.karaokeTag,
    required this.durMs,
    required this.startOffsetMs,
    required this.endOffsetMs,
    required this.absStartMs,
    required this.absEndMs,
    required this.effectiveStyle,
    required this.width,
    required this.height,
    required this.prespace,
    required this.postspace,
    required this.textSpaceStripped,
    required this.prespaceWidth,
    required this.postspaceWidth,
    required this.coreWidth,
    required this.lineIndex,
    required this.x,
    required this.left,
    required this.center,
    required this.right,
  });
}

Future<Map<int, _AssBreakLayout>> _computeBreakLayoutForDialog(AssDialog dialog) async {
  final header = dialog.header;
  if (header.playResX <= 0 || header.playResY <= 0) return const {};
  final resX = header.playResX.toDouble();
  final resY = header.playResY.toDouble();
  final line = dialog.line;
  if (line == null) return const {};
  final breaks = await line.lineBreaks(useTextData: true);
  final align = _effectiveAlignForDialog(dialog);
  final mL = _effectiveMarginL(dialog);
  final mR = _effectiveMarginR(dialog);
  final mV = _effectiveMarginV(dialog);

  // If the line has an explicit \pos or \move, use it as anchor.
  double? anchorX;
  double? anchorY;
  for (final seg in dialog.text.segments) {
    final t = seg.overrideTags;
    if (t == null) continue;
    final p = t.position;
    if (p != null) {
      anchorX = p.x;
      anchorY = p.y;
      break;
    }
    final mv = t.move;
    if (mv != null) {
      anchorX = mv.x1;
      anchorY = mv.y1;
      break;
    }
  }

  double totalH = 0;
  for (final br in breaks) {
    totalH += br.height ?? 0.0;
  }

  // Compute baseTop for the whole multi-line block.
  double baseTop;
  if (anchorY != null) {
    switch (align) {
      case 7:
      case 8:
      case 9:
        baseTop = anchorY;
        break;
      case 4:
      case 5:
      case 6:
        baseTop = anchorY - (totalH * 0.5);
        break;
      case 1:
      case 2:
      case 3:
      default:
        baseTop = anchorY - totalH;
        break;
    }
  } else {
    switch (align) {
      case 7:
      case 8:
      case 9:
        baseTop = mV;
        break;
      case 4:
      case 5:
      case 6:
        baseTop = (resY - (mV * 2) - totalH) / 2 + mV;
        break;
      case 1:
      case 2:
      case 3:
      default:
        baseTop = resY - mV - totalH;
        break;
    }
  }

  final out = <int, _AssBreakLayout>{};
  double yCursor = 0;
  for (final br in breaks) {
    final idx = br.index ?? 0;
    final w = br.width ?? 0.0;
    final h = br.height ?? 0.0;

    double left;
    if (anchorX != null) {
      switch (align) {
        case 1:
        case 4:
        case 7:
          left = anchorX;
          break;
        case 2:
        case 5:
        case 8:
          left = anchorX - (w * 0.5);
          break;
        case 3:
        case 6:
        case 9:
        default:
          left = anchorX - w;
          break;
      }
    } else {
      left = _breakLeftForWidth(breakWidth: w, align: align, resX: resX, marginL: mL, marginR: mR);
    }

    final top = baseTop + yCursor;
    final bottom = top + h;
    final middle = top + (h * 0.5);
    out[idx] = _AssBreakLayout(
      left: left,
      center: left + (w * 0.5),
      right: left + w,
      top: top,
      middle: middle,
      bottom: bottom,
      width: w,
      height: h,
    );
    yCursor += h;
  }
  return out;
}

class AssCharUnit implements AssTimedUnit {
  final AssDialog source;
  final int sourceIndex;
  final int charIndex;
  final String char;
  final bool isSpace;
  final int absStartMs;
  final int absEndMs;
  final String baseTagsAss;
  final AssDialog defaultDialog;
  final double? width;
  final double? height;
  final int? lineIndex;
  final double? x;
  final double? left;
  final double? center;
  final double? right;
  /// Absolute (script) X of this char, when layout info is available.
  final double? absX;
  /// Absolute left edge of this char.
  final double? absLeft;
  /// Absolute center of this char.
  final double? absCenter;
  /// Absolute right edge of this char.
  final double? absRight;
  /// Absolute top of the visual line-break this char belongs to.
  final double? absTop;
  /// Absolute middle of the visual line-break this char belongs to.
  final double? absMiddle;
  /// Absolute bottom of the visual line-break this char belongs to.
  final double? absBottom;
  /// Effective style state for this unit, when metrics are available.
  final Object? effectiveStyle;
  double? xf;
  double? tf;

  AssCharUnit({
    required this.source,
    required this.sourceIndex,
    required this.charIndex,
    required this.char,
    required this.isSpace,
    required this.absStartMs,
    required this.absEndMs,
    required this.baseTagsAss,
    required this.defaultDialog,
    this.width,
    this.height,
    this.lineIndex,
    this.x,
    this.left,
    this.center,
    this.right,
    this.absX,
    this.absLeft,
    this.absCenter,
    this.absRight,
    this.absTop,
    this.absMiddle,
    this.absBottom,
    this.effectiveStyle,
  });

  AssOverrideTags ensureLeadingTags(AssDialog dialog) => _ensureLeadingOverrideTags(dialog.text);

  /// Convenience for `\pos(x,y)` usage.
  ///
  /// After `ensureMetrics()` (or when fallbacks are applied), these are expected
  /// to be non-null.
  double? get absPosX => absCenter ?? absX;
  double? get absPosY => absMiddle ?? absTop;
}

/// A single highlight window within a karaoke unit.
///
/// This exists mainly to support multi-highlight workflows where additional
/// timing blocks are encoded as `#`/`＃` prefixed "dummy" syllables.
class AssKaraokeHighlight {
  /// Relative start offset (ms) from the line start.
  final int startOffsetMs;

  /// Relative end offset (ms) from the line start.
  final int endOffsetMs;

  /// Karaoke tag kind: `k`, `kf`, `ko` (or null when derived).
  final String? karaokeTag;

  const AssKaraokeHighlight({
    required this.startOffsetMs,
    required this.endOffsetMs,
    required this.karaokeTag,
  });

  int get durationMs => endOffsetMs - startOffsetMs;
}

class AssKaraokeUnit implements AssTimedUnit {
  final AssDialog source;
  final int sourceIndex;
  final int blockIndex;
  final String text;
  final String? karaokeTag;
  final int durMs;
  final int absStartMs;
  final int absEndMs;
  final List<AssKaraokeHighlight> highlights;
  final String baseTagsAss;
  final AssDialog defaultDialog;
  final double? width;
  final double? height;
  /// Leading spaces (ASCII spaces/tabs) of this block.
  final String? prespace;
  /// Trailing spaces (ASCII spaces/tabs) of this block.
  final String? postspace;
  /// Core text without leading/trailing ASCII spaces/tabs.
  final String? textSpaceStripped;
  /// Width of [prespace] in script pixels.
  final double? prespaceWidth;
  /// Width of [postspace] in script pixels.
  final double? postspaceWidth;
  /// Width of [textSpaceStripped] in script pixels.
  final double? coreWidth;
  final int? lineIndex;
  final double? x;
  final double? left;
  final double? center;
  final double? right;
  /// Absolute (script) X of this block, when layout info is available.
  final double? absX;
  /// Absolute left edge of the core text (excludes prespacewidth).
  final double? absLeft;
  /// Absolute center of the core text.
  final double? absCenter;
  /// Absolute right edge of the core text.
  final double? absRight;
  /// Absolute top of the visual line-break this block belongs to.
  final double? absTop;
  /// Absolute middle of the visual line-break this block belongs to.
  final double? absMiddle;
  /// Absolute bottom of the visual line-break this block belongs to.
  final double? absBottom;
  /// Effective style state for this unit, when metrics are available.
  final Object? effectiveStyle;
  double? xf;
  double? tf;

  AssKaraokeUnit({
    required this.source,
    required this.sourceIndex,
    required this.blockIndex,
    required this.text,
    required this.karaokeTag,
    required this.durMs,
    required this.absStartMs,
    required this.absEndMs,
    required this.highlights,
    required this.baseTagsAss,
    required this.defaultDialog,
    this.width,
    this.height,
    this.prespace,
    this.postspace,
    this.textSpaceStripped,
    this.prespaceWidth,
    this.postspaceWidth,
    this.coreWidth,
    this.lineIndex,
    this.x,
    this.left,
    this.center,
    this.right,
    this.absX,
    this.absLeft,
    this.absCenter,
    this.absRight,
    this.absTop,
    this.absMiddle,
    this.absBottom,
    this.effectiveStyle,
  });

  AssOverrideTags ensureLeadingTags(AssDialog dialog) => _ensureLeadingOverrideTags(dialog.text);

  /// Convenience for `\pos(x,y)` usage.
  ///
  /// After `ensureMetrics()` (or when fallbacks are applied), these are expected
  /// to be non-null.
  double? get absPosX => absCenter ?? absX;
  double? get absPosY => absMiddle ?? absTop;

  /// Convenience: the first highlight window (always present).
  AssKaraokeHighlight get highlight => highlights.first;
}

/// A unit representing a (clamped) frame interval within a dialogue line.
///
/// `frameStart`/`frameEnd` are integer indices derived from `fps`. The emitted
/// time range is `[absStartMs, absEndMs]` clamped to the original line.
class AssFrameUnit implements AssTimedUnit {
  final AssDialog source;
  final int sourceIndex;
  final int stepIndex;

  /// First frame index of this unit (inclusive).
  final int frameStart;

  /// Last frame index of this unit (exclusive).
  final int frameEnd;

  /// Total number of frames considered for the original line.
  final int frameCount;

  /// `fps` used to compute frame ranges.
  final double fps;

  final int absStartMs;
  final int absEndMs;

  /// Timestamp at the middle of this unit (ms).
  final int midMs;

  final String baseTagsAss;
  final AssDialog defaultDialog;

  /// Normalized time fraction 0..1 across generated units.
  double? tf;

  AssFrameUnit({
    required this.source,
    required this.sourceIndex,
    required this.stepIndex,
    required this.frameStart,
    required this.frameEnd,
    required this.frameCount,
    required this.fps,
    required this.absStartMs,
    required this.absEndMs,
    required this.midMs,
    required this.baseTagsAss,
    required this.defaultDialog,
  });

  AssOverrideTags ensureLeadingTags(AssDialog dialog) => _ensureLeadingOverrideTags(dialog.text);
}

class AssWordUnit implements AssTimedUnit {
  final AssDialog source;
  final int sourceIndex;
  final int wordIndex;
  final String text;
  final bool isSpace;
  @override
  final int absStartMs;
  @override
  final int absEndMs;
  final String baseTagsAss;
  final AssDialog defaultDialog;
  final double? width;
  final double? height;
  final int? lineIndex;
  final double? x;
  final double? left;
  final double? center;
  final double? right;
  final double? absX;
  final double? absLeft;
  final double? absCenter;
  final double? absRight;
  final double? absTop;
  final double? absMiddle;
  final double? absBottom;
  final Object? effectiveStyle;
  double? xf;
  double? tf;

  AssWordUnit({
    required this.source,
    required this.sourceIndex,
    required this.wordIndex,
    required this.text,
    required this.isSpace,
    required this.absStartMs,
    required this.absEndMs,
    required this.baseTagsAss,
    required this.defaultDialog,
    this.width,
    this.height,
    this.lineIndex,
    this.x,
    this.left,
    this.center,
    this.right,
    this.absX,
    this.absLeft,
    this.absCenter,
    this.absRight,
    this.absTop,
    this.absMiddle,
    this.absBottom,
    this.effectiveStyle,
  });

  AssOverrideTags ensureLeadingTags(AssDialog dialog) => _ensureLeadingOverrideTags(dialog.text);

  double? get absPosX => absCenter ?? absX;
  double? get absPosY => absMiddle ?? absTop;
}

/// A unit representing a whole dialog expanded into a vector drawing (`\p1`).
class AssShapeExpandUnit implements AssTimedUnit {
  final AssDialog source;
  final int sourceIndex;
  final int segmentIndex;
  final int segmentLineIndex;

  @override
  final int absStartMs;
  @override
  final int absEndMs;

  /// Effective alignment used for anchor reallocation and transforms.
  final int an;

  /// Effective `\pos` for this unit (explicit/derived).
  final AssTagPosition pos;

  /// Effective `\org` for this unit (defaults to [pos]).
  final AssTagPosition org;

  /// Normalized plain text used to generate the glyph outlines.
  final String text;

  /// Parsed vector paths for the generated glyph outlines.
  ///
  /// You can mutate these before emitting the line.
  final AssPaths paths;

  /// Default output dialog produced by the operation.
  final AssDialog defaultDialog;

  AssShapeExpandUnit({
    required this.source,
    required this.sourceIndex,
    required this.segmentIndex,
    required this.segmentLineIndex,
    required this.absStartMs,
    required this.absEndMs,
    required this.an,
    required this.pos,
    required this.org,
    required this.text,
    required this.paths,
    required this.defaultDialog,
  });
}

class AssAutomation {
  /// The ASS document being automated.
  final Ass ass;
  AssAutomation(this.ass);

  /// Starts a new automation flow.
  ///
  /// All automation flows are async (use `await flow().run()`).
  ///
  /// If [shared] is not provided, the flow owns an internal [AssAutomationShared]
  /// instance and disposes it automatically at the end of [AssAutomationFlow.run].
  AssAutomationFlow flow({AssAutomationShared? shared}) =>
      AssAutomationFlow._(ass, const [], shared ?? AssAutomationShared(), ownsShared: shared == null);

  @Deprecated('Use flow() (all automation is async).')
  AssAutomationFlow flowAsync() => flow();

  /// Helper to create a new dialog referencing the current ASS header/styles.
  ///
  /// `textAss` is the full ASS text field (may include override tags and `\N`).
  AssDialog createDialog({
    required int startMs,
    required int endMs,
    required String styleName,
    required String textAss,
    int layer = 0,
    String name = '',
    double? marginL,
    double? marginR,
    double? marginV,
    String effect = '',
    bool commented = false,
  }) {
    if (startMs < 0 || endMs < 0 || endMs < startMs) {
      throw ArgumentError('Invalid time range: startMs=$startMs endMs=$endMs');
    }
    final header = ass.header;
    final styles = ass.styles;
    if (header == null) throw StateError('ASS has no header loaded.');
    if (styles == null) throw StateError('ASS has no styles loaded.');
    final style = styles.getStyleByName(styleName);
    return AssDialog(
      layer: layer,
      startTime: AssTime(time: startMs),
      endTime: AssTime(time: endMs),
      styleName: styleName,
      name: name,
      marginL: marginL ?? style.marginL,
      marginR: marginR ?? style.marginR,
      marginV: marginV ?? style.marginV,
      effect: effect,
      text: AssText.parse(textAss) ?? AssText(segments: [AssTextSegment(text: textAss)]),
      header: header,
      commented: commented,
      style: style,
    );
  }
}

/// Automation flow (async).
///
/// Use this when you want to measure text (`ensureMetrics`) or when you need to
/// run metric-aware FX generation.
class AssAutomationFlow {
  final Ass _ass;
  final List<AssAutomationOp> _ops;
  final AssAutomationShared _shared;
  final bool _ownsShared;

  const AssAutomationFlow._(this._ass, this._ops, this._shared, {required bool ownsShared}) : _ownsShared = ownsShared;

  AssAutomationFlow _add(AssAutomationOp op) => AssAutomationFlow._(_ass, [..._ops, op], _shared, ownsShared: _ownsShared);

  AssAutomationFlow selectAll({bool includeComments = false}) => _add(_AssSelectAllOp(includeComments: includeComments));

  AssAutomationFlow where(AssDialogPredicate predicate) => _add(_AssWhereOp(predicate));

  AssAutomationFlow whereKaraoke() => _add(const _AssWhereKaraokeOp());

  AssAutomationFlow whereStyle(String styleName) => where((d, _) => d.styleName == styleName);

  /// Filters by the ASS "Name" field (often used as Actor).
  AssAutomationFlow whereActor(String actor) => where((d, _) => d.name == actor);

  AssAutomationFlow whereEffect(String effect) => where((d, _) => d.effect == effect);

  /// Ensures `dialog.line` is populated with measured segment metrics.
  ///
  /// This calls `await ass.dialogs?.extend(useTextData)`.
  AssAutomationFlow ensureMetrics({bool useTextData = true}) => _add(_AssEnsureMetricsOp(useTextData: useTextData));

  /// Warms up FreeType fonts for the current selection.
  ///
  /// This is useful because `splitKaraokeFx` / `splitCharsFx` callbacks
  /// are synchronous, so you generally cannot `await AssFont.init()` inside them.
  ///
  /// Notes:
  /// - Requires `ass.styles` to be present.
  /// - If no selection exists yet, it falls back to all dialogs.
  AssAutomationFlow warmupFonts({bool includeComments = false}) => _add(_AssWarmupFontsOp(includeComments: includeComments));

  AssAutomationFlow insertAt(int index, List<AssDialog> dialogs) => _add(_AssInsertAtOp(index, dialogs));

  AssAutomationFlow append(List<AssDialog> dialogs) => _add(_AssAppendOp(dialogs));

  /// Convenience wrapper over [insertAt] for inserting a single dialog.
  AssAutomationFlow insertDialogAt(int index, AssDialog dialog) => insertAt(index, [dialog]);

  /// Convenience wrapper over [append] for appending a single dialog.
  AssAutomationFlow appendDialog(AssDialog dialog) => append([dialog]);

  /// Convenience wrapper over [insertAt] for inserting a single dialog at the start.
  AssAutomationFlow prependDialog(AssDialog dialog) => insertAt(0, [dialog]);

  AssAutomationFlow removeSelected() => _add(const _AssRemoveSelectedOp());

  AssAutomationFlow sortByTime({bool stable = true}) => _add(_AssSortByTimeOp(stable: stable));

  AssAutomationFlow commentSelected(bool commented) => _add(_AssCommentSelectedOp(commented));

  AssAutomationFlow setStyle(String styleName) => _add(_AssSetStyleOp(styleName));

  AssAutomationFlow setEffect(String effect) => _add(_AssSetEffectOp(effect));

  AssAutomationFlow setLayer(int layer) => _add(_AssSetLayerOp(layer));

  /// Removes dialogs with `Effect=<effect>` (default: `fx`).
  ///
  /// If [onlySelected] is true, only the current selection is considered.
  AssAutomationFlow removeFx({
    String effect = 'fx',
    bool includeCommented = false,
    bool onlySelected = false,
  }) =>
      _add(_AssRemoveFxOp(effect: effect, includeCommented: includeCommented, onlySelected: onlySelected));

  /// Duplicates each selected dialog and inserts the copies.
  AssAutomationFlow duplicateSelected({
    int times = 1,
    int layerOffset = 0,
    int timeOffsetMs = 0,
    AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource(),
  }) =>
      _add(
        _AssDuplicateSelectedOp(
          times: times,
          layerOffset: layerOffset,
          timeOffsetMs: timeOffsetMs,
          outputStrategy: outputStrategy,
        ),
      );

  /// Copies selected dialogs into a specific [layer] (keeping originals).
  AssAutomationFlow copyToLayer({
    required int layer,
    int timeOffsetMs = 0,
    AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource(),
  }) =>
      _add(
        _AssCopyToLayerOp(
          layer: layer,
          timeOffsetMs: timeOffsetMs,
          outputStrategy: outputStrategy,
        ),
      );

  AssAutomationFlow mapDialogs(AssDialogMapper mapper) => _add(_AssMapDialogsOp(mapper));

  AssAutomationFlow shiftTime(int deltaMs, {bool clampAtZero = true}) =>
      _add(_AssShiftTimeOp(deltaMs, clampAtZero: clampAtZero));

  AssAutomationFlow mapText(AssTextMapper mapper) => _add(_AssMapTextOp(mapper));

  AssAutomationFlow replaceText(RegExp pattern, String replacement) => mapText((text, _, __) => text.replaceAll(pattern, replacement));

  AssAutomationFlow ensureLeadingTags() => _add(const _AssEnsureLeadingTagsOp());

  AssAutomationFlow setTag(String tagName, String value, {AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssSetTagOp(tagName, value, scope: scope));

  AssAutomationFlow removeTag(String tagName, {AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssRemoveTagOp(tagName, scope: scope));

  /// Typed tag helpers (preferred over [setTag]/[removeTag] when possible).
  AssAutomationFlow setAlignment(int an, {AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssSetAlignmentOp(an, scope: scope));

  AssAutomationFlow setPos(AssTagPosition pos, {AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssSetPosOp(pos, scope: scope));

  AssAutomationFlow removePos({AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssRemovePosOp(scope: scope));

  AssAutomationFlow setOrg(AssTagPosition org, {AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssSetOrgOp(org, scope: scope));

  AssAutomationFlow setMove(AssMove mv, {AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssSetMoveOp(mv, scope: scope));

  AssAutomationFlow removeMove({AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssRemoveMoveOp(scope: scope));

  AssAutomationFlow setClipRect(AssTagClipRect clip, {bool inverse = false, AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssSetClipRectOp(clip, inverse: inverse, scope: scope));

  AssAutomationFlow setClipVect(AssTagClipVect clip, {bool inverse = false, AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssSetClipVectOp(clip, inverse: inverse, scope: scope));

  AssAutomationFlow addTransform(AssTransformation tr, {AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssAddTransformOp(tr, scope: scope));

  AssAutomationFlow setFad(int tInMs, int tOutMs, {AssTagScope scope = AssTagScope.leading}) =>
      _add(_AssSetFadOp(tInMs, tOutMs, scope: scope));

  /// Generates FX lines per character for each selected dialog.
  ///
  /// This can use metrics when available (recommended: call [ensureMetrics] first),
  /// but it also works without metrics (in that case you still get correct timing,
  /// but layout/width fields may be null and absolute position falls back to a
  /// best-effort base `\pos`).
  ///
  /// When metrics exist, [AssCharUnit] will contain:
  /// - relative metrics: `x/left/center/right`
  /// - absolute script coords: `absX/absCenter/absMiddle/...`
  AssAutomationFlow splitCharsFx({
    int stepMs = 35,
    int durMs = 300,
    int layerOffset = 10,
    bool includeSpaces = false,
    bool commentOriginal = true,
    bool preserveInlineStyle = true,
    AssSplitTimeMode timeMode = AssSplitTimeMode.indexStep,
    AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource(),
    AssCharFxEnvCallback? onCharEnv,
  }) =>
      _add(
        _AssSplitCharsFxOp(
          stepMs: stepMs,
          durMs: durMs,
          layerOffset: layerOffset,
          includeSpaces: includeSpaces,
          commentOriginal: commentOriginal,
          preserveInlineStyle: preserveInlineStyle,
          timeMode: timeMode,
          outputStrategy: outputStrategy,
          onCharEnv: onCharEnv,
        ),
      );

  AssAutomationFlow splitWordsFx({
    int stepMs = 120,
    int durMs = 600,
    int layerOffset = 10,
    bool includeSpaces = false,
    bool commentOriginal = true,
    bool preserveInlineStyle = true,
    AssSplitTimeMode timeMode = AssSplitTimeMode.indexStep,
    AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource(),
    AssWordFxEnvCallback? onWordEnv,
  }) =>
      _add(
        _AssSplitWordsFxOp(
          stepMs: stepMs,
          durMs: durMs,
          layerOffset: layerOffset,
          includeSpaces: includeSpaces,
          commentOriginal: commentOriginal,
          preserveInlineStyle: preserveInlineStyle,
          timeMode: timeMode,
          outputStrategy: outputStrategy,
          onWordEnv: onWordEnv,
        ),
      );

  AssAutomationFlow splitKaraokeFx({
    int layerOffset = 10,
    bool commentOriginal = true,
    bool includeNonKaraokeSegments = false,
    AssKaraokeSplitMode mode = AssKaraokeSplitMode.blocks,
    bool preserveInlineStyle = true,
    AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource(),
    AssKaraokeFxEnvCallback? onKaraokeEnv,
  }) =>
      _add(
        _AssSplitKaraokeFxOp(
          layerOffset: layerOffset,
          commentOriginal: commentOriginal,
          includeNonKaraokeSegments: includeNonKaraokeSegments,
          mode: mode,
          preserveInlineStyle: preserveInlineStyle,
          outputStrategy: outputStrategy,
          onKaraokeEnv: onKaraokeEnv,
        ),
      );

  /// Generates FX lines frame-by-frame for each selected dialog.
  ///
  /// This is a general "FBF" operation: it splits the line into time windows
  /// computed from `fps` and `stepFrames`. Each unit becomes an `Effect=fx`
  /// dialogue line by default (unless [onFrameEnv] emits custom lines).
  ///
  /// This does not require metrics.
  AssAutomationFlow splitLineFbfFx({
    required double fps,
    int stepFrames = 1,
    int layerOffset = 10,
    bool commentOriginal = true,
    bool preserveOriginalText = true,
    AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource(),
    AssFrameFxEnvCallback? onFrameEnv,
  }) =>
      _add(
        _AssSplitLineFbfFxOp(
          fps: fps,
          stepFrames: stepFrames,
          layerOffset: layerOffset,
          commentOriginal: commentOriginal,
          preserveOriginalText: preserveOriginalText,
          outputStrategy: outputStrategy,
          onFrameEnv: onFrameEnv,
        ),
      );

  /// Expands each selected dialog into a vector drawing (`\p1`) and emits it as an FX line.
  ///
  /// This is a higher-level helper than manually calling `font.getTextToShape(...)`:
  /// it also bakes common transform tags (scale/rotation/shear/perspective/shadow)
  /// into the vector points (karaskel-like "expand appearance").
  ///
  /// The default output uses:
  /// - `\an7`
  /// - `\pos(...)` (best-effort: explicit `\pos`, `\move` start, or derived)
  /// - `\p1`, `\bord0`, `\shad0`
  ///
  /// If [onShapeExpandEnv] is provided, it is called for each selected dialog.
  /// You can mutate `env.unit.paths` and/or `env.line`, then call `env.addDialog()`.
  AssAutomationFlow onShapeExpand({
    int layerOffset = 0,
    bool commentOriginal = true,
    String effect = 'shape',
    AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource(),
    AssShapeExpandEnvCallback? onShapeExpandEnv,
  }) =>
      _add(
        _AssOnShapeExpandOp(
          layerOffset: layerOffset,
          commentOriginal: commentOriginal,
          effect: effect,
          outputStrategy: outputStrategy,
          onShapeExpandEnv: onShapeExpandEnv,
        ),
      );

  AssAutomationFlow custom(AssAutomationOp op) => _add(op);

  Future<AssAutomationResult> run() async {
    final ctx = AssAutomationContext(_ass, shared: _shared);
    try {
      for (final op in _ops) {
        await op.apply(ctx);
      }
    } finally {
      if (_ownsShared) {
        _shared.dispose();
      }
    }
    return AssAutomationResult(ass: _ass, logs: ctx.logs, dialogsTouched: ctx.dialogsTouched);
  }
}

@Deprecated('Use AssAutomationFlow (all automation is async).')
typedef AssAutomationFlowAsync = AssAutomationFlow;

class _AssEnsureMetricsOp extends AssAutomationOp {
  final bool useTextData;
  const _AssEnsureMetricsOp({required this.useTextData});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    if (ctx.ass.dialogs == null) return;
    await ctx.ass.dialogs!.extend(useTextData);
    ctx.log('ensureMetrics: useTextData=$useTextData');
  }
}

class _AssWarmupFontsOp extends AssAutomationOp {
  final bool includeComments;
  const _AssWarmupFontsOp({required this.includeComments});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final indices = ctx.selection.isEmpty
        ? List<int>.generate(dialogs.length, (i) => i)
        : (ctx.selection.toList()..sort());

    final styleNames = <String>{};
    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      if (!includeComments && d.commented) continue;
      if (d.styleName.trim().isEmpty) continue;
      styleNames.add(d.styleName);
    }

    await ctx.shared.warmupFonts(ctx.ass, styleNames);
    ctx.log('warmupFonts: styles=${styleNames.length}');
  }
}

class _AssSelectAllOp extends AssAutomationOp {
  final bool includeComments;
  const _AssSelectAllOp({required this.includeComments});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    ctx.selection.clear();
    for (int i = 0; i < dialogs.length; i++) {
      if (!includeComments && dialogs[i].commented) continue;
      ctx.selection.add(i);
    }
    ctx.log('selectAll: ${ctx.selection.length} dialogs');
  }
}

class _AssWhereOp extends AssAutomationOp {
  final AssDialogPredicate predicate;
  const _AssWhereOp(this.predicate);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    if (ctx.selection.isEmpty) {
      for (int i = 0; i < dialogs.length; i++) {
        if (dialogs[i].commented) continue;
        ctx.selection.add(i);
      }
    }
    final next = <int>{};
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      if (predicate(dialogs[i], i)) next.add(i);
    }
    ctx.selection
      ..clear()
      ..addAll(next);
    ctx.log('where: ${ctx.selection.length} dialogs');
  }
}

class _AssWhereKaraokeOp extends AssAutomationOp {
  const _AssWhereKaraokeOp();

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    if (ctx.selection.isEmpty) {
      for (int i = 0; i < dialogs.length; i++) {
        if (dialogs[i].commented) continue;
        ctx.selection.add(i);
      }
    }
    final next = <int>{};
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      if (_dialogHasAnyKaraokeTags(dialogs[i])) next.add(i);
    }
    ctx.selection
      ..clear()
      ..addAll(next);
    ctx.log('whereKaraoke: ${ctx.selection.length} dialogs');
  }
}

class _AssInsertAtOp extends AssAutomationOp {
  final int index;
  final List<AssDialog> dialogsToInsert;
  const _AssInsertAtOp(this.index, this.dialogsToInsert);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final i = index.clamp(0, dialogs.length);
    dialogs.insertAll(i, dialogsToInsert);
    ctx.log('insertAt: index=$i count=${dialogsToInsert.length}');

    // Shift selection indices after insertion.
    if (dialogsToInsert.isEmpty) return;
    final shifted = <int>{};
    for (final sel in ctx.selection) {
      shifted.add(sel >= i ? sel + dialogsToInsert.length : sel);
    }
    ctx.selection
      ..clear()
      ..addAll(shifted);
  }
}

class _AssAppendOp extends AssAutomationOp {
  final List<AssDialog> dialogsToAppend;
  const _AssAppendOp(this.dialogsToAppend);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    dialogs.addAll(dialogsToAppend);
    ctx.log('append: count=${dialogsToAppend.length}');
  }
}

class _AssRemoveSelectedOp extends AssAutomationOp {
  const _AssRemoveSelectedOp();

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final indices = ctx.selection.toList()..sort((a, b) => b.compareTo(a));
    int removed = 0;
    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      dialogs.removeAt(i);
      removed++;
    }
    ctx.selection.clear();
    ctx.log('removeSelected: removed=$removed');
  }
}

class _AssSplitWordsFxOp extends AssAutomationOp {
  final int stepMs;
  final int durMs;
  final int layerOffset;
  final bool includeSpaces;
  final bool commentOriginal;
  final bool preserveInlineStyle;
  final AssSplitTimeMode timeMode;
  final AssGeneratedOutputStrategy outputStrategy;
  final AssWordFxEnvCallback? onWordEnv;

  const _AssSplitWordsFxOp({
    required this.stepMs,
    required this.durMs,
    required this.layerOffset,
    required this.includeSpaces,
    required this.commentOriginal,
    required this.preserveInlineStyle,
    required this.timeMode,
    required this.outputStrategy,
    required this.onWordEnv,
  });

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final auto = AssAutomation(ctx.ass);

    final afterSource = outputStrategy.placement == AssGeneratedOutputPlacement.afterSource;
    final indices = ctx.selection.toList()
      ..sort((a, b) => afterSource ? b.compareTo(a) : a.compareTo(b));
    int generatedTotal = 0;
    final globalOut = <AssDialog>[];

    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      final start = d.startTime.time;
      final end = d.endTime.time;
      if (start == null || end == null || end <= start) continue;

      final baseTagsAss = _baseTagsAssWithoutKaraoke(d);
      final basePos = _effectiveBasePosForDialog(d);

      final out = <AssDialog>[];
      final emitter = AssFxEmitter(out);
      final units = <AssWordUnit>[];
      final breakLayout = d.line != null ? await _computeBreakLayoutForDialog(d) : const <int, _AssBreakLayout>{};

      if (d.line != null) {
        final all = await d.line!.words(useTextData: true, includeWhitespace: true);
        final words = <AssWords>[];
        for (final w in all) {
          final token = w.text;
          final isSpace = token.trim().isEmpty;
          if (!includeSpaces && isSpace) continue;
          words.add(w);
        }

        final total = words.length;
        final startCs = _msToAssCsFloor(start);
        final endCs = _msToAssCsFloor(end);
        final totalCs = endCs - startCs;
        for (int ui = 0; ui < total; ui++) {
          final w = words[ui];
          final wi = w.index ?? ui;
          final token = w.text;
          final isSpace = token.trim().isEmpty;

          int absStart;
          int absEnd;
          if (timeMode == AssSplitTimeMode.proportional) {
            if (totalCs <= 0) continue;
            final sCs = startCs + ((ui * totalCs) ~/ total);
            var eCs = startCs + (((ui + 1) * totalCs) ~/ total);
            if (eCs <= sCs) eCs = sCs + 1;
            if (eCs > endCs) eCs = endCs;
            absStart = _assCsToMs(sCs);
            absEnd = _assCsToMs(eCs);
          } else {
            final stepCs = math.max(1, _msToAssCsRound(stepMs));
            final durCs2 = math.max(1, _msToAssCsRound(durMs));
            final sCs = startCs + (ui * stepCs);
            if (sCs >= endCs) break;
            var eCs = sCs + durCs2;
            if (eCs > endCs) eCs = endCs;
            absStart = _assCsToMs(sCs);
            absEnd = _assCsToMs(eCs);
          }
          if (absEnd <= absStart) continue;

          final tokenAss = _normalizeTextForFx(token);
          final textAss = '$baseTagsAss${_escapeAssText(tokenAss)}';
          final fx = auto.createDialog(
            startMs: absStart,
            endMs: absEnd,
            styleName: d.styleName,
            layer: d.layer + layerOffset,
            name: d.name,
            marginL: d.marginL,
            marginR: d.marginR,
            marginV: d.marginV,
            effect: 'fx',
            commented: false,
            textAss: textAss,
          );

          if (preserveInlineStyle) {
            final tags = _ensureLeadingOverrideTags(fx.text);
            _applyEffectiveStyleOverrides(tags: tags, base: d.style, effectiveStyle: w.effectiveStyle);
          }

          final ww = w.width ?? 0.0;
          final x = w.x ?? 0.0;
          final left = x;
          final center = x + ww * 0.5;
          final right = x + ww;
          final bl = breakLayout[w.lineIndex ?? 0];
          final absX = bl != null ? (bl.left + x) : null;
          final absLeft = bl != null ? (bl.left + left) : null;
          final absCenter = bl != null ? (bl.left + center) : null;
          final absRight = bl != null ? (bl.left + right) : null;

          units.add(
            AssWordUnit(
              source: d,
              sourceIndex: i,
              wordIndex: wi,
              text: tokenAss,
              isSpace: isSpace,
              absStartMs: absStart,
              absEndMs: absEnd,
              baseTagsAss: baseTagsAss,
              defaultDialog: fx,
              width: w.width,
              height: w.height,
              lineIndex: w.lineIndex,
              x: x,
              left: left,
              center: center,
              right: right,
              absX: absX ?? basePos.pos.x,
              absLeft: absLeft ?? basePos.pos.x,
              absCenter: absCenter ?? basePos.pos.x,
              absRight: absRight ?? basePos.pos.x,
              absTop: bl?.top ?? basePos.pos.y,
              absMiddle: bl?.middle ?? basePos.pos.y,
              absBottom: bl?.bottom ?? basePos.pos.y,
              effectiveStyle: w.effectiveStyle,
            ),
          );
        }
      } else {
        // No metrics available. Fallback: split on whitespace boundaries.
        final raw = d.text.segments.map((s) => s.text).join();
        final normalized = _normalizeTextForFx(raw);
        final re = RegExp(r'(\s+|\S+)');
        final tokens = <String>[];
        for (final m in re.allMatches(normalized)) {
          final token = m.group(0) ?? '';
          final isSpace = token.trim().isEmpty;
          if (!includeSpaces && isSpace) {
            continue;
          }
          tokens.add(token);
        }

        final total = tokens.length;
        final startCs = _msToAssCsFloor(start);
        final endCs = _msToAssCsFloor(end);
        final totalCs = endCs - startCs;
        for (int ui = 0; ui < total; ui++) {
          final token = tokens[ui];
          final isSpace = token.trim().isEmpty;
          final wi = ui;

          int absStart;
          int absEnd;
          if (timeMode == AssSplitTimeMode.proportional) {
            if (totalCs <= 0) continue;
            final sCs = startCs + ((ui * totalCs) ~/ total);
            var eCs = startCs + (((ui + 1) * totalCs) ~/ total);
            if (eCs <= sCs) eCs = sCs + 1;
            if (eCs > endCs) eCs = endCs;
            absStart = _assCsToMs(sCs);
            absEnd = _assCsToMs(eCs);
          } else {
            final stepCs = math.max(1, _msToAssCsRound(stepMs));
            final durCs2 = math.max(1, _msToAssCsRound(durMs));
            final sCs = startCs + (ui * stepCs);
            if (sCs >= endCs) break;
            var eCs = sCs + durCs2;
            if (eCs > endCs) eCs = endCs;
            absStart = _assCsToMs(sCs);
            absEnd = _assCsToMs(eCs);
          }
          if (absEnd <= absStart) continue;

          final textAss = '$baseTagsAss${_escapeAssText(token)}';
          final fx = auto.createDialog(
            startMs: absStart,
            endMs: absEnd,
            styleName: d.styleName,
            layer: d.layer + layerOffset,
            name: d.name,
            marginL: d.marginL,
            marginR: d.marginR,
            marginV: d.marginV,
            effect: 'fx',
            commented: false,
            textAss: textAss,
          );

          units.add(
            AssWordUnit(
              source: d,
              sourceIndex: i,
              wordIndex: wi,
              text: token,
              isSpace: isSpace,
              absStartMs: absStart,
              absEndMs: absEnd,
              baseTagsAss: baseTagsAss,
              defaultDialog: fx,
              absX: basePos.pos.x,
              absLeft: basePos.pos.x,
              absCenter: basePos.pos.x,
              absRight: basePos.pos.x,
              absTop: basePos.pos.y,
              absMiddle: basePos.pos.y,
              absBottom: basePos.pos.y,
              effectiveStyle: null,
            ),
          );
        }
      }

      for (int ui = 0; ui < units.length; ui++) {
        units[ui].tf = units.length <= 1 ? 0 : ui / (units.length - 1);
      }

      if (units.isNotEmpty) {
        final x0 = units.first.absCenter ?? units.first.center;
        final x1 = units.last.absCenter ?? units.last.center;
        for (final u in units) {
          final x = u.absCenter ?? u.center;
          if (x0 == null || x1 == null || x == null || x1 == x0) {
            u.xf = 0;
          } else {
            u.xf = (x - x0) / (x1 - x0);
          }
        }
      }

      for (final u in units) {
        if (onWordEnv != null) {
          onWordEnv!(
            AssWordTemplateEnv(
              shared: ctx.shared,
              basePos: basePos,
              orgline: d,
              sourceIndex: i,
              units: units,
              unit: u,
              line: u.defaultDialog,
              emit: emitter,
            ),
          );
        } else {
          emitter.emit(u.defaultDialog);
        }
      }

      if (out.isNotEmpty && commentOriginal) {
        d.commented = true;
        ctx.touchDialog(d);
      }

      if (out.isNotEmpty) {
        if (afterSource) {
          dialogs.insertAll(i + 1, out);
        } else {
          globalOut.addAll(out);
        }
        generatedTotal += out.length;
        ctx.log('splitWordsFx: dialog#$i generated=${out.length}');
      }
    }

    if (!afterSource && globalOut.isNotEmpty) {
      switch (outputStrategy.placement) {
        case AssGeneratedOutputPlacement.appendToEnd:
          dialogs.addAll(globalOut);
          break;
        case AssGeneratedOutputPlacement.prependToStart:
          dialogs.insertAll(0, globalOut);
          break;
        case AssGeneratedOutputPlacement.insertAtIndex:
          final idx = (outputStrategy.index ?? dialogs.length).clamp(0, dialogs.length);
          dialogs.insertAll(idx, globalOut);
          break;
        case AssGeneratedOutputPlacement.afterSource:
          break;
      }
    }

    ctx.log('splitWordsFx: totalGenerated=$generatedTotal');
  }
}

class _AssSplitCharsFxOp extends AssAutomationOp {
  final int stepMs;
  final int durMs;
  final int layerOffset;
  final bool includeSpaces;
  final bool commentOriginal;
  final bool preserveInlineStyle;
  final AssSplitTimeMode timeMode;
  final AssGeneratedOutputStrategy outputStrategy;
  final AssCharFxEnvCallback? onCharEnv;

  const _AssSplitCharsFxOp({
    required this.stepMs,
    required this.durMs,
    required this.layerOffset,
    required this.includeSpaces,
    required this.commentOriginal,
    required this.preserveInlineStyle,
    required this.timeMode,
    required this.outputStrategy,
    required this.onCharEnv,
  });

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final auto = AssAutomation(ctx.ass);

    final afterSource = outputStrategy.placement == AssGeneratedOutputPlacement.afterSource;
    final indices = ctx.selection.toList()
      ..sort((a, b) => afterSource ? b.compareTo(a) : a.compareTo(b));
    int generatedTotal = 0;
    final globalOut = <AssDialog>[];

    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      final start = d.startTime.time;
      final end = d.endTime.time;
      if (start == null || end == null || end <= start) continue;

      final baseTagsAss = _baseTagsAssWithoutKaraoke(d);
      final basePos = _effectiveBasePosForDialog(d);

      final out = <AssDialog>[];
      final emitter = AssFxEmitter(out);
      final units = <AssCharUnit>[];
      final breakLayout = d.line != null ? await _computeBreakLayoutForDialog(d) : const <int, _AssBreakLayout>{};

      if (d.line != null) {
        final all = await d.line!.chars(useTextData: true, includeWhitespace: true);
        final chars = <AssChars>[];
        for (final c in all) {
          final ch = c.text;
          final isSpace = c.isSpace ?? ch.trim().isEmpty;
          if (!includeSpaces && isSpace) continue;
          chars.add(c);
        }

        final total = chars.length;
        final startCs = _msToAssCsFloor(start);
        final endCs = _msToAssCsFloor(end);
        final totalCs = endCs - startCs;
        for (int ui = 0; ui < total; ui++) {
          final c = chars[ui];
          final ci = c.index ?? ui;
          final ch = c.text;
          final isSpace = c.isSpace ?? ch.trim().isEmpty;

          int absStart;
          int absEnd;
          if (timeMode == AssSplitTimeMode.proportional) {
            if (totalCs <= 0) continue;
            final sCs = startCs + ((ui * totalCs) ~/ total);
            var eCs = startCs + (((ui + 1) * totalCs) ~/ total);
            if (eCs <= sCs) eCs = sCs + 1;
            if (eCs > endCs) eCs = endCs;
            absStart = _assCsToMs(sCs);
            absEnd = _assCsToMs(eCs);
          } else {
            final stepCs = math.max(1, _msToAssCsRound(stepMs));
            final durCs2 = math.max(1, _msToAssCsRound(durMs));
            final sCs = startCs + (ui * stepCs);
            if (sCs >= endCs) break;
            var eCs = sCs + durCs2;
            if (eCs > endCs) eCs = endCs;
            absStart = _assCsToMs(sCs);
            absEnd = _assCsToMs(eCs);
          }
          if (absEnd <= absStart) continue;

          final textAss = '$baseTagsAss${_escapeAssText(ch)}';
          final fx = auto.createDialog(
            startMs: absStart,
            endMs: absEnd,
            styleName: d.styleName,
            layer: d.layer + layerOffset,
            name: d.name,
            marginL: d.marginL,
            marginR: d.marginR,
            marginV: d.marginV,
            effect: 'fx',
            commented: false,
            textAss: textAss,
          );
          if (preserveInlineStyle) {
            final tags = _ensureLeadingOverrideTags(fx.text);
            _applyEffectiveStyleOverrides(tags: tags, base: d.style, effectiveStyle: c.effectiveStyle);
          }

          final w = c.width ?? 0;
          final x = c.x ?? 0;
          final bl = breakLayout[c.lineIndex ?? 0];
          final absX = bl != null ? (bl.left + x) : null;
          final absLeft = bl != null ? (bl.left + (c.left ?? x)) : null;
          final absCenter = bl != null ? (bl.left + (c.center ?? (x + w * 0.5))) : null;
          final absRight = bl != null ? (bl.left + (c.right ?? (x + w))) : null;
          units.add(
            AssCharUnit(
              source: d,
              sourceIndex: i,
              charIndex: ci,
              char: ch,
              isSpace: isSpace,
              absStartMs: absStart,
              absEndMs: absEnd,
              baseTagsAss: baseTagsAss,
              defaultDialog: fx,
              width: c.width,
              height: c.height,
              lineIndex: c.lineIndex,
              x: x,
              left: c.left ?? x,
              center: c.center ?? (x + w * 0.5),
              right: c.right ?? (x + w),
              absX: absX ?? basePos.pos.x,
              absLeft: absLeft ?? basePos.pos.x,
              absCenter: absCenter ?? basePos.pos.x,
              absRight: absRight ?? basePos.pos.x,
              absTop: bl?.top ?? basePos.pos.y,
              absMiddle: bl?.middle ?? basePos.pos.y,
              absBottom: bl?.bottom ?? basePos.pos.y,
              effectiveStyle: c.effectiveStyle,
            ),
          );
        }
      } else {
        final raw = d.text.segments.map((s) => s.text).join();
        final normalized = _normalizeTextForFx(raw);
        final chars = <String>[];
        for (final rune in normalized.runes) {
          final ch = String.fromCharCode(rune);
          final isSpace = ch.trim().isEmpty;
          if (!includeSpaces && isSpace) {
            continue;
          }
          chars.add(ch);
        }

        final total = chars.length;
        final startCs = _msToAssCsFloor(start);
        final endCs = _msToAssCsFloor(end);
        final totalCs = endCs - startCs;
        for (int ui = 0; ui < total; ui++) {
          final ch = chars[ui];
          final isSpace = ch.trim().isEmpty;
          final ci = ui;

          int absStart;
          int absEnd;
          if (timeMode == AssSplitTimeMode.proportional) {
            if (totalCs <= 0) continue;
            final sCs = startCs + ((ui * totalCs) ~/ total);
            var eCs = startCs + (((ui + 1) * totalCs) ~/ total);
            if (eCs <= sCs) eCs = sCs + 1;
            if (eCs > endCs) eCs = endCs;
            absStart = _assCsToMs(sCs);
            absEnd = _assCsToMs(eCs);
          } else {
            final stepCs = math.max(1, _msToAssCsRound(stepMs));
            final durCs2 = math.max(1, _msToAssCsRound(durMs));
            final sCs = startCs + (ui * stepCs);
            if (sCs >= endCs) break;
            var eCs = sCs + durCs2;
            if (eCs > endCs) eCs = endCs;
            absStart = _assCsToMs(sCs);
            absEnd = _assCsToMs(eCs);
          }
          if (absEnd <= absStart) continue;

          final textAss = '$baseTagsAss${_escapeAssText(ch)}';
          final fx = auto.createDialog(
            startMs: absStart,
            endMs: absEnd,
            styleName: d.styleName,
            layer: d.layer + layerOffset,
            name: d.name,
            marginL: d.marginL,
            marginR: d.marginR,
            marginV: d.marginV,
            effect: 'fx',
            commented: false,
            textAss: textAss,
          );

          units.add(
            AssCharUnit(
              source: d,
              sourceIndex: i,
              charIndex: ci,
              char: ch,
              isSpace: isSpace,
              absStartMs: absStart,
              absEndMs: absEnd,
              baseTagsAss: baseTagsAss,
              defaultDialog: fx,
              absX: basePos.pos.x,
              absLeft: basePos.pos.x,
              absCenter: basePos.pos.x,
              absRight: basePos.pos.x,
              absTop: basePos.pos.y,
              absMiddle: basePos.pos.y,
              absBottom: basePos.pos.y,
              effectiveStyle: null,
            ),
          );
        }
      }

      for (int ui = 0; ui < units.length; ui++) {
        units[ui].tf = units.length <= 1 ? 0 : ui / (units.length - 1);
      }

      if (units.isNotEmpty) {
        final x0 = units.first.absCenter ?? units.first.center;
        final x1 = units.last.absCenter ?? units.last.center;
        for (final u in units) {
          final x = u.absCenter ?? u.center;
          if (x0 == null || x1 == null || x == null || x1 == x0) {
            u.xf = 0;
          } else {
            u.xf = (x - x0) / (x1 - x0);
          }
        }
      }

      for (final u in units) {
        if (onCharEnv != null) {
          onCharEnv!(
            AssCharTemplateEnv(
              shared: ctx.shared,
              basePos: basePos,
              orgline: d,
              sourceIndex: i,
              units: units,
              unit: u,
              line: u.defaultDialog,
              emit: emitter,
            ),
          );
        } else {
          emitter.emit(u.defaultDialog);
        }
      }

      if (out.isNotEmpty && commentOriginal) {
        d.commented = true;
        ctx.touchDialog(d);
      }

      if (out.isNotEmpty) {
        if (afterSource) {
          dialogs.insertAll(i + 1, out);
        } else {
          globalOut.addAll(out);
        }
        generatedTotal += out.length;
        ctx.log('splitCharsFx: dialog#$i generated=${out.length}');
      }
    }

    if (!afterSource && globalOut.isNotEmpty) {
      switch (outputStrategy.placement) {
        case AssGeneratedOutputPlacement.appendToEnd:
          dialogs.addAll(globalOut);
          break;
        case AssGeneratedOutputPlacement.prependToStart:
          dialogs.insertAll(0, globalOut);
          break;
        case AssGeneratedOutputPlacement.insertAtIndex:
          final idx = (outputStrategy.index ?? dialogs.length).clamp(0, dialogs.length);
          dialogs.insertAll(idx, globalOut);
          break;
        case AssGeneratedOutputPlacement.afterSource:
          break;
      }
    }

    ctx.log('splitCharsFx: totalGenerated=$generatedTotal');
  }
}

class _AssSplitKaraokeFxOp extends AssAutomationOp {
  final int layerOffset;
  final bool commentOriginal;
  final bool includeNonKaraokeSegments;
  final AssKaraokeSplitMode mode;
  final bool preserveInlineStyle;
  final AssGeneratedOutputStrategy outputStrategy;
  final AssKaraokeFxEnvCallback? onKaraokeEnv;

  const _AssSplitKaraokeFxOp({
    required this.layerOffset,
    required this.commentOriginal,
    required this.includeNonKaraokeSegments,
    required this.mode,
    required this.preserveInlineStyle,
    required this.outputStrategy,
    required this.onKaraokeEnv,
  });

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final auto = AssAutomation(ctx.ass);

    final afterSource = outputStrategy.placement == AssGeneratedOutputPlacement.afterSource;
    final indices = ctx.selection.toList()
      ..sort((a, b) => afterSource ? b.compareTo(a) : a.compareTo(b));
    int generatedTotal = 0;
    final globalOut = <AssDialog>[];

    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      final start = d.startTime.time;
      final end = d.endTime.time;
      if (start == null || end == null || end <= start) continue;

      // Don't mutate/comment lines that aren't actually karaoke.
      if (!_dialogHasAnyKaraokeTags(d) && !includeNonKaraokeSegments) {
        continue;
      }

      final baseTagsAss = _baseTagsAssWithoutKaraoke(d);
      final basePos = _effectiveBasePosForDialog(d);
      final out = <AssDialog>[];
      final emitter = AssFxEmitter(out);
      final breakLayout = d.line != null ? await _computeBreakLayoutForDialog(d) : const <int, _AssBreakLayout>{};

      // Optional metrics: if the dialog has a pre-extended `line` whose segments
      // correspond 1:1 with AssText.segments, we can attach widths and x offsets.
      final line = d.line;
      final hasSegmentMetrics = line != null && line.segments.length == d.text.segments.length;
      final segWidth = <double>[];
      final segHeight = <double>[];
      final segX = <double>[];
      final segLineIndex = <int>[];
      if (hasSegmentMetrics) {
        double x = 0;
        int li = 0;
        for (int si = 0; si < line.segments.length; si++) {
          final s = line.segments[si];
          final w = s.width ?? 0;
          final h = s.height ?? 0;
          segWidth.add(w);
          segHeight.add(h);
          segX.add(x);
          segLineIndex.add(li);

          // crude line break detection: a segment may contain `\N` or `\n`.
          // Most karaoke lines keep breaks as their own segment, so this is ok.
          final rawText = d.text.segments[si].text;
          if (rawText.contains(r'\N') || rawText.contains(r'\n') || rawText.contains('\n')) {
            x = 0;
            li += 1;
          } else {
            x += w;
          }
        }
      }

      final rawBlocks = <_AssKaraokeRawBlock>[];

      // Prefer using AssLine.karaoke() when available: it matches karaskel's
      // "fixed" metrics (pre/core/post spacing widths + core left/center/right).
      final canUseFixedMetrics = line != null && line.segments.every((s) => s.effectiveStyle != null);
      if (line != null && canUseFixedMetrics && !includeNonKaraokeSegments) {
        final blocks = await line.karaoke(useTextData: true);
        for (final k in blocks) {
          final durMs = k.durationMs ?? 0;
          final startOffset = k.startOffsetMs ?? 0;
          final endOffset = k.endOffsetMs ?? (startOffset + durMs);
          if (durMs < 0) continue;

          final absStart = start + startOffset;
          if (absStart >= end) continue;
          var absEnd = start + endOffset;
          if (absEnd > end) absEnd = end;
          if (absEnd <= absStart) continue;

          final segText = _normalizeTextForFx(k.text);
          if (durMs == 0 && segText.isEmpty) continue;

          rawBlocks.add(
            _AssKaraokeRawBlock(
              text: segText,
              karaokeTag: k.karaokeTag,
              durMs: durMs,
              startOffsetMs: startOffset,
              endOffsetMs: endOffset,
              absStartMs: absStart,
              absEndMs: absEnd,
              effectiveStyle: k.effectiveStyle,
              width: k.width,
              height: k.height,
              prespace: k.prespace,
              postspace: k.postspace,
              textSpaceStripped: k.textSpaceStripped,
              prespaceWidth: k.prespaceWidth,
              postspaceWidth: k.postspaceWidth,
              coreWidth: k.coreWidth,
              lineIndex: k.lineIndex,
              x: k.x,
              left: k.left,
              center: k.center,
              right: k.right,
            ),
          );
        }
      } else {
        // Fallback parser based on AssText segments.
        //
        // This is more robust than "one segment = one syllable", because
        // karaoke timing tags apply until the next karaoke timing tag; inline
        // style overrides inside the syllable must be merged into the same unit.
        int cursor = 0;
        int? curStartOffset;
        int? curEndOffset;
        int curDurMs = 0;
        String? curTagName;
        StringBuffer curText = StringBuffer();
        int? curFirstSegIndex;
        double? curWidth;
        double? curHeight;

        void flushCurrent() {
          if (curStartOffset == null || curEndOffset == null) return;
          final text = curText.toString();
          if (text.isEmpty && curDurMs == 0) return;
          final absStart = start + curStartOffset!;
          var absEnd = start + curEndOffset!;
          if (absStart >= end) return;
          if (absEnd > end) absEnd = end;
          if (absEnd <= absStart) return;

          int? li;
          double? x;
          double? w;
          double? h;
          if (curFirstSegIndex != null && hasSegmentMetrics) {
            li = segLineIndex[curFirstSegIndex!];
            x = segX[curFirstSegIndex!];
            // Approximate: sum widths of involved segments when available.
            w = curWidth;
            h = curHeight;
          }

          rawBlocks.add(
            _AssKaraokeRawBlock(
              text: text,
              karaokeTag: curTagName,
              durMs: curDurMs,
              startOffsetMs: curStartOffset!,
              endOffsetMs: curEndOffset!,
              absStartMs: absStart,
              absEndMs: absEnd,
              effectiveStyle: null,
              width: w,
              height: h,
              prespace: null,
              postspace: null,
              textSpaceStripped: null,
              prespaceWidth: null,
              postspaceWidth: null,
              coreWidth: null,
              lineIndex: li,
              x: x,
              left: x,
              center: (x != null && w != null) ? (x + w * 0.5) : null,
              right: (x != null && w != null) ? (x + w) : null,
            ),
          );
        }

        void resetCurrent() {
          curStartOffset = null;
          curEndOffset = null;
          curDurMs = 0;
          curTagName = null;
          curFirstSegIndex = null;
          curWidth = null;
          curHeight = null;
          curText = StringBuffer();
        }

        for (int si = 0; si < d.text.segments.length; si++) {
          final seg = d.text.segments[si];
          final segText = _normalizeTextForFx(seg.text);

          final tags = seg.overrideTags;
          int? ktCs;
          int? kCs;
          String? tagName;

          if (tags != null) {
            final ktRaw = tags.getTagValue('kt');
            ktCs = ktRaw != null ? int.tryParse(ktRaw.trim()) : null;

            String? raw;
            raw = tags.getTagValue('kf');
            if (raw != null) {
              tagName = 'kf';
            } else {
              raw = tags.getTagValue('ko');
              if (raw != null) tagName = 'ko';
            }
            raw ??= tags.getTagValue('k');
            tagName ??= raw != null ? 'k' : null;
            kCs = raw != null ? int.tryParse(raw.trim()) : null;
          }

          final hasK = kCs != null;
          if (hasK) {
            // Start a new timed block.
            flushCurrent();
            resetCurrent();

            final durMs = kCs * 10;
            final startOffset = ktCs != null ? (ktCs * 10) : cursor;
            final endOffset = startOffset + durMs;
            cursor = ktCs != null ? (endOffset > cursor ? endOffset : cursor) : endOffset;

            curStartOffset = startOffset;
            curEndOffset = endOffset;
            curDurMs = durMs;
            curTagName = tagName;
            curFirstSegIndex = si;

            if (hasSegmentMetrics) {
              curWidth = segWidth[si];
              curHeight = segHeight[si];
            }

            if (segText.isNotEmpty) {
              curText.write(segText);
            }
          } else {
            // Continuation of the current karaoke block (style tags, etc).
            if (curStartOffset != null && segText.isNotEmpty) {
              curText.write(segText);
              if (hasSegmentMetrics) {
                curWidth = (curWidth ?? 0.0) + segWidth[si];
                curHeight = (curHeight ?? 0.0) > segHeight[si] ? curHeight : segHeight[si];
              }
            }
          }
        }

        flushCurrent();
      }

      // If this line has no karaoke tags but the caller explicitly asked to
      // include non-karaoke content, treat the whole line as a single unit.
      if (rawBlocks.isEmpty && includeNonKaraokeSegments) {
        final raw = d.text.segments.map((s) => s.text).join();
        final normalized = _normalizeTextForFx(raw);
        if (normalized.isNotEmpty) {
          rawBlocks.add(
            _AssKaraokeRawBlock(
              text: normalized,
              karaokeTag: null,
              durMs: end - start,
              startOffsetMs: 0,
              endOffsetMs: end - start,
              absStartMs: start,
              absEndMs: end,
              effectiveStyle: null,
              width: null,
              height: null,
              prespace: null,
              postspace: null,
              textSpaceStripped: null,
              prespaceWidth: null,
              postspaceWidth: null,
              coreWidth: null,
              lineIndex: null,
              x: null,
              left: null,
              center: null,
              right: null,
            ),
          );
        }
      }

      String displayTextFrom(_AssKaraokeRawBlock b, {required bool stripHighlightPrefix}) {
        if (!stripHighlightPrefix) return b.text;
        final pre = b.prespace ?? '';
        final post = b.postspace ?? '';
        final core = (b.textSpaceStripped ?? b.text).trim();
        if (core.isEmpty) return b.text;
        final first = core[0];
        if (first != '#' && first != '＃') return b.text;
        final strippedCore = core.length > 1 ? core.substring(1) : '';
        return _normalizeTextForFx('$pre$strippedCore$post');
      }

      bool isExtraHighlight(_AssKaraokeRawBlock b) {
        final core = (b.textSpaceStripped ?? b.text).trim();
        if (core.isEmpty) return false;
        final first = core[0];
        return first == '#' || first == '＃';
      }

      final units = <AssKaraokeUnit>[];

      if (mode == AssKaraokeSplitMode.blocks) {
        int bi = 0;
        for (final b in rawBlocks) {
          final textAss = '$baseTagsAss${_escapeAssText(b.text)}';
          final fx = auto.createDialog(
            startMs: b.absStartMs,
            endMs: b.absEndMs,
            styleName: d.styleName,
            layer: d.layer + layerOffset,
            name: d.name,
            marginL: d.marginL,
            marginR: d.marginR,
            marginV: d.marginV,
            effect: 'fx',
            commented: false,
            textAss: textAss,
          );
          if (preserveInlineStyle) {
            final tags = _ensureLeadingOverrideTags(fx.text);
            _applyEffectiveStyleOverrides(tags: tags, base: d.style, effectiveStyle: b.effectiveStyle);
          }

          final bl = b.lineIndex != null ? breakLayout[b.lineIndex!] : null;
          final absX = (bl != null && b.x != null) ? (bl.left + b.x!) : null;
          final absLeft = (bl != null && b.left != null) ? (bl.left + b.left!) : null;
          final absCenter = (bl != null && b.center != null) ? (bl.left + b.center!) : null;
          final absRight = (bl != null && b.right != null) ? (bl.left + b.right!) : null;

          units.add(
            AssKaraokeUnit(
              source: d,
              sourceIndex: i,
              blockIndex: bi,
              text: b.text,
              karaokeTag: b.karaokeTag,
              durMs: b.durMs,
              absStartMs: b.absStartMs,
              absEndMs: b.absEndMs,
              highlights: [
                AssKaraokeHighlight(
                  startOffsetMs: b.startOffsetMs,
                  endOffsetMs: b.endOffsetMs,
                  karaokeTag: b.karaokeTag,
                ),
              ],
              baseTagsAss: baseTagsAss,
              defaultDialog: fx,
              width: b.width,
              height: b.height,
              prespace: b.prespace,
              postspace: b.postspace,
              textSpaceStripped: b.textSpaceStripped,
              prespaceWidth: b.prespaceWidth,
              postspaceWidth: b.postspaceWidth,
              coreWidth: b.coreWidth,
              lineIndex: b.lineIndex,
              x: b.x,
              left: b.left,
              center: b.center,
              right: b.right,
              absX: absX ?? basePos.pos.x,
              absLeft: absLeft ?? basePos.pos.x,
              absCenter: absCenter ?? basePos.pos.x,
              absRight: absRight ?? basePos.pos.x,
              absTop: bl?.top ?? basePos.pos.y,
              absMiddle: bl?.middle ?? basePos.pos.y,
              absBottom: bl?.bottom ?? basePos.pos.y,
              effectiveStyle: b.effectiveStyle,
            ),
          );

          bi++;
        }
      } else {
        // Syllable mode: merge extra highlight blocks (`#` prefix) into the
        // previous unit (multi-highlight).
        int bi = 0;
        _AssKaraokeRawBlock? seed;
        final highlights = <AssKaraokeHighlight>[];
        int absStartMs = 0;
        int absEndMs = 0;
        int startOffsetMs = 0;
        int endOffsetMs = 0;
        String? tagName;

        void flushSyllable() {
          if (seed == null) return;
          final seedBlock = seed!;
          final displayText = displayTextFrom(seedBlock, stripHighlightPrefix: true);
          final totalDurMs = highlights.fold<int>(0, (p, h) => p + h.durationMs);

          final textAss = '$baseTagsAss${_escapeAssText(displayText)}';
          final fx = auto.createDialog(
            startMs: absStartMs,
            endMs: absEndMs,
            styleName: d.styleName,
            layer: d.layer + layerOffset,
            name: d.name,
            marginL: d.marginL,
            marginR: d.marginR,
            marginV: d.marginV,
            effect: 'fx',
            commented: false,
            textAss: textAss,
          );
          if (preserveInlineStyle) {
            final tags = _ensureLeadingOverrideTags(fx.text);
            _applyEffectiveStyleOverrides(tags: tags, base: d.style, effectiveStyle: seedBlock.effectiveStyle);
          }

          final bl = seedBlock.lineIndex != null ? breakLayout[seedBlock.lineIndex!] : null;
          final absX = (bl != null && seedBlock.x != null) ? (bl.left + seedBlock.x!) : null;
          final absLeft = (bl != null && seedBlock.left != null) ? (bl.left + seedBlock.left!) : null;
          final absCenter = (bl != null && seedBlock.center != null) ? (bl.left + seedBlock.center!) : null;
          final absRight = (bl != null && seedBlock.right != null) ? (bl.left + seedBlock.right!) : null;

          units.add(
            AssKaraokeUnit(
              source: d,
              sourceIndex: i,
              blockIndex: bi,
              text: displayText,
              karaokeTag: tagName,
              durMs: totalDurMs,
              absStartMs: absStartMs,
              absEndMs: absEndMs,
              highlights: List<AssKaraokeHighlight>.unmodifiable(highlights),
              baseTagsAss: baseTagsAss,
              defaultDialog: fx,
              width: seedBlock.width,
              height: seedBlock.height,
              prespace: seedBlock.prespace,
              postspace: seedBlock.postspace,
              textSpaceStripped: seedBlock.textSpaceStripped,
              prespaceWidth: seedBlock.prespaceWidth,
              postspaceWidth: seedBlock.postspaceWidth,
              coreWidth: seedBlock.coreWidth,
              lineIndex: seedBlock.lineIndex,
              x: seedBlock.x,
              left: seedBlock.left,
              center: seedBlock.center,
              right: seedBlock.right,
              absX: absX ?? basePos.pos.x,
              absLeft: absLeft ?? basePos.pos.x,
              absCenter: absCenter ?? basePos.pos.x,
              absRight: absRight ?? basePos.pos.x,
              absTop: bl?.top ?? basePos.pos.y,
              absMiddle: bl?.middle ?? basePos.pos.y,
              absBottom: bl?.bottom ?? basePos.pos.y,
              effectiveStyle: seedBlock.effectiveStyle,
            ),
          );

          bi++;
          seed = null;
          highlights.clear();
        }

        for (final b in rawBlocks) {
          final extra = isExtraHighlight(b);
          if (extra && seed != null) {
            highlights.add(
              AssKaraokeHighlight(
                startOffsetMs: b.startOffsetMs,
                endOffsetMs: b.endOffsetMs,
                karaokeTag: b.karaokeTag,
              ),
            );
            if (b.absEndMs > absEndMs) absEndMs = b.absEndMs;
            if (b.endOffsetMs > endOffsetMs) endOffsetMs = b.endOffsetMs;
            continue;
          }

          flushSyllable();
          seed = b;
          tagName = b.karaokeTag;
          absStartMs = b.absStartMs;
          absEndMs = b.absEndMs;
          startOffsetMs = b.startOffsetMs;
          endOffsetMs = b.endOffsetMs;
          highlights.add(
            AssKaraokeHighlight(
              startOffsetMs: b.startOffsetMs,
              endOffsetMs: b.endOffsetMs,
              karaokeTag: b.karaokeTag,
            ),
          );
        }

        flushSyllable();
      }

      for (int ui = 0; ui < units.length; ui++) {
        final u = units[ui];
        u.tf = units.length <= 1 ? 0 : ui / (units.length - 1);
      }
      if (units.isNotEmpty) {
        final x0 = units.first.absCenter ?? units.first.center;
        final x1 = units.last.absCenter ?? units.last.center;
        for (final u in units) {
          final x = u.absCenter ?? u.center;
          if (x0 == null || x1 == null || x == null || x1 == x0) {
            u.xf = 0;
          } else {
            u.xf = (x - x0) / (x1 - x0);
          }
        }
      }

      for (final u in units) {
        if (onKaraokeEnv != null) {
          onKaraokeEnv!(
            AssKaraokeTemplateEnv(
              shared: ctx.shared,
              basePos: basePos,
              orgline: d,
              sourceIndex: i,
              units: units,
              unit: u,
              line: u.defaultDialog,
              emit: emitter,
            ),
          );
        } else {
          emitter.emit(u.defaultDialog);
        }
      }

      if (out.isNotEmpty && commentOriginal) {
        d.commented = true;
        ctx.touchDialog(d);
      }

      if (out.isNotEmpty) {
        if (afterSource) {
          dialogs.insertAll(i + 1, out);
        } else {
          globalOut.addAll(out);
        }
        generatedTotal += out.length;
        ctx.log('splitKaraokeFx: dialog#$i generated=${out.length}');
      }
    }

    if (!afterSource && globalOut.isNotEmpty) {
      switch (outputStrategy.placement) {
        case AssGeneratedOutputPlacement.appendToEnd:
          dialogs.addAll(globalOut);
          break;
        case AssGeneratedOutputPlacement.prependToStart:
          dialogs.insertAll(0, globalOut);
          break;
        case AssGeneratedOutputPlacement.insertAtIndex:
          final idx = (outputStrategy.index ?? dialogs.length).clamp(0, dialogs.length);
          dialogs.insertAll(idx, globalOut);
          break;
        case AssGeneratedOutputPlacement.afterSource:
          break;
      }
    }

    ctx.log('splitKaraokeFx: totalGenerated=$generatedTotal');
  }
}

class _AssSplitLineFbfFxOp extends AssAutomationOp {
  final double fps;
  final int stepFrames;
  final int layerOffset;
  final bool commentOriginal;
  final bool preserveOriginalText;
  final AssGeneratedOutputStrategy outputStrategy;
  final AssFrameFxEnvCallback? onFrameEnv;

  const _AssSplitLineFbfFxOp({
    required this.fps,
    required this.stepFrames,
    required this.layerOffset,
    required this.commentOriginal,
    required this.preserveOriginalText,
    required this.outputStrategy,
    required this.onFrameEnv,
  });

  static int _frameFromMs(int ms, double frameMs) => (ms / frameMs).floor();
  static int _msFromFrame(int frame, double frameMs) => (frame * frameMs).round();

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    if (fps <= 0) throw ArgumentError('fps must be > 0');
    if (stepFrames <= 0) throw ArgumentError('stepFrames must be >= 1');

    final dialogs = ctx.ensureDialogs().dialogs;
    final auto = AssAutomation(ctx.ass);
    final frameMs = 1000.0 / fps;

    final afterSource = outputStrategy.placement == AssGeneratedOutputPlacement.afterSource;
    final indices = ctx.selection.toList()
      ..sort((a, b) => afterSource ? b.compareTo(a) : a.compareTo(b));
    int generatedTotal = 0;
    final globalOut = <AssDialog>[];

    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      final start = d.startTime.time;
      final end = d.endTime.time;
      if (start == null || end == null || end <= start) continue;

      final baseTagsAss = _baseTagsAssWithoutKaraoke(d);
      final String textAss;
      if (preserveOriginalText) {
        textAss = d.text.getAss();
      } else {
        final raw = d.text.segments.map((s) => s.text).join();
        final normalized = _normalizeTextForFx(raw);
        textAss = '$baseTagsAss${_escapeAssText(normalized)}';
      }

      final firstFrame = _frameFromMs(start, frameMs);
      final lastFrameExclusive = (end / frameMs).ceil();
      final totalFrames = (lastFrameExclusive - firstFrame).clamp(0, 1 << 30);
      if (totalFrames <= 0) continue;

      final out = <AssDialog>[];
      final emitter = AssFxEmitter(out);
      final units = <AssFrameUnit>[];

      int si = 0;
      for (int f = firstFrame; f < lastFrameExclusive; f += stepFrames) {
        final f2 = (f + stepFrames) > lastFrameExclusive ? lastFrameExclusive : (f + stepFrames);

        var absStart = _msFromFrame(f, frameMs);
        var absEnd = _msFromFrame(f2, frameMs);

        if (absStart < start) absStart = start;
        if (absEnd > end) absEnd = end;
        if (absEnd <= absStart) continue;

        final mid = absStart + ((absEnd - absStart) ~/ 2);

        final fx = auto.createDialog(
          startMs: absStart,
          endMs: absEnd,
          styleName: d.styleName,
          layer: d.layer + layerOffset,
          name: d.name,
          marginL: d.marginL,
          marginR: d.marginR,
          marginV: d.marginV,
          effect: 'fx',
          commented: false,
          textAss: textAss,
        );

        units.add(
          AssFrameUnit(
            source: d,
            sourceIndex: i,
            stepIndex: si,
            frameStart: f,
            frameEnd: f2,
            frameCount: totalFrames,
            fps: fps,
            absStartMs: absStart,
            absEndMs: absEnd,
            midMs: mid,
            baseTagsAss: baseTagsAss,
            defaultDialog: fx,
          ),
        );
        si++;
      }

      for (int ui = 0; ui < units.length; ui++) {
        final u = units[ui];
        u.tf = units.length <= 1 ? 0 : ui / (units.length - 1);
      }

      for (final u in units) {
        if (onFrameEnv != null) {
          onFrameEnv!(
            AssFrameTemplateEnv(
              shared: ctx.shared,
              basePos: _effectiveBasePosForDialog(d),
              orgline: d,
              sourceIndex: i,
              units: units,
              unit: u,
              line: u.defaultDialog,
              emit: emitter,
            ),
          );
        } else {
          emitter.emit(u.defaultDialog);
        }
      }

      if (commentOriginal) {
        d.commented = true;
        ctx.touchDialog(d);
      }

      if (out.isNotEmpty) {
        if (afterSource) {
          dialogs.insertAll(i + 1, out);
        } else {
          globalOut.addAll(out);
        }
        generatedTotal += out.length;
      }
      ctx.log('splitLineFbfFx: dialog#$i fps=$fps stepFrames=$stepFrames generated=${out.length}');
    }

    if (!afterSource && globalOut.isNotEmpty) {
      switch (outputStrategy.placement) {
        case AssGeneratedOutputPlacement.appendToEnd:
          dialogs.addAll(globalOut);
          break;
        case AssGeneratedOutputPlacement.prependToStart:
          dialogs.insertAll(0, globalOut);
          break;
        case AssGeneratedOutputPlacement.insertAtIndex:
          final idx = (outputStrategy.index ?? dialogs.length).clamp(0, dialogs.length);
          dialogs.insertAll(idx, globalOut);
          break;
        case AssGeneratedOutputPlacement.afterSource:
          break;
      }
    }

    ctx.log('splitLineFbfFx: totalGenerated=$generatedTotal');
  }
}

class _AssOnShapeExpandOp extends AssAutomationOp {
  final int layerOffset;
  final bool commentOriginal;
  final String effect;
  final AssGeneratedOutputStrategy outputStrategy;
  final AssShapeExpandEnvCallback? onShapeExpandEnv;

  const _AssOnShapeExpandOp({
    required this.layerOffset,
    required this.commentOriginal,
    required this.effect,
    required this.outputStrategy,
    required this.onShapeExpandEnv,
  });

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final afterSource = outputStrategy.placement == AssGeneratedOutputPlacement.afterSource;
    final indices = ctx.selection.toList()
      ..sort((a, b) => afterSource ? b.compareTo(a) : a.compareTo(b));
    int generatedTotal = 0;
    final globalOut = <AssDialog>[];

    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      final start = d.startTime.time;
      final end = d.endTime.time;
      if (start == null || end == null || end <= start) continue;

      final basePos = _effectiveBasePosForDialog(d);
      // Expand appearance while preserving original multi-line layout:
      // - First compute visual line breaks for the whole line.
      // - Then expand each tag-segment piece inside each visual line.
      final align = _effectiveAlignForDialog(d);
      final baseStyleState = AssTextStyleState.fromStyle(d.style);
      var state = baseStyleState.copy();

      // Transform state (persistent across segments).
      double fax = 0.0;
      double fay = 0.0;
      double frx = 0.0;
      double fry = 0.0;
      double frz = d.style.angle;
      double shad = d.style.shadow;
      double xshad = shad;
      double yshad = shad;
      bool xshadExplicit = false;
      bool yshadExplicit = false;
      int p = 1;

      AssTagPosition org = basePos.pos;
      bool orgExplicit = false;

      // Visual lines built from pieces. Each piece holds the *effective* style and transform state.
      final visualLines = <List<({int segmentIndex, String text, AssTextStyleState style, double fax, double fay, double frx, double fry, double frz, double xshad, double yshad, int p, AssTagPosition org, bool orgExplicit})>>[];
      final visualLineStates = <AssTextStyleState>[];
      visualLines.add([]);
      visualLineStates.add(state.copy());

      void startNewVisualLine() {
        visualLines.add([]);
        visualLineStates.add(state.copy());
      }

      for (int si = 0; si < d.text.segments.length; si++) {
        final seg = d.text.segments[si];
        final t = seg.overrideTags;
        if (t != null) {
          // Handle \rStyleName by resetting to that style when possible.
          // This is important for font changes like \fn which are often applied via \r.
          final r = t.getTagValue('r');
          if (r != null) {
            final styleName = r.trim();
            AssStyle resetStyle;
            if (styleName.isEmpty) {
              resetStyle = d.style;
            } else {
              try {
                resetStyle = ctx.styleByName(styleName);
              } catch (_) {
                resetStyle = d.style;
              }
            }
            final resetTo = AssTextStyleState.fromStyle(resetStyle);
            state = resetTo.copy();
            state.applyOverrideTags(t, resetTo: resetTo);
          } else {
            state.applyOverrideTags(t, resetTo: baseStyleState);
          }

          final orgTag = t.originalPosition;
          if (orgTag != null) {
            org = orgTag;
            orgExplicit = true;
          }

          final vFax = _parseTagDouble(t, 'fax');
          if (vFax != null) fax = vFax;
          final vFay = _parseTagDouble(t, 'fay');
          if (vFay != null) fay = vFay;
          final vFrx = _parseTagDouble(t, 'frx');
          if (vFrx != null) frx = vFrx;
          final vFry = _parseTagDouble(t, 'fry');
          if (vFry != null) fry = vFry;
          final vFrz = _parseTagDouble(t, 'frz');
          if (vFrz != null) frz = vFrz;

          final vShad = _parseTagDouble(t, 'shad');
          if (vShad != null) {
            shad = vShad;
            if (!xshadExplicit) xshad = shad;
            if (!yshadExplicit) yshad = shad;
          }
          final vXshad = _parseTagDouble(t, 'xshad');
          if (vXshad != null) {
            xshad = vXshad;
            xshadExplicit = true;
          }
          final vYshad = _parseTagDouble(t, 'yshad');
          if (vYshad != null) {
            yshad = vYshad;
            yshadExplicit = true;
          }

          final vP = _parseTagInt(t, 'p');
          if (vP != null) p = vP;
        }

        // Split by line breaks, but keep pieces in the same visual line.
        final s = seg.text;
        int idx = 0;
        final buf = StringBuffer();

        void flushPiece() {
          final text = buf.toString();
          buf.clear();
          if (text.isEmpty) return;
          visualLines.last.add((
            segmentIndex: si,
            text: text,
            style: state.copy(),
            fax: fax,
            fay: fay,
            frx: frx,
            fry: fry,
            frz: frz,
            xshad: xshad,
            yshad: yshad,
            p: p,
            org: org,
            orgExplicit: orgExplicit,
          ));
        }

        while (idx < s.length) {
          final ch = s[idx];
          if (ch == '\n') {
            flushPiece();
            startNewVisualLine();
            idx++;
            continue;
          }
          if (ch == '\\' && idx + 1 < s.length) {
            final n = s[idx + 1];
            if (n == 'N' || n == 'n') {
              flushPiece();
              startNewVisualLine();
              idx += 2;
              continue;
            }
          }
          buf.write(ch);
          idx++;
        }
        flushPiece();
      }

      // Measure baseline-aligned layout per visual line.
      final lineWidths = List<double>.filled(visualLines.length, 0.0);
      final lineAscents = List<double>.filled(visualLines.length, 0.0);
      final lineDescents = List<double>.filled(visualLines.length, 0.0);

      final measuredLines = <List<({int segmentIndex, String text, double width, double ascent, double descent, AssFont font, double fax, double fay, double frx, double fry, double frz, double xshad, double yshad, int p, AssTagPosition org, bool orgExplicit, AssTextStyleState style})>>[];

      for (int li = 0; li < visualLines.length; li++) {
        final pieces = visualLines[li];
        final measured = <({int segmentIndex, String text, double width, double ascent, double descent, AssFont font, double fax, double fay, double frx, double fry, double frz, double xshad, double yshad, int p, AssTagPosition org, bool orgExplicit, AssTextStyleState style})>[];

        if (pieces.isEmpty) {
          // Blank visual line: keep height using current style metrics.
          final st = visualLineStates[li];
          final font = await ctx.shared.fontForTextState(styleName: d.styleName, state: st);
          final m = font.metrics();
          lineAscents[li] = math.max(lineAscents[li], m?.ascent ?? 0.0);
          lineDescents[li] = math.max(lineDescents[li], m?.descent ?? 0.0);
          measuredLines.add(measured);
          continue;
        }

        for (final pz in pieces) {
          final font = await ctx.shared.fontForTextState(styleName: d.styleName, state: pz.style);
          final textAll = _normalizeTextForFx(pz.text.replaceAll(r'\h', ' '));
          final extAll = font.textExtents(textAll);
          final widthAll = extAll?.width ?? 0.0;

          final m = font.metrics();
          final ascent = m?.ascent ?? ((extAll?.height ?? 0.0) * 0.8);
          final descent = m?.descent ?? ((extAll?.height ?? 0.0) - ascent);

          measured.add((
            segmentIndex: pz.segmentIndex,
            text: textAll,
            width: widthAll,
            ascent: ascent,
            descent: descent,
            font: font,
            fax: pz.fax,
            fay: pz.fay,
            frx: pz.frx,
            fry: pz.fry,
            frz: pz.frz,
            xshad: pz.xshad,
            yshad: pz.yshad,
            p: pz.p,
            org: pz.org,
            orgExplicit: pz.orgExplicit,
            style: pz.style,
          ));

          lineWidths[li] += widthAll;
          lineAscents[li] = math.max(lineAscents[li], ascent);
          lineDescents[li] = math.max(lineDescents[li], descent);
        }
        measuredLines.add(measured);
      }

      final lineHeights = List<double>.generate(
        measuredLines.length,
        (li) => math.max(0.0, lineAscents[li] + lineDescents[li]),
      );
      double blockWidth = 0.0;
      double blockHeight = 0.0;
      for (int li = 0; li < measuredLines.length; li++) {
        blockWidth = math.max(blockWidth, lineWidths[li]);
        blockHeight += lineHeights[li];
      }
      if (blockWidth <= 0 && blockHeight <= 0) continue;

      final anchor = basePos.pos;
      final blockLeft = switch (align) {
        1 || 4 || 7 => anchor.x,
        2 || 5 || 8 => anchor.x - (blockWidth * 0.5),
        3 || 6 || 9 => anchor.x - blockWidth,
        _ => anchor.x - (blockWidth * 0.5),
      };
      final blockTop = switch (align) {
        7 || 8 || 9 => anchor.y,
        4 || 5 || 6 => anchor.y - (blockHeight * 0.5),
        1 || 2 || 3 => anchor.y - blockHeight,
        _ => anchor.y - blockHeight,
      };

      final units = <AssShapeExpandUnit>[];
      final out = <AssDialog>[];
      final emitter = AssFxEmitter(out);

      double yCursor = 0.0;
      for (int li = 0; li < measuredLines.length; li++) {
        final lineW = lineWidths[li];
        final lineH = lineHeights[li];
        final lineTop = blockTop + yCursor;
        final baseline = lineTop + lineAscents[li];

        final lineLeft = switch (align) {
          1 || 4 || 7 => blockLeft,
          2 || 5 || 8 => blockLeft + (blockWidth - lineW) * 0.5,
          3 || 6 || 9 => blockLeft + (blockWidth - lineW),
          _ => blockLeft,
        };

        double xCursor = 0.0;
        int layerInLine = 0;

        for (final mz in measuredLines[li]) {
          final textPiece = mz.text;
          final widthAll = mz.width;

          if (textPiece.trim().isNotEmpty) {
            // Important: do not "reallocate by bounding box" here, otherwise leading spaces
            // (which affect layout) would be lost and the visual position would drift.
            final paths = mz.font.getTextToAssPaths(textPiece);
            if (paths != null) {
              final pFactor = 1.0 / math.pow(2.0, (mz.p - 1).toDouble());
              final sx = (mz.style.scaleX / 100.0) * pFactor;
              final sy = (mz.style.scaleY / 100.0) * pFactor;

              // Approximate unscaled height for asc logic.
              final extCore = mz.font.textExtents(textPiece);
              final effSy = sy == 0 ? 1.0 : sy;
              final hScaled = extCore?.height ?? paths.boundingBox().height;
              final h = hScaled / effSy;

              final posX = lineLeft + xCursor;
              final posY = lineTop + (lineAscents[li] - mz.ascent);
              final posPiece = AssTagPosition(posX, posY);
              final orgPiece = mz.orgExplicit ? mz.org : posPiece;

              _expandAssPathsAppearance(
                paths: paths,
                an: 7,
                pos: posPiece,
                org: orgPiece,
                fax: mz.fax,
                fay: mz.fay,
                frx: mz.frx,
                fry: mz.fry,
                frz: mz.frz,
                scaleX: sx,
                scaleY: sy,
                xshad: mz.xshad,
                yshad: mz.yshad,
                heightUnscaled: h,
              );

              final outTags = AssOverrideTags()
                ..setAlignment(7)
                ..setPos(posPiece)
                ..addTag('p', 1)
                ..addTag('bord', 0)
                ..addTag('shad', 0);

              final fx = AssDialog(
                layer: d.layer + layerOffset + layerInLine,
                startTime: AssTime(time: start),
                endTime: AssTime(time: end),
                styleName: d.styleName,
                name: d.name,
                marginL: d.marginL,
                marginR: d.marginR,
                marginV: d.marginV,
                effect: effect,
                text: AssText(
                  segments: [
                    AssTextSegment(
                      text: paths.toString(),
                      overrideTags: outTags,
                    ),
                  ],
                ),
                header: d.header,
                commented: false,
                style: d.style,
              );

              final u = AssShapeExpandUnit(
                source: d,
                sourceIndex: i,
                segmentIndex: mz.segmentIndex,
                segmentLineIndex: li,
                absStartMs: start,
                absEndMs: end,
                an: 7,
                pos: posPiece,
                org: orgPiece,
                text: textPiece,
                paths: paths,
                defaultDialog: fx,
              );

              units.add(u);
              layerInLine++;
            }
          }

          xCursor += widthAll;
        }

        yCursor += lineH;
      }

      if (units.isEmpty) continue;

      for (final u in units) {
        if (onShapeExpandEnv != null) {
          onShapeExpandEnv!(
            AssShapeExpandTemplateEnv(
              shared: ctx.shared,
              basePos: basePos,
              orgline: d,
              sourceIndex: i,
              units: units,
              unit: u,
              line: u.defaultDialog,
              emit: emitter,
            ),
          );
        } else {
          emitter.emit(u.defaultDialog);
        }
      }

      if (out.isNotEmpty && commentOriginal) {
        d.commented = true;
        ctx.touchDialog(d);
      }

      if (out.isNotEmpty) {
        if (afterSource) {
          dialogs.insertAll(i + 1, out);
        } else {
          globalOut.addAll(out);
        }
        generatedTotal += out.length;
        ctx.log('onShapeExpand: dialog#$i generated=${out.length}');
      }
    }

    if (!afterSource && globalOut.isNotEmpty) {
      switch (outputStrategy.placement) {
        case AssGeneratedOutputPlacement.appendToEnd:
          dialogs.addAll(globalOut);
          break;
        case AssGeneratedOutputPlacement.prependToStart:
          dialogs.insertAll(0, globalOut);
          break;
        case AssGeneratedOutputPlacement.insertAtIndex:
          final idx = (outputStrategy.index ?? dialogs.length).clamp(0, dialogs.length);
          dialogs.insertAll(idx, globalOut);
          break;
        case AssGeneratedOutputPlacement.afterSource:
          break;
      }
    }

    ctx.log('onShapeExpand: totalGenerated=$generatedTotal');
  }
}

class _AssSortByTimeOp extends AssAutomationOp {
  final bool stable;
  const _AssSortByTimeOp({required this.stable});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    if (stable) {
      final indexed = dialogs.asMap().entries.toList();
      indexed.sort((a, b) {
        final da = a.value;
        final db = b.value;
        final sa = da.startTime.time ?? 0;
        final sb = db.startTime.time ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        final ea = da.endTime.time ?? 0;
        final eb = db.endTime.time ?? 0;
        if (ea != eb) return ea.compareTo(eb);
        if (da.layer != db.layer) return da.layer.compareTo(db.layer);
        return a.key.compareTo(b.key);
      });
      dialogs
        ..clear()
        ..addAll(indexed.map((e) => e.value));
    } else {
      dialogs.sort((a, b) {
        final sa = a.startTime.time ?? 0;
        final sb = b.startTime.time ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        final ea = a.endTime.time ?? 0;
        final eb = b.endTime.time ?? 0;
        if (ea != eb) return ea.compareTo(eb);
        return a.layer.compareTo(b.layer);
      });
    }
    ctx.selection.clear();
    ctx.log('sortByTime: dialogs=${dialogs.length} stable=$stable');
  }
}

class _AssCommentSelectedOp extends AssAutomationOp {
  final bool commented;
  const _AssCommentSelectedOp(this.commented);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      dialogs[i].commented = commented;
      touched++;
      ctx.touchDialog(dialogs[i]);
    }
    ctx.log('commentSelected: commented=$commented touched=$touched');
  }
}

class _AssSetStyleOp extends AssAutomationOp {
  final String styleName;
  const _AssSetStyleOp(this.styleName);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final style = ctx.styleByName(styleName);
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      d.styleName = styleName;
      d.style = style;
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setStyle: styleName=$styleName touched=$touched');
  }
}

class _AssSetEffectOp extends AssAutomationOp {
  final String effect;
  const _AssSetEffectOp(this.effect);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      d.effect = effect;
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setEffect: effect=$effect touched=$touched');
  }
}

class _AssSetLayerOp extends AssAutomationOp {
  final int layer;
  const _AssSetLayerOp(this.layer);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      d.layer = layer;
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setLayer: layer=$layer touched=$touched');
  }
}

class _AssRemoveFxOp extends AssAutomationOp {
  final String effect;
  final bool includeCommented;
  final bool onlySelected;

  const _AssRemoveFxOp({
    required this.effect,
    required this.includeCommented,
    required this.onlySelected,
  });

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;

    bool shouldRemove(int index, AssDialog d) {
      if (d.effect != effect) return false;
      if (!includeCommented && d.commented) return false;
      if (onlySelected && !ctx.selection.contains(index)) return false;
      return true;
    }

    int removed = 0;
    for (int i = dialogs.length - 1; i >= 0; i--) {
      final d = dialogs[i];
      if (!shouldRemove(i, d)) continue;
      dialogs.removeAt(i);
      removed++;
      ctx.selection.remove(i);
    }

    // Selection indices are now stale; clear to avoid accidental misuse.
    ctx.selection.clear();
    ctx.log('removeFx: effect=$effect includeCommented=$includeCommented onlySelected=$onlySelected removed=$removed');
  }
}

class _AssDuplicateSelectedOp extends AssAutomationOp {
  final int times;
  final int layerOffset;
  final int timeOffsetMs;
  final AssGeneratedOutputStrategy outputStrategy;

  const _AssDuplicateSelectedOp({
    required this.times,
    required this.layerOffset,
    required this.timeOffsetMs,
    required this.outputStrategy,
  });

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    if (times <= 0) return;
    final dialogs = ctx.ensureDialogs().dialogs;

    final afterSource = outputStrategy.placement == AssGeneratedOutputPlacement.afterSource;
    final indices = ctx.selection.toList()
      ..sort((a, b) => afterSource ? b.compareTo(a) : a.compareTo(b));

    final globalOut = <AssDialog>[];
    int generated = 0;

    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      final out = <AssDialog>[];
      for (int k = 0; k < times; k++) {
        final copy = AssDialog(
          layer: d.layer + layerOffset,
          startTime: AssTime(time: (d.startTime.time ?? 0) + timeOffsetMs),
          endTime: AssTime(time: (d.endTime.time ?? 0) + timeOffsetMs),
          styleName: d.styleName,
          name: d.name,
          marginL: d.marginL,
          marginR: d.marginR,
          marginV: d.marginV,
          effect: d.effect,
          text: AssText.parse(d.text.getAss()) ?? d.text,
          header: d.header,
          commented: d.commented,
          style: d.style,
        );
        out.add(copy);
      }

      if (afterSource) {
        dialogs.insertAll(i + 1, out);
      } else {
        globalOut.addAll(out);
      }
      generated += out.length;
    }

    if (!afterSource && globalOut.isNotEmpty) {
      switch (outputStrategy.placement) {
        case AssGeneratedOutputPlacement.appendToEnd:
          dialogs.addAll(globalOut);
          break;
        case AssGeneratedOutputPlacement.prependToStart:
          dialogs.insertAll(0, globalOut);
          break;
        case AssGeneratedOutputPlacement.insertAtIndex:
          final idx = (outputStrategy.index ?? dialogs.length).clamp(0, dialogs.length);
          dialogs.insertAll(idx, globalOut);
          break;
        case AssGeneratedOutputPlacement.afterSource:
          break;
      }
    }

    ctx.log('duplicateSelected: times=$times layerOffset=$layerOffset timeOffsetMs=$timeOffsetMs generated=$generated');
  }
}

class _AssCopyToLayerOp extends AssAutomationOp {
  final int layer;
  final int timeOffsetMs;
  final AssGeneratedOutputStrategy outputStrategy;

  const _AssCopyToLayerOp({
    required this.layer,
    required this.timeOffsetMs,
    required this.outputStrategy,
  });

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    final afterSource = outputStrategy.placement == AssGeneratedOutputPlacement.afterSource;
    final indices = ctx.selection.toList()
      ..sort((a, b) => afterSource ? b.compareTo(a) : a.compareTo(b));

    final globalOut = <AssDialog>[];
    int generated = 0;

    for (final i in indices) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      final copy = AssDialog(
        layer: layer,
        startTime: AssTime(time: (d.startTime.time ?? 0) + timeOffsetMs),
        endTime: AssTime(time: (d.endTime.time ?? 0) + timeOffsetMs),
        styleName: d.styleName,
        name: d.name,
        marginL: d.marginL,
        marginR: d.marginR,
        marginV: d.marginV,
        effect: d.effect,
        text: AssText.parse(d.text.getAss()) ?? d.text,
        header: d.header,
        commented: d.commented,
        style: d.style,
      );

      if (afterSource) {
        dialogs.insert(i + 1, copy);
      } else {
        globalOut.add(copy);
      }
      generated++;
    }

    if (!afterSource && globalOut.isNotEmpty) {
      switch (outputStrategy.placement) {
        case AssGeneratedOutputPlacement.appendToEnd:
          dialogs.addAll(globalOut);
          break;
        case AssGeneratedOutputPlacement.prependToStart:
          dialogs.insertAll(0, globalOut);
          break;
        case AssGeneratedOutputPlacement.insertAtIndex:
          final idx = (outputStrategy.index ?? dialogs.length).clamp(0, dialogs.length);
          dialogs.insertAll(idx, globalOut);
          break;
        case AssGeneratedOutputPlacement.afterSource:
          break;
      }
    }

    ctx.log('copyToLayer: layer=$layer timeOffsetMs=$timeOffsetMs generated=$generated');
  }
}

class _AssMapDialogsOp extends AssAutomationOp {
  final AssDialogMapper mapper;
  const _AssMapDialogsOp(this.mapper);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      dialogs[i] = mapper(dialogs[i], i);
      touched++;
      ctx.touchDialog(dialogs[i]);
    }
    ctx.log('mapDialogs: touched=$touched');
  }
}

class _AssShiftTimeOp extends AssAutomationOp {
  final int deltaMs;
  final bool clampAtZero;
  const _AssShiftTimeOp(this.deltaMs, {required this.clampAtZero});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      final s = d.startTime.time;
      final e = d.endTime.time;
      if (s == null || e == null) continue;
      var ns = s + deltaMs;
      var ne = e + deltaMs;
      if (clampAtZero) {
        if (ns < 0) ns = 0;
        if (ne < 0) ne = 0;
      }
      if (ne < ns) ne = ns;
      d.startTime.time = ns;
      d.endTime.time = ne;
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('shiftTime: deltaMs=$deltaMs touched=$touched');
  }
}

class _AssMapTextOp extends AssAutomationOp {
  final AssTextMapper mapper;
  const _AssMapTextOp(this.mapper);

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in d.text.segments) {
        seg.text = mapper(seg.text, d, i);
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('mapText: touched=$touched');
  }
}

class _AssEnsureLeadingTagsOp extends AssAutomationOp {
  const _AssEnsureLeadingTagsOp();

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      if (d.text.segments.isEmpty) {
        d.text.segments.add(AssTextSegment(text: '', overrideTags: AssOverrideTags()));
        touched++;
        ctx.touchDialog(d);
        continue;
      }
      if (d.text.segments.first.overrideTags == null) {
        d.text.segments.insert(0, AssTextSegment(text: '', overrideTags: AssOverrideTags()));
        touched++;
        ctx.touchDialog(d);
      }
    }
    ctx.log('ensureLeadingTags: touched=$touched');
  }
}

abstract class _AssTagsScopeOp extends AssAutomationOp {
  final AssTagScope scope;
  const _AssTagsScopeOp({required this.scope});

  Iterable<AssTextSegment> targetSegments(AssText text) sync* {
    switch (scope) {
      case AssTagScope.leading:
        if (text.segments.isEmpty) {
          text.segments.add(AssTextSegment(text: '', overrideTags: AssOverrideTags()));
        }
        if (text.segments.first.overrideTags == null) {
          text.segments.insert(0, AssTextSegment(text: '', overrideTags: AssOverrideTags()));
        }
        yield text.segments.first;
        return;
      case AssTagScope.existingSegmentsOnly:
        for (final s in text.segments) {
          if (s.overrideTags != null) yield s;
        }
        return;
      case AssTagScope.allSegments:
        for (final s in text.segments) {
          s.overrideTags ??= AssOverrideTags();
          yield s;
        }
        return;
    }
  }
}

abstract class _AssTagEditOp extends AssAutomationOp {
  final String tagName;
  final AssTagScope scope;

  const _AssTagEditOp(this.tagName, {required this.scope});

  Iterable<AssTextSegment> _targetSegments(AssText text) sync* {
    switch (scope) {
      case AssTagScope.leading:
        if (text.segments.isEmpty) {
          text.segments.add(AssTextSegment(text: '', overrideTags: AssOverrideTags()));
        }
        if (text.segments.first.overrideTags == null) {
          text.segments.insert(0, AssTextSegment(text: '', overrideTags: AssOverrideTags()));
        }
        yield text.segments.first;
        return;
      case AssTagScope.existingSegmentsOnly:
        for (final s in text.segments) {
          if (s.overrideTags != null) yield s;
        }
        return;
      case AssTagScope.allSegments:
        for (final s in text.segments) {
          s.overrideTags ??= AssOverrideTags();
          yield s;
        }
        return;
    }
  }
}

class _AssSetTagOp extends _AssTagEditOp {
  final String value;
  const _AssSetTagOp(super.tagName, this.value, {required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in _targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        seg.overrideTags!.setTag(tagName, value);
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setTag: $tagName=$value scope=$scope touched=$touched');
  }
}

class _AssRemoveTagOp extends _AssTagEditOp {
  const _AssRemoveTagOp(super.tagName, {required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in _targetSegments(d.text)) {
        seg.overrideTags?.removeTag(tagName);
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('removeTag: $tagName scope=$scope touched=$touched');
  }
}

class _AssSetAlignmentOp extends _AssTagsScopeOp {
  final int an;
  const _AssSetAlignmentOp(this.an, {required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        seg.overrideTags!.alignmentCode = an;
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setAlignment: an=$an scope=$scope touched=$touched');
  }
}

class _AssSetPosOp extends _AssTagsScopeOp {
  final AssTagPosition pos;
  const _AssSetPosOp(this.pos, {required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        seg.overrideTags!.position = pos;
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setPos: pos=$pos scope=$scope touched=$touched');
  }
}

class _AssRemovePosOp extends _AssTagsScopeOp {
  const _AssRemovePosOp({required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags?.removeTag('pos');
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('removePos: scope=$scope touched=$touched');
  }
}

class _AssSetOrgOp extends _AssTagsScopeOp {
  final AssTagPosition org;
  const _AssSetOrgOp(this.org, {required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        seg.overrideTags!.originalPosition = org;
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setOrg: org=$org scope=$scope touched=$touched');
  }
}

class _AssSetMoveOp extends _AssTagsScopeOp {
  final AssMove mv;
  const _AssSetMoveOp(this.mv, {required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        seg.overrideTags!.move = mv;
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setMove: move=$mv scope=$scope touched=$touched');
  }
}

class _AssRemoveMoveOp extends _AssTagsScopeOp {
  const _AssRemoveMoveOp({required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags?.removeTag('move');
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('removeMove: scope=$scope touched=$touched');
  }
}

class _AssSetClipRectOp extends _AssTagsScopeOp {
  final AssTagClipRect clip;
  final bool inverse;
  const _AssSetClipRectOp(this.clip, {required this.inverse, required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        if (inverse) {
          seg.overrideTags!.iclipRect = clip;
        } else {
          seg.overrideTags!.clipRect = clip;
        }
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setClipRect: inverse=$inverse clip=$clip scope=$scope touched=$touched');
  }
}

class _AssSetClipVectOp extends _AssTagsScopeOp {
  final AssTagClipVect clip;
  final bool inverse;
  const _AssSetClipVectOp(this.clip, {required this.inverse, required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        if (inverse) {
          seg.overrideTags!.iclipVect = clip;
        } else {
          seg.overrideTags!.clipVect = clip;
        }
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setClipVect: inverse=$inverse clip=$clip scope=$scope touched=$touched');
  }
}

class _AssAddTransformOp extends _AssTagsScopeOp {
  final AssTransformation tr;
  const _AssAddTransformOp(this.tr, {required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        seg.overrideTags!.transformations.add(tr);
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('addTransform: scope=$scope touched=$touched');
  }
}

class _AssSetFadOp extends _AssTagsScopeOp {
  final int tInMs;
  final int tOutMs;
  const _AssSetFadOp(this.tInMs, this.tOutMs, {required super.scope});

  @override
  Future<void> apply(AssAutomationContext ctx) async {
    final dialogs = ctx.ensureDialogs().dialogs;
    int touched = 0;
    for (final i in ctx.selection) {
      if (i < 0 || i >= dialogs.length) continue;
      final d = dialogs[i];
      for (final seg in targetSegments(d.text)) {
        seg.overrideTags ??= AssOverrideTags();
        seg.overrideTags!.setTag('fad', '$tInMs,$tOutMs');
      }
      touched++;
      ctx.touchDialog(d);
    }
    ctx.log('setFad: tInMs=$tInMs tOutMs=$tOutMs scope=$scope touched=$touched');
  }
}
