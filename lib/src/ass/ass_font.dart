/// Font measurement and text-to-shape utilities for ASS automation.
///
/// This module uses FreeType (via FFI) to:
/// - Measure text extents ([AssFontTextExtents])
/// - Read font metrics ([AssFontMetrics])
/// - Convert text to vector shapes (ASS drawing / SVG)
///
/// Notes:
/// - Calls are relatively expensive because fonts are initialized via FFI.
/// - Prefer caching [AssFont] instances in automation code.
import 'dart:ffi';
import 'package:dart_ass/dart_ass.dart';
import 'package:dart_freetype/dart_freetype_ffi.dart';
import 'package:ffi/ffi.dart';

import '../font_collector.dart';
// ignore: constant_identifier_names
const int UPSCALE = 64;
// ignore: constant_identifier_names
const double FONT_DOWNSCALE = 1 / UPSCALE;
// ignore: constant_identifier_names
const int OUTLINE_MAX = (1 << 28) - 1;

void setFontMetrics(FreetypeBinding ft, FT_Face face) {
  final os2Ptr =
      ft.FT_Get_Sfnt_Table(face, FT_Sfnt_Tag_.FT_SFNT_OS2) as Pointer<TT_OS2_>?;
  if (os2Ptr != null) {
    final os2 = os2Ptr.ref;
    final winAscent = os2.usWinAscent;
    final winDescent = os2.usWinDescent;
    if ((winAscent.toInt() + winDescent.toInt()) != 0) {
      face.ref.ascender = winAscent.toInt();
      face.ref.descender = -winDescent.toInt();
      face.ref.height = face.ref.ascender - face.ref.descender;
    }
  }
  if (face.ref.ascender - face.ref.descender == 0 || face.ref.height == 0) {
    if (os2Ptr != null) {
      final os2 = os2Ptr.ref;
      final typoAsc = os2.sTypoAscender;
      final typoDesc = os2.sTypoDescender;
      if ((typoAsc - typoDesc) != 0) {
        face.ref.ascender = typoAsc;
        face.ref.descender = typoDesc;
        face.ref.height = face.ref.ascender - face.ref.descender;
        return;
      }
    }
    final bbox = face.ref.bbox;
    face.ref.ascender = bbox.yMax;
    face.ref.descender = bbox.yMin;
    face.ref.height = face.ref.ascender - face.ref.descender;
  }
}

void assFaceSetSize(FreetypeBinding ft, FT_Face face, double size) {
  final req = calloc<FT_Size_RequestRec_>();
  final rq = req.ref;
  rq.type = FT_Size_Request_Type_.FT_SIZE_REQUEST_TYPE_REAL_DIM.value;
  rq.width = 0;
  rq.height = (size * UPSCALE).round();
  rq.horiResolution = 0;
  rq.vertResolution = 0;
  final err = ft.FT_Request_Size(face, req);
  if (err != FT_Err_Ok) {
    print("FT_Request_Size failed: $err");
  }
  calloc.free(req);
}

int assFaceGetWeight(FreetypeBinding ft, FT_Face face) {
  final os2Ptr =
      ft.FT_Get_Sfnt_Table(face, FT_Sfnt_Tag_.FT_SFNT_OS2) as Pointer<TT_OS2_>?;
  int os2Weight = 0;
  if (os2Ptr != null) {
    os2Weight = os2Ptr.ref.usWeightClass;
  }
  switch (os2Weight) {
    case 0:
      // 300 * (face->style_flags & FT_STYLE_FLAG_BOLD ? 1 : 0) + 400
      final isBold = (face.ref.style_flags & FT_STYLE_FLAG_BOLD) != 0 ? 1 : 0;
      return 300 * isBold + 400;
    case 1:
      return 100;
    case 2:
      return 200;
    case 3:
      return 300;
    case 4:
      return 350;
    case 5:
      return 400;
    case 6:
      return 600;
    case 7:
      return 700;
    case 8:
      return 800;
    case 9:
      return 900;
    default:
      return os2Weight;
  }
}

AscDesc assFontGetAscDesc(FreetypeBinding ft, FT_Face face) {
  final metrics = face.ref.size.ref.metrics;
  final yScale = metrics.y_scale;
  final asc = ft.FT_MulFix(face.ref.ascender, yScale);
  final desc = ft.FT_MulFix(-face.ref.descender, yScale);
  return AscDesc(asc, desc);
}

