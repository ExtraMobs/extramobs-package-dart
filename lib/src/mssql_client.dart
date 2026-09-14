import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'ffi/freetds_bindings.dart';
import 'ffi/freetds_text.dart';
import 'sql_exception.dart';
import 'sql_row.dart';
import 'tls_config.dart';
import 'tls_certificate.dart';

import 'mssql_cursor.dart';
export 'mssql_cursor.dart';

part 'native_cursor.dart';
part 'sync_connection.dart';

/// One serialized DB-Lib session. Native calls block the owning isolate.
class MssqlClient {
  final String server, username, password;
  final TlsConfig? tls;
  TlsCertificate? _peerCertificate;
  TlsCertificate? get peerCertificate => _peerCertificate;
  final int queryTimeoutSeconds, maxResultRows, maxResultBytes;
  DBLib? _db;
  Pointer<DBPROCESS>? _dbproc;
  Future<void> _tail = Future.value();
  final _cursors = <_NativeCursor>{};
  _NativeCursor? _activeCursor;
  bool _autocommit;

  MssqlClient({
    required this.server,
    required this.username,
    required this.password,
    this.tls,
    this.queryTimeoutSeconds = 30,
    this.maxResultRows = 100000,
    this.maxResultBytes = 64 * 1024 * 1024,
    bool autocommit = false,
    DBLib? dbLib,
  }) : _db = dbLib,
       _autocommit = autocommit;

  bool get autocommit => _autocommit;

