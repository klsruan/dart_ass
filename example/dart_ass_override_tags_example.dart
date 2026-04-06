import 'dart:io';

import 'package:dart_ass/dart_ass.dart';

/// Example: parse an override tags block and inspect values.
///
/// This demonstrates tag blocks where values are not parenthesized:
/// - `\fnFontName`
/// - `\rStyleName`
void main() {
  final raw = r'{\k36\fnC059\b1\rAltStyle\pos(850,370)}';
  final tags = AssOverrideTags.parse(raw);
  if (tags == null) {
    stderr.writeln('Failed to parse tags: $raw');
    exitCode = 1;
    return;
  }

  stdout.writeln('Input: $raw');
  stdout.writeln('k  : ${tags.getTagValue('k')}');
  stdout.writeln('fn : ${tags.getTagValue('fn')}');
  stdout.writeln('r  : ${tags.getTagValue('r')}');
  stdout.writeln('b  : ${tags.getTagValue('b')}');
  stdout.writeln('pos: ${tags.position}');
  stdout.writeln('Serialized: ${tags.getAss()}');
}

