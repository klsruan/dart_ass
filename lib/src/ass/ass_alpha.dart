int assAlphaToRGB(String hexColor) {
  if (hexColor.length < 2) {
    throw FormatException("Hexadecimal deve ter exatamente 2 caracteres.");
  }
  try {
    return int.parse(hexColor.substring(0, 2), radix: 16);
  } catch (e) {
    throw FormatException("Entrada inválida. Certifique-se de que todos os caracteres são hexadecimais.");
  }
}

String rgbToAssAlpha(int alpha) {
  if (alpha < 0 || alpha > 255) {
    throw FormatException("Alpha deve estar entre 0 e 255.");
  }
  return alpha.toRadixString(16).padLeft(2, '0').toUpperCase();
}

class AssAlpha {
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