  bool get isConnected => _dbproc != null;
  Future<T> _run<T>(FutureOr<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  T _checked<T>(String operation, T Function() action, bool Function(T) ok) {
    final (value, diagnostics) = DBLib.captureDiagnostics(action);
    if (!ok(value)) {
      throw SQLException(
        '$operation failed${diagnostics.isEmpty ? '.' : ': ${diagnostics.join(' | ')}'}',
      );
    }
    return value;
  }

  void _check(String operation, int Function() action) =>
      _checked<int>(operation, action, (rc) => rc == SUCCEED);

  Future<bool> connect({int loginTimeoutSeconds = 15}) =>
      _run(() => _connectSync(loginTimeoutSeconds: loginTimeoutSeconds));

  bool _connectSync({int loginTimeoutSeconds = 15}) {
    if (isConnected) return true;
    if (loginTimeoutSeconds <= 0 ||
        loginTimeoutSeconds > 0x7fffffff ||
        queryTimeoutSeconds <= 0 ||
        queryTimeoutSeconds > 0x7fffffff ||
        maxResultRows <= 0 ||
        maxResultBytes <= 0) {
      throw ArgumentError(
        'Timeouts must fit a positive signed 32-bit integer; result limits must be positive',
      );
    }
    final policy = tls;
    final trust = switch (policy) {
      TlsWithTrust(:final trust) => trust,
      _ => null,
    };
    final hostname = switch (policy) {
      TlsWithTrust(:final certificateHostname) => certificateHostname,
      _ => null,
    };
    final caFile = switch (trust) {
      TlsSystemTrust() => 'system',
      TlsPemTrust(:final path) => path,
      null => '',
    };
    for (final text in [server, username, password, caFile, hostname ?? '']) {
      if (text.contains('\u0000')) {
        throw ArgumentError('Login fields cannot contain NUL');
      }
    }
    if (server.isEmpty || username.isEmpty || password.isEmpty) {
      throw ArgumentError('Server and credentials must be specified');
    }
    if (trust is TlsPemTrust && (caFile.isEmpty || !File(caFile).isAbsolute)) {
      throw ArgumentError('The PEM file must have an absolute path');
    }
    if (hostname != null && hostname.isEmpty) {
      throw ArgumentError('certificateHostname cannot be empty');
    }
    final hp = _splitHostPort(server);
    final db = _db ??= DBLib.load();
    _check(
      'DB-Lib initialization (one owning isolate required)',
      () => db.initialize(kErrHandlerPtr, kMsgHandlerPtr),
    );
    _check('dbsetlogintime', () => db.dbsetlogintime(loginTimeoutSeconds));
    final login = _checked('dblogin', db.dblogin, (p) => p != nullptr);
    try {
      using((arena) {
        Pointer<Utf8> text(String value) =>
            toNativeFreeTdsText(value, allocator: arena);
        _check(
          'dbsetlcharset',
          () => db.dbsetlcharset(login, text(freeTdsClientCharset)),
        );
        _check('dbsetluser', () => db.dbsetluser(login, text(username)));
        _check('dbsetlpwd', () => db.dbsetlpwd(login, text(password)));
        // An omitted policy leaves FreeTDS files/environment/defaults intact.
        if (policy != null) {
          _check(
            'DBSETCAFILE',
            () => db.dbsetlname(login, text(caFile), DBSETCAFILE),
          );
          final mode = switch (policy) {
            TlsOff() => 'off',
            TlsRequest() => 'request',
            TlsRequire() => 'require',
            TlsStrict() => 'strict',
          };
          _check(
            'DBSETENCRYPTION',
            () => db.dbsetlname(login, text(mode), DBSETENCRYPTION),
          );
          if (trust != null) {
            _check(
              'DBSETCERTIFICATEHOSTNAME',
              () => db.dbsetlname(
                login,
                text(hostname ?? hp?.$1 ?? server),
                DBSETCERTIFICATEHOSTNAME,
              ),
            );
          }
        }
        _check('DBSETBCP', () => db.dbsetlbool(login, 1, DBSETBCP));
        _dbproc = _checked(
          'dbopen',
          () => db.dbopen(login, text(server)),
          (p) => p != nullptr,
        );
        final length = db.peerCertificate(_dbproc!, nullptr, 0);
        if (length < 0) {
          throw SQLException('Failed to read the peer certificate');
        }
        if (length > 0) {
          final bytes = arena<Uint8>(length);
          if (db.peerCertificate(_dbproc!, bytes, length) != length) {
            throw SQLException('Failed to copy the peer certificate');
          }
          _peerCertificate = TlsCertificate(bytes.asTypedList(length));
        }
        _check(
          'DBSETTIME',
          () =>
              db.dbsetopt(_dbproc!, DBSETTIME, text('$queryTimeoutSeconds'), 0),
        );
      });
      _command(
        'SET TEXTSIZE 2147483647; SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; '
        'SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; '
        'SET ARITHABORT ON; SET NUMERIC_ROUNDABORT OFF; '
        'SET IMPLICIT_TRANSACTIONS ${_autocommit ? 'OFF' : 'ON'};',
      );
      return true;
    } catch (_) {
      _close();
      rethrow;
    } finally {
      db.dbloginfree(login);
    }
  }

  Future<void> close() => _run(_close);

  void _commit() => _command('WHILE @@TRANCOUNT > 0 COMMIT TRAN');
  Future<void> commit() => _run(_commit);

  void _rollback() => _command('IF @@TRANCOUNT > 0 ROLLBACK TRAN');
  Future<void> rollback() => _run(_rollback);

  Future<void> setAutocommit(bool value) => _run(() {
    if (!isConnected) throw StateError('Not connected');
    if (value == _autocommit) return;
    if (value) _commit();
    _command('SET IMPLICIT_TRANSACTIONS ${value ? 'OFF' : 'ON'}');
    _autocommit = value;
  });
  void _close() {
    _peerCertificate = null;
    final proc = _dbproc;
    _dbproc = null;
    for (final cursor in _cursors.toList()) {
      cursor._finish();
    }
    _activeCursor = null;
    if (proc != null) {
      try {
        _db!.dbclose(proc);
      } finally {
        DBLib.takeLastMessage(proc);
        DBLib.takeLastError(proc);
      }
    }
  }

  T _operation<T>(T Function(DBLib, Pointer<DBPROCESS>) action) {
    final proc = _dbproc;
    if (proc == null) {
      throw SQLException('Not connected. Call connect() first.');
    }
    DBLib.takeLastError(proc);
    DBLib.takeLastMessage(proc);
    try {
      return action(_db!, proc);
    } catch (_) {
      // Closing aborts native buffers/BCP and rolls back any transaction.
      _close();
      rethrow;
    }
  }

  Future<MssqlCursor> execute(String sql, [Object? parameters]) async {
    final current = cursor();
    try {
      return await current.execute(sql, parameters);
    } catch (_) {
      await current.close();
      rethrow;
    }
  }

  void _command(String sql, [Object? parameters]) {
    final current = _cursor();
    try {
      current._execute(sql, parameters);
      current._drain();
    } finally {
      current._close();
    }
  }

  void _sendSql(String sql) {
    if (sql.contains('\u0000')) throw ArgumentError('SQL cannot contain NUL');
    _operation(
      (db, proc) => using((arena) {
        _check(
          'dbcmd',
          () => db.dbcmd(proc, toNativeFreeTdsText(sql, allocator: arena)),
        );
        _check('dbsqlexec', () => db.dbsqlexec(proc));
      }),
    );
  }

  List<(String, dynamic)> _sqlParams(String sql, Object params) {
    if (params is List) {
      final bound = _bindPositional(sql, params);
      sql = bound.$1;
      params = bound.$2;
    }
    if (params is! Map<String, dynamic>) {
      throw ArgumentError(
        'Parameters must be a List or a Map<String, dynamic>',
      );
    }
    final norm = _normalizeParams(params, limit: 2098);
    // Positional user arguments cannot collide with the built-in @stmt/@params.
    return [
      ('@stmt', sql),
      (
        '@params',
        norm.entries
            .map((e) => '${e.key} ${_inferSqlType(e.value)}')
            .join(', '),
      ),
      for (final value in norm.values) ('', value),
    ];
  }

  void _sendRpc(String name, List<(String, dynamic)> params) => using((arena) {
    final rpcName = toNativeFreeTdsText(name, allocator: arena);
    // Validate and encode before starting RPC; retain all buffers through send.
    final values = [
      for (final (key, value) in params)
        (
          toNativeFreeTdsText(key, allocator: arena),
          _encodeForRpc(value, arena),
        ),
    ];
    return _operation((db, proc) {
      _check('dbrpcinit', () => db.dbrpcinit(proc, rpcName, 0));
      for (final (key, value) in values) {
        _check(
          'dbrpcparam',
          () => db.dbrpcparam(
            proc,
            key,
            value.ptr != nullptr && value.length == 0 ? DBRPCEMPTY : 0,
            value.type,
            -1,
            value.length,
            value.ptr,
          ),
        );
      }
      _check('dbrpcsend', () => db.dbrpcsend(proc));
      _check('dbsqlok', () => db.dbsqlok(proc));
    });
  });

  /// Creates an idle cursor; commands are serialized when executed.
  MssqlCursor cursor({
    void Function()? validate,
    Future<T> Function<T>(FutureOr<T> Function())? schedule,
    void Function()? validateTransactionControl,
  }) => _cursor(
    validate: validate,
    schedule: schedule,
    validateTransactionControl: validateTransactionControl,
  );

  _NativeCursor _cursor({
    void Function()? validate,
    Future<T> Function<T>(FutureOr<T> Function())? schedule,
    void Function()? validateTransactionControl,
  }) {
    final proc = _dbproc;
    if (proc == null) throw StateError('Not connected. Call connect() first.');
    final current = _NativeCursor(
      this,
      _db!,
      proc,
      validate,
      schedule,
      validateTransactionControl,
    );
    _cursors.add(current);
    return current;
  }

  /// Manual mode uses RPC INSERTs so the connection owns the entire transaction.
  /// Autocommit may preserve completed rows/batches if a later row fails.
  int _bulkInsert(
    String tableName,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  }) {
    final table = quoteSqlName(tableName);
    if (batchSize <= 0) throw ArgumentError.value(batchSize, 'batchSize');
    if (rows.isEmpty) return 0;
    final cols = columns ?? rows.first.keys.toList();
    if (cols.isEmpty || cols.toSet().length != cols.length) {
      throw ArgumentError('Columns must be nonempty and unique');
    }
    final columnSql = cols.map(quoteSqlIdentifier).join(', ');
    for (final row in rows) {
      if (cols.any((c) => !row.containsKey(c))) {
        throw ArgumentError('Missing bulk column');
      }
    }
    final types = [for (final col in cols) _bulkType(rows.map((r) => r[col]))];
    var useBcp =
        _autocommit && !table.startsWith('[#') && !types.contains(null);
    if (useBcp) {
      final metadata = _cursor();
      late final List<String> actual;
      try {
        metadata._execute('SELECT @@TRANCOUNT', null);
        useBcp = metadata._native(() => metadata._rows.fetchone()!.single) == 0;
        metadata._drain();
        metadata._execute('SELECT TOP (0) * FROM $table', null);
        actual = metadata.columns!;
        metadata._drain();
      } finally {
        metadata._close();
      }
      useBcp =
          useBcp &&
          actual.length == cols.length &&
          List.generate(
            cols.length,
            (i) => actual[i] == cols[i],
          ).every((v) => v);
    }
    if (!useBcp) {
      // ponytail: one INSERT per row; optimize only with a charset-aware bulk path.
      for (final row in rows) {
        // Untyped Dart null has no SQL type. A NULL literal lets the target
        // column determine it, including binary columns that reject NVARCHAR.
        final values = List.generate(
          cols.length,
          (i) => row[cols[i]] == null ? 'NULL' : '@p$i',
        ).join(', ');
        final sql = 'INSERT INTO $table ($columnSql) VALUES ($values)';
        _command(sql, {
          for (var i = 0; i < cols.length; i++)
            if (row[cols[i]] != null) 'p$i': row[cols[i]],
        });
      }
      return rows.length;
    }
    return _operation(
      (db, proc) => using((arena) {
        _check(
          'bcp_init',
          () => db.bcp_init(
            proc,
            toNativeFreeTdsText(table, allocator: arena),
            nullptr,
            nullptr,
            DB_IN,
          ),
        );
        for (var i = 0; i < cols.length; i++) {
          _check(
            'bcp_bind',
            () =>
                db.bcp_bind(proc, nullptr, 0, -1, nullptr, 0, types[i]!, i + 1),
          );
        }
        var sent = 0, copied = 0;
        for (final row in rows) {
          using((rowArena) {
            for (var i = 0; i < cols.length; i++) {
              final v = _encodeForRpc(row[cols[i]], rowArena, type: types[i]);
              _check('bcp_collen', () => db.bcp_collen(proc, v.length, i + 1));
              _check('bcp_colptr', () => db.bcp_colptr(proc, v.ptr, i + 1));
            }
            _check('bcp_sendrow', () => db.bcp_sendrow(proc));
          });
          if (++sent % batchSize == 0) {
            copied += _checked(
              'bcp_batch',
              () => db.bcp_batch(proc),
              (n) => n >= 0,
            );
          }
        }
        copied += _checked('bcp_done', () => db.bcp_done(proc), (n) => n >= 0);
        return copied;
      }),
    );
  }
}

