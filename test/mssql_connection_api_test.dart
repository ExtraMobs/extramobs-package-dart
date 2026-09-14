import 'dart:typed_data';

import 'package:mssql/mssql_connection.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  group('MssqlConnectionAsync API', () {
    final harness = TempDbHarness();
    late MssqlConnectionAsync conn;

    setUpAll(() async {
      await harness.init();
      conn = harness.client;
      expect(conn.isConnected, isTrue);
    });

    tearDownAll(harness.dispose);

    test('cursor execution handles basic DDL/DML', () async {
      await runSql(
        conn,
        'CREATE TABLE dbo.T (id INT PRIMARY KEY, name NVARCHAR(50))',
      );
      await runSql(
        conn,
        "INSERT INTO dbo.T (id, name) VALUES (1, N'Alice'), (2, N'Bob')",
      );
      final rows = parseRows(
        await runSql(conn, 'SELECT COUNT(*) AS cnt FROM dbo.T'),
      );
      expect(rows.first['cnt'], 2);
    });

    test('cursor execution handles parameterized reads and writes', () async {
      await runSql(
        conn,
        'CREATE TABLE dbo.P (id INT PRIMARY KEY, val VARBINARY(MAX))',
      );
      final ok = await runSql(
        conn,
        'INSERT INTO dbo.P (id, val) VALUES (@id, @val)',
        {
          '@id': 10,
          '@val': Uint8List.fromList([1, 2, 3, 4]),
        },
      );
      expect(affectedCount(ok) >= 1, true);

      final out = await runSql(
        conn,
        'SELECT id, DATALENGTH(val) AS len FROM dbo.P WHERE id=@id',
        {'@id': 10},
      );
      final rows = parseRows(out);
      expect(rows.length, 1);
      expect(rows.first['len'], 4);
    });

    test('bulkInsert inserts multiple rows', () async {
      await runSql(
        conn,
        'CREATE TABLE dbo.[Bulk] (id INT NOT NULL, flag BIT NOT NULL, note NVARCHAR(100) NULL)',
      );
      final rows = [
        {'id': 1, 'flag': true, 'note': 'a'},
        {'id': 2, 'flag': false, 'note': 'b'},
        {'id': 3, 'flag': true, 'note': 'c'},
      ];
      final inserted = await runBulk(conn, 'dbo.[Bulk]', rows, batchSize: 2);
      expect(inserted, rows.length);
      final out = parseRows(
        await runSql(conn, 'SELECT COUNT(*) AS cnt FROM dbo.[Bulk]'),
      );
      expect(out.first['cnt'], rows.length);
    });

    test('transaction helpers begin/commit', () async {
      await runSql(conn, 'CREATE TABLE dbo.Tx (id INT PRIMARY KEY)');
      await conn.transaction((tx) async {
        await runSql(tx, 'INSERT INTO dbo.Tx (id) VALUES (1)');
      });
      final rows = parseRows(
        await runSql(conn, 'SELECT COUNT(*) AS cnt FROM dbo.Tx WHERE id=1'),
      );
      expect(rows.first['cnt'], 1);
    });

    test('numeric binary BCP and transactional bulk preserve rollback', () async {
      await runSql(
        conn,
        'CREATE TABLE dbo.NumericBulk (id int NOT NULL, bytes varbinary(8) NOT NULL)',
      );
      final values = [
        {
          'id': 1,
          'bytes': Uint8List.fromList([0, 255]),
        },
        {
          'id': 2,
          'bytes': Uint8List.fromList([128, 1]),
        },
      ];
      expect(await runBulk(conn, 'dbo.NumericBulk', values, batchSize: 1), 2);
      final rows = parseRows(
        await runSql(conn, 'SELECT * FROM dbo.NumericBulk ORDER BY id'),
      );
      expect(
        rows.map((row) => row['bytes']),
        values.map((row) => row['bytes']),
      );
      expect(rows.map((row) => row['bytes']), everyElement(isA<Uint8List>()));
      await conn.setAutocommit(false);
      expect(await runBulk(conn, 'dbo.NumericBulk', values), 2);
      await conn.rollback();
      await conn.setAutocommit(true);
      await expectLater(
        conn.transaction((tx) async {
          expect(await runBulk(tx, 'dbo.NumericBulk', values), 2);
          throw StateError('Rollback numeric bulk');
        }),
        throwsStateError,
      );
      expect(
        parseRows(
          await runSql(conn, 'SELECT COUNT(*) AS n FROM dbo.NumericBulk'),
        ).single['n'],
        2,
      );
    });

    test('transaction helpers begin/rollback', () async {
      await expectLater(
        conn.transaction((tx) async {
          await runSql(tx, 'INSERT INTO dbo.Tx (id) VALUES (2)');
          throw StateError('Rollback requested by application');
        }),
        throwsStateError,
      );
      final rows = parseRows(
        await runSql(conn, 'SELECT COUNT(*) AS cnt FROM dbo.Tx WHERE id=2'),
      );
      expect(rows.first['cnt'], 0);
    });

    test('disconnect returns to not connected state', () async {
      final ok = await conn.disconnect();
      expect(ok, isTrue);
      expect(conn.isConnected, isFalse);
    });
  });
}
