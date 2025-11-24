import 'dart:ffi';
import 'package:ffi/ffi.dart';

import '../font_collector.dart';
import 'package:dart_freetype/dart_freetype.dart';

// ignore: constant_identifier_names
const int UPSCALE = 64;

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
  AssFontTextExtents({
    required this.width,
    required this.height,
  });
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

  FreetypeBinding? freeType;
  Pointer<Pointer<FT_LibraryRec_>>? library;
  Pointer<Pointer<FT_FaceRec_>>? face;

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

    String? fontPath = await FontCollector(fontName: fontName).getFontPath();

    face = calloc<FT_Face>();
    err = freeType!.FT_New_Face(library!.value, fontPath!.asCharP(), 0, face!);
    if (err == FT_Err_Unknown_File_Format) {
      print("Font format is unsupported");
    } else if (err == 1) {
      print("Font file is missing or corrupted");
    }

    // limits font size to 100 using scale 0 <--> 1
		if (fontSize > 100) {
			double factor = (fontSize - 100) / 100;
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
    done = true;
  }

  AssFontMetrics? metrics() {
    if (done) {
      return AssFontMetrics(
        ascent: ascender! * scaleY,
        descent: descender! * scaleY,
        height: height! * scaleY,
        internalLeading: (ascender! -
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

  void callBackCharsGlyph(
    String text,
    GlyphCallback callback,
  ) async {
    if (done) {
      Runes units = text.runes;
      for (int codePoint in units) {
        int glyphIndex = freeType!.FT_Get_Char_Index(face!.value, codePoint);
        if (glyphIndex == 0) {
          continue;
        }
        int err =
            freeType!.FT_Load_Glyph(face!.value, glyphIndex, FT_LOAD_DEFAULT);
        if (err != 0) {
          continue;
        }
        Pointer<FT_GlyphSlotRec_> glyphSlot = face!.value.ref.glyph;
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