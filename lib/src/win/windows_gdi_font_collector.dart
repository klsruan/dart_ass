import 'dart:ffi';
import 'package:ffi/ffi.dart';

const int DEFAULT_CHARSET = 1;
const int HKEY_LOCAL_MACHINE = 0x80000002;
const int KEY_READ = 0x20019;
const int ERROR_SUCCESS = 0;
const int FONTTYPE_RASTER = 0x1;
const int FONTTYPE_DEVICE = 0x2;
const int FONTTYPE_TRUETYPE = 0x4;

base class LOGFONTW extends Struct {
  @Int32() external int lfHeight;
  @Int32() external int lfWidth;
  @Int32() external int lfEscapement;
  @Int32() external int lfOrientation;
  @Int32() external int lfWeight;
  @Uint8() external int lfItalic;
  @Uint8() external int lfUnderline;
  @Uint8() external int lfStrikeOut;
  @Uint8() external int lfCharSet;
  @Uint8() external int lfOutPrecision;
  @Uint8() external int lfClipPrecision;
  @Uint8() external int lfQuality;
  @Uint8() external int lfPitchAndFamily;

  @Array<Uint16>(32)
  external Array<Uint16> lfFaceName;
}

base class ENUMLOGFONTEXW extends Struct {
  external LOGFONTW elfLogFont;
  @Array<Uint16>(64)
  external Array<Uint16> elfFullName;
  @Array<Uint16>(32)
  external Array<Uint16> elfStyle;
  @Array<Uint16>(32)
  external Array<Uint16> elfScript;
}

String utf16ArrayToString(Array<Uint16> arr, int length) {
  final list = <int>[];
  for (int i = 0; i < length; i++) {
    final v = arr[i];
    if (v == 0) break;
    list.add(v);
  }
  return String.fromCharCodes(list);
}

String utf16PtrToString(Pointer<Uint16> ptr) {
  final list = <int>[];
  int offset = 0;
  while (true) {
    final v = ptr.elementAt(offset).value;
    if (v == 0) break;
    list.add(v);
    offset++;
  }
  return String.fromCharCodes(list);
}

String normalizeRegName(String name) {
  var s = name.replaceAll(RegExp(r'\s*\(.*?\)$'), '');
  s = s.trim();
  if (s.startsWith('@')) s = s.substring(1);
  return s;
}

class WindowsFont {
  String name;
  String style;
  String longName;
  String type;
  String? file;
  WindowsFont({
    required this.name,
    required this.style,
    required this.longName,
    required this.type,
    this.file,
  });
}

typedef EnumFontProcNative = Int32 Function(
  Pointer<ENUMLOGFONTEXW>,
  Pointer<Void>,
  Uint32,
  IntPtr,
);

typedef EnumFontProcDart = int Function(
  Pointer<ENUMLOGFONTEXW>,
  Pointer<Void>,
  int,
  int,
);

final List<WindowsFont> _callbackFonts = [];

int _enumFontCallback(
  Pointer<ENUMLOGFONTEXW> p,
  Pointer<Void> _,
  int fontType,
  int __,
) {
  try {
    final ref = p.ref;

    final face = utf16ArrayToString(ref.elfLogFont.lfFaceName, 32);
    final style = utf16ArrayToString(ref.elfStyle, 32);
    final longName = utf16ArrayToString(ref.elfFullName, 64);

    String type =
        (fontType & FONTTYPE_TRUETYPE) != 0 ? "TrueType"
      : (fontType & FONTTYPE_RASTER) != 0 ? "Raster"
      : (fontType & FONTTYPE_DEVICE) != 0 ? "Device"
      : "Unknown";

    _callbackFonts.add(WindowsFont(
      name: face,
      style: style,
      longName: longName,
      type: type,
    ));
  } catch (_) {}

  return 1;
}

class WindowsGdiFontCollector {
  final DynamicLibrary gdi32 = DynamicLibrary.open("gdi32.dll");
  final DynamicLibrary advapi32 = DynamicLibrary.open("advapi32.dll");

