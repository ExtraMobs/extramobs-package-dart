import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

// The client charset set at login must match every DB-Lib text buffer.
// FreeTDS owns conversion between this codec and the server's encoding.
const freeTdsTextCodec = Utf8Codec();
// FreeTDS charset aliases are case-sensitive; Dart's "utf-8" is not accepted.
const freeTdsClientCharset = 'UTF-8';

/// Allocate a C string. The caller must free it with its allocator.
/// Embedded NUL is only supported in length-delimited parameter values.
Pointer<Utf8> toNativeFreeTdsText(String text, {Allocator allocator = malloc}) {
  if (text.contains('\u0000')) {
    throw ArgumentError('FreeTDS C strings cannot contain NUL characters.');
  }
  final bytes = freeTdsTextCodec.encode(text);
  final pointer = allocator<Uint8>(bytes.length + 1);
  pointer.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return pointer.cast<Utf8>();
}

String fromNativeFreeTdsText(Pointer<Utf8> text) => text == nullptr
    ? ''
    : freeTdsTextCodec.decode(text.cast<Uint8>().asTypedList(text.length));
