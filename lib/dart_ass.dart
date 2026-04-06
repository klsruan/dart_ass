/// `dart_ass` — Advanced ASS subtitle reader & editor for Dart.
///
/// This library provides a structured API for:
/// - Parsing `.ass` files into strongly-typed objects ([Ass], [AssDialog], [AssStyle], etc.)
/// - Editing dialogue text and override tags ([AssText], [AssOverrideTags])
/// - Measuring text using FreeType ([AssFont]) for automation/layout use-cases
/// - Running automation flows ([AssAutomation]) inspired by Aegisub Automation
///
/// ## Quick start
/// ```dart
/// import 'package:dart_ass/dart_ass.dart';
///
/// Future<void> main() async {
///   final ass = Ass(filePath: 'subtitles.ass');
///   await ass.parse();
///
///   // Example: shift all dialogues by +250ms
///   await AssAutomation(ass).flow().selectAll().shiftTime(250).run();
///   await ass.toFile('subtitles_out.ass');
/// }
/// ```
library;

export 'src/ass/ass_color.dart';
export 'src/ass/ass_font.dart';
export 'src/ass/ass_alpha.dart';
export 'src/ass/ass_time.dart';
export 'src/ass/ass_text.dart';
export 'src/ass/ass_line.dart';
export 'src/ass/ass_tags.dart';
export 'src/ass/ass_struct.dart';
export 'src/ass/ass_path.dart';
export 'src/ass/ass.dart';
export 'src/ass/ass_automation.dart';
export 'src/util.dart';
export 'src/version.dart';
