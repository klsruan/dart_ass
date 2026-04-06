# Automation — `dart_ass`

This document explains the automation API (`lib/src/ass/ass_automation.dart`) and how to use it to build
subtitle editing and FX generation workflows in pure Dart.

If you are reading this on pub.dev, this file is intended to be a complete, practical reference.

## Mental model

An automation run is:

1) Parse an `.ass` file into an `Ass`
2) Build a `flow()` (selection + operations)
3) `await flow.run()` mutates the `ass` in memory (insert/remove/edit lines)
4) Save `ass` back to disk

Flows are **always async** because measuring text uses FreeType via FFI.

## Quick start

Generate one `Effect=fx` line per karaoke unit:

```dart
import 'package:dart_ass/dart_ass.dart';

Future<void> main() async {
  final ass = Ass(filePath: 'example/test.ass');
  await ass.parse();

  await AssAutomation(ass)
    .flow()
    .selectAll()
    .whereKaraoke()
    .ensureMetrics(useTextData: true)
    .splitKaraokeFx(
      mode: AssKaraokeSplitMode.syllables,
      onKaraokeEnv: (env) {
        env.retime(AssRetimeMode.unit);
        env.tags.setPos(AssTagPosition(env.unit.absPosX ?? 0, env.unit.absPosY ?? 0));
        env.addDialog();
      },
    )
    .run();

  await ass.toFile('example/out.ass');
}
```

## Concepts

### Selection

Selection is a set of indices inside `ass.dialogs!.dialogs`. A typical flow starts with:

```dart
final flow = AssAutomation(ass).flow().selectAll();
```

Then refine:

- `where((dialog, index) => ...)`
- `whereKaraoke()` (keeps only lines with karaoke tags)

### Metrics (`ensureMetrics`)

If you need measured width/height/x for chars or karaoke blocks, call:

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .ensureMetrics(useTextData: true)
  .run();
```

Internally this calls `await ass.dialogs?.extend(useTextData)`, which populates `dialog.line` (`AssLine`) and enables:

- line-break layout
- `chars(...)` / `words(...)`
- karaoke metrics (`prespaceWidth`, `coreWidth`, `left/center/right`, etc.)

### `AssAutomationShared` (reusable caches/resources)

Some callbacks are **synchronous** (ex: `onKaraokeEnv`), but FreeType/font init (`AssFont.init()`) is **async** and expensive.
`AssAutomationShared` solves that by caching and warming resources before you enter sync callbacks.

Most users do not need to create a shared manually: `flow()` creates an internal
shared instance and disposes it automatically when `run()` finishes.

Create your own shared only if you want to reuse caches across multiple flows.

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .whereKaraoke()
  .warmupFonts()
  .splitKaraokeFx(onKaraokeEnv: (env) {
    final font = env.shared.warmedFontForStyle(env.orgline.styleName);
    // ...
  })
  .run();
```

If you do want an explicit shared but dislike manual dispose, use:

```dart
await AssAutomationShared.using((shared) async {
  return AssAutomation(ass)
    .flow(shared: shared)
    .selectAll()
    .warmupFonts()
    .run();
});
```

## FX generators

FX generators typically:

- comment the original line (optional)
- insert new lines after it (`Effect=fx`) or using an output strategy
- call your callback with an `env` object (templater-like)

### Output placement (`outputStrategy`)

Split operations can control where generated dialogs are written:

- `const AssGeneratedOutputStrategy.afterSource()` (default)
- `const AssGeneratedOutputStrategy.appendToEnd()`
- `const AssGeneratedOutputStrategy.prependToStart()`
- `const AssGeneratedOutputStrategy.insertAt(index)`

Example:

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .whereKaraoke()
  .ensureMetrics(useTextData: true)
  .splitKaraokeFx(
    outputStrategy: const AssGeneratedOutputStrategy.appendToEnd(),
    onKaraokeEnv: (env) => env.addDialog(),
  )
  .run();
