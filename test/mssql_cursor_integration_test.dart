import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:mssql/mssql.dart';
import 'package:test/test.dart';
import 'cursor_results.dart';

void main({Map<String, String>? configuration, bool tablesOnly = false}) {
  final env = configuration ?? Platform.environment;
  final configured = [
    'MSSQL_IP',
    'MSSQL_USER',
    'MSSQL_PASSWORD',
  ].every((key) => env[key]?.isNotEmpty == true);
  late MssqlConnectionAsync db;

  Future<MssqlConnectionAsync> connect({bool autocommit = false}) async {
    if (env['MSSQL_NATIVE_DIR'] != null) {
      NativeLoader.libraryDirectory = env['MSSQL_NATIVE_DIR'];
    }
    final connection = MssqlConnectionAsync();
    expect(
      await connection.connect(
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
        autocommit: autocommit,
      ),
      isTrue,
    );
    return connection;
  }

  Future<dynamic> scalar(String sql) async =>
      (await runSql(db, sql)).resultSets.single.rows.single.single;

  group(
    'native cursor',
    () {
      setUp(() async {
        db = await connect();
      });
      tearDown(() async {
        await db.close();
      });

      test(
        'manual transactions span cursors and reject control with unread results',
        () async {
          expect(db.autocommit, isFalse);
          await runSql(db, 'CREATE TABLE #Manual (id int)');
          await db.commit();
          final first = db.cursor();
          final second = db.cursor();
          try {
            await first.execute('INSERT INTO #Manual VALUES (?)', [1]);
            await second.execute('INSERT INTO #Manual VALUES (?)', [2]);
            expect(await scalar('SELECT @@TRANCOUNT'), 1);
            await second.commit();
            expect(await scalar('SELECT @@TRANCOUNT'), 0);
            await first.execute('INSERT INTO #Manual VALUES (3)');
            await second.bulkInsert('#Manual', [
              {'id': 4},
              {'id': 5},
            ]);
            await first.rollback();
            expect(await scalar('SELECT COUNT(*) FROM #Manual'), 2);
            await first.execute('SELECT id FROM #Manual');
            await expectLater(db.commit(), throwsStateError);
            await expectLater(db.rollback(), throwsStateError);
            await expectLater(db.setAutocommit(true), throwsStateError);
            expect(db.autocommit, isFalse);
            expect(db.isConnected, isTrue);
            await first.cancel();
            await db.rollback();
            await expectLater(db.transaction((tx) async {}), throwsStateError);
            await db.commit();
            await db.rollback();
          } finally {
            await first.close();
            await second.close();
          }
        },
      );

      test(
        'enabling autocommit commits pending work and disabling restores rollback',
        () async {
          await runSql(db, 'CREATE TABLE #Modes (id int)');
          await runSql(db, 'INSERT INTO #Modes VALUES (1)');
          await db.setAutocommit(true);
          expect(db.autocommit, isTrue);
          await db.rollback();
          expect(await scalar('SELECT COUNT(*) FROM #Modes'), 1);
          await runSql(db, 'INSERT INTO #Modes VALUES (2)');
          await db.rollback();
          expect(await scalar('SELECT COUNT(*) FROM #Modes'), 2);
          await db.setAutocommit(false);
          await runSql(db, 'INSERT INTO #Modes VALUES (3)');
          await db.setAutocommit(false);
          await db.rollback();
          expect(await scalar('SELECT COUNT(*) FROM #Modes'), 2);
        },
      );

      test(
        'connection close rolls back; committed rows remain visible to another session',
        () async {
          final observer = await connect(autocommit: true);
          final table =
              '##CursorClose_${DateTime.now().microsecondsSinceEpoch}';
          try {
            await runSql(observer, 'CREATE TABLE $table (id int)');
            final writer = db.cursor();
            await writer.execute('INSERT INTO $table VALUES (1)');
            await writer.commit();
            expect(
              (await runSql(
                observer,
                'SELECT COUNT(*) FROM $table',
              )).resultSets.single.rows.single.single,
              1,
            );
            await writer.bulkInsert(table, [
              {'id': 2},
              {'id': 3},
            ]);
            await writer.close();
            expect(await scalar('SELECT COUNT(*) FROM $table'), 3);
            await db.close();
            expect(
              (await runSql(
                observer,
                'SELECT COUNT(*) FROM $table',
              )).resultSets.single.rows.single.single,
              1,
            );
          } finally {
            await db.close();
            try {
              if (observer.isConnected) {
                await runSql(observer, 'DROP TABLE IF EXISTS $table');
              }
            } finally {
              await observer.close();
            }
          }
        },
      );

      test('mixed fetches, positional RPC and native result navigation', () async {
        final cursor = db.cursor();
        try {
          expect(
            await cursor.execute(
              'SELECT v.id FROM (VALUES (1),(2),(3),(4),(5)) v(id) ORDER BY v.id',
            ),
            same(cursor),
          );
          expect(cursor.columns, ['id']);
          expect(await cursor.fetchval(), 1);
          cursor.arraysize = 2;
          expect((await cursor.fetchmany()).map((r) => r[0]), [2, 3]);
          expect((await cursor.fetchall()).map((r) => r[0]), [4, 5]);
          expect(await cursor.fetchone(), isNull);
          expect(await cursor.nextset(), isFalse);

          const value = 'a\u00e7\u00e3o \u4e2d\u6587\u0000';
          await cursor.execute(
            "SELECT '?' AS [q?], ? AS texto, ? AS vazio, ? AS nulo /* ? */",
            [value, '', null],
          );
          final row = (await cursor.fetchone())!;
          expect(row.values, ['?', value, '', null]);
          await cursor.execute(
            'SELECT 10 AS a; SELECT 20 AS b WHERE 1=0; SELECT 30 AS c',
          );
          expect(await cursor.nextset(), isTrue);
          expect(cursor.columns, ['b']);
          expect(await cursor.fetchone(), isNull);
          expect(cursor.columns, ['b']);
          expect(await cursor.nextset(), isTrue);
          expect(cursor.columns, ['c']);
          expect(await cursor.fetchval(), 30);
          expect(await cursor.nextset(), isFalse);
          expect(row.values, ['?', value, '', null]);

          if (!tablesOnly) {
            await cursor.execute(
              'CREATE PROCEDURE #CursorEcho @v nvarchar(max) AS SELECT @v AS texto; SELECT 2 AS n',
            );
            await cursor.execute('EXEC #CursorEcho @v=?', [value]);
            expect(await cursor.fetchval(), value);
            expect(await cursor.nextset(), isTrue);
            expect(await cursor.fetchval(), 2);
          }
        } finally {
          await cursor.close();
        }
      });

      test(
        'idle cursors coexist; unread results reject interleaving; EOF permits reuse',
        () async {
          final first = db.cursor();
          final second = db.cursor();
          try {
            await first.execute('SELECT v.id FROM (VALUES (1),(2),(3)) v(id)');
            await expectLater(second.execute('SELECT 42'), throwsStateError);
            expect((await first.fetchall()).length, 3);
            await second.execute('SELECT 42');
            expect(await first.fetchone(), isNull);
            expect(await first.nextset(), isFalse);
            expect(await second.fetchval(), 42);
            await second.cancel();
            expect(second.isClosed, isFalse);
            await first.execute('SELECT 43');
            expect(await first.fetchval(), 43);
          } finally {
            await first.close();
            await second.close();
          }
        },
      );

      test(
        'direct cursor loop supports pause, break and subsequent fetches',
        () async {
          final cursor = await db.execute(
            'SELECT v.id FROM (VALUES (1),(2),(3)) v(id) ORDER BY v.id',
          );
          try {
            final values = <int>[];
            await for (final row in cursor) {
              values.add(row[0] as int);
              await Future<void>.delayed(const Duration(milliseconds: 10));
              if (values.length == 2) break;
            }
            expect(values, [1, 2]);
            expect(cursor.isClosed, isFalse);
            expect(await cursor.fetchval(), 3);
            expect(await cursor.fetchval(), isNull);
            await cursor.execute(
              'SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 ORDER BY 1',
            );
            await cursor.skipRows(2);
            expect(await cursor.fetchval(), 3);
          } finally {
            await cursor.close();
          }
        },
      );

      test(
        'executemany handles a generator and mixed types through RPC',
        () async {
          final cursor = db.cursor();
          try {
            await cursor.execute(
              'CREATE TABLE #CursorMany (id int, texto nvarchar(max), instante datetimeoffset(7) NULL, bytes varbinary(max))',
            );
            final instant = DateTime.utc(2024, 2, 29, 12, 34, 56, 123, 456);
            Iterable<List<Object?>> rows() sync* {
              yield [
                1,
                'a\u00e7\u00e3o\u0000',
                instant,
                Uint8List.fromList([0, 255]),
              ];
              yield [2, '', null, Uint8List(0)];
            }

            await cursor.executemany(
              'INSERT INTO #CursorMany VALUES (?, ?, ?, ?)',
              rows(),
            );
            expect(cursor.rowcount, -1);
            await cursor.execute('SELECT * FROM #CursorMany ORDER BY id');
            final fetched = await cursor.fetchall();
            expect(fetched.first.values, [
              1,
              'a\u00e7\u00e3o\u0000',
              '2024-02-29T12:34:56.1234560+00:00',
              Uint8List.fromList([0, 255]),
            ]);
            expect(fetched.first['bytes'], isA<Uint8List>());
            expect(fetched.last['bytes'], isA<Uint8List>());
            expect(fetched.last.values, [2, '', null, Uint8List(0)]);
            await cursor.execute('UPDATE #CursorMany SET texto=? WHERE id=?', [
              'updated',
              2,
            ]);
            expect(cursor.rowcount, 1);
            await cursor.execute('DELETE FROM #CursorMany WHERE id=?', [2]);
            expect(cursor.rowcount, 1);
          } finally {
            await cursor.close();
          }
        },
      );

      test(
        'large Unicode and binary values survive RPC and temporary bulk',
        () async {
          await db.setAutocommit(true);
          final cursor = db.cursor();
          try {
            await cursor.execute(
              'CREATE TABLE #CursorCodec (texto nvarchar(max) NULL, bytes varbinary(max) NULL)',
            );
            final text =
                '${List.filled(5000, 'é').join()} João 中文 مرحبا 🙂\u0000';
            final bytes = Uint8List.fromList(
              List.generate(16385, (i) => i % 256),
            );
            for (final values in <List<Object?>>[
              [text, bytes],
              ['', Uint8List(0)],
              [null, null],
            ]) {
              await cursor.execute(
                'INSERT INTO #CursorCodec VALUES (?, CAST(? AS varbinary(max)))',
                values,
              );
              await cursor.execute('SELECT texto, bytes FROM #CursorCodec');
              expect((await cursor.fetchone())!.values, values);
              await cursor.execute('DELETE FROM #CursorCodec');
              await cursor.bulkInsert('#CursorCodec', [
                {'texto': values[0], 'bytes': values[1]},
              ]);
              await cursor.execute('SELECT texto, bytes FROM #CursorCodec');
              expect((await cursor.fetchone())!.values, values);
              await cursor.execute('DELETE FROM #CursorCodec');
            }
            // Exercise procedure RPC without creating a stored procedure.
            await cursor.executeProcedure('sys.sp_executesql', {
              'stmt': 'SELECT @value',
              'params': '@value varbinary(max)',
              'value': bytes,
            });
            expect(await cursor.fetchval(), bytes);
            final instant = DateTime.utc(2024, 2, 29, 12, 34, 56, 123, 456);
            for (final format in ['mdy', 'dmy', 'ymd', 'ydm', 'myd', 'dym']) {
              await cursor.execute('SET DATEFORMAT $format');
              await cursor.execute(
                'SELECT CONVERT(datetime2(7), @v), @v, CAST(-0.0001 AS money), '
                'CAST(12345678901234567890.123456789012345678 AS decimal(38,18))',
                {'v': instant},
              );
              expect((await cursor.fetchone())!.values, [
                '2024-02-29T12:34:56.1234560',
                '2024-02-29T12:34:56.1234560+00:00',
                '-0.0001',
                '12345678901234567890.123456789012345678',
              ]);
            }
          } finally {
            await cursor.close();
          }
        },
      );

      test('transaction cursors close before commit and rollback', () async {
        await db.setAutocommit(true);
        await runSql(db, 'CREATE TABLE #CursorTx (id int)');
        late MssqlCursor escaped;
        await db.transaction((tx) async {
          escaped = tx.cursor();
          await escaped.execute('INSERT INTO #CursorTx VALUES (?)', [1]);
          await escaped.execute('SELECT id FROM #CursorTx');
          expect(await escaped.fetchval(), 1);
        });
        expect(escaped.isClosed, isTrue);
        await expectLater(escaped.fetchone(), throwsStateError);
        expect(
          (await runSql(
            db,
            'SELECT COUNT(*) FROM #CursorTx',
          )).resultSets.single.rows.single.single,
          1,
        );
        await expectLater(
          db.transaction((tx) async {
            final cursor = tx.cursor();
            await cursor.executemany('INSERT INTO #CursorTx VALUES (?)', [
              [2],
              [3],
            ]);
            throw StateError('Rollback');
          }),
          throwsStateError,
        );
        expect(
          (await runSql(
            db,
            'SELECT COUNT(*) FROM #CursorTx',
          )).resultSets.single.rows.single.single,
          1,
        );
      });

      test(
        'external operations wait for transaction; escaped cursor use is rejected',
        () async {
          await db.setAutocommit(true);
          final entered = Completer<MssqlCursor>();
          final release = Completer<void>();
          final transaction = db.transaction((tx) async {
            final cursor = tx.cursor();
            await expectLater(cursor.commit(), throwsStateError);
            await expectLater(cursor.rollback(), throwsStateError);
            await expectLater(tx.commit(), throwsStateError);
            await expectLater(tx.setAutocommit(false), throwsStateError);
            await cursor.execute('SELECT 1');
            entered.complete(cursor);
            await release.future;
          });
          final outside = db.cursor();
          late Future<MssqlCursor> queued;
          var executed = false;
          try {
            final escaped = await entered.future;
            await expectLater(escaped.fetchone(), throwsStateError);
            await expectLater(escaped.commit(), throwsStateError);
            await expectLater(escaped.rollback(), throwsStateError);
            queued = outside.execute('SELECT 42').then((c) {
              executed = true;
              return c;
            });
            await Future<void>.delayed(const Duration(milliseconds: 20));
            expect(executed, isFalse);
          } finally {
            release.complete();
          }
          await transaction;
          await queued;
          try {
            expect(await outside.fetchval(), 42);
          } finally {
            await outside.close();
          }
        },
      );

      test('DML counts and empty metadata survive native lookahead', () async {
        final cursor = db.cursor();
        try {
          await cursor.execute('CREATE TABLE #CursorCounts (id int)');
          await cursor.execute(
            'INSERT INTO #CursorCounts VALUES (1),(2); SELECT id FROM #CursorCounts ORDER BY id',
          );
          expect(cursor.description, isNull);
          expect(cursor.rowcount, 2);
          await expectLater(cursor.fetchall(), throwsStateError);
          expect(await cursor.nextset(), isTrue);
          expect((await cursor.fetchall()).map((r) => r[0]), [1, 2]);
          expect(await cursor.nextset(), isFalse);
        } finally {
          await cursor.close();
        }
      });

      test(
        'connection close invalidates active and idle cursors without waiting for fetches',
        () async {
          final active = await db.execute('SELECT 1 UNION ALL SELECT 2');
          final idle = db.cursor();
          await db.close();
          expect(active.isClosed, isTrue);
          expect(idle.isClosed, isTrue);
          await expectLater(active.fetchone(), throwsStateError);
          await expectLater(idle.execute('SELECT 3'), throwsStateError);
        },
      );

      test('SQL failure invalidates all cursors and the session', () async {
        final cursor = db.cursor();
        final idle = db.cursor();
        try {
          await expectLater(() async {
            await cursor.execute(
              "SELECT 1 AS n; RAISERROR('cursor integration failure',16,1)",
            );
            await cursor.fetchall();
            while (await cursor.nextset()) {
              if (cursor.description != null) await cursor.fetchall();
            }
          }(), throwsA(isA<SQLException>()));
          expect(db.isConnected, isFalse);
          expect(cursor.isClosed, isTrue);
          expect(idle.isClosed, isTrue);
        } finally {
          await cursor.close();
          await idle.close();
        }
      });
    },
    skip: configured
        ? false
        : 'Set MSSQL_IP, MSSQL_USER and MSSQL_PASSWORD for a test server.',
  );
}