(String, Map<String, dynamic>) _bindPositional(String sql, List values) {
  var prefix = '@__cursor';
  final lower = sql.toLowerCase();
  while (lower.contains(prefix)) {
    prefix += '_';
  }
  final output = StringBuffer();
  final parameters = <String, dynamic>{};
  var i = 0;
  while (i < sql.length) {
    final ch = sql[i];
    if (ch == "'" || ch == '"' || ch == '[') {
      final end = ch == '[' ? ']' : ch;
      output.write(ch);
      i++;
      while (i < sql.length) {
        final quoted = sql[i++];
        output.write(quoted);
        if (quoted == end) {
          if (i < sql.length && sql[i] == end) {
            output.write(sql[i++]);
          } else {
            break;
          }
        }
      }
    } else if (sql.startsWith('--', i)) {
      while (i < sql.length && sql[i] != '\n' && sql[i] != '\r') {
        output.write(sql[i++]);
      }
    } else if (sql.startsWith('/*', i)) {
      var depth = 1;
      output.write('/*');
      i += 2;
      while (i < sql.length && depth > 0) {
        if (sql.startsWith('/*', i)) {
          depth++;
          output.write('/*');
          i += 2;
        } else if (sql.startsWith('*/', i)) {
          depth--;
          output.write('*/');
          i += 2;
        } else {
          output.write(sql[i++]);
        }
      }
    } else if (ch == '?') {
      final index = parameters.length;
      if (index >= values.length) throw ArgumentError('Too few SQL parameters');
      final name = '${prefix}_$index';
      parameters[name] = values[index];
      output.write(name);
      i++;
    } else {
      output.write(ch);
      i++;
    }
  }
  if (parameters.length != values.length) {
    throw ArgumentError('Too many SQL parameters');
  }
  return (output.toString(), parameters);
}

