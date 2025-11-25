import 'dart:ffi';
import 'package:dart_ass/dart_ass.dart';
import 'package:ffi/ffi.dart';

import '../font_collector.dart';
import 'package:dart_freetype/dart_freetype.dart';

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
  Pointer<Pointer<FT_FaceRec_>>? face;
  FontCollector? fontCollector;

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

  Future init() async {
    int err;
    freeType = loadFreeType();

    library = calloc<FT_Library>();
    err = freeType!.FT_Init_FreeType(library!);
    if (err != FT_Err_Ok) {
      print('err on Init FreeType');
    }

    fontCollector = FontCollector(fontName: fontName, bold: bold, italic: italic);
    String? fontPath = await fontCollector!.getFontPath();

    face = calloc<FT_Face>();
    err = freeType!.FT_New_Face(library!.value, fontPath!.asCharP(), 0, face!);
    if (err == FT_Err_Unknown_File_Format) {
      print("Font format is unsupported");
    } else if (err == 1) {
      print("Font file is missing or corrupted");
    }
    setSize(fontSize);

    scx = scaleX;
    scy = scaleY;

    done = true;
  }

  void setSize(double? newFontSize) {
    if (done) {
      scaleX = scx!;
      scaleY = scy!;
      if (newFontSize != null) {
        // limits font size to 100 using scale 0 <--> 1
        if (newFontSize > 100) {
          double factor = (newFontSize - 100) / 100;
          scaleX += scaleX * factor;
          scaleY += scaleY * factor;
          fontSize = 100;
        }
        scaleX /= 100;
        scaleY /= 100;
        setFontMetrics(freeType!, face!.value);
        assFaceSetSize(freeType!, face!.value, fontSize);
        AscDesc ascDesc = assFontGetAscDesc(freeType!, face!.value);
        ascender = ascDesc.asc / UPSCALE;
        descender = ascDesc.desc / UPSCALE;
        if (ascender != null && descender != null) {
          height = ascender! + descender!;
        }
        weight = assFaceGetWeight(freeType!, face!.value);
      }
    } else {
      print('call method init fist');
    }
  }

  AssFontMetrics? metrics() {
    if (done) {
      return AssFontMetrics(
        ascent: ascender! * scaleY,
        descent: descender! * scaleY,
        height: height! * scaleY,
        internalLeading:
            (ascender! -
                descender! -
                (face!.value.ref.units_per_EM / UPSCALE)) *
            scaleY,
        externalLeading: 0,
      );
    } else {
      print('call method init fist');
    }
    return null;
  }

  void callBackCharsGlyph(String text, GlyphCallback callback) async {
    if (done) {
      Runes units = text.runes;
      for (int codePoint in units) {
        int glyphIndex = freeType!.FT_Get_Char_Index(face!.value, codePoint);
        if (glyphIndex == 0) {
          continue;
        }
        int err = freeType!.FT_Load_Glyph(
          face!.value,
          glyphIndex,
          FT_LOAD_DEFAULT,
        );
        if (err != 0) {
          continue;
        }
        Pointer<FT_GlyphSlotRec_> glyphSlot = face!.value.ref.glyph;
        if (bold && weight! < 700 && !fontCollector!.resolvedBold) {
          assGlyphEmbolden(freeType!, glyphSlot);
        }
        if (italic && !fontCollector!.resolvedItalic) {
          assGlyphItalicize(freeType!, glyphSlot);
        }
        callback(glyphSlot);
      }
    } else {
      print('call method init fist');
    }
  }

  AssFontTextExtents? textExtents(String text) {
    if (done) {
      double width = 0;
      callBackCharsGlyph(text, (glyph) {
        width += glyph.ref.metrics.horiAdvance + (spacing * UPSCALE);
      });
      return AssFontTextExtents(
        width: (width / UPSCALE) * scaleX,
        height: height! * scaleY,
      );
    } else {
      print('call method init fist');
    }
    return null;
  }

  String? getTextToShape(String text) {
    isSvg = false;
    if (done) {
      final ft = freeType!;
      final fface = face!.value;
      final paths = <String>[];
      int penX = 0;
      callBackCharsGlyph(text, (glyph) {
        final outline = glyph.ref.outline;
        if (outline.n_points == 0 || outline.n_contours == 0) {
          penX +=
              glyph.ref.metrics.horiAdvance.toInt() +
              (spacing * UPSCALE).toInt();
          return;
        }
        final build = <List<dynamic>>[];
        final ctxId = _nextDecomposeId++;
        _decomposeRegistry[ctxId] = _DecomposeContext(
          build,
          penX,
          (ascender! * UPSCALE).toInt(),
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
            fface,
            underline,
            strikeOut,
            penX,
            (ascender! * UPSCALE).toInt(),
          );
        }
        paths.add(path);
        penX +=
            glyph.ref.metrics.horiAdvance.toInt() + (spacing * UPSCALE).toInt();
      });
      return paths.join(" ");
    } else {
      print('call method init fist');
    }
    return null;
  }

  AssPaths? getTextToAssPaths(String text) {
    String? shape = getTextToShape(text);
    if (shape != null) {
      return AssPaths.parse(shape);
    }
    return null;
  }

  String? getTextToSvg(String text) {
    isSvg = true;
    if (done) {
      final ft = freeType!;
      final fface = face!.value;
      final buffer = StringBuffer();
      buffer.writeln(
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'version="1.1" fill="black">',
      );
      double penX = 0.0;
      callBackCharsGlyph(text, (glyph) {
        final outline = glyph.ref.outline;
        if (outline.n_points == 0 || outline.n_contours == 0) {
          penX += glyph.ref.metrics.horiAdvance / UPSCALE + spacing;
          return;
        }
        final build = <List<dynamic>>[];
        final ctxId = _nextDecomposeId++;
        _decomposeRegistry[ctxId] = _DecomposeContext(
          build,
          (penX * UPSCALE).toInt(),
          (ascender! * UPSCALE).toInt(),
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
        final localBuild = ctx?.build ?? [];
        for (int i = 1; i < localBuild.length; i++) {
          final val = localBuild[i];
          if (val[0] == "q") {
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
            fface,
            underline,
            strikeOut,
            (penX * UPSCALE).toInt(),
            (ascender! * UPSCALE).toInt(),
          );
        }
        buffer.writeln('<path d="$path" />');
        penX += glyph.ref.metrics.horiAdvance / UPSCALE + spacing;
      });
      buffer.writeln('</svg>');
      return buffer.toString();
    } else {
      print('call method init fist');
    }
    return null;
  }

  void dispose() {
    done = false;
    if (face != null) {
      freeType!.FT_Done_Face(face!.value);
    }
    if (library != null) {
      freeType!.FT_Done_FreeType(library!.value);
    }
  }
}