void assGlyphEmbolden(FreetypeBinding ft, Pointer<FT_GlyphSlotRec_> slot) {
  if (slot.ref.format != FT_Glyph_Format_.FT_GLYPH_FORMAT_OUTLINE.value) return;
  final unitsPerEm = slot.ref.face.ref.units_per_EM;
  final yScale = slot.ref.face.ref.size.ref.metrics.y_scale;
  final int str = (ft.FT_MulFix(unitsPerEm, yScale) / UPSCALE).toInt();
  final outlinePtr = malloc<FT_Outline_>();
  outlinePtr.ref = slot.ref.outline;
  ft.FT_Outline_Embolden(outlinePtr, str);
  slot.ref.outline = outlinePtr.ref;
  malloc.free(outlinePtr);
}

bool assFaceIsPostscript(FreetypeBinding ft, Pointer<FT_FaceRec_> facePtr) {
  final psInfo = calloc<PS_FontInfoRec>();
  final err = ft.FT_Get_PS_Font_Info(facePtr, psInfo);
  final ok = err == 0;
  calloc.free(psInfo);
  return ok;
}

void assGlyphItalicize(FreetypeBinding ft, Pointer<FT_GlyphSlotRec_> slot) {
  final int shear = assFaceIsPostscript(ft, slot.ref.face) ? 0x02d24 : 0x05700;
  final matrix = calloc<FT_Matrix_>();
  matrix.ref.xx = 0x10000;
  matrix.ref.xy = shear;
  matrix.ref.yx = 0x00000;
  matrix.ref.yy = 0x10000;
  final outlinePtr = malloc<FT_Outline_>();
  outlinePtr.ref = slot.ref.outline;
  ft.FT_Outline_Transform(outlinePtr, matrix);
  slot.ref.outline = outlinePtr.ref;
  malloc.free(outlinePtr);
  calloc.free(matrix);
}

String assGetGlyphOutline(
  FreetypeBinding ft,
  Pointer<FT_FaceRec_> facePtr,
  bool hasUnderline,
  bool hasStrikeout,
  int addx,
  int addy,
) {
  final yScale = facePtr.ref.size.ref.metrics.y_scale;
  final adv = facePtr.ref.glyph.ref.advance.x;
  final sourcePtr = malloc<FT_Outline_>();
  sourcePtr.ref = facePtr.ref.glyph.ref.outline;
  List<double>? underline;
  List<double>? strikeout;
  if (adv > 0 && hasUnderline) {
    final psPtr =
        ft.FT_Get_Sfnt_Table(facePtr, FT_Sfnt_Tag_.FT_SFNT_POST)
            as Pointer<TT_Postscript_>?;
    if (psPtr != null) {
      final ps = psPtr.ref;
      if (ps.underlinePosition <= 0 && ps.underlineThickness > 0) {
        final pos = ((ps.underlinePosition * yScale) + 0x8000) ~/ 65536;
        final size = ((ps.underlineThickness * yScale) + 0x8000) ~/ 65536;
        int p = -pos - (size >> 1);
        if (p >= -OUTLINE_MAX && (p + size) <= OUTLINE_MAX) {
          underline = [
            (p + addy) * FONT_DOWNSCALE,
            (p + size + addy) * FONT_DOWNSCALE,
          ];
        }
      }
    }
  }
  if (adv > 0 && hasStrikeout) {
    final os2Ptr =
        ft.FT_Get_Sfnt_Table(facePtr, FT_Sfnt_Tag_.FT_SFNT_OS2)
            as Pointer<TT_OS2_>?;
    if (os2Ptr != null) {
      final os2 = os2Ptr.ref;
      if (os2.yStrikeoutPosition >= 0 && os2.yStrikeoutSize > 0) {
        final pos = ((os2.yStrikeoutPosition * yScale) + 0x8000) ~/ 65536;
        final size = ((os2.yStrikeoutSize * yScale) + 0x8000) ~/ 65536;
        int p = -pos - (size >> 1);
        if (p >= -OUTLINE_MAX && (p + size) <= OUTLINE_MAX) {
          strikeout = [
            (p + addy) * FONT_DOWNSCALE,
            (p + size + addy) * FONT_DOWNSCALE,
          ];
        }
      }
    }
  }
  final dir = ft.FT_Outline_Get_Orientation(sourcePtr);
  final iy = dir == FT_Orientation_.FT_ORIENTATION_TRUETYPE ? 0 : 1;
  String path = ' ';
  if (underline != null) {
    final y1 = underline[iy == 0 ? 1 : 0];
    final y2 = underline[iy == 0 ? 0 : 1];
    path += isSvg ? 'M ' : 'm ';
    path += '${addx * FONT_DOWNSCALE} $y2 ';
    path += isSvg ? 'L ' : 'l ';
    path +=
        '${(addx + adv) * FONT_DOWNSCALE} $y2 ${(addx + adv) * FONT_DOWNSCALE} $y1 ${addx * FONT_DOWNSCALE} $y1 ';
  }
  if (strikeout != null) {
    final y1 = strikeout[iy == 0 ? 1 : 0];
    final y2 = strikeout[iy == 0 ? 0 : 1];
    path += isSvg ? 'M ' : 'm ';
    path += '${addx * FONT_DOWNSCALE} $y2 ';
    path += isSvg ? 'L ' : 'l ';
    path +=
        '${(addx + adv) * FONT_DOWNSCALE} $y2 ${(addx + adv) * FONT_DOWNSCALE} $y1 ${addx * FONT_DOWNSCALE} $y1 ';
  }
  malloc.free(sourcePtr);
  return path;
}