```

### Per character: `splitCharsFx`

Splits the line into character units. It works without metrics (timing only), but if you call
`ensureMetrics()` first you also get layout fields (`abs*`, `x/left/center/right`, `xf`, etc.).

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .whereKaraoke()
  .ensureMetrics(useTextData: true)
  .splitCharsFx(
    timeMode: AssSplitTimeMode.proportional,
    stepMs: 35,
    durMs: 300,
    onCharEnv: (env) {
      env.retime(AssRetimeMode.unit);
      env.tags.setPos(AssTagPosition(env.unit.absPosX ?? 0, env.unit.absPosY ?? 0));
      env.tags.addTag('bord', '2');
      env.addDialog();
    },
  )
  .run();
```

### Per word: `splitWordsFx`

Splits the line into word tokens (whitespace or non-whitespace). Requires `ensureMetrics()` for proper `x/width/lineIndex`.

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .ensureMetrics(useTextData: true)
  .splitWordsFx(onWordEnv: (env) {
    env.retime(AssRetimeMode.unit);
    env.tags.setPos(AssTagPosition(env.unit.absPosX ?? 0, env.unit.absPosY ?? 0));
    env.addDialog();
  })
  .run();
```

### Per karaoke block: `splitKaraokeFx`

Splits by karaoke tags. Supports `\k`, `\kf`, `\ko`, `\K` (alias of `\kf`) and `\kt`.

You can choose a grouping mode:

- `AssKaraokeSplitMode.blocks`: one unit per karaoke timing tag
- `AssKaraokeSplitMode.syllables`: merges multi-highlight blocks starting with `#`/`＃`
  and exposes all highlight windows in `env.unit.highlights`

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .whereKaraoke()
  .ensureMetrics(useTextData: true)
  .splitKaraokeFx(
    mode: AssKaraokeSplitMode.syllables,
    onKaraokeEnv: (env) {
      env.retime(AssRetimeMode.unit);
      env.tags.setPos(AssTagPosition(env.unit.absPosX ?? 0, env.unit.absPosY ?? 0));
      env.addDialog();
    },
  )
  .run();
```

Karaoke units also expose:

- `tf`: time fraction across units (0..1)
- `xf`: x fraction across units (0..1, when x/center is known)
- `highlights`: one or more highlight windows (syllable mode)

### Frame-by-frame (FBF): `splitLineFbfFx`

Generates one `Effect=fx` line per frame (or per `stepFrames`) for the full line range.

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .splitLineFbfFx(
    fps: 23.976,
    stepFrames: 1,
    onFrameEnv: (env) {
      env.retime(AssRetimeMode.unit);
      env.tags.addTag('frz', ((env.unit.tf ?? 0) * 360).toStringAsFixed(2));
      env.addDialog();
    },
  )
  .run();
```

### Nested FBF inside split callbacks: `env.fbf(...)`

If you want frame-by-frame output **inside** a karaoke unit:

```dart
.splitKaraokeFx(
  mode: AssKaraokeSplitMode.syllables,
  onKaraokeEnv: (env) {
    env.fbf(
      fps: 23.976,
      stepFrames: 2,
      onFrameEnv: (fenv) {
        fenv.retime(AssRetimeMode.unit);
        fenv.bakeMoveToPosAtMid();
        fenv.addDialog();
      },
    );
  },
)
```

## Shapes (text → drawing) inside karaoke/char callbacks

If you want to replace `env.line` text by a `\p` drawing:

1) use `AssAutomationShared` + `.warmupFonts()`
2) in the callback, read the warmed font
3) call `font.getTextToShape(text)`
4) set `\p1` and replace `env.line.text`

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .whereKaraoke()
  .warmupFonts()
  .splitKaraokeFx(onKaraokeEnv: (env) {
    env.retime(AssRetimeMode.unit);
    env.tags.addTag('an', '7');
    env.tags.addTag('pos', '${env.unit.absLeft},${env.unit.absTop}');
    env.tags.addTag('p', '1');
    env.tags.addTag('bord', '0');
    env.tags.addTag('shad', '0');

    final font = env.shared.warmedFontForStyle(env.orgline.styleName);
    final shape = font?.getTextToShape(env.unit.textSpaceStripped ?? env.unit.text) ?? '';

    env.line.text = AssText(
      segments: [AssTextSegment(text: shape, overrideTags: env.tags)],
    );
    env.addDialog();
  })
  .run();
