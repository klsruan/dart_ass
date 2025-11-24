import 'dart:ffi';
import 'package:ffi/ffi.dart';

base class FcConfig extends Opaque {}
base class FcFontSet extends Struct {
  @Int32()
  external int nfont;
  @Int32()
  external int sfont;
  external Pointer<Pointer<FcPattern>> fonts;
}
base class FcPattern extends Opaque {}

typedef FcInitNative = Int32 Function();
typedef FcInitDart = int Function();

typedef FcFiniNative = Void Function();
typedef FcFiniDart = void Function();

typedef FcObjectSetBuildNative = Pointer<Void> Function(
  Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef FcObjectSetBuildDart = Pointer<Void> Function(
  Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef FcPatternCreateNative = Pointer<FcPattern> Function();
typedef FcPatternCreateDart = Pointer<FcPattern> Function();

typedef FcFontListNative = Pointer<FcFontSet> Function(
  Pointer<FcConfig>, Pointer<FcPattern>, Pointer<Void>);
typedef FcFontListDart = Pointer<FcFontSet> Function(
  Pointer<FcConfig>, Pointer<FcPattern>, Pointer<Void>);

typedef FcPatternDestroyNative = Void Function(Pointer<FcPattern>);
typedef FcPatternDestroyDart = void Function(Pointer<FcPattern>);

typedef FcFontSetDestroyNative = Void Function(Pointer<FcFontSet>);
typedef FcFontSetDestroyDart = void Function(Pointer<FcFontSet>);

typedef FcPatternGetStringNative = Int32 Function(
  Pointer<FcPattern>, Pointer<Utf8>, Int32, Pointer<Pointer<Uint8>>);
typedef FcPatternGetStringDart = int Function(
  Pointer<FcPattern>, Pointer<Utf8>, int, Pointer<Pointer<Uint8>>);

final class LinuxFont {
  String family;
  String? style;
  String? file;
  LinuxFont({
    required this.family,
    this.style,
    this.file,
  });
}

class LinuxFontCollector {
  late final DynamicLibrary fc;

  late final FcInitDart FcInit;
  late final FcFiniDart FcFini;
  late final FcObjectSetBuildDart FcObjectSetBuild;
  late final FcPatternCreateDart FcPatternCreate;
  late final FcFontListDart FcFontList;
  late final FcPatternDestroyDart FcPatternDestroy;
  late final FcFontSetDestroyDart FcFontSetDestroy;
  late final FcPatternGetStringDart FcPatternGetString;

  LinuxFontCollector() {
    fc = DynamicLibrary.open("libfontconfig.so.1");

    FcInit = fc
        .lookup<NativeFunction<FcInitNative>>("FcInit")
        .asFunction();

    FcFini = fc
        .lookup<NativeFunction<FcFiniNative>>("FcFini")
        .asFunction();

    FcObjectSetBuild = fc
        .lookup<NativeFunction<FcObjectSetBuildNative>>("FcObjectSetBuild")
        .asFunction();

    FcPatternCreate = fc
        .lookup<NativeFunction<FcPatternCreateNative>>("FcPatternCreate")
        .asFunction();

    FcFontList = fc
        .lookup<NativeFunction<FcFontListNative>>("FcFontList")
        .asFunction();

    FcPatternDestroy = fc
        .lookup<NativeFunction<FcPatternDestroyNative>>("FcPatternDestroy")
        .asFunction();

    FcFontSetDestroy = fc
        .lookup<NativeFunction<FcFontSetDestroyNative>>("FcFontSetDestroy")
        .asFunction();

    FcPatternGetString = fc
        .lookup<NativeFunction<FcPatternGetStringNative>>("FcPatternGetString")
        .asFunction();

    FcInit();
  }

  Future<List<LinuxFont>> collect() async {
    final List<LinuxFont> fonts = [];

    final pattern = FcPatternCreate();
    final os = FcObjectSetBuild(
      "family".toNativeUtf8(),
      "style".toNativeUtf8(),
      "file".toNativeUtf8(),
    );

    final fs = FcFontList(nullptr, pattern, os);

    for (int i = 0; i < fs.ref.nfont; i++) {
      final p = fs.ref.fonts[i];

      final famPtrPtr = calloc<Pointer<Uint8>>();
      final stylePtrPtr = calloc<Pointer<Uint8>>();
      final filePtrPtr = calloc<Pointer<Uint8>>();

      FcPatternGetString(p, "family".toNativeUtf8(), 0, famPtrPtr);
      FcPatternGetString(p, "style".toNativeUtf8(), 0, stylePtrPtr);
      FcPatternGetString(p, "file".toNativeUtf8(), 0, filePtrPtr);

      final family = famPtrPtr.value.cast<Utf8>().toDartString();
      final style = stylePtrPtr.value.address != 0
          ? stylePtrPtr.value.cast<Utf8>().toDartString()
          : null;
      final file = filePtrPtr.value.address != 0
          ? filePtrPtr.value.cast<Utf8>().toDartString()
          : null;

      fonts.add(LinuxFont(
        family: family,
        style: style,
        file: file,
      ));

      calloc.free(famPtrPtr);
      calloc.free(stylePtrPtr);
      calloc.free(filePtrPtr);
    }

    FcFontSetDestroy(fs);
    FcPatternDestroy(pattern);

    return fonts;
  }
}