class _DecomposeContext {
  List<List<dynamic>> build;
  int penX;
  int ascUpscaled;
  _DecomposeContext(this.build, this.penX, this.ascUpscaled);
}

final Map<int, _DecomposeContext> _decomposeRegistry = {};
int _nextDecomposeId = 1;
bool isSvg = false;

int _moveToNative(Pointer<FT_Vector> to, Pointer<Void> user) {
  final id = user.cast<Int64>().value;
  final ctx = _decomposeRegistry[id];
  if (ctx == null) return 0;
  ctx.build.add([
    isSvg ? "M" : "m",
    (to.ref.x + ctx.penX) * FONT_DOWNSCALE,
    (ctx.ascUpscaled - to.ref.y) * FONT_DOWNSCALE,
  ]);
  return 0;
}

int _lineToNative(Pointer<FT_Vector> to, Pointer<Void> user) {
  final id = user.cast<Int64>().value;
  final ctx = _decomposeRegistry[id];
  if (ctx == null) return 0;
  ctx.build.add([
    isSvg ? "L" : "l",
    (to.ref.x + ctx.penX) * FONT_DOWNSCALE,
    (ctx.ascUpscaled - to.ref.y) * FONT_DOWNSCALE,
  ]);
  return 0;
}

int _conicToNative(
  Pointer<FT_Vector> control,
  Pointer<FT_Vector> to,
  Pointer<Void> user,
) {
  final id = user.cast<Int64>().value;
  final ctx = _decomposeRegistry[id];
  if (ctx == null) return 0;
  ctx.build.add([
    isSvg ? "Q" : "q",
    (control.ref.x + ctx.penX) * FONT_DOWNSCALE,
    (ctx.ascUpscaled - control.ref.y) * FONT_DOWNSCALE,
    (to.ref.x + ctx.penX) * FONT_DOWNSCALE,
    (ctx.ascUpscaled - to.ref.y) * FONT_DOWNSCALE,
  ]);
  return 0;
}

int _cubicToNative(
  Pointer<FT_Vector> c1,
  Pointer<FT_Vector> c2,
  Pointer<FT_Vector> to,
  Pointer<Void> user,
) {
  final id = user.cast<Int64>().value;
  final ctx = _decomposeRegistry[id];
  if (ctx == null) return 0;
  ctx.build.add([
    isSvg ? "C" : "b",
    (c1.ref.x + ctx.penX) * FONT_DOWNSCALE,
    (ctx.ascUpscaled - c1.ref.y) * FONT_DOWNSCALE,
    (c2.ref.x + ctx.penX) * FONT_DOWNSCALE,
    (ctx.ascUpscaled - c2.ref.y) * FONT_DOWNSCALE,
    (to.ref.x + ctx.penX) * FONT_DOWNSCALE,
    (ctx.ascUpscaled - to.ref.y) * FONT_DOWNSCALE,
  ]);
  return 0;
}

final FT_Outline_MoveToFunc _moveToPtr =
    Pointer.fromFunction<Int32 Function(Pointer<FT_Vector>, Pointer<Void>)>(
      _moveToNative,
      0,
    ).cast();
final FT_Outline_LineToFunc _lineToPtr =
    Pointer.fromFunction<Int32 Function(Pointer<FT_Vector>, Pointer<Void>)>(
      _lineToNative,
      0,
    ).cast();
