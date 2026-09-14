import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mssql/mssql_connection.dart';

Future<void> main() async {
  final env = Platform.environment;
  String required(String key) =>
      env[key] ?? (throw StateError('Set $key for a test server'));
  final db = MssqlConnectionAsync();
  try {
    final connected = await db.connect(
      ip: required('MSSQL_IP'),
      port: env['MSSQL_PORT'] ?? '1433',
      databaseName: env['MSSQL_DB'] ?? 'tempdb',
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
      autocommit: false,
    );
    if (!connected) throw StateError('Connection failed');

    final cursor = db.cursor();
    try {
      await cursor.execute(
        'CREATE TABLE #Items (id int PRIMARY KEY, name nvarchar(50))',
      );
      Iterable<List<Object?>> items() sync* {
        yield [1, 'Alice'];
        yield [2, 'Bob'];
      }

      await cursor.executemany('INSERT INTO #Items VALUES (?, ?)', items());
      await db.commit();

      await cursor.execute('SELECT id, name FROM #Items ORDER BY id');
      await for (final row in cursor) {
        debugPrint('${row[0]}: ${row['name']}');
      }

      await cursor.execute('UPDATE #Items SET name=? WHERE id=?', ['Carol', 2]);
      debugPrint('Updated: ${cursor.rowcount}');
      await cursor.rollback(); // Alias for db.rollback(), across all cursors.

      await cursor.execute('SELECT ? AS instante, ? AS bytes', [
        DateTime.now().toUtc(),
        Uint8List.fromList([0, 255]),
      ]);
      debugPrint((await cursor.fetchone())!.values.toString());
      await cursor.cancel();
      await db.commit();
    } catch (_) {
      await cursor.close();
      if (db.isConnected) await db.rollback();
      rethrow;
    } finally {
      await cursor.close();
    }
  } finally {
    await db.close();
  }
}
