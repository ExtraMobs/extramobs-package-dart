import 'cursor_results.dart';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:mssql/mssql_connection.dart';
import 'package:mssql/src/native_logger.dart';
import 'package:test/test.dart';

void main() {
  MssqlLogger.enabled = true;
  NativeLogger.enabled = true;
  final env = Platform.environment;
  final configured = [
    'MSSQL_IP',
    'MSSQL_USER',
    'MSSQL_PASSWORD',
  ].every((key) => env[key]?.isNotEmpty == true);

  test(
    'text and binary round trip through SQL, RPC, a procedure and bulkInsert',
    () async {
      final db = MssqlConnectionAsync.getInstance();
      if (env['MSSQL_NATIVE_DIR'] != null) {
        NativeLoader.libraryDirectory = env['MSSQL_NATIVE_DIR'];
      }
      const value = 'João ação € “aspas” 中文 مرحبا 🙂';
      final longValue = List.filled(5000, 'é').join();

      ResultSnapshot checked(ResultSnapshot response) {
        if (response.error != null) throw SQLException(response.error!);
        return response;
      }

      void expectValue(ResultSnapshot response, String expected) {
        final set = checked(response).resultSets.single;
        expect(set.rows.single.single, expected);
      }

      void expectBinary(ResultSnapshot response, Uint8List? expected) {
        final actual = checked(response).resultSets.single.rows.single.single;
        expect(actual, expected);
        if (expected != null) expect(actual, isA<Uint8List>());
      }

      try {
        expect(
          await db.connect(
            ip: env['MSSQL_IP']!,
            port: env['MSSQL_PORT'] ?? '1433',
            databaseName: env['MSSQL_DB'] ?? 'tempdb',
            autocommit: true,
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
          ),
          isTrue,
        );

        final direct = await runSql(db, "SELECT N'$value' AS [Descrição]");
        expectValue(direct, value);
        expect(direct.resultSets.single.columns, ['Descrição']);

        checked(
          await runSql(
            db,
            'CREATE TABLE #CodecText (Id INT NOT NULL, Texto NVARCHAR(MAX))',
          ),
        );
        checked(
          await runSql(
            db,
            'CREATE PROCEDURE #CodecEcho @texto NVARCHAR(MAX) AS SELECT @texto',
          ),
        );

        for (final text in [value, longValue, 'A\u0000BC', '']) {
          expectValue(await runSql(db, 'SELECT @texto', {'texto': text}), text);
          expectValue(
            await runProcedure(db, '#CodecEcho', {'texto': text}),
            text,
          );
          checked(
            await runSql(
              db,
              'INSERT INTO #CodecText (Id, Texto) VALUES (@id, @texto)',
              {'id': 1, 'texto': text},
            ),
          );
          expectValue(
            await runSql(db, 'SELECT Texto FROM #CodecText WHERE Id = 1'),
            text,
          );
          checked(
            await runSql(
              db,
              'UPDATE #CodecText SET Texto = @texto WHERE Id = @id',
              {'id': 1, 'texto': value},
            ),
          );
          expectValue(
            await runSql(db, 'SELECT Texto FROM #CodecText WHERE Id = 1'),
            value,
          );
          checked(await runSql(db, 'DELETE FROM #CodecText'));

          await runBulk(db, '#CodecText', [
            {'Id': 2, 'Texto': text},
          ]);
          expectValue(
            await runSql(db, 'SELECT Texto FROM #CodecText WHERE Id = 2'),
            text,
          );
          checked(await runSql(db, 'DELETE FROM #CodecText'));
        }

        await runSql(
          db,
          'CREATE PROCEDURE #EmptyValues @a nvarchar(max), @b varbinary(max), @c nvarchar(max) AS SELECT @a, @b, @c',
        );
        final emptyParams = {'a': '', 'b': Uint8List(0), 'c': null};
        expect(
          (await runSql(
            db,
            'SELECT @a, @b, @c',
            emptyParams,
          )).resultSets.single.rows.single,
          ['', Uint8List(0), null],
        );
        expect(
          (await runProcedure(
            db,
            '#EmptyValues',
            emptyParams,
          )).resultSets.single.rows.single,
          ['', Uint8List(0), null],
        );
        await runSql(
          db,
          'CREATE TABLE #CodecBytes (value varbinary(max) NULL)',
        );
        await runSql(
          db,
          'CREATE PROCEDURE #BinaryEcho @value varbinary(max) AS SELECT @value',
        );
        expectBinary(
          await runSql(db, 'SELECT CAST(0x00FF80 AS varbinary(max))'),
          Uint8List.fromList([0, 255, 128]),
        );
        for (final bytes in [
          null,
          Uint8List(0),
          Uint8List.fromList(List.generate(256, (i) => i)),
          Uint8List.fromList(List.generate(16385, (i) => i % 256)),
        ]) {
          expectBinary(
            await runSql(db, 'SELECT CAST(? AS varbinary(max))', [bytes]),
            bytes,
          );
          expectBinary(
            await runSql(db, 'SELECT CAST(@value AS varbinary(max))', {
              'value': bytes,
            }),
            bytes,
          );
          expectBinary(
            await runProcedure(db, '#BinaryEcho', {'value': bytes}),
            bytes,
          );
          await runBulk(db, '#CodecBytes', [
            {'value': bytes},
          ]);
          final read = await runSql(db, 'SELECT value FROM #CodecBytes');
          expectBinary(read, bytes);
          // Returned Uint8List values can be bound again without conversion.
          expectBinary(
            await runSql(
              db,
              'SELECT CAST(? AS varbinary(max))',
              read.resultSets.single.rows.single,
            ),
            bytes,
          );
          await runSql(db, 'DELETE FROM #CodecBytes');
        }

        final money = await runSql(
          db,
          "SELECT CAST(1 AS money), CAST(-0.0001 AS money), CAST(12345678901234567890.123456789012345678 AS decimal(38,18))",
        );
        expect(money.resultSets.single.rows.single, [
          '1.0000',
          '-0.0001',
          '12345678901234567890.123456789012345678',
        ]);

        await runSql(
          db,
          'CREATE PROCEDURE #DateEcho @v datetimeoffset(7) AS SELECT CONVERT(datetime,@v), CONVERT(datetime2(7),@v), @v',
        );
        final instant = DateTime.utc(2024, 2, 29, 12, 34, 56, 123, 456);
        for (final format in ['mdy', 'dmy', 'ymd', 'ydm', 'myd', 'dym']) {
          await runSql(db, 'SET DATEFORMAT $format');
          for (final response in [
            await runSql(
              db,
              'SELECT CONVERT(datetime,@v), CONVERT(datetime2(7),@v), @v',
              {'v': instant},
            ),
            await runProcedure(db, '#DateEcho', {'v': instant}),
          ]) {
            final row = response.resultSets.single.rows.single;
            expect(row[0], '2024-02-29T12:34:56.123333');
            expect(row[1], '2024-02-29T12:34:56.1234560');
            expect(row[2], '2024-02-29T12:34:56.1234560+00:00');
          }
        }

        await runSql(db, 'CREATE TABLE #Tx (id int)');
        final entered = Completer<void>();
        final release = Completer<void>();
        final transaction = db.transaction((tx) async {
          await runSql(tx, 'INSERT INTO #Tx VALUES (1)');
          entered.complete();
          await release.future;
        });
        await entered.future;
        var outsideFinished = false;
        final outside = runSql(db, 'SELECT COUNT(*) FROM #Tx').then((r) {
          outsideFinished = true;
          return r;
        });
        try {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(outsideFinished, isFalse);
        } finally {
          release.complete();
        }
        await transaction;
        expect((await outside).resultSets.single.rows.single.single, 1);
        await expectLater(
          db.transaction((tx) async {
            await runSql(tx, 'INSERT INTO #Tx VALUES (2)');
            throw StateError('Application rollback');
          }),
          throwsStateError,
        );
        expect(
          (await runSql(
            db,
            'SELECT COUNT(*) FROM #Tx',
          )).resultSets.single.rows.single.single,
          1,
        );

        // Certificate rejection is tested against the same configured test server.
        final badIdentity = MssqlConnectionAsync();
        try {
          await expectLater(
            badIdentity.connect(
              ip: env['MSSQL_IP']!,
              port: env['MSSQL_PORT'] ?? '1433',
              databaseName: env['MSSQL_DB'] ?? 'tempdb',
              username: env['MSSQL_USER']!,
              password: env['MSSQL_PASSWORD']!,
              tls: TlsRequire(
                trust:
                    env['MSSQL_CA_FILE'] == null ||
                        env['MSSQL_CA_FILE'] == 'system'
                    ? const TlsSystemTrust()
                    : TlsPemTrust(env['MSSQL_CA_FILE']!),
                certificateHostname:
                    'wrong-certificate.sql-server-wrapper.invalid',
              ),
            ),
            throwsA(isA<SQLException>()),
          );
          expect(badIdentity.isConnected, isFalse);
        } finally {
          await badIdentity.disconnect();
        }
      } finally {
        // Both objects are local to this session and disappear on disconnect.
        await db.disconnect();
      }
    },
    skip: configured
        ? false
        : 'Set MSSQL_IP, MSSQL_USER and MSSQL_PASSWORD for a test server.',
  );
}
