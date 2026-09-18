import 'dart:convert';
import 'dart:typed_data';

/// An owned copy of a public certificate. Does not establish trust or parse it.
final class TlsCertificate {
  final Uint8List der;

  TlsCertificate(Uint8List der)
    : der = Uint8List.fromList(der).asUnmodifiableView();

  String get pem {
    final encoded = base64Encode(der);
    final result = StringBuffer('-----BEGIN CERTIFICATE-----\n');
    for (var start = 0; start < encoded.length; start += 64) {
      final end = start + 64;
      result.writeln(
        encoded.substring(start, end < encoded.length ? end : encoded.length),
      );
    }
    return (result..writeln('-----END CERTIFICATE-----')).toString();
  }
}