final FT_Outline_ConicToFunc _conicToPtr =
    Pointer.fromFunction<
          Int32 Function(Pointer<FT_Vector>, Pointer<FT_Vector>, Pointer<Void>)
        >(_conicToNative, 0)
        .cast();
final FT_Outline_CubicToFunc _cubicToPtr =
    Pointer.fromFunction<
          Int32 Function(
            Pointer<FT_Vector>,
            Pointer<FT_Vector>,
            Pointer<FT_Vector>,
            Pointer<Void>,
          )
        >(_cubicToNative, 0)
        .cast();

typedef GlyphCallback = void Function(FT_GlyphSlot glyph);

class AscDesc {
  final int asc;
  final int desc;
  AscDesc(this.asc, this.desc);
}

class AssFontMetrics {
  double ascent;
  double descent;
  double height;
  double internalLeading;
  double externalLeading;
  AssFontMetrics({
    required this.ascent,
    required this.descent,
    required this.height,
    required this.internalLeading,
    required this.externalLeading,
  });
}

class AssFontTextExtents {
  double width;
  double height;
  AssFontTextExtents({required this.width, required this.height});
}

class AssFont {
  String styleName;
  String fontName;
  double fontSize;
  bool bold;
  bool italic;
  bool underline;
  bool strikeOut;
  double scaleX;
  double scaleY;
  double spacing;

  // save old state
  double? scx;
  double? scy;

  FreetypeBinding? freeType;
  Pointer<Pointer<FT_LibraryRec_>>? library;
  // Back-compat: primary face handle (FT_Face*).
  //
  // Prefer using multi-face APIs (`addFallbackFont*`) instead of relying on this.
  Pointer<Pointer<FT_FaceRec_>>? face;
  FontCollector? fontCollector;

  // Multi-face support (fallback fonts for missing glyphs).
  final Map<String, Pointer<FT_FaceRec_>> _facesByPath = {};
  final List<_AssFaceEntry> _faces = [];
  final Map<int, int> _codePointToFaceIndex = {};

  double? ascender;
  double? descender;
  double? height;
  int? weight;

  bool done = false;

  AssFont({
    required this.styleName,
    required this.fontName,
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.underline,
    required this.strikeOut,
    required this.scaleX,
    required this.scaleY,
    required this.spacing,
  });

  Pointer<FT_FaceRec_>? get _primaryFace => _faces.isEmpty ? null : _faces.first.face;

  /// Loads the primary face and initializes the FreeType library.
  ///
  /// You can later add fallback faces using:
  /// - [addFallbackFont]
  /// - [addFallbackFontPath]
  Future<void> init() async {
    int err;
    freeType = loadFreeType();

    library = calloc<FT_Library>();
    err = freeType!.FT_Init_FreeType(library!);
    if (err != FT_Err_Ok) {
      print('err on Init FreeType');
    }

    final primaryCollector = FontCollector(fontName: fontName, bold: bold, italic: italic);
    fontCollector = primaryCollector;
    final fontPath = await primaryCollector.getFontPath();
    if (fontPath == null) {
      print('Font not found: $fontName');
      dispose();
      return;
    }

    await _getOrLoadFace(
      fontPath,
      resolvedBold: primaryCollector.resolvedBold,
      resolvedItalic: primaryCollector.resolvedItalic,
    );
    if (_faces.isEmpty) {
      dispose();
      return;
    }

    // Primary face back-compat handle.
    face = calloc<FT_Face>();
    face!.value = _primaryFace!;

    scx = scaleX;
    scy = scaleY;
    setSize(fontSize, fromInit: true);

    done = true;
  }

  /// Updates this font's style parameters.
  ///
  /// This is a convenience to update all style-related fields at once
  /// (similar to the constructor arguments). It keeps [setSize] as the single
  /// place that applies scaling and updates FreeType sizes/metrics.
  ///
  /// If `fontName`/`bold`/`italic` changes, the primary face may be reloaded.
  /// Existing fallback faces are kept.
  Future<void> setStyle({
    required String styleName,
    required String fontName,
    required double fontSize,
    required bool bold,
    required bool italic,
    required bool underline,
    required bool strikeOut,
    required double scaleX,
    required double scaleY,
    required double spacing,
  }) async {
    if (!done) {
      print('call method init first');
      return;
    }

    final needsPrimaryReload =
        this.fontName != fontName || this.bold != bold || this.italic != italic;

    this.styleName = styleName;
    this.fontName = fontName;
    this.bold = bold;
    this.italic = italic;
    this.underline = underline;
    this.strikeOut = strikeOut;
    this.spacing = spacing;

    // Store the original percentage values (setSize() will normalize them).
    scx = scaleX;
    scy = scaleY;
    this.scaleX = scaleX;
    this.scaleY = scaleY;
    this.fontSize = fontSize;

    if (needsPrimaryReload) {
      await _reloadPrimaryFace();
    }

    setSize(fontSize);
  }