(String, int)? _splitHostPort(String server) {
  final colon = server.lastIndexOf(':');
  if (colon <= 0) return null;
  final port = int.tryParse(server.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) return null;
  var host = server.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  return (host, port);
}

String quoteSqlIdentifier(String value) {
  if (value.isEmpty || value.length > 128 || value.contains('\u0000')) {
    throw ArgumentError('Invalid SQL identifier');
  }
  return '[${value.replaceAll(']', ']]')}]';
}

/// Parse regular or bracket-quoted multipart identifiers, never SQL expressions.
String quoteSqlName(String value) {
  final parts = <String>[];
  var i = 0;
  while (i < value.length) {
    while (i < value.length && value[i].trim().isEmpty) {
      i++;
    }
    final part = StringBuffer();
    if (i < value.length && value[i] == '[') {
      i++;
      var closed = false;
      while (i < value.length) {
        final ch = value[i++];
        if (ch == ']') {
          if (i < value.length && value[i] == ']') {
            part.write(']');
            i++;
          } else {
            closed = true;
            break;
          }
        } else {
          part.write(ch);
        }
      }
      if (!closed) throw ArgumentError('Unclosed SQL identifier');
    } else {
      final start = i;
      while (i < value.length && value[i] != '.') {
        i++;
      }
      final raw = value.substring(start, i).trim();
      if (!RegExp(
        r'^[\p{L}_#][\p{L}\p{N}_@$#]*$',
        unicode: true,
      ).hasMatch(raw)) {
        throw ArgumentError('Invalid SQL identifier');
      }
      part.write(raw);
    }
    parts.add(quoteSqlIdentifier(part.toString()));
    while (i < value.length && value[i].trim().isEmpty) {
      i++;
    }
    if (i == value.length) break;
    if (value[i++] != '.' || i == value.length) {
      throw ArgumentError('Invalid SQL name');
    }
  }
  if (parts.isEmpty || parts.length > 4) {
    throw ArgumentError('Invalid SQL name');
  }
  return parts.join('.');
}

