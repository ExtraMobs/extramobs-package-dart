import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'native_loader.dart';
import 'sql_exception.dart';
import 'sql_row.dart';
import 'mssql_client.dart';
import 'tls_config.dart';
import 'tls_certificate.dart';
export 'sql_row.dart';
export 'mssql_client.dart' show MssqlCursor, MssqlConnection, MssqlCursorSync;
part 'async_client.dart';

/// Owns a session. getInstance preserves the original shared-instance entry point.
class MssqlConnectionAsync {
  static final _instance = MssqlConnectionAsync();
  factory MssqlConnectionAsync.getInstance() => _instance;
  MssqlConnectionAsync();

  /// Close all async sessions and stop the native worker permanently.
  /// Await once at the end of a standalone Dart program, after all database work.
  static Future<void> shutdownWorker() => _AsyncWorker.shutdown();

  _AsyncClient? _client;
  Future<void> _tail = Future.value();
  final Object _transactionKey = Object();
  Object? _activeTransaction;
  final _transactionCursors = <MssqlCursor>{};
  bool get isConnected => _client?.isConnected == true;

  /// Received certificate, including login-only TLS; null after close/failure.
  /// A copy saved by the caller remains valid after the connection closes.
  TlsCertificate? get peerCertificate => _client?.peerCertificate;
  bool get autocommit => _connected.autocommit;

  Future<T> _schedule<T>(
    FutureOr<T> Function() action, {
    bool lifecycle = false,
  }) {
    final token = Zone.current[_transactionKey];
    if (token != null) {
      if (!identical(token, _activeTransaction)) {
        return Future.error(StateError('Transaction has ended'));
      }
      if (lifecycle) {
        return Future.error(
          StateError(
            'Cannot change the session or transaction mode inside transaction(callback)',
          ),
        );
      }
      return Future.sync(action);
    }
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  _AsyncClient get _connected {
    final client = _client;
    if (client == null || !client.isConnected) {
      throw StateError('Not connected. Call connect() explicitly.');
    }
    return client;
  }

  /// Omit tls to use FreeTDS configuration and defaults. Strict mode requires
  /// an explicit trust source and a server supporting TDS 8.0.
  Future<bool> connect({
    required String ip,
    required String port,
    required String databaseName,
    required String username,
    required String password,
    int timeoutInSeconds = 15,
    int queryTimeoutSeconds = 30,
    TlsConfig? tls,
    int maxResultRows = 100000,
    int maxResultBytes = 64 * 1024 * 1024,
    bool autocommit = false,
  }) => _schedule(() async {
    final host = ip.trim(), user = username.trim();
    final portNumber = int.tryParse(port.trim());
    if (host.isEmpty ||
        user.isEmpty ||
        password.isEmpty ||
        portNumber == null ||
        portNumber < 1 ||
        portNumber > 65535 ||
        timeoutInSeconds <= 0) {
      return false;
    }
    final dbName = databaseName.isEmpty
        ? null
        : quoteSqlIdentifier(databaseName);
    final address = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    await _client?.close();
    _client = null;
    final candidate = _AsyncClient(
      server: '$address:$portNumber',
      username: user,
      password: password,
      tls: tls,
      queryTimeoutSeconds: queryTimeoutSeconds,
      maxResultRows: maxResultRows,
      maxResultBytes: maxResultBytes,
      autocommit: autocommit,
    );
    try {
      if (!await candidate.connect(loginTimeoutSeconds: timeoutInSeconds)) {
        return false;
      }
      if (dbName != null) await _control(candidate, 'USE $dbName');
      _client = candidate;
      return true;
    } catch (_) {
      await candidate.close();
      rethrow;
    }
  }, lifecycle: true);

  /// Creates an idle cursor. Execute and fetch on it; close it in finally.
  MssqlCursor cursor() {
    final token = Zone.current[_transactionKey];
    _validateCursorTransaction(token);
    final current = _connected.cursor(
      validate: () => _validateCursorTransaction(token),
      schedule: _schedule,
      validateTransactionControl: () {
        if (Zone.current[_transactionKey] != null) {
          throw StateError(
            'Cannot commit or roll back inside transaction(callback)',
          );
        }
      },
    );
    if (token != null) _transactionCursors.add(current);
    return current;
  }

  void _validateCursorTransaction(Object? token) {
    if (token != null &&
        (!identical(token, _activeTransaction) ||
            !identical(token, Zone.current[_transactionKey]))) {
      throw StateError('Cursor must be used in its active transaction');
    }
  }

  /// pyodbc-style convenience: creates, executes and returns a new cursor.
  Future<MssqlCursor> execute(String sql, [Object? parameters]) async {
    final current = cursor();
    try {
      return await current.execute(sql, parameters);
    } catch (_) {
      await current.close();
      rethrow;
    }
  }

  Future<void> _control(_AsyncClient client, String sql) async {
    final current = await client.execute(sql);
    try {
      while (await current.nextset()) {}
    } finally {
      await current.close();
    }
  }

  Future<bool> disconnect() => _schedule(() async {
    final client = _client;
    _client = null;
    await client?.close();
    return true;
  }, lifecycle: true);

  /// Closes the session and invalidates all its cursors.
  Future<void> close() async {
    await disconnect();
  }

  /// Applies to all cursors on this connection. Fetch/cancel pending results first.
  Future<void> commit() =>
      _schedule(() => _connected.commit(), lifecycle: true);

  Future<void> rollback() =>
      _schedule(() => _connected.rollback(), lifecycle: true);

  /// Enabling autocommit commits pending work. Async equivalent of assigning
  /// pyodbc's autocommit property; state changes only after the native call succeeds.
  Future<void> setAutocommit(bool value) =>
      _schedule(() => _connected.setAutocommit(value), lifecycle: true);

  /// Reserves the session for the entire callback, including its awaits.
  /// Calls outside its Zone wait; callbacks used after completion are rejected.
  /// Requires autocommit=true. Errors roll back; native failures close the session.
  Future<T> transaction<T>(Future<T> Function(MssqlConnectionAsync tx) action) {
    if (Zone.current[_transactionKey] != null) {
      return Future.error(StateError('Nested transactions are not supported'));
    }
    return _schedule(() async {
      final client = _connected;
      if (!client.autocommit) {
        throw StateError(
          'transaction(callback) requires autocommit=true; use commit()/rollback() in manual mode',
        );
      }
      final token = Object();
      await _control(client, 'BEGIN TRAN');
      _activeTransaction = token;
      try {
        final T result;
        try {
          result = await runZoned(
            () => action(this),
            zoneValues: {_transactionKey: token},
          );
        } finally {
          _activeTransaction = null;
          for (final cursor in _transactionCursors.toList()) {
            await cursor.close();
          }
          _transactionCursors.clear();
        }
        await _control(client, 'COMMIT');
        return result;
      } catch (_) {
        _activeTransaction = null;
        if (client.isConnected) {
          try {
            await _control(client, 'ROLLBACK');
          } catch (_) {
            await client.close();
          }
        }
        rethrow;
      }
    });
  }
}