  Future<void> _reloadPrimaryFace() async {
    if (!done) return;
    if (_faces.isEmpty) return;

    final oldPrimary = _faces.first;

    final collector = FontCollector(fontName: fontName, bold: bold, italic: italic);
    fontCollector = collector;
    final newPath = await collector.getFontPath();
    if (newPath == null) return;

    final newPrimary = await _getOrLoadFace(
      newPath,
      resolvedBold: collector.resolvedBold,
      resolvedItalic: collector.resolvedItalic,
    );
    if (!newPrimary.isValid) return;

    // Move new primary entry to the front.
    final idxNew = _faces.indexWhere((e) => e.face == newPrimary.face && e.path == newPrimary.path);
    if (idxNew > 0) {
      _faces.removeAt(idxNew);
      _faces.insert(0, newPrimary);
    } else if (idxNew == -1) {
      // Should not happen, but keep it safe.
      _faces.insert(0, newPrimary);
    }

    // Drop the old primary entry (avoid accumulating faces on repeated setStyle calls).
    if (oldPrimary.face != newPrimary.face || oldPrimary.path != newPrimary.path) {
      final idxOld = _faces.indexWhere(
        (e) => e.face == oldPrimary.face && e.path == oldPrimary.path && (e.face != newPrimary.face || e.path != newPrimary.path),
      );
      if (idxOld >= 0) {
        _faces.removeAt(idxOld);
      }

      final stillUsed = _faces.any((e) => e.face == oldPrimary.face);
      if (!stillUsed && oldPrimary.isValid) {
        // Keep maps consistent with live faces.
        if (_facesByPath[oldPrimary.path] == oldPrimary.face) {
          _facesByPath.remove(oldPrimary.path);
        }
        freeType!.FT_Done_Face(oldPrimary.face);
      }
    }

    // Update caches/handles.
    _codePointToFaceIndex.clear();
    face ??= calloc<FT_Face>();
    face!.value = _primaryFace!;
  }

  /// Adds a fallback face by font name (resolved via [FontCollector]).
  Future<void> addFallbackFont(
    String fallbackFontName, {
    bool bold = false,
    bool italic = false,
  }) async {
    if (!done) {
      print('call method init first');
      return;
    }
    final collector = FontCollector(fontName: fallbackFontName, bold: bold, italic: italic);
    final path = await collector.getFontPath();
    if (path == null) return;
    await _getOrLoadFace(path, resolvedBold: collector.resolvedBold, resolvedItalic: collector.resolvedItalic);
    setSize(fontSize);
  }

  /// Adds a fallback face by absolute file path.
  Future<void> addFallbackFontPath(String fontPath) async {
    if (!done) {
      print('call method init first');
      return;
    }
    await _getOrLoadFace(fontPath, resolvedBold: false, resolvedItalic: false);
    setSize(fontSize);
  }

  Future<_AssFaceEntry> _getOrLoadFace(
    String fontPath, {
    required bool resolvedBold,
    required bool resolvedItalic,
  }) async {
    final existingFace = _facesByPath[fontPath];
    if (existingFace != null) {
      final idx = _faces.indexWhere((e) => e.face == existingFace);
      if (idx >= 0) return _faces[idx];
    }

    final ft = freeType!;
    final lib = library!;

    final outFacePtr = calloc<FT_Face>();
    final pathPtr = fontPath.asCharP(); // malloc by default (must free)
    try {
      final err = ft.FT_New_Face(lib.value, pathPtr, 0, outFacePtr);
      if (err == FT_Err_Unknown_File_Format) {
        print("Font format is unsupported: $fontPath");
      } else if (err == 1) {
        print("Font file is missing or corrupted: $fontPath");
      }
      if (err != FT_Err_Ok) {
        return _AssFaceEntry.empty(fontPath);
      }

      final face = outFacePtr.value;
      _facesByPath[fontPath] = face;
      final entry = _AssFaceEntry(
        path: fontPath,
        face: face,
        resolvedBold: resolvedBold,
        resolvedItalic: resolvedItalic,
      );
      _faces.add(entry);
      _codePointToFaceIndex.clear(); // face set changed; clear cache
      return entry;
    } finally {
      malloc.free(pathPtr);
      calloc.free(outFacePtr);
    }
  }

