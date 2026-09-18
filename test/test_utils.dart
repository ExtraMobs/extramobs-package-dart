import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:extramobs/mssql.dart';

import 'cursor_results.dart';

export 'cursor_results.dart';

void requireTempDbConfig() {
  final env = Platform.environment;
  if (env['RUN_DB_TESTS'] != '1' ||
      (env['MSSQL_SERVER']?.isNotEmpty != true &&
          env['MSSQL_IP']?.isNotEmpty != true) ||
      env['MSSQL_USER']?.isNotEmpty != true ||
      ![
        env['MSSQL_PASS'],
        env['MSSQL_PASSWORD'],
      ].any((p) => p?.isNotEmpty == true)) {
    throw StateError(
      'Temporary database tests require RUN_DB_TESTS=1, '
      'MSSQL_SERVER (or MSSQL_IP), MSSQL_USER and MSSQL_PASSWORD (or MSSQL_PASS).',
    );
  }
}

String _uniqueDbName([String prefix = 'Test']) {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final rnd = Random().nextInt(0xFFFFFF);
  return '${prefix}_${ts}_$rnd';
}

Future<void> runWithClientAndTempDb(
  Future<void> Function(MssqlConnectionAsync client, String dbName) body,
) async {
  final harness = TempDbHarness();
  try {
    await harness.init();
    await body(harness.client, harness.dbName);
  } finally {
    await harness.dispose();
  }
}

extension _TestQueries on MssqlConnectionAsync {
  Future<ResultSnapshot> query(String sql) => runSql(this, sql);
  Future<ResultSnapshot> executeParams(
    String sql,
    Map<String, dynamic> params,
  ) => runSql(this, sql, params);
}

List<Map<String, dynamic>> parseRows(ResultSnapshot response) {
  if (response.error != null) throw SQLException(response.error!);
  if (response.resultSets.isEmpty) return [];
  final set = response.resultSets.single;
  return [
    for (final row in set.rows)
      Map<String, dynamic>.fromIterables(set.columns, row),
  ];
}

int affectedCount(ResultSnapshot response) {
  if (response.error != null) throw SQLException(response.error!);
  return response.totalAffectedRows;
}

/// A reusable temp-database harness for running many tests within a single DB.
///
/// This avoids the overhead of creating/dropping a database for each test case
/// when scaling up to dozens of cases per mode. Use setUpAll/tearDownAll in
/// your test group to initialize and dispose this harness once per group.
class TempDbHarness {
  final MssqlConnectionAsync client = MssqlConnectionAsync();
  final String dbName = _uniqueDbName('Bulk');
  bool _created = false;

  Future<void> init() async {
    await reconnect(database: 'master');
    await runSql(client, 'CREATE DATABASE [$dbName]');
    _created = true;
    await runSql(client, 'USE [$dbName]');
  }

  Future<void> reconnect({
    String? database,
    int maxResultRows = 100000,
    int maxResultBytes = 64 * 1024 * 1024,
  }) async {
    final ok = await TestDbConfig.current.connect(
      client,
      database: database ?? dbName,
      maxResultRows: maxResultRows,
      maxResultBytes: maxResultBytes,
    );
    if (!ok) {
      throw StateError('Failed to connect to the configured test server');
    }
  }

  Future<void> dispose() async {
    try {
      if (!_created) return;
      if (!client.isConnected) await reconnect(database: 'master');
      await runSql(client, 'USE master');
      await runSql(
        client,
        'ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE',
      );
      await runSql(client, 'DROP DATABASE [$dbName]');
      _created = false;
    } finally {
      await client.disconnect();
    }
  }

  Future<ResultSnapshot> execute(String sql) => runSql(client, sql);
  Future<ResultSnapshot> query(String sql) => client.query(sql);
  Future<ResultSnapshot> executeParams(
    String sql,
    Map<String, dynamic> params,
  ) => client.executeParams(sql, params);

  /// Drops the table if it exists and recreates it using the provided CREATE TABLE statement.
  Future<void> recreateTable(String createTableSql) async {
    // Attempt to extract table name from CREATE TABLE statement to drop it first.
    // Expect pattern like: CREATE TABLE [schema.]Name ( ... )
    final match = RegExp(
      r'CREATE\s+TABLE\s+([^\s(]+)',
      caseSensitive: false,
    ).firstMatch(createTableSql);
    if (match != null) {
      final tableIdent = match.group(1)!;
      // Build raw (unbracketed) two-part name for OBJECT_ID and a bracketed form for DROP TABLE
      String raw = tableIdent.replaceAll('[', '').replaceAll(']', '');
      if (!raw.contains('.')) raw = 'dbo.$raw';
      final parts = raw.split('.');
      final bracketed = '[${parts[0]}].[${parts[1]}]';
      await execute(
        "IF OBJECT_ID(N'$raw', N'U') IS NOT NULL DROP TABLE $bracketed",
      );
    }
    await execute(createTableSql);
  }
}

// Centralized test DB configuration
class TestDbConfig {
  final String ip;
  final int port;
  final String databaseName;
  final String username;
  final String password;

  const TestDbConfig({
    required this.ip,
    required this.port,
    required this.databaseName,
    required this.username,
    required this.password,
  });

  static TestDbConfig fromEnv([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final server = env['MSSQL_SERVER'];
    final address = server == null ? null : Uri.parse('mssql://$server');
    return TestDbConfig(
      ip: env['MSSQL_IP']?.trim().isNotEmpty == true
          ? env['MSSQL_IP']!.trim()
          : address?.host ?? '',
      port:
          int.tryParse(env['MSSQL_PORT'] ?? '') ??
          (address?.hasPort == true ? address!.port : 1433),
      databaseName: env['MSSQL_DB']?.trim().isNotEmpty == true
          ? env['MSSQL_DB']!.trim()
          : 'master',
      username: env['MSSQL_USER']?.trim() ?? '',
      password: env['MSSQL_PASSWORD'] ?? env['MSSQL_PASS'] ?? '',
    );
  }

  static final TestDbConfig current = TestDbConfig.fromEnv();

  Future<bool> connect(
    MssqlConnectionAsync client, {
    String? database,
    String? username,
    String? password,
    int timeoutInSeconds = 15,
    int maxResultRows = 100000,
    int maxResultBytes = 64 * 1024 * 1024,
  }) {
    requireTempDbConfig();
    final env = Platform.environment;
    if (env['MSSQL_NATIVE_DIR'] != null) {
      NativeLoader.libraryDirectory = env['MSSQL_NATIVE_DIR'];
    }
    return client.connect(
      ip: ip,
      port: '$port',
      databaseName: database ?? databaseName,
      username: username ?? this.username,
      password: password ?? this.password,
      timeoutInSeconds: timeoutInSeconds,
      autocommit: true,
      maxResultRows: maxResultRows,
      maxResultBytes: maxResultBytes,
      tls: TlsRequire(
        trust: env['MSSQL_TRUST_SERVER_CERTIFICATE'] == 'true'
            ? null
            : env['MSSQL_CA_FILE'] == null || env['MSSQL_CA_FILE'] == 'system'
            ? const TlsSystemTrust()
            : TlsPemTrust(env['MSSQL_CA_FILE']!),
        certificateHostname: env['MSSQL_CERTIFICATE_HOSTNAME'],
      ),
    );
  }
}