```

## Text expand (bake tags into a shape)

If you want to convert dialogue text into a `\p1` drawing and bake common tags
into the vector path (position, scale, rotation, shear, perspective), see:

- `AssAutomationFlow.onShapeExpand(...)`
- `example/dart_ass_expand_text_example.dart`

## Editing / transforming dialogs (non-FX)

These ops mutate the selected dialogs in-place:

- `shiftTime(deltaMs, {clampAtZero = true})`
- `mapText((text, dialog, index) => String)` / `replaceText(pattern, replacement)`
- `setStyle(styleName)`
- `commentSelected(true|false)`
- `sortByTime({stable = true})`
- `insertAt(index, dialogs)` / `append(dialogs)`
- `insertDialogAt(index, dialog)` / `prependDialog(dialog)` / `appendDialog(dialog)`
- `removeSelected()`
- `setEffect(effect)`
- `setLayer(layer)`

Common high-level helpers:

- `removeFx({effect = 'fx'})`
- `duplicateSelected(...)`
- `copyToLayer(layer: ...)`

## Tag editing (`ensureLeadingTags`, `setTag`, `removeTag`)

Override-tag ops work on `AssTextSegment.overrideTags` and support `AssTagScope`:

- `leading`: only the first override block (creates if missing)
- `existingSegmentsOnly`: only segments which already have tags
- `allSegments`: ensures every segment has tags then edits all

Example:

```dart
await AssAutomation(ass)
  .flow()
  .selectAll()
  .ensureLeadingTags()
  .setTag('an', '5', scope: AssTagScope.leading)
  .setTag('pos', '640,360', scope: AssTagScope.leading)
  .run();
