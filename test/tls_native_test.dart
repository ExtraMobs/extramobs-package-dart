@TestOn('windows || linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

// Run sync and async in separate processes, with Python 3 and OpenSSL installed.
void main() {
  final env = Platform.environment;
  final asynchronous = env['MSSQL_TEST_ASYNC'] == 'true';
  final enabled = env['MSSQL_TEST_TLS'] == '1';
  late Map<String, dynamic> fixture;
  late dynamic db;
  Future<void> connect(String server, TlsConfig? tls) async {
    expect(
      await db.connect(
        ip: '127.0.0.1',
        port: '${fixture['ports'][server]}',
        databaseName: '',
        username: 'fixture',
        password: 'fixture',
        tls: tls,
        timeoutInSeconds: 3,
      ),
      isTrue,
    );
  }

  group(
    'native TLS (${asynchronous ? 'async' : 'sync'})',
    () {
      setUpAll(() async {
        NativeLoader.libraryDirectory = Directory(
          Platform.isWindows ? 'windows/Libraries/bin' : 'linux/Libraries/lib',
        ).absolute.path;
        if (env['MSSQL_TLS_FIXTURE'] != null) {
          fixture =
              jsonDecode(env['MSSQL_TLS_FIXTURE']!) as Map<String, dynamic>;
        } else {
          final server = await Process.start(
            env['MSSQL_TEST_PYTHON'] ??
                (Platform.isWindows ? 'python' : 'python3'),
            ['test/support/tls_server.py'],
          );
          final errors = StringBuffer();
          server.stderr.transform(utf8.decoder).listen(errors.write);
          addTearDown(() async {
            server.stdin.writeln();
            await server.stdin.close();
            expect(await server.exitCode, 0, reason: errors.toString());
          });
          fixture =
              jsonDecode(
                    await server.stdout
                        .transform(utf8.decoder)
                        .transform(const LineSplitter())
                        .first,
                  )
                  as Map<String, dynamic>;
        }
        db = asynchronous ? MssqlConnectionAsync() : MssqlConnection();
      });
      tearDown(() async => await db.close());
      tearDownAll(() async {
        if (asynchronous) await MssqlConnectionAsync.shutdownWorker();
      });

      if (env['MSSQL_TLS_FIXTURE'] != null) {
        if (env['MSSQL_TLS_CONFIG_CHILD'] == '1') {
          test(
            'omitted policy preserves native configuration; explicit policy overrides it',
            () async {
              await expectLater(
                connect('plain', null),
                throwsA(isA<SQLException>()),
              );
              await expectLater(
                connect('full', null),
                throwsA(isA<SQLException>()),
              );
              await connect('full', const TlsRequire());
              expect(db.peerCertificate, isA<TlsCertificate>());
              await connect('plain', const TlsRequest());
              expect(db.peerCertificate, isNull);
            },
          );
          return;
        }
        test(
          'system trust authenticates strict and require through OpenSSL paths',
          () async {
            for (final (server, tls) in <(String, TlsConfig)>[
              (
                'full',
                const TlsRequire(
                  trust: TlsSystemTrust(),
                  certificateHostname: 'localhost',
                ),
              ),
              (
                'strict',
                const TlsStrict(
                  trust: TlsSystemTrust(),
                  certificateHostname: 'localhost',
                ),
              ),
            ]) {
              await connect(server, tls);
              expect(db.peerCertificate, isA<TlsCertificate>());
            }
          },
        );
        return;
      }

      test(
        'default/request/off accept a server without TLS; require rejects it',
        () async {
          for (final policy in <TlsConfig?>[
            null,
            const TlsRequest(),
            const TlsOff(),
          ]) {
            await connect('plain', policy);
            expect(db.peerCertificate, isNull);
          }
          await expectLater(
            connect('plain', const TlsRequire()),
            throwsA(isA<SQLException>()),
          );
          expect(db.isConnected, isFalse);
          expect(db.peerCertificate, isNull);
        },
      );

      test(
        'captures the exact certificate, including login-only TLS, in both APIs',
        () async {
          final pem = File(fixture['pem'] as String).readAsStringSync();
          final expected = base64Decode(
            pem
                .replaceAll('\r', '')
                .split('\n')
                .where((line) => !line.startsWith('-----'))
                .join()
                .trim(),
          );
          for (final (server, policy) in <(String, TlsConfig?)>[
            ('login', null),
            ('login', const TlsRequest()),
            ('full', const TlsRequire()),
            ('full', TlsRequest(trust: TlsPemTrust(fixture['pem'] as String))),
            ('full', TlsRequire(trust: TlsPemTrust(fixture['pem'] as String))),
            ('strict', TlsStrict(trust: TlsPemTrust(fixture['pem'] as String))),
          ]) {
            await connect(server, policy);
            final saved = db.peerCertificate as TlsCertificate;
            expect(saved.der, expected);
            expect(saved.pem.replaceAll('\r', ''), pem.replaceAll('\r', ''));
            await db.close();
            expect(db.peerCertificate, isNull);
            expect(saved.der, expected);
          }
          await connect('plain', null);
          expect(db.peerCertificate, isNull);
        },
      );

      test(
        'wrong CA, hostname and strict plaintext downgrade fail closed',
        () async {
          for (final (server, policy) in <(String, TlsConfig)>[
            (
              'full',
              TlsRequire(trust: TlsPemTrust(fixture['wrongPem'] as String)),
            ),
            (
              'full',
              TlsRequire(
                trust: TlsPemTrust(fixture['pem'] as String),
                certificateHostname: 'wrong.invalid',
              ),
            ),
            (
              'strict',
              TlsStrict(trust: TlsPemTrust(fixture['wrongPem'] as String)),
            ),
            (
              'strict',
              TlsStrict(
                trust: TlsPemTrust(fixture['pem'] as String),
                certificateHostname: 'wrong.invalid',
              ),
            ),
            ('plain', TlsStrict(trust: TlsPemTrust(fixture['pem'] as String))),
          ]) {
            await expectLater(
              connect(server, policy),
              throwsA(isA<SQLException>()),
            );
            expect(db.isConnected, isFalse);
            expect(db.peerCertificate, isNull);
          }
        },
      );

      test(
        'native configuration is preserved or overridden as requested',
        () async {
          final directory = Directory.systemTemp.createTempSync(
            'mssql-tls-config-',
          );
          addTearDown(() => directory.deleteSync(recursive: true));
          final config = File('${directory.path}/freetds.conf')
            ..writeAsStringSync(
              '[global]\nencryption = require\nca file = ${fixture['wrongPem']}\n',
            );
          final result = await Process.run(
            Platform.resolvedExecutable,
            ['test', 'test/tls_native_test.dart', '--reporter', 'expanded'],
            environment: {
              'MSSQL_TLS_FIXTURE': jsonEncode(fixture),
              'MSSQL_TLS_CONFIG_CHILD': '1',
              'FREETDSCONF': config.path,
            },
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        },
      );

      test('system trust uses the configured native trust store', () async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          ['test', 'test/tls_native_test.dart', '--reporter', 'expanded'],
          environment: {
            'MSSQL_TLS_FIXTURE': jsonEncode(fixture),
            'SSL_CERT_FILE': fixture['pem'] as String,
          },
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      });
    },
    skip: enabled
        ? false
        : 'Set MSSQL_TEST_TLS=1; requires Python 3 and OpenSSL.',
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