  void _applySizeToFace(_AssFaceEntry entry) {
    final ft = freeType!;
    setFontMetrics(ft, entry.face);
    assFaceSetSize(ft, entry.face, fontSize);
    entry.weight = assFaceGetWeight(ft, entry.face);
  }

  void setSize(double? newFontSize, {bool fromInit = false}) {
    if (!done && !fromInit) {
      print('call method init first');
      return;
    }
    if (newFontSize == null) return;

    scaleX = scx!;
    scaleY = scy!;
    fontSize = newFontSize;

    if (fontSize > 100) {
      double factor = (fontSize - 100) / 100;
      scaleX += scaleX * factor;
      scaleY += scaleY * factor;
      fontSize = 100;
    }

    scaleX /= 100;
    scaleY /= 100;

    for (final f in _faces) {
      if (!f.isValid) continue;
      _applySizeToFace(f);
    }

    // Metrics are derived from the primary face.
    final primary = _primaryFace;
    if (primary != null) {
      final ascDesc = assFontGetAscDesc(freeType!, primary);
      ascender = ascDesc.asc / UPSCALE;
      descender = ascDesc.desc / UPSCALE;
      height = ascender! + descender!;
      weight = _faces.isNotEmpty ? _faces.first.weight : null;
    }
  }

  AssFontMetrics? metrics() {
    if (!done) {
      print('call method init first');
      return null;
    }
    final primary = _primaryFace;
    if (primary == null) return null;
    return AssFontMetrics(
      ascent: (ascender ?? 0) * scaleY,
      descent: (descender ?? 0) * scaleY,
      height: (height ?? 0) * scaleY,
      internalLeading: ((ascender ?? 0) - (descender ?? 0) - (primary.ref.units_per_EM / UPSCALE)) * scaleY,
      externalLeading: 0,
    );
  }

  _AssFaceEntry? _faceEntryForCodePoint(int codePoint) {
    if (_faces.isEmpty) return null;
    final cached = _codePointToFaceIndex[codePoint];
    if (cached != null && cached >= 0 && cached < _faces.length) {
      final e = _faces[cached];
      if (e.isValid) return e;
    }
    final ft = freeType!;
    for (int i = 0; i < _faces.length; i++) {
      final e = _faces[i];
      if (!e.isValid) continue;
      final glyphIndex = ft.FT_Get_Char_Index(e.face, codePoint);
      if (glyphIndex != 0) {
        _codePointToFaceIndex[codePoint] = i;
        return e;
      }
    }
    return null;
  }

  void callBackCharsGlyph(String text, GlyphCallback callback) {
    if (!done) {
      print('call method init first');
      return;
    }
    final ft = freeType!;
    for (final codePoint in text.runes) {
      final entry = _faceEntryForCodePoint(codePoint);
      if (entry == null) continue;
      final face = entry.face;
      final glyphIndex = ft.FT_Get_Char_Index(face, codePoint);
      if (glyphIndex == 0) continue;
      final err = ft.FT_Load_Glyph(face, glyphIndex, FT_LOAD_DEFAULT);
      if (err != 0) continue;
      final glyphSlot = face.ref.glyph;

      // Synthetic styles when the resolved font doesn't match requested style.
      if (bold && (entry.weight ?? 400) < 700 && !entry.resolvedBold) {
        assGlyphEmbolden(ft, glyphSlot);
      }
      if (italic && !entry.resolvedItalic) {
        assGlyphItalicize(ft, glyphSlot);
      }

      callback(glyphSlot);
    }
  }

  AssFontTextExtents? textExtents(String text) {
    if (!done) {
      print('call method init first');
      return null;
    }
    double width = 0;
    callBackCharsGlyph(text, (glyph) {
      width += glyph.ref.metrics.horiAdvance + (spacing * UPSCALE);
    });
    return AssFontTextExtents(
      width: (width / UPSCALE) * scaleX,
      height: (height ?? 0) * scaleY,
    );
  }

