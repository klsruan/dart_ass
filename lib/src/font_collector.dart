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
  final bool bold;
  final bool italic;

  bool resolvedBold = false;
  bool resolvedItalic = false;

  FontCollector({
    required this.fontName,
    this.bold = false,
    this.italic = false,
  });

  static bool _isBoldName(String name) {
    final n = name.toLowerCase();
    return n.contains("bold") ||
        n.contains("black") ||
        n.contains("heavy") ||
        n.contains("semibold") ||
        n.contains("demibold");
  }

  static bool _isItalicName(String name) {
    final n = name.toLowerCase();
    return n.contains("italic") || n.contains("oblique");
  }

  static bool _isBoldItalicName(String name) {
    return _isBoldName(name) && _isItalicName(name);
  }

  static Future<List<SystemFont>> _getWindowsFonts() async {
    final collector = WindowsGdiFontCollector();
    final winFonts = await collector.collect();
    final windir = Platform.environment["WINDIR"] ?? "C:\\Windows";
    final fontDir = "$windir\\Fonts";
    List<SystemFont> result = [];
    for (final f in winFonts) {
      if (f.file != null && f.file!.isNotEmpty) {
        result.add(
          SystemFont(
            f.longName.isNotEmpty ? f.longName : f.name,
            p.join(fontDir, f.file!),
          ),
        );
      }
    }
    return result;
  }

  static Future<List<SystemFont>> _getLinuxFonts() async {
    final fontDirs = <String>["/usr/share/fonts", "/usr/local/share/fonts"];
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
            fonts.add(SystemFont(name, entity.path));
          }
        }
      }
    }
    return fonts;
  }

  static Future<List<SystemFont>> getFontsData() async {
    if (Platform.isWindows) return _getWindowsFonts();
    if (Platform.isLinux) return _getLinuxFonts();
    if (Platform.isAndroid) return _getAndroidFonts();
    throw UnsupportedError("Operating system not supported");
  }

  Future<SystemFont?> getFontData() async {
    final fonts = await getFontsData();
    final query = fontName.toLowerCase().trim();
    final baseMatches = fonts
        .where((f) => f.name.toLowerCase().contains(query))
        .toList();
    SystemFont? chosen;
    if (bold && italic) {
      final exact = baseMatches.where((f) => _isBoldItalicName(f.name)).toList();
      if (exact.isNotEmpty) chosen = exact.first;
      if (chosen == null) {
        final boldOnly = baseMatches
            .where((f) => _isBoldName(f.name) && !_isItalicName(f.name))
            .toList();
        if (boldOnly.isNotEmpty) chosen = boldOnly.first;
      }
      if (chosen == null) {
        final italicOnly = baseMatches
            .where((f) => _isItalicName(f.name) && !_isBoldName(f.name))
            .toList();
        if (italicOnly.isNotEmpty) chosen = italicOnly.first;
      }
    }
    if (chosen == null && bold && !italic) {
      final exact = baseMatches.where((f) => _isBoldName(f.name)).toList();
      if (exact.isNotEmpty) chosen = exact.first;
    }
    if (chosen == null && !bold && italic) {
      final exact = baseMatches.where((f) => _isItalicName(f.name)).toList();
      if (exact.isNotEmpty) chosen = exact.first;
    }
    if (chosen == null && baseMatches.isNotEmpty) {
      chosen = baseMatches.first;
    }
    if (chosen == null) {
      const winFallback = "Arial";
      const linuxFallback = "DejaVuSans";
      const androidFallback = "Roboto-Regular";
      final fallback = Platform.isWindows
          ? winFallback
          : Platform.isLinux
              ? linuxFallback
              : androidFallback;
      for (final f in fonts) {
        if (f.name.toLowerCase() == fallback.toLowerCase()) {
          chosen = f;
          break;
        }
      }
    }
    if (chosen == null) {
      throw Exception(
        'Font "$fontName" not found and no fallback available.',
      );
    }
    resolvedBold = _isBoldName(chosen.name);
    resolvedItalic = _isItalicName(chosen.name);
    return chosen;
  }

  Future<String?> getFontPath() async {
    final font = await getFontData();
    return font?.filePath;
  }
}