```

### Typed tag helpers

Prefer typed helpers when possible (they update the correct tag formatting):

- `setAlignment(an)`
- `setPos(AssTagPosition)`
- `setOrg(AssTagPosition)`
- `setMove(AssMove)`
- `setClipRect(AssTagClipRect, inverse: false|true)`
- `setClipVect(AssTagClipVect, inverse: false|true)`
- `addTransform(AssTransformation)`
- `addT(t1: ..., t2: ..., accel: ..., build: (t) { ... })` (typed `\t(...)` builder)
- `setFad(tInMs, tOutMs)`

### `addTag` vs `setTag` vs `replaceTag` vs typed helpers

`AssOverrideTags` is an ordered list. Adding the same tag multiple times is valid in ASS.

- `tags.addTag(name, value)` appends a new tag entry. `value` is converted to a string (`bool` → `1/0`, `null` → empty).
- `tags.setTag(name, value)` appends a new tag entry (legacy API; `value` must be a `String`).
- `tags.replaceTag(name, value)` updates existing entries (and creates it if missing).
- Typed properties like `tags.position = AssTagPosition(...)` call `replaceTag(...)` under the hood.

For templater-style code, prefer typed env helpers when possible:

```dart
env.tags.setAlignment(7);
env.tags.setPos(AssTagPosition(x, y));
env.tags.setMove(AssMove(x1: 0, y1: 0, x2: 100, y2: 100));
```

## Callback environments (`env`)

FX callbacks receive an env object with:

- `env.orgline`: original input dialog (`AssDialog`)
- `env.sourceIndex`: index of `orgline` in `ass.dialogs!.dialogs`
- `env.units`: all units for the same original line
- `env.unit`: current unit (`AssCharUnit`, `AssKaraokeUnit`, `AssFrameUnit`)
- `env.line`: default output dialog for this unit (mutate it)
- `env.emit.emit(dialog)`: emit one or more dialogs
- `env.addDialog([dialog])`: emits `dialog` or the current `env.line`
- `env.retime(mode, ...)`: helper to set `env.line.startTime/endTime`
- `env.shared`: shared caches/resources for the current flow run
- `env.basePos`: best-effort base position (`pos|move|derived`)
- `env.util`: helpers (`lerp`, `clamp`, `remap`, easing, random, `movePosAt`, etc.)
- typed tag helpers: `env.tags.setPos(...)`, `env.tags.setMove(...)`, `env.tags.setClipRect(...)`, ...
- motion helpers: `env.bakeMoveToPosAtMid()`

### `AssRetimeMode`

Common modes:

- `line`: original line range
- `unit`: current unit range
- `start2unit`: line start → unit start
- `unit2end`: unit end → line end
- `abs`: absolute time range (`absStartMs/absEndMs`)
- `delta`: add offsets to current line
- `clamp`: clamp current line inside the original line

### `AssSplitTimeMode`

Split generators which synthesize time windows (chars/words) support two timing modes:

- `indexStep` (default): `start = lineStart + (index * stepMs)` and `end = start + durMs`
- `proportional`: divides the full line time range evenly across the number of emitted units
  - in this mode, `stepMs` and `durMs` are ignored (the whole line range is covered)

## Absolute positioning rules (`abs*` fields)

When metrics exist, absolute positioning is computed from:

- measured break layout (`AssLine.lineBreaks(...)`)
- alignment (`\an` or style alignment)
- margins (`MarginL/MarginR/MarginV`)
- explicit `\pos` / `\move` anchor when present

When metrics do **not** exist, `dart_ass` still provides best-effort fallbacks:

1) `\pos(x,y)` if present on the original line
2) else `\move(x1,y1,...)` if present (uses start point)
3) else derive from `PlayRes + \an + margins`

Convenience:

- `AssCharUnit.absPosX/absPosY`
- `AssKaraokeUnit.absPosX/absPosY`

## Full flow API reference

Selection and metrics:

- `selectAll({includeComments = false})`
- `where((dialog, index) => bool)`
- `whereKaraoke()`
- `whereStyle(styleName)`
- `whereActor(actor)`
- `whereEffect(effect)`
- `ensureMetrics({useTextData = true})`
- `warmupFonts({includeComments = false})`

Edit/transform:

- `insertAt(index, dialogs)`
- `append(dialogs)`
- `removeSelected()`
- `sortByTime({stable = true})`
- `commentSelected(commented)`
- `setStyle(styleName)`
- `setEffect(effect)`
- `setLayer(layer)`
- `removeFx(...)`
- `duplicateSelected(...)`
- `copyToLayer(...)`
- `mapDialogs((dialog, index) => dialog)`
- `shiftTime(deltaMs, {clampAtZero = true})`
- `mapText((text, dialog, index) => String)`
- `replaceText(pattern, replacement)`

Tags:

- `ensureLeadingTags()`
- `setTag(tagName, value, {scope = AssTagScope.leading})`
- `removeTag(tagName, {scope = AssTagScope.leading})`
- typed: `setPos(...)`, `setMove(...)`, `setClipRect(...)`, ...

FX generators:

- `splitCharsFx(..., outputStrategy: ...)`
- `splitWordsFx(..., outputStrategy: ...)`
- `splitKaraokeFx(..., mode: ..., outputStrategy: ...)`
- `splitLineFbfFx(..., outputStrategy: ...)`
- `onShapeExpand(..., outputStrategy: ...)`

Custom:

- `custom(AssAutomationOp op)`
- `run()`

---

## Complete reference

This section documents every public type and parameter in `ass_automation.dart`.

### Core types

#### `AssAutomation`

- `AssAutomation(Ass ass)`
  - `ass`: the in-memory ASS document which will be mutated by flows.
- `flow({AssAutomationShared? shared})`
  - `shared`: optional shared cache/resources (fonts, caches) reused across runs.
- `createDialog(...)`
  - `startMs` / `endMs`: absolute time range in milliseconds.
  - `styleName`: name of an existing style in `ass.styles`.
  - `textAss`: full ASS dialogue text field, may include `{...}` overrides and `\N`.
  - `layer`, `name`, `marginL`, `marginR`, `marginV`, `effect`, `commented`: mapped to `AssDialog`.

#### `AssAutomationFlow`

A flow is immutable; each call returns a new flow with an extra operation appended.

##### Selection

- `selectAll({bool includeComments = false})`
  - `includeComments`: if true, selects commented lines too.
- `where((AssDialog dialog, int index) => bool predicate)`
  - `predicate`: called with dialog + its index inside `ass.dialogs!.dialogs`.
- `whereKaraoke()`
  - Keeps only dialogs which contain any karaoke timing tag (`\k/\kf/\ko/\K/\kt`) in any override block.
- `whereStyle(String styleName)`
- `whereActor(String actor)`
  - Filters by the ASS `Name` field (commonly used as “Actor”).
- `whereEffect(String effect)`

##### Metrics / caches

- `ensureMetrics({bool useTextData = true})`
  - Populates `dialog.line` (`AssLine`) for dialogs and measures segments.
  - `useTextData`: when true, uses override tags to compute accurate layout and karaoke metrics.
- `warmupFonts({bool includeComments = false})`
  - Pre-initializes FreeType fonts for the currently selected styles.
  - Important because FX callbacks are synchronous and cannot `await AssFont.init()`.

##### Edit / transform dialogs (in-place)

- `insertAt(int index, List<AssDialog> dialogs)`
- `append(List<AssDialog> dialogs)`
- `removeSelected()`
- `sortByTime({bool stable = true})`
  - `stable=true`: stable sort (keeps original order when times match).
- `commentSelected(bool commented)`
- `setStyle(String styleName)`
- `setEffect(String effect)`
- `setLayer(int layer)`
- `shiftTime(int deltaMs, {bool clampAtZero = true})`
- `mapDialogs((AssDialog dialog, int index) => AssDialog mapper)`
- `mapText((String text, AssDialog dialog, int index) => String mapper)`
- `replaceText(RegExp pattern, String replacement)`

##### High-level helpers

- `removeFx({String effect = 'fx', bool includeCommented = false, bool onlySelected = false})`
  - Removes dialogs matching `Effect == effect`.
  - `onlySelected`: if true, removes only within the current selection.
- `duplicateSelected({int times = 1, int layerOffset = 0, int timeOffsetMs = 0, AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource()})`
  - Generates `times` copies for each selected dialog.
- `copyToLayer({required int layer, int timeOffsetMs = 0, AssGeneratedOutputStrategy outputStrategy = const AssGeneratedOutputStrategy.afterSource()})`
  - Creates one copy per selected dialog with a fixed layer.

##### Tag operations (Flow-level)

Flow tag ops mutate the selected dialogs directly.

- `ensureLeadingTags()`
  - Ensures the first segment has an `overrideTags` block (creates one if missing).
- `setTag(String tagName, String value, {AssTagScope scope = AssTagScope.leading})`
- `removeTag(String tagName, {AssTagScope scope = AssTagScope.leading})`

`AssTagScope`:

- `leading`: only the first override block (created if missing)
- `existingSegmentsOnly`: only segments which already have `overrideTags`
- `allSegments`: ensures every segment has `overrideTags` then applies to all

##### Typed tag operations (Flow-level)

These prefer typed objects and correct ASS formatting:

- `setAlignment(int an, {scope})` → `\an`
- `setPos(AssTagPosition pos, {scope})` → `\pos`
- `removePos({scope})`
- `setOrg(AssTagPosition org, {scope})` → `\org`
- `setMove(AssMove mv, {scope})` → `\move`
- `removeMove({scope})`
- `setClipRect(AssTagClipRect clip, {bool inverse = false, scope})` → `\clip` / `\iclip`
- `setClipVect(AssTagClipVect clip, {bool inverse = false, scope})` → `\clip` / `\iclip`
- `addTransform(AssTransformation tr, {scope})` → `\t(...)`
- `setFad(int tInMs, int tOutMs, {scope})` → `\fad(tIn,tOut)`

### FX generators (Flow-level)

All split operations:

- generate `Effect=fx` output dialogs by default
- optionally comment the source dialog (`commentOriginal`)
- call your callback synchronously (`on...Env`) so you can mutate and emit

#### Output placement

All split operations accept `outputStrategy`:

- `const AssGeneratedOutputStrategy.afterSource()` (default): insert right after each source dialog
- `const AssGeneratedOutputStrategy.appendToEnd()`: append all generated dialogs at the end
- `const AssGeneratedOutputStrategy.prependToStart()`: insert all generated dialogs at the start
- `const AssGeneratedOutputStrategy.insertAt(index)`: insert all generated dialogs at a fixed position

#### `splitCharsFx(...)`

Signature (simplified):

- `stepMs` (default: `35`): time cadence per unit index.
- `durMs` (default: `300`): duration of each emitted unit.
- `timeMode` (default: `AssSplitTimeMode.indexStep`): how unit time ranges are computed (`indexStep` or `proportional`).
- `layerOffset` (default: `10`): output layer = source layer + offset.
- `includeSpaces` (default: `false`): if true, emits whitespace characters too.
- `commentOriginal` (default: `true`): comment the original dialog when output is produced.
- `preserveInlineStyle` (default: `true`): when metrics exist, applies style overrides (`\fn`, `\fs`, `\b`, `\i`, `\u`, `\s`, `\fscx`, `\fscy`, `\fsp`) matching the character effective style.
- `outputStrategy` (default: `afterSource()`): where to write generated output dialogs.
- `onCharEnv`: callback for each `AssCharUnit`.

Notes:

- Without metrics (no `ensureMetrics()`), the split still works, but layout fields are null and base positioning is derived from `env.basePos`.

#### `splitWordsFx(...)`

Signature (simplified):

- `stepMs` (default: `120`): time cadence per word index.
- `durMs` (default: `600`): duration of each emitted unit.
- `timeMode` (default: `AssSplitTimeMode.indexStep`)
- `layerOffset` (default: `10`)
- `includeSpaces` (default: `false`): if true, emits whitespace tokens too.
- `commentOriginal` (default: `true`)
- `preserveInlineStyle` (default: `true`): applies the measured effective style state for the word when available.
- `outputStrategy` (default: `afterSource()`)
- `onWordEnv`: callback for each `AssWordUnit`.

#### `splitKaraokeFx(...)`

- `layerOffset` (default: `10`)
- `commentOriginal` (default: `true`)
- `includeNonKaraokeSegments` (default: `false`)
  - If true, lines without karaoke tags are treated as one unit.
- `mode` (default: `AssKaraokeSplitMode.blocks`)
  - `blocks`: one unit per karaoke timing tag block (`\k/\kf/\ko`)
  - `syllables`: merges multi-highlight blocks starting with `#`/`＃`, exposing `env.unit.highlights`
