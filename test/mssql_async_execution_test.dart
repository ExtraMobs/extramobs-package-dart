import 'dart:async';
import 'dart:io';

import 'package:extramobs/mssql.dart';
import 'package:test/test.dart';

import 'cursor_results.dart';

void main() {
  final env = Platform.environment;
  final configured = [
    'MSSQL_IP',
    'MSSQL_USER',
    'MSSQL_PASSWORD',
  ].every((key) => env[key]?.isNotEmpty == true);
  group('async execution', () {
    late MssqlConnectionAsync db;
    setUp(() async {
      NativeLoader.libraryDirectory = env['MSSQL_NATIVE_DIR'];
      db = MssqlConnectionAsync();
      expect(
        await db.connect(
          ip: env['MSSQL_IP']!,
          port: env['MSSQL_PORT'] ?? '1433',
          databaseName: env['MSSQL_DB'] ?? 'tempdb',
          username: env['MSSQL_USER']!,
          password: env['MSSQL_PASSWORD']!,
          tls: TlsRequire(
            trust: env['MSSQL_TRUST_SERVER_CERTIFICATE'] == 'true'
                ? null
                : env['MSSQL_CA_FILE'] == null ||
                      env['MSSQL_CA_FILE'] == 'system'
                ? const TlsSystemTrust()
                : TlsPemTrust(env['MSSQL_CA_FILE']!),
            certificateHostname: env['MSSQL_CERTIFICATE_HOSTNAME'],
          ),
          queryTimeoutSeconds: 2,
          autocommit: true,
        ),
        isTrue,
      );
      addTearDown(db.close);
    });
    test('WAITFOR permits timers while native execution waits', () async {
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 25),
        (_) => ticks++,
      );
      try {
        final result = await runSql(db, "WAITFOR DELAY '00:00:01'; SELECT 1");
        expect(result.resultSets.single.rows.single.single, 1);
        expect(ticks, greaterThan(10));
      } finally {
        timer.cancel();
      }
    });
    test(
      'timeout reaches caller and invalidates active and idle cursors',
      () async {
        final cursor = db.cursor(), idle = db.cursor();
        final watch = Stopwatch()..start();
        await expectLater(
          cursor.execute("WAITFOR DELAY '00:00:05'; SELECT 1"),
          throwsA(isA<SQLException>()),
        );
        expect(watch.elapsed.inSeconds, lessThan(5));
        expect(db.isConnected, isFalse);
        expect(cursor.isClosed, isTrue);
        expect(idle.isClosed, isTrue);
        await idle.done;
      },
    );
    test('shutdown releases pending callers and native sessions', () async {
      final cursor = db.cursor();
      final pending = cursor.execute("WAITFOR DELAY '00:00:01'; SELECT 1");
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await MssqlConnectionAsync.shutdownWorker();
      await pending;
      expect(db.isConnected, isFalse);
      expect(cursor.isClosed, isTrue);
      await cursor.done;
      await expectLater(db.execute('SELECT 1'), throwsStateError);
      await MssqlConnectionAsync.shutdownWorker();
    });
  }, skip: configured ? false : 'Set MSSQL_IP, MSSQL_USER and MSSQL_PASSWORD');
}