  String? getTextToShape(String text) {
    isSvg = false;
    if (!done) {
      print('call method init first');
      return null;
    }

    final ft = freeType!;
    final paths = <String>[];
    int penX = 0;

    for (final codePoint in text.runes) {
      final entry = _faceEntryForCodePoint(codePoint);
      if (entry == null) continue;
      final facePtr = entry.face;
      final glyphIndex = ft.FT_Get_Char_Index(facePtr, codePoint);
      if (glyphIndex == 0) continue;
      final err = ft.FT_Load_Glyph(facePtr, glyphIndex, FT_LOAD_DEFAULT);
      if (err != 0) continue;

      final glyph = facePtr.ref.glyph;

      if (bold && (entry.weight ?? 400) < 700 && !entry.resolvedBold) {
        assGlyphEmbolden(ft, glyph);
      }
      if (italic && !entry.resolvedItalic) {
        assGlyphItalicize(ft, glyph);
      }

      final outline = glyph.ref.outline;
      if (outline.n_points == 0 || outline.n_contours == 0) {
        penX += glyph.ref.metrics.horiAdvance.toInt() + (spacing * UPSCALE).toInt();
        continue;
      }

      final build = <List<dynamic>>[];
      final ctxId = _nextDecomposeId++;
      _decomposeRegistry[ctxId] = _DecomposeContext(
        build,
        penX,
        ((ascender ?? 0) * UPSCALE).toInt(),
      );
      final userPtr = malloc<Int64>();
      userPtr.value = ctxId;
      final funcs = calloc<FT_Outline_Funcs>();
      funcs.ref.move_to = _moveToPtr;
      funcs.ref.line_to = _lineToPtr;
      funcs.ref.conic_to = _conicToPtr;
      funcs.ref.cubic_to = _cubicToPtr;
      funcs.ref.shift = 0;
      funcs.ref.delta = 0;
      final outlinePtr = malloc<FT_Outline_>();
      outlinePtr.ref = outline;
      try {
        ft.FT_Outline_Decompose(outlinePtr, funcs, userPtr.cast<Void>());
      } catch (e) {
        // If it fails, clear and continue (do not abort).
      }
      malloc.free(outlinePtr);
      calloc.free(funcs);
      final int idForRemoval = userPtr.value;
      malloc.free(userPtr);
      final _DecomposeContext? ctx = _decomposeRegistry.remove(idForRemoval);
      final localBuild = ctx?.build ?? <List<dynamic>>[];
      for (int i = 1; i < localBuild.length; i++) {
        final val = localBuild[i];
        if (val.isNotEmpty && val[0] == "q") {
          final prev = localBuild[i - 1];
          final p1x = prev[prev.length - 2] as num;
          final p1y = prev.last as num;
          final p4x = val[3] as num;
          final p4y = val[4] as num;
          final p2x = p1x + 2 / 3 * (val[1] - p1x);
          final p2y = p1y + 2 / 3 * (val[2] - p1y);
          final p3x = p4x + 2 / 3 * (val[1] - p4x);
          final p3y = p4y + 2 / 3 * (val[2] - p4y);
          localBuild[i] = ["b", p2x, p2y, p3x, p3y, p4x, p4y];
        }
      }
      final glyphPath = localBuild.map((cmd) => cmd.join(" ")).join(" ");
      String path = glyphPath;
      if (underline || strikeOut) {
        path += assGetGlyphOutline(
          ft,
          facePtr,
          underline,
          strikeOut,
          penX,
          ((ascender ?? 0) * UPSCALE).toInt(),
        );
      }
      paths.add(path);
      penX += glyph.ref.metrics.horiAdvance.toInt() + (spacing * UPSCALE).toInt();
    }

    return paths.join(" ");
  }

  AssPaths? getTextToAssPaths(String text) {
    final shape = getTextToShape(text);
    if (shape != null) return AssPaths.parse(shape);
    return null;
  }

  String? getTextToSvg(String text) {
    isSvg = true;
    if (!done) {
      print('call method init first');
      return null;
    }

    final ft = freeType!;
    final buffer = StringBuffer();
    buffer.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'version="1.1" fill="black">',
    );