- `preserveInlineStyle` (default: `true`)
  - Applies the effective style state measured for that karaoke block when available.
- `outputStrategy` (default: `afterSource()`)
- `onKaraokeEnv`: callback for each unit.

Karaoke parsing supports: `\k`, `\kf`, `\ko`, `\K` (alias), and `\kt`.

#### `splitLineFbfFx(...)`

- `fps` (required): frames per second.
- `stepFrames` (default: `1`): number of frames per output unit.
- `layerOffset` (default: `10`)
- `commentOriginal` (default: `true`)
- `preserveOriginalText` (default: `true`)
  - If true, each frame unit starts from the original text (including tags).
  - If false, it uses a normalized text with a “base tags” prefix.
- `outputStrategy` (default: `afterSource()`)
- `onFrameEnv`: callback per `AssFrameUnit`.

#### `onShapeExpand(...)`

Generates one output dialog per selected source line by converting its text into
an ASS drawing (`\p1`) and baking common transform tags into the vector points.

- `layerOffset` (default: `0`)
- `commentOriginal` (default: `true`)
- `effect` (default: `'shape'`): `Effect` value for generated dialogs.
- `outputStrategy` (default: `afterSource()`)
- `onShapeExpandEnv`: callback per `AssShapeExpandUnit`.

Practical notes:

