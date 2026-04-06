
# dart_ass – Advanced ASS Subtitle Reader & Editor

`dart_ass` is a Dart (Flutter) library for reading and dynamically manipulating Advanced SubStation Alpha (`.ass`) subtitle files.
It is designed for apps and tools that need to parse, inspect, measure and generate subtitles (players, editors and FX automation).

## ✨ Features

- Parse `.ass` files into structured objects
- Edit dialogue lines, styles and override tags (e.g. `\b`, `\i`, `\pos`, `\t`)
- Karaoke parsing (`\k`, `\kf`, `\ko`, `\K`, `\kt`) and split helpers (line breaks / words / chars)
- Automation flows (Aegisub-inspired) to generate FX lines (`Effect=fx`)
- Optional text metrics via FreeType (precise width/height + positioning helpers)
- Write back updated `.ass` files

## 🚀 Getting Started

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  dart_ass: ^1.2.2
```

### Flutter requirement (metrics)

For text metrics and text-to-shape (FreeType via FFI), this package is meant to be used with the Flutter SDK.

- Install deps: `flutter pub get`
- Run tests: `flutter test`

This repo uses `dart_freetype` via Git (because it relies on the FFI bindings exported by `dart_freetype_ffi.dart`).

## 📚 Usage

```dart
import 'package:dart_ass/dart_ass.dart';

Future<void> main() async {
  final ass = Ass(filePath: 'files/test.ass');
  await ass.parse();

  // Ensure there is a leading override tags block and set \pos().
  final dialogs = ass.dialogs?.dialogs ?? const <AssDialog>[];
  for (final dialog in dialogs) {
    if (dialog.text.segments.isEmpty) continue;
    dialog.text.segments.first.overrideTags ??= AssOverrideTags();
    dialog.text.segments.first.overrideTags!.position = AssTagPosition(100, 200);
  }

  await ass.toFile('files/test_out.ass');
}
```

## Automation (Aegisub-like)

The automation API is inspired by Aegisub Automation + karaskel, but runs native Dart callbacks (no Lua runtime).

Generate one `Effect=fx` line per karaoke unit (syllable-like block):

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
      env.emit.emit(env.line);
    },
  )
  .run();
```

## 📁 Example

A complete working set of examples is available in `example/`:

- `example/dart_ass_example.dart` (basic parse/edit/write)
- `example/dart_ass_automation_example.dart` (flow ops)
- `example/dart_ass_automation_chars_example.dart` (chars → FX)
- `example/dart_ass_automation_words_example.dart` (words → FX)
- `example/dart_ass_automation_karaoke_example.dart` (karaoke → FX)
- `example/dart_ass_automation_fbf_example.dart` (frame-by-frame → FX)
- `example/dart_ass_expand_text_example.dart` (text → expanded `\p1` shapes)
- `example/dart_ass_expand_text_segments_example.dart` (segments + line breaks → expanded `\p1` shapes)
- `example/dart_ass_on_shape_expand_callback_example.dart` (shape expand callback / mutate paths)
- `example/dart_ass_override_tags_example.dart` (override tag parsing)

Automation notes: see `docs/automation.md`.

## 📌 Additional Information

- ASS tags reference: https://docs.aegisub.org/3.2/ASS_Tags/
- Feel free to open issues or submit pull requests for improvements.
- Built with extensibility in mind, suitable for editors and players.

## 📄 License

This project is licensed under the MIT License (see `LICENSE`).

## 🧾 Changelog

See `CHANGELOG.md`.
