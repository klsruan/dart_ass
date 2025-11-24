List<int> assColorToRGB(String hexColor) {
  if (hexColor.toUpperCase().trim().startsWith('&H') && hexColor.toUpperCase().trim().endsWith('&')) {
    hexColor = hexColor.substring(2, hexColor.length - 1);
  }
  if (hexColor.length < 6) {
    throw FormatException("Hexadecimal must be exactly 6 characters long.");
  }
  try {
    if (hexColor.length == 8) {
      return [
        int.parse(hexColor.substring(2, 4), radix: 16),  // Red
        int.parse(hexColor.substring(4, 6), radix: 16),  // Green
        int.parse(hexColor.substring(6, 8), radix: 16)   // Blue
      ];
    }
    return [
      int.parse(hexColor.substring(0, 2), radix: 16),  // Red
      int.parse(hexColor.substring(2, 4), radix: 16),  // Green
      int.parse(hexColor.substring(4, 6), radix: 16)   // Blue
    ];
  } catch (e) {
    throw FormatException("Invalid entry. Make sure all characters are hexadecimal.");
  }
}

String rgbToAssColor(int red, int green, int blue) {
  if (red < 0 || red > 255 || green < 0 || green > 255 || blue < 0 || blue > 255) {
    throw FormatException("Each RGB value must be between 0 and 255.");
  }
  String redHex = red.toRadixString(16).padLeft(2, '0');
  String greenHex = green.toRadixString(16).padLeft(2, '0');
  String blueHex = blue.toRadixString(16).padLeft(2, '0');
  return "$redHex$greenHex$blueHex".toUpperCase();
}

class AssColor {
  int? red;
  int? green;
  int? blue;

  AssColor({this.red, this.green, this.blue});

  factory AssColor.parse(String assColor) {
    List<int> rgb = assColorToRGB(assColor);
    return AssColor(red: rgb[0], green: rgb[1], blue: rgb[2]);
  }

  String getAss() {
    StringBuffer bff = StringBuffer();
    if (red != null && green != null && blue != null) {
      bff.write("&H${rgbToAssColor(red!, green!, blue!)}&");
    }
    return bff.toString();
  }

  @override
  String toString() {
    StringBuffer bff = StringBuffer();
    if (red != null && green != null && blue != null) {
      bff.write(rgbToAssColor(red!, green!, blue!));
    }
    return bff.toString();
  }
}