  late final int Function(int) CreateCompatibleDC =
      gdi32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
          "CreateCompatibleDC");

  late final int Function(int) DeleteDC =
      gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          "DeleteDC");

  late final int Function(
    int,
    Pointer<LOGFONTW>,
    Pointer<NativeFunction<EnumFontProcNative>>,
    int,
    int,
  ) EnumFontFamiliesExW =
      gdi32.lookupFunction<
          Int32 Function(IntPtr, Pointer<LOGFONTW>,
              Pointer<NativeFunction<EnumFontProcNative>>, IntPtr, Uint32),
          int Function(
              int,
              Pointer<LOGFONTW>,
              Pointer<NativeFunction<EnumFontProcNative>>,
              int,
              int)>('EnumFontFamiliesExW');

  late final int Function(
    int,
    Pointer<Utf16>,
    int,
    int,
    Pointer<IntPtr>,
  ) RegOpenKeyExW =
      advapi32.lookupFunction<
          Uint32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32,
              Pointer<IntPtr>),
          int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>(
          "RegOpenKeyExW");

  late final int Function(
    int,
    int,
    Pointer<Utf16>,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<Uint8>,
    Pointer<Uint32>,
  ) RegEnumValueW =
      advapi32.lookupFunction<
          Uint32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>,
              Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>,
              Pointer<Uint32>),
          int Function(
              int,
              int,
              Pointer<Utf16>,
              Pointer<Uint32>,
              Pointer<Uint32>,
              Pointer<Uint32>,
              Pointer<Uint8>,
              Pointer<Uint32>)>("RegEnumValueW");

  late final int Function(int) RegCloseKey =
      advapi32.lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
          "RegCloseKey");

  Future<List<WindowsFont>> collect() async {
    _callbackFonts.clear();
    _enumerateGdiFonts();
    final result = List<WindowsFont>.from(_callbackFonts);
    _attachRegistryFiles(result);
    _callbackFonts.clear();
    return result;
  }

  void _enumerateGdiFonts() {
    final log = calloc<LOGFONTW>();
    log.ref.lfCharSet = DEFAULT_CHARSET;
    final hdc = CreateCompatibleDC(0);
    final cbPointer =
        Pointer.fromFunction<EnumFontProcNative>(_enumFontCallback, 1);
    EnumFontFamiliesExW(hdc, log, cbPointer, 0, 0);
    DeleteDC(hdc);
    calloc.free(log);
  }

  void _attachRegistryFiles(List<WindowsFont> fonts) {
    final key = calloc<IntPtr>();
    final subKey =
        "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
            .toNativeUtf16();

    final rc = RegOpenKeyExW(
      HKEY_LOCAL_MACHINE,
      subKey,
      0,
      KEY_READ,
      key,
    );

    if (rc != ERROR_SUCCESS) {
      calloc.free(key);
      calloc.free(subKey);
      return;
    }

    final hKey = key.value;
    final nameBuffer = calloc<Uint16>(1024);
    final nameLen = calloc<Uint32>();
    final dataBuffer = calloc<Uint8>(4096);
    final dataLen = calloc<Uint32>();
    final typeBuffer = calloc<Uint32>();

    int index = 0;
    while (true) {
      nameLen.value = 1024;
      dataLen.value = 4096;

      final r = RegEnumValueW(
        hKey,
        index,
        nameBuffer.cast<Utf16>(),
        nameLen,
        nullptr,
        typeBuffer,
        dataBuffer,
        dataLen,
      );
      if (r != ERROR_SUCCESS) break;
      index++;

      final regName = utf16PtrToString(nameBuffer);
      final fileName = utf16PtrToString(dataBuffer.cast<Uint16>());
      final cleaned = normalizeRegName(regName);

      for (final f in fonts) {
        if (f.file != null) continue;
        if (f.name == cleaned ||
            f.longName == cleaned ||
            "${cleaned} ${f.style}" == f.name) {
          f.file = fileName;
        }
      }
    }

    calloc.free(nameBuffer);
    calloc.free(nameLen);
    calloc.free(dataBuffer);
    calloc.free(dataLen);
    calloc.free(typeBuffer);
    RegCloseKey(hKey);
    calloc.free(key);
    calloc.free(subKey);
  }
}