Map<String, dynamic> _normalizeParams(
  Map<String, dynamic> params, {
  int limit = 2100,
}) {
  final result = <String, dynamic>{};
  final seen = <String>{};
  for (final entry in params.entries) {
    final name = entry.key.startsWith('@') ? entry.key : '@${entry.key}';
    if (name.length > 128 ||
        !RegExp(r'^@[\p{L}_][\p{L}\p{N}_]*$', unicode: true).hasMatch(name)) {
      throw ArgumentError('Invalid SQL parameter name');
    }
    if (!seen.add(name.toLowerCase())) {
      throw ArgumentError('Duplicate SQL parameter');
    }
    result[name] = entry.value;
  }
  if (result.length > limit) {
    throw ArgumentError('SQL Server parameter limit exceeded');
  }
  return result;
}

String _inferSqlType(dynamic v) {
  if (v is bool) return 'bit';
  if (v is int) return v < -2147483648 || v > 2147483647 ? 'bigint' : 'int';
  if (v is double) return 'float';
  if (v is DateTime) return 'datetimeoffset(7)';
  if (v is Uint8List) return 'varbinary(max)';
  return 'nvarchar(max)';
}

int? _bulkType(Iterable<dynamic> values) {
  if (values.every((v) => v is int)) {
    return values.any((v) => v < -2147483648 || v > 2147483647)
        ? SYBINT8
        : SYBINT4;
  }
  if (values.every((v) => v is double && v.isFinite)) return SYBFLT8;
  if (values.every((v) => v is bool)) return SYBBIT;
  if (values.every((v) => v is Uint8List && v.isNotEmpty)) return SYBVARBINARY;
  return null;
}