- The implementation preserves appearance by computing line breaks first, then expanding each tag-layer piece inside each break.
- Font switches like `\fnC059` and style resets like `\rAltStyle` are supported even when they are *not* parenthesized.

### Environment objects

Every generator callback receives one environment instance.

All env types share the same base fields:

- `env.shared`: `AssAutomationShared` for warmed fonts/caches.
- `env.basePos`: best-effort line base position (`pos|move|derived`).
- `env.orgline`: original input dialog.
- `env.sourceIndex`: index of the original dialog inside `ass.dialogs!.dialogs`.
- `env.units`: all units for this original dialog.
- `env.unit`: current unit object.
- `env.line`: mutable output dialog (pre-filled for this unit).
- `env.emit.emit(dialog)`: emit output dialogs.
- `env.util`: helper math utilities.

Time helpers:

- `env.unitStartMs`, `env.unitEndMs`, `env.unitDurationMs`, `env.unitMidMs`
- `env.unitMidRelMs`: unit midpoint relative to original line start
- `env.retime(AssRetimeMode mode, {startOffsetMs, endOffsetMs, absStartMs, absEndMs})`

Tag helpers (env-local, mutate `env.line`):

- `env.tags.setAlignment(...)`, `env.tags.setPos(...)`, `env.tags.setMove(...)`, `env.tags.setClipRect(...)`, ...
- `env.tags.addTransform(...)`, `env.tags.setFad(...)`
- `env.tags.addT(...)`: typed builder for `\t(...)`
- `env.bakeMoveToPosAtMid()`:
  - Evaluates `\move` at the unit midpoint and writes a static `\pos`, optionally removing `\move`.

