import 'dart:ffi';
import 'dart:io';
import 'generated_bindings.dart';

FreetypeBinding loadFreeType() {
  late DynamicLibrary lib;
  if (Platform.isWindows) {
    lib = DynamicLibrary.open('libfreetype-6.dll');
  } else if (Platform.isMacOS) {
    lib = DynamicLibrary.open('libfreetype.6.dylib');
  } else if (Platform.isLinux) {
    lib = DynamicLibrary.open('libfreetype.so.6');
  } else if (Platform.isAndroid) {
    lib = DynamicLibrary.open('libfreetype.so');
  } else if (Platform.isIOS) {
    lib = DynamicLibrary.process();
  } else {
    throw UnsupportedError('Unsupported platform');
  }
  return FreetypeBinding(lib);
}