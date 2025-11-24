import 'dart:io';
import 'package:path/path.dart' as p;
import 'win/windows_gdi_font_collector.dart';

class SystemFont {
  final String name;
  final String filePath;
  SystemFont(this.name, this.filePath);
}

class FontCollector {
  final String fontName;

  FontCollector({
    required this.fontName,
  });

  static Future<List<SystemFont>> _getWindowsFonts() async {
    final collector = WindowsGdiFontCollector();
    final winFonts = await collector.collect();
    final windir = Platform.environment["WINDIR"] ?? "C:\\Windows";
    final fontDir = "$windir\\Fonts";
    List<SystemFont> result = [];
    for (final f in winFonts) {
      if (f.file != null && f.file!.isNotEmpty) {
        result.add(SystemFont(
          f.longName.isNotEmpty ? f.longName : f.name,
          p.join(fontDir, f.file!),
        ));
      }
    }
    return result;
  }

  static Future<List<SystemFont>> _getLinuxFonts() async {
    const fontDirs = [
      "/usr/share/fonts",
      "/usr/local/share/fonts",
    ];
    final home = Platform.environment["HOME"];
    if (home != null) {
      fontDirs.add("$home/.fonts");
      fontDirs.add("$home/.local/share/fonts");
    }
    List<SystemFont> fonts = [];
    for (final dir in fontDirs) {
      final directory = Directory(dir);
      if (!directory.existsSync()) continue;
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (ext == ".ttf" || ext == ".otf" || ext == ".ttc") {
            final name = p.basenameWithoutExtension(entity.path);
            fonts.add(SystemFont(name, entity.path));
          }
        }
      }
    }
    return fonts;
  }

  static Future<List<SystemFont>> _getAndroidFonts() async {
    final fontDirs = <String>[
      "/system/fonts",
      "/system/font",
      "/product/fonts",
      "/vendor/fonts",
    ];
    List<SystemFont> fonts = [];
    for (final dir in fontDirs) {
      final directory = Directory(dir);
      if (!directory.existsSync()) continue;
      await for (final entity in directory.list(recursive: false)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (ext == ".ttf" || ext == ".otf" || ext == ".ttc") {
            final name = p.basenameWithoutExtension(entity.path);
            fonts.add(SystemFont(
              name,
              entity.path,
            ));
          }
        }
      }
    }
    return fonts;
  }

  static Future<List<SystemFont>> getFontsData() async {
    if (Platform.isWindows) {
      return _getWindowsFonts();
    } else if (Platform.isLinux) {
      return _getLinuxFonts();
    } else if (Platform.isAndroid) {
      return _getAndroidFonts();
    } else {
      throw UnsupportedError("Operating system not supported");
    }
  }

  Future<SystemFont?> getFontData() async {
    final fonts = await getFontsData();
    final query = fontName.toLowerCase().trim();
    for (final f in fonts) {
      if (f.name.toLowerCase() == query) return f;
    }
    for (final f in fonts) {
      if (f.name.toLowerCase().startsWith(query)) return f;
    }
    for (final f in fonts) {
      if (f.name.toLowerCase().contains(query)) return f;
    }
    const winFallback = "Arial";
    const linuxFallback = "DejaVuSans";
    const androidFallback = "Roboto-Regular";
    late final String fallback;
    if (Platform.isWindows) {
      fallback = winFallback;
    } else if (Platform.isLinux) {
      fallback = linuxFallback;
    } else if (Platform.isAndroid) {
      fallback = androidFallback;
    } else {
      throw Exception("Font \"$fontName\" not found and no fallback available.");
    }
    for (final f in fonts) {
      if (f.name.toLowerCase() == fallback.toLowerCase()) {
        return f;
      }
    }
    throw Exception(
      "Font \"$fontName\" not found, and fallback \"$fallback\" also not available.",
    );
  }

  Future<String?> getFontPath() async {
    final font = await getFontData();
    return font?.filePath;
  }
}