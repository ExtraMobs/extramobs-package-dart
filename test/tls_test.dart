import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:extramobs/mssql.dart';
import 'package:extramobs/packages/mssql/src/mssql_client.dart';
import 'package:test/test.dart';

void main() {
  test('invalid PEM paths and hostnames fail before native access', () async {
    for (final policy in <TlsConfig>[
      const TlsRequire(trust: TlsPemTrust('')),
      const TlsStrict(trust: TlsPemTrust('relative.pem')),
      TlsRequire(trust: TlsPemTrust('${File('ca.pem').absolute.path}\u0000')),
      const TlsRequest(certificateHostname: ''),
      const TlsStrict(
        trust: TlsSystemTrust(),
        certificateHostname: 'host\u0000',
      ),
    ]) {
      final client = MssqlClient(
        server: 'unused.invalid',
        username: 'test',
        password: 'test',
        tls: policy,
      );
      await expectLater(client.connect(), throwsArgumentError);
      expect(client.isConnected, isFalse);
    }
  });

  test('certificate owns immutable DER and produces wrapped PEM', () {
    final bytes = Uint8List.fromList(List.generate(257, (i) => i % 256));
    final original = bytes.toList();
    final certificate = TlsCertificate(bytes);
    bytes.fillRange(0, bytes.length, 0);
    expect(certificate.der, original);
    expect(() => certificate.der[0] = 1, throwsUnsupportedError);
    expect(
      () => certificate.der.buffer.asUint8List()[0] = 1,
      throwsUnsupportedError,
    );
    final lines = certificate.pem.trim().split('\n');
    expect(lines.first, '-----BEGIN CERTIFICATE-----');
    expect(lines.last, '-----END CERTIFICATE-----');
    expect(certificate.pem.endsWith('\n'), isTrue);
    final body = lines.sublist(1, lines.length - 1);
    expect(
      body.take(body.length - 1).every((line) => line.length == 64),
      isTrue,
    );
    expect(base64Decode(body.join()), original);
  });

  test(
    'TLS restrictions are enforced by the compiler',
    () async {
      final directory = Directory.systemTemp.createTempSync('mssql-tls-types-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final config = File('lib/packages/mssql/src/tls_config.dart').absolute.uri;
      final valid = File('${directory.path}/valid.dart')
        ..writeAsStringSync('''
import '$config';
void main() {
  const List<TlsConfig> modes = [
    TlsOff(), TlsRequest(), TlsRequire(),
    TlsRequest(trust: TlsSystemTrust()),
    TlsRequire(trust: TlsPemTrust('/ca.pem')),
    TlsStrict(trust: TlsSystemTrust()),
    TlsStrict(trust: TlsPemTrust('/ca.pem')),
  ];
  print(modes.length);
}
''');
      final positive = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        valid.path,
        '-o',
        '${directory.path}/valid.dill',
      ]);
      expect(
        positive.exitCode,
        0,
        reason: '${positive.stdout}\n${positive.stderr}',
      );

      final invalid = <String>[
        'void main() { TlsStrict(); }',
        'void main() { TlsStrict(trust: null); }',
        'void main() { TlsOff(trust: TlsSystemTrust()); }',
        'void main() { TlsStrict(trust: "system"); }',
        'final class Bad extends TlsConfig {} void main() {}',
        'final class Bad with TlsWithRequiredTrust {} void main() {}',
        '''final class Bad with TlsWithTrust, TlsWithRequiredTrust {
        TlsTrust? get trust => null;
        String? get certificateHostname => null;
      } void main() {}''',
      ];
      for (var i = 0; i < invalid.length; i++) {
        final source = File('${directory.path}/invalid_$i.dart')
          ..writeAsStringSync("import '$config';\n${invalid[i]}\n");
        final result = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'kernel',
          source.path,
          '-o',
          '${directory.path}/invalid_$i.dill',
        ]);
        expect(result.exitCode, isNot(0), reason: invalid[i]);
        expect(
          '${result.stdout}${result.stderr}',
          contains('Error:'),
          reason: 'Must fail compilation, not process startup',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    testOn: 'windows || linux || mac-os',
  );
}