    double penX = 0.0;
    for (final codePoint in text.runes) {
      final entry = _faceEntryForCodePoint(codePoint);
      if (entry == null) continue;
      final facePtr = entry.face;
      final glyphIndex = ft.FT_Get_Char_Index(facePtr, codePoint);
      if (glyphIndex == 0) continue;
      final err = ft.FT_Load_Glyph(facePtr, glyphIndex, FT_LOAD_DEFAULT);
      if (err != 0) continue;

      final glyph = facePtr.ref.glyph;

      if (bold && (entry.weight ?? 400) < 700 && !entry.resolvedBold) {
        assGlyphEmbolden(ft, glyph);
      }
      if (italic && !entry.resolvedItalic) {
        assGlyphItalicize(ft, glyph);
      }

      final outline = glyph.ref.outline;
      if (outline.n_points == 0 || outline.n_contours == 0) {
        penX += glyph.ref.metrics.horiAdvance / UPSCALE + spacing;
        continue;
      }
      final build = <List<dynamic>>[];
      final ctxId = _nextDecomposeId++;
      _decomposeRegistry[ctxId] = _DecomposeContext(
        build,
        (penX * UPSCALE).toInt(),
        ((ascender ?? 0) * UPSCALE).toInt(),
      );
      final userPtr = malloc<Int64>();
      userPtr.value = ctxId;
      final funcs = calloc<FT_Outline_Funcs>();
      funcs.ref.move_to = _moveToPtr;
      funcs.ref.line_to = _lineToPtr;
      funcs.ref.conic_to = _conicToPtr;
      funcs.ref.cubic_to = _cubicToPtr;
      funcs.ref.shift = 0;
      funcs.ref.delta = 0;
      final outlinePtr = malloc<FT_Outline_>();
      outlinePtr.ref = outline;
      try {
        ft.FT_Outline_Decompose(outlinePtr, funcs, userPtr.cast<Void>());
      } catch (e) {
        // If it fails, clear and continue (do not abort).
      }
      malloc.free(outlinePtr);
      calloc.free(funcs);
      final int idForRemoval = userPtr.value;
      malloc.free(userPtr);
      final ctx = _decomposeRegistry.remove(idForRemoval);
      final localBuild = ctx?.build ?? <List<dynamic>>[];
      for (int i = 1; i < localBuild.length; i++) {
        final val = localBuild[i];
        if (val.isNotEmpty && val[0] == "q") {
          final prev = localBuild[i - 1];
          final p1x = prev[prev.length - 2] as num;
          final p1y = prev.last as num;
          final p4x = val[3] as num;
          final p4y = val[4] as num;
          final p2x = p1x + 2 / 3 * (val[1] - p1x);
          final p2y = p1y + 2 / 3 * (val[2] - p1y);
          final p3x = p4x + 2 / 3 * (val[1] - p4x);
          final p3y = p4y + 2 / 3 * (val[2] - p4y);
          localBuild[i] = ["C", p2x, p2y, p3x, p3y, p4x, p4y];
        }
      }
      String path = localBuild.map((cmd) => cmd.join(" ")).join(" ");
      if (underline || strikeOut) {
        path += assGetGlyphOutline(
          ft,
          facePtr,
          underline,
          strikeOut,
          (penX * UPSCALE).toInt(),
          ((ascender ?? 0) * UPSCALE).toInt(),
        );
      }
      buffer.writeln('<path d="$path" />');
      penX += glyph.ref.metrics.horiAdvance / UPSCALE + spacing;
    }
    buffer.writeln('</svg>');
    return buffer.toString();
  }

  void dispose() {
    done = false;

    final ft = freeType;
    if (ft != null) {
      // Face pointers belong to this library; dispose them all.
      final seen = <Pointer<FT_FaceRec_>>{};
      for (final entry in _faces) {
        if (!entry.isValid) continue;
        if (seen.add(entry.face)) {
          ft.FT_Done_Face(entry.face);
        }
      }
      _faces.clear();
      _facesByPath.clear();
      _codePointToFaceIndex.clear();

      if (library != null) {
        ft.FT_Done_FreeType(library!.value);
        calloc.free(library!);
        library = null;
      }
    }

    if (face != null) {
      calloc.free(face!);
      face = null;
    }

    fontCollector = null;
    freeType = null;
  }
}

class _AssFaceEntry {
  final String path;
  final Pointer<FT_FaceRec_> face;
  final bool resolvedBold;
  final bool resolvedItalic;
  int? weight;

  _AssFaceEntry({
    required this.path,
    required this.face,
    required this.resolvedBold,
    required this.resolvedItalic,
    this.weight,
  });

  bool get isValid => face != nullptr;

  static _AssFaceEntry empty(String path) => _AssFaceEntry(
        path: path,
        face: nullptr,
        resolvedBold: false,
        resolvedItalic: false,
      );
}
