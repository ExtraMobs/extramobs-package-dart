import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Loads only bundled libraries or an explicitly configured absolute directory.
/// Set libraryDirectory before the first load for standalone Dart development.
class NativeLoader {
  static String? libraryDirectory;
  static DynamicLibrary? _dbLib;

  static DynamicLibrary loadDBLib() => _dbLib ??= _load('sybdb');

  static DynamicLibrary _load(String stem) {
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isAndroid && libraryDirectory == null) {
      // Android's application linker namespace resolves packaged jniLibs.
      return DynamicLibrary.open('lib$stem.so');
    }
    final directory = libraryDirectory;
    if (directory != null && !Directory(directory).isAbsolute) {
      throw ArgumentError('Native library directory must be absolute');
    }
    final executable = File(Platform.resolvedExecutable).parent;
    final root =
        directory ??
        (Platform.isWindows
            ? executable.path
            : Platform.isMacOS
            ? '${executable.parent.path}/Frameworks'
            : '${executable.path}/lib');
    final filename = Platform.isWindows
        ? '$stem.dll'
        : Platform.isMacOS
        ? 'lib$stem.dylib'
        : 'lib$stem.so';
    final path = File('$root/$filename').absolute.path;
    if (!File(path).existsSync()) {
      throw UnsupportedError('Bundled native library missing: $path');
    }
    if (Platform.isWindows) {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final load = kernel
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf16>, Pointer<Void>, Uint32),
            Pointer<Void> Function(Pointer<Utf16>, Pointer<Void>, int)
          >('LoadLibraryExW');
      final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
        'GetLastError',
      );
      using((arena) {
        // DLL_LOAD_DIR | APPLICATION_DIR | SYSTEM32; never cwd/PATH/user dirs.
        final handle = load(
          path.toNativeUtf16(allocator: arena),
          nullptr,
          0x100 | 0x200 | 0x800,
        );
        if (handle == nullptr) {
          throw StateError(
            'Cannot load bundled library (Windows error ${error()})',
          );
        }
      });
    }
    return DynamicLibrary.open(path);
  }
}
