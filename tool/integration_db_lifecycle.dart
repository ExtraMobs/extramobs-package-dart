import 'dart:io';
import 'dart:typed_data';

import 'package:extramobs/mssql.dart';

// Destructive integration tool: creates and removes its own temporary database.
Future<void> main() async {
  final env = Platform.environment;
  String required(String key) =>
      env[key] ??
      (throw StateError('Explicit $key test configuration required'));
  final db = MssqlConnectionAsync();
  final dbName = 'Test_${DateTime.now().microsecondsSinceEpoch}';
  var created = false;
  try {
    final connected = await db.connect(
      ip: required('MSSQL_IP'),
      port: env['MSSQL_PORT'] ?? '1433',
      databaseName: 'master',
      username: required('MSSQL_USER'),
      password: required('MSSQL_PASSWORD'),
      tls: TlsRequire(
        trust: env['MSSQL_TRUST_SERVER_CERTIFICATE'] == 'true'
            ? null
            : env['MSSQL_CA_FILE'] == null || env['MSSQL_CA_FILE'] == 'system'
            ? const TlsSystemTrust()
            : TlsPemTrust(env['MSSQL_CA_FILE']!),
        certificateHostname: env['MSSQL_CERTIFICATE_HOSTNAME'],
      ),
      autocommit: true, // CREATE/DROP DATABASE cannot run in a transaction.
    );
    if (!connected) throw StateError('Connection failed');
    final cursor = db.cursor();
    try {
      await cursor.execute('CREATE DATABASE [$dbName]');
      created = true;
      await cursor.execute('USE [$dbName]');
      await cursor.execute('''
        CREATE TABLE dbo.Items (
          id int PRIMARY KEY, name nvarchar(100), created datetimeoffset(7),
          flag bit, data varbinary(max)
        )
      ''');
      await cursor.execute('INSERT INTO dbo.Items VALUES (?, ?, ?, ?, ?)', [
        1,
        'hello',
        DateTime.now(),
        true,
        Uint8List.fromList([1, 2, 3, 4]),
      ]);
      await cursor.execute('SELECT * FROM dbo.Items');
      await for (final row in cursor) {
        stdout.writeln(row.values);
      }
    } finally {
      await cursor.close();
      if (created && db.isConnected) {
        final cleanup = db.cursor();
        try {
          await cleanup.execute('USE master');
          await cleanup.execute(
            'ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE',
          );
          await cleanup.execute('DROP DATABASE [$dbName]');
          created = false;
        } finally {
          await cleanup.close();
        }
      }
    }
  } finally {
    await db.close();
    if (created) stderr.writeln('Cleanup required for database [$dbName]');
  }
}
