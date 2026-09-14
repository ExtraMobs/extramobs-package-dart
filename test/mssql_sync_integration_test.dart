import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  final configured = [
    'MSSQL_IP',
    'MSSQL_USER',
    'MSSQL_PASSWORD',
  ].every((key) => env[key]?.isNotEmpty == true);
  group('synchronous API', () {
    late MssqlConnection db;
    setUp(() {
      NativeLoader.libraryDirectory = env['MSSQL_NATIVE_DIR'];
      db = MssqlConnection();
      final bool connected = db.connect(
        ip: env['MSSQL_IP']!,
        port: env['MSSQL_PORT'] ?? '1433',
        databaseName: env['MSSQL_DB'] ?? 'tempdb',
        username: env['MSSQL_USER']!,
        password: env['MSSQL_PASSWORD']!,
        tls: TlsRequire(
          trust: env['MSSQL_TRUST_SERVER_CERTIFICATE'] == 'true'
              ? null
              : env['MSSQL_CA_FILE'] == null || env['MSSQL_CA_FILE'] == 'system'
              ? const TlsSystemTrust()
              : TlsPemTrust(env['MSSQL_CA_FILE']!),
          certificateHostname: env['MSSQL_CERTIFICATE_HOSTNAME'],
        ),
        autocommit: true,
      );
      expect(connected, isTrue);
      addTearDown(db.close);
    });

    dynamic scalar(String sql, [Object? params]) {
      final MssqlCursorSync cursor = db.execute(sql, params);
      try {
        do {
          if (cursor.columns != null) return cursor.fetchval();
        } while (cursor.nextset());
        return null;
      } finally {
        cursor.close();
      }
    }

    test('returns direct values and preserves RPC types', () {
      final cursor = db.execute(
        'SELECT @texto AS texto, @bytes AS bytes, @n AS n',
        {
          'texto': "João D'Ávila",
          'bytes': Uint8List.fromList([0, 128, 255]),
          'n': null,
        },
      );
      try {
        final List<SqlRow> rows = cursor.fetchall();
        expect(rows.single['texto'], "João D'Ávila");
        expect(rows.single['bytes'], [0, 128, 255]);
        expect(
          () => (rows.single['bytes'] as Uint8List)[0] = 1,
          throwsUnsupportedError,
        );
        expect(rows.single['n'], isNull);
        expect(cursor.nextset(), isFalse);
        cursor.execute('SELECT CAST(? AS datetime2) AS data', [
          DateTime(2026, 9, 14),
        ]);
        expect(cursor.fetchval().toString(), startsWith('2026-09-14'));
        cursor.executeProcedure('sys.sp_executesql', {'stmt': 'SELECT 8 AS n'});
        expect(cursor.fetchval(), 8);
      } finally {
        cursor.close();
      }
    });

    test('incremental iteration, metadata, multiple sets and cancellation', () {
      final cursor = db.execute(
        'SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3; SELECT 4 AS other',
      );
      try {
        expect(cursor.columns, ['n']);
        for (final row in cursor) {
          expect(row[0], 1);
          break;
        }
        expect(cursor.isClosed, isFalse);
        cursor.arraysize = 2;
        expect(cursor.fetchmany().map((row) => row[0]), [2, 3]);
        expect(cursor.nextset(), isTrue);
        expect(cursor.columns, ['other']);
        expect(cursor.fetchval(), 4);
        cursor.cancel();
        cursor.execute('SELECT 5 AS empty WHERE 1=0');
        expect(cursor.columns, ['empty']);
        expect(cursor.fetchall(), isEmpty);
        expect(() => cursor.fetchmany(-1), throwsArgumentError);
      } finally {
        cursor.close();
      }
      expect(cursor.isClosed, isTrue);
      expect(() => cursor.fetchone(), throwsStateError);
    });

    test(
      'manual and scoped transactions preserve rollback and cursor scope',
      () {
        scalar('CREATE TABLE #SyncTx (id int)');
        db.setAutocommit(false);
        scalar('INSERT INTO #SyncTx VALUES (1)');
        db.rollback();
        expect(scalar('SELECT COUNT(*) FROM #SyncTx'), 0);
        scalar('INSERT INTO #SyncTx VALUES (2)');
        db.commit();
        db.setAutocommit(true);
        late MssqlCursorSync escaped;
        final int result = db.transaction((tx) {
          escaped = tx.execute('INSERT INTO #SyncTx VALUES (3)');
          expect(tx.disconnect, throwsStateError);
          expect(escaped.commit, throwsStateError);
          expect(() => tx.transaction((_) => 0), throwsStateError);
          return 42;
        });
        expect(result, 42);
        expect(escaped.isClosed, isTrue);
        expect(
          () => db.transaction<void>((tx) {
            tx.execute('INSERT INTO #SyncTx VALUES (4)').close();
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        expect(() => db.transaction((_) => Future.value(1)), throwsStateError);
        expect(
          () => db.transaction(
            (_) => Future<int>.error(StateError('async callback')),
          ),
          throwsStateError,
        );
        expect(scalar('SELECT COUNT(*) FROM #SyncTx'), 2);
      },
    );

    test('executemany and bulk reuse native execution and autocommit', () {
      scalar('CREATE TABLE #SyncMany (id int, nome nvarchar(50) NULL)');
      final cursor = db.cursor();
      try {
        Iterable<Object> parameters() sync* {
          yield [1, 'ação'];
          yield [2, ''];
        }

        cursor.executemany('INSERT INTO #SyncMany VALUES (?, ?)', parameters());
        expect(cursor.rowcount, -1);
        expect(
          cursor.bulkInsert('#SyncMany', [
            {'id': 3, 'nome': null},
          ]),
          1,
        );
        expect(scalar('SELECT COUNT(*) FROM #SyncMany'), 3);
        expect(scalar('SELECT @@TRANCOUNT'), 0);
      } finally {
        cursor.close();
      }
    });

    test('native SQL errors close the session and all cursors', () {
      final first = db.cursor(), second = db.cursor();
      expect(
        () => first.execute("THROW 50001, 'sync failure', 1;"),
        throwsA(isA<SQLException>()),
      );
      expect(db.isConnected, isFalse);
      expect(first.isClosed, isTrue);
      expect(second.isClosed, isTrue);
    });

    test('synchronous WAITFOR blocks caller until it returns', () async {
      var eventRan = false;
      Timer.run(() => eventRan = true);
      final watch = Stopwatch()..start();
      expect(scalar("WAITFOR DELAY '00:00:01'; SELECT 1"), 1);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(900));
      expect(eventRan, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(eventRan, isTrue);
    });

    test(
      'another native owner is rejected without breaking the sync session',
      () async {
        final other = MssqlConnectionAsync();
        try {
          await expectLater(
            other.connect(
              ip: env['MSSQL_IP']!,
              port: env['MSSQL_PORT'] ?? '1433',
              databaseName: env['MSSQL_DB'] ?? 'tempdb',
              username: env['MSSQL_USER']!,
              password: env['MSSQL_PASSWORD']!,
              tls: const TlsRequire(),
            ),
            throwsA(isA<SQLException>()),
          );
          expect(scalar('SELECT 1'), 1);
        } finally {
          await other.close();
          await MssqlConnectionAsync.shutdownWorker();
        }
      },
    );
  }, skip: configured ? false : 'Set MSSQL_IP, MSSQL_USER and MSSQL_PASSWORD');
}
