/// Alpha (transparency) utilities for ASS.
///
/// In ASS, alpha is a hex byte where `00` is opaque and `FF` is fully transparent.
int assAlphaToRGB(String hexColor) {
  if (hexColor.length < 2) {
    throw FormatException('Hex alpha must be exactly 2 characters.');
  }
  try {
    return int.parse(hexColor.substring(0, 2), radix: 16);
  } catch (e) {
    throw FormatException('Invalid alpha. Ensure all characters are hexadecimal.');
  }
}

String rgbToAssAlpha(int alpha) {
  if (alpha < 0 || alpha > 255) {
    throw FormatException('Alpha must be between 0 and 255.');
  }
  return alpha.toRadixString(16).padLeft(2, '0').toUpperCase();
}

class AssAlpha {
  /// Alpha byte (0..255), where 0 is opaque and 255 is transparent.
  int? alpha;

  AssAlpha({this.alpha});

  factory AssAlpha.parse(String assAlpha) {
    return AssAlpha(alpha: assAlphaToRGB(assAlpha));
  }

  String getAss() {
    StringBuffer bff = StringBuffer();
    if (alpha != null) {
      bff.write("&H${rgbToAssAlpha(alpha!)}&");
    }
    return bff.toString();
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    if (alpha != null) {
      bff.write(rgbToAssAlpha(alpha!));
    }
    return bff.toString();
  }
}
