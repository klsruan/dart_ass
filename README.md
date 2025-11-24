
# 📦 dart_ass – Advanced ASS Subtitle Reader & Editor for Dart

`dart_ass` is a Dart library for reading and dynamically manipulating Advanced SubStation Alpha (.ass) subtitle files. 
It is designed for applications that need to parse, inspect, and modify subtitles in real-time, such as custom video players, subtitle editors, and automation tools.

## ✨ Features

- Parse `.ass` files into structured objects
- Access and update dialogue lines and text segments
- Modify visual styles and override tags (e.g., bold, italic, position)
- Extend and rewrite dialogue timings
- Save back updated `.ass` files
- Designed to support automation and batch editing workflows

## 🚀 Getting Started

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  dart_ass: ^1.0.1
```

## 📚 Usage

```dart
import 'package:dart_ass/dart_ass.dart';

void main() async {
  Ass ass = Ass(filePath: 'files/test.ass');
  await ass.parse();
  if (ass.dialogs != null) {
    List<AssDialog> dialogs = ass.dialogs!.dialogs;
    for (AssDialog dialog in dialogs) {
      List<AssTextSegment> segments = dialog.text.segments;
      for (AssTextSegment segment in segments) {
        print('Old: ${segment.overrideTags!.getAss()}');
        segment.overrideTags!.position = AssTagPosition(-10, 1.10938);
        print('New: ${segment.overrideTags!.getAss()}');
      }
    }
  }
}
```

## 📁 Example

A complete working example is available in the [`/example`](example/) directory.

## 📌 Additional Information

- Learn about ASS format: https://docs.aegisub.org/3.2/ASS_Tags/
- Feel free to open issues or submit pull requests for improvements.
- Built with extensibility in mind, suitable for editors and players.