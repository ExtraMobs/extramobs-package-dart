import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

void main() {
  final cases = <(String, List<int>, String)>[
    ('UTF-8 normal', [0x41, 0x42, 0x43], 'ABC'),
    ('UTF-16LE completo', [0x41, 0, 0x42, 0, 0x43, 0], 'ABC'),
    ('UTF-16LE sem o ultimo byte', [0x41, 0, 0x42, 0, 0x43], 'A\u0000B\u0000C'),
    (
      'UTF-16LE com um byte zero extra',
      [0x41, 0, 0x42, 0, 0x43, 0, 0],
      'A\u0000B\u0000C\u0000\u0000',
    ),
    (
      'UTF-16LE incluindo terminador de dois bytes',
      [0x41, 0, 0x42, 0, 0x43, 0, 0, 0],
      'ABC\u0000',
    ),
    ('UTF-16BE completo', [0, 0x41, 0, 0x42, 0, 0x43], '\u0000A\u0000B\u0000C'),
    ('UTF-8 incluindo terminador C', [0x41, 0x42, 0x43, 0], '\u4241C'),
    ('UTF-16LE chines sem zeros', [0x2d, 0x4e, 0x87, 0x65], '-N\u0087e'),
  ];
  for (final (label, input, expected) in cases) {
    test('legacy: $label', () {
      final bytes = Uint8List.fromList(input);
      final result = _legacyDecodeText(bytes);
      expect(result, expected);
      final hex = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      // JSON makes real NUL characters visible; no removal or cleanup is used.
      print('$label: $hex -> ${jsonEncode(result)}');
    });
  }
}

// Historical text branch and helpers from HEAD:lib/src/ffi/freetds_bindings.dart,
// before the UTF-8 unification. Kept only to reproduce the old behavior.
String _legacyDecodeText(Uint8List bytes) {
  if (_looksUtf16LeText(bytes)) return _utf16leDecode(bytes);
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

String _utf16leDecode(Uint8List bytes) {
  final n = bytes.length & ~1;
  final codes = List<int>.filled(n >> 1, 0);
  for (int i = 0, j = 0; i < n; i += 2, j++) {
    codes[j] = bytes[i] | (bytes[i + 1] << 8);
  }
  return String.fromCharCodes(codes);
}

bool _looksUtf16LeText(Uint8List bytes) {
  if (bytes.length < 2 || (bytes.length & 1) == 1) return false;
  for (int i = 1; i < bytes.length; i += 2) {
    if (bytes[i] == 0) return true;
  }
  return false;
}