class _RpcValue {
  final int type, length;
  final Pointer<Uint8> ptr;
  _RpcValue(this.type, this.ptr, this.length);
}

_RpcValue _encodeForRpc(dynamic value, Allocator arena, {int? type}) {
  if (value == null) return _RpcValue(SYBNTEXT, nullptr, 0);
  if (value is int) {
    if (type == SYBINT8 || value < -2147483648 || value > 2147483647) {
      final p = arena<Int64>()..value = value;
      return _RpcValue(SYBINT8, p.cast(), 8);
    }
    final p = arena<Int32>()..value = value;
    return _RpcValue(SYBINT4, p.cast(), 4);
  }
  if (value is double) {
    if (!value.isFinite) throw ArgumentError('SQL float must be finite');
    final p = arena<Double>()..value = value;
    return _RpcValue(SYBFLT8, p.cast(), 8);
  }
  if (value is bool) {
    final p = arena<Uint8>()..value = value ? 1 : 0;
    return _RpcValue(SYBBIT, p, 1);
  }
  if (value is DateTime) {
    final utc = value.toUtc();
    if (utc.year < 1 ||
        utc.year > 9999 ||
        value.timeZoneOffset.inMinutes.abs() > 840) {
      throw ArgumentError('DateTime outside SQL Server datetimeoffset range');
    }
    final p = arena<Uint8>(16);
    p.asTypedList(16).fillRange(0, 16, 0);
    final bytes = ByteData.sublistView(p.asTypedList(16));
    final midnight = DateTime.utc(utc.year, utc.month, utc.day);
    bytes.setUint64(
      0,
      utc.difference(midnight).inMicroseconds * 10,
      Endian.host,
    );
    bytes.setInt32(
      8,
      midnight.difference(DateTime.utc(1900, 1, 1)).inDays,
      Endian.host,
    );
    bytes.setInt16(12, value.timeZoneOffset.inMinutes, Endian.host);
    bytes.setUint16(14, 7 | (1 << 13) | (1 << 14) | (1 << 15), Endian.host);
    return _RpcValue(SYBMSDATETIMEOFFSET, p, 16);
  }
  final bytes = value is Uint8List
      ? value
      : freeTdsTextCodec.encode(value.toString());
  final p = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedList(bytes.length).setAll(0, bytes);
  return _RpcValue(
    // FreeTDS caps ordinary VARBINARY at 8000 bytes. IMAGE is promoted to
    // VARBINARY(MAX) on TDS 7.2+, preserving larger RPC inputs.
    value is Uint8List
        ? (bytes.length > 8000 ? SYBIMAGE : SYBVARBINARY)
        : SYBNTEXT,
    p,
    bytes.length,
  );
}