#### `AssCharTemplateEnv` / `AssCharUnit`

Unit fields:

- `charIndex`, `char`, `isSpace`
- `absStartMs`, `absEndMs`
- Layout (relative): `x`, `left`, `center`, `right`, `width`, `height`, `lineIndex`
- Layout (absolute): `absX`, `absLeft`, `absCenter`, `absRight`, `absTop`, `absMiddle`, `absBottom`
- Convenience: `absPosX`, `absPosY`
- Fractions: `tf` (time fraction), `xf` (x fraction)
- `effectiveStyle`: the measured effective style state (when available)

#### `AssWordTemplateEnv` / `AssWordUnit`

Unit fields:

- `wordIndex`, `text`, `isSpace`
- (same layout/absolute/fractions as chars)
- `effectiveStyle` when available

#### `AssKaraokeTemplateEnv` / `AssKaraokeUnit`

Unit fields:

- `blockIndex`, `text`, `karaokeTag`
- `durMs`, `absStartMs`, `absEndMs`
- `highlights`: list of `AssKaraokeHighlight` windows (`startOffsetMs/endOffsetMs/tag`)
- Fixed spacing metrics (when available):
  - `prespace`, `postspace`, `textSpaceStripped`
  - `prespaceWidth`, `postspaceWidth`, `coreWidth`
  - `left/center/right` refer to the **core** text (karaskel-like)
- Layout (relative/absolute): same pattern as chars/words
- Fractions: `tf`, `xf`
- `effectiveStyle` when available

Nested FBF:

- `env.fbf({required fps, stepFrames = 1, layerOffset = 0, AssFrameFxEnvCallback? onFrameEnv})`
  - Splits the current karaoke unit time range into frame windows and emits per-frame output.

#### `AssFrameTemplateEnv` / `AssFrameUnit`

Unit fields:

- `stepIndex`
- `frameStart`, `frameEnd`, `frameCount`, `fps`
- `absStartMs`, `absEndMs`, `midMs`
- Fraction: `tf`

#### `AssShapeExpandTemplateEnv` / `AssShapeExpandUnit`

This generator can produce multiple units per source dialog.

The text is processed in two stages to preserve appearance:

1) The whole line is split into *visual lines* using `\N`, `\n` and literal newlines.
2) Inside each visual line, each tag-layer piece (`AssTextSegment`) is expanded separately
   and emitted as its own `\p1` dialog.

This ensures line breaks are handled *before* segment splitting, so tag layers do not get
mistaken as separate line breaks.

Each unit contains its own generated vector paths.

Unit fields:

- `absStartMs`, `absEndMs`
- `an`, `pos`, `org`
- `text`: normalized plain text used for glyph outline generation
- `paths`: `AssPaths` (mutable)
- `segmentIndex`: index of the original `AssTextSegment` this unit comes from (0-based)
- `segmentLineIndex`: visual line index (0-based)

Tag parsing note:

- `\fn` and `\r` may appear without parentheses (e.g. `\fnC059`, `\rAltStyle`). These are
  supported by the tag parser and reflected in the effective font selection.

Env helpers:

- `env.syncLineTextFromPaths()`: rebuilds `env.line.text` from `env.unit.paths`

### `AssAutomationShared`

Reusable cache container. You only need an explicit shared if you want to reuse
caches across multiple flows (otherwise the flow owns and disposes it).

Methods:

- `Future<AssFont> fontForStyle(Ass ass, String styleName)`
- `AssFont? warmedFontForStyle(String styleName)`
- `Future<AssFont> fontForTextState({required String styleName, required AssTextStyleState state})`
- `AssFont? warmedFontForTextState(AssTextStyleState state)`
- `Future<void> warmupFonts(Ass ass, Iterable<String> styleNames)`
- `static Future<T> using<T>(Future<T> Function(AssAutomationShared shared) fn)`
- `void dispose()`
