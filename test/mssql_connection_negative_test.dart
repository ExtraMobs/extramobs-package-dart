import 'dart:io';

import 'package:mssql/mssql_connection.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

// Set RUN_DB_TESTS=1 in environment to enable tests that require a live DB + native libs.

void main() {
  final runDbTests = Platform.environment['RUN_DB_TESTS'] == '1';
  group('Negative cases - connection', () {
    // 1) IP address negative cases
    test('connect fails with empty IP', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: '',
        port: '1433',
        databaseName: 'master',
        username: 'sa',
        password: 'unused-test-password',
        timeoutInSeconds: 2,
      );
      expect(ok, isFalse);
    });

    test('connect fails with malformed IP/hostname', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: 'invalid_host_name',
        port: '1433',
        databaseName: 'master',
        username: 'sa',
        password: 'unused-test-password',
        timeoutInSeconds: 2,
      );
      expect(ok, isFalse);
    });

    // 2) Port negative cases
    test('connect fails with empty port', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: '192.168.1.10',
        port: '',
        databaseName: 'master',
        username: 'sa',
        password: 'unused-test-password',
        timeoutInSeconds: 2,
      );
      expect(ok, isFalse);
    });

    test('connect fails to unreachable port quickly', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: '192.168.1.10',
        port: '1',
        databaseName: 'master',
        username: 'sa',
        password: 'unused-test-password',
        timeoutInSeconds: 2,
      );
      expect(ok, isFalse);
    });

    test('connect fails with non-numeric port', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: '192.168.1.10',
        port: 'abc',
        databaseName: 'master',
        username: 'sa',
        password: 'unused-test-password',
        timeoutInSeconds: 2,
      );
      expect(ok, isFalse);
    });

    // 3) Database name negative case
    test('missing database surfaces SQL error', () async {
      final config = TestDbConfig.current;
      final conn = MssqlConnectionAsync.getInstance();
      addTearDown(conn.disconnect);
      expect(await config.connect(conn), isTrue);
      await expectLater(
        runSql(conn, 'USE [db_does_not_exist_123]'),
        throwsA(isA<SQLException>()),
      );
      expect(conn.isConnected, isFalse);
    }, skip: !runDbTests);

    // 4) Username negative case
    test('connect fails with empty username', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: '192.168.1.10',
        port: '1433',
        databaseName: 'master',
        username: '',
        password: 'unused-test-password',
        timeoutInSeconds: 2,
      );
      expect(ok, isFalse);
    });

    test('connect fails with wrong username (low timeout)', () async {
      final config = TestDbConfig.current;
      final conn = MssqlConnectionAsync.getInstance();
      addTearDown(conn.disconnect);
      await expectLater(
        config.connect(conn, username: 'definitely-wrong', timeoutInSeconds: 2),
        throwsA(isA<SQLException>()),
      );
    }, skip: !runDbTests);

    // 5) Password negative case
    test('connect fails with empty password', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: '192.168.1.10',
        port: '1433',
        databaseName: 'master',
        username: 'sa',
        password: '',
        timeoutInSeconds: 2,
      );
      expect(ok, isFalse);
    });

    test('connect fails with wrong password (low timeout)', () async {
      final config = TestDbConfig.current;
      final conn = MssqlConnectionAsync.getInstance();
      addTearDown(conn.disconnect);
      await expectLater(
        config.connect(conn, password: 'definitely-wrong', timeoutInSeconds: 2),
        throwsA(isA<SQLException>()),
      );
    }, skip: !runDbTests);
    // 6) Timeout negative cases
    test('connect fails fast with zero timeout to unreachable port', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: '192.168.1.10',
        port: '1',
        databaseName: 'master',
        username: 'sa',
        password: 'unused-test-password',
        timeoutInSeconds: 0,
      );
      expect(ok, isFalse);
    });

    test('connect fails with negative timeout and bad port', () async {
      final conn = MssqlConnectionAsync.getInstance();
      final ok = await conn.connect(
        ip: 'invalid_host_name',
        port: 'abc', // skip TCP probe; exercise dbopen path defensively
        databaseName: 'master',
        username: 'sa',
        password: 'unused-test-password',
        timeoutInSeconds: -1,
      );
      expect(ok, isFalse);
    });
  });

  group('Negative cases - SQL execution (syntax/semantics)', () {
    final harness = TempDbHarness();

    setUp(() async {
      if (!harness.client.isConnected) await harness.reconnect();
    });

    setUpAll(() async {
      await harness.init();
      await harness.recreateTable('''
        CREATE TABLE dbo.NegItems (
          id INT NOT NULL PRIMARY KEY,
          name NVARCHAR(50) NULL
        )
      ''');
    });

    tearDownAll(() async {
      await harness.dispose();
    });

    test('invalid write SQL throws SQLException', () async {
      await expectLater(
        harness.execute('SELEC 1'),
        throwsA(isA<SQLException>()),
      );
    });

    test('invalid read SQL throws SQLException', () async {
      await expectLater(
        harness.query('SELET * FROM dbo.NegItems'),
        throwsA(isA<SQLException>()),
      );
    });

    test('missing parameter in executeParams throws SQLException', () async {
      await expectLater(
        harness.executeParams('SELECT @missingParam', {}),
        throwsA(isA<SQLException>()),
      );
      expect(harness.client.isConnected, isFalse);
    });

    test('type overflow via params surfaces error', () async {
      // INT column can't store > INT32 max
      final tooBig = 9223372036854775807; // fits bigint, not int
      try {
        await harness.executeParams(
          'INSERT INTO dbo.NegItems (id, name) VALUES (@id, @name)',
          {'id': tooBig, 'name': 'x'},
        );
        fail('Expected an error due to int overflow');
      } catch (e) {
        expect(e, isA<SQLException>());
      }
    });

    test('bulkInsert into non-existent table throws', () async {
      final conn = harness.client;
      final rows = [
        {'id': 1, 'name': 'a'},
        {'id': 2, 'name': 'b'},
      ];
      await expectLater(
        runBulk(conn, 'dbo.NoSuchTable', rows),
        throwsA(isA<SQLException>()),
      );
    });

    test('transaction rollback after error leaves table empty', () async {
      final c = harness.client;
      await expectLater(
        c.transaction((tx) async {
          await runSql(
            tx,
            "INSERT INTO dbo.NegItems (id, wrong_name) VALUES (1, N'x')",
          );
        }),
        throwsA(isA<SQLException>()),
      );
      // Native errors invalidate the session; reconnect explicitly to inspect.
      expect(c.isConnected, isFalse);
      await harness.reconnect();
      final rows = parseRows(
        await harness.query('SELECT COUNT(*) AS n FROM dbo.NegItems'),
      );
      expect(rows.single['n'], 0);
    });
  });

  group('Edge-case regression', () {
    final harness = TempDbHarness();

    setUpAll(() async {
      await harness.init();
      await harness.recreateTable('''
        CREATE TABLE dbo.Texts (
          k INT PRIMARY KEY,
          v NVARCHAR(200) NULL
        )
      ''');
    });

    tearDownAll(() async {
      await harness.dispose();
    });

    test(
      'NVARCHAR parameters with non-ASCII characters are handled correctly',
      () async {
        final unicode = 'こんにちは世界 👋';
        final affected = affectedCount(
          await harness.executeParams(
            'INSERT INTO dbo.Texts (k, v) VALUES (@k, @v)',
            {'k': 1, 'v': unicode},
          ),
        );
        expect(affected, 1);

        final rows = parseRows(
          await harness.executeParams('SELECT v FROM dbo.Texts WHERE k=@k', {
            'k': 1,
          }),
        );
        expect(rows.first['v'], unicode);
      },
    );
  });

  group('Offline API negative behavior (no DB)', () {
    test(
      'query without connect throws StateError without reconnecting',
      () async {
        final c = MssqlConnectionAsync.getInstance();
        // Ensure disconnected
        await c.disconnect();
        await expectLater(runSql(c, 'SELECT 1'), throwsA(isA<StateError>()));
      },
    );

    test('parameterized write without connect throws StateError', () async {
      final c = MssqlConnectionAsync.getInstance();
      await c.disconnect();
      await expectLater(
        runSql(c, 'SELECT @p', {'p': 1}),
        throwsA(isA<StateError>()),
      );
    });
  });
}
