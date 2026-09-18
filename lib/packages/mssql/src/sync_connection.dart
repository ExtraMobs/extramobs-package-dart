part of 'mssql_client.dart';

/// Direct, blocking SQL Server API. All methods return values, never Futures.
/// Use one owning isolate per process; do not mix with MssqlConnectionAsync in it.
class MssqlConnection {
  MssqlClient? _client;
  final Object _transactionKey = Object();
  Object? _transaction;
  final _transactionCursors = <MssqlCursorSync>{};
  bool get isConnected => _client?.isConnected == true;

  /// Received certificate, including login-only TLS; null after close/failure.
  /// A copy saved by the caller remains valid after the connection closes.
  TlsCertificate? get peerCertificate => _client?.peerCertificate;
  bool get autocommit => _connected.autocommit;

  MssqlClient get _connected {
    _validateScope();
    if (!isConnected) {
      throw StateError('Not connected. Call connect() explicitly.');
    }
    return _client!;
  }

  void _validateScope({bool lifecycle = false}) {
    final token = Zone.current[_transactionKey];
    if (token != null && !identical(token, _transaction)) {
      throw StateError('Transaction has ended');
    }
    if (lifecycle && _transaction != null) {
      throw StateError(
        'Cannot control the connection inside transaction(callback)',
      );
    }
  }

  bool connect({
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
  }) {
    _validateScope(lifecycle: true);
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
    disconnect();
    final candidate = MssqlClient(
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
      if (!candidate._connectSync(loginTimeoutSeconds: timeoutInSeconds)) {
        return false;
      }
      if (dbName != null) candidate._command('USE $dbName');
      _client = candidate;
      return true;
    } catch (_) {
      candidate._close();
      rethrow;
    }
  }

  MssqlCursorSync cursor() {
    final token = Zone.current[_transactionKey];
    final cursor = MssqlCursorSync._(
      _connected._cursor(
        validate: () {
          _validateScope();
          if (token != null &&
              (!identical(token, _transaction) ||
                  !identical(token, Zone.current[_transactionKey]))) {
            throw StateError('Cursor must be used in its active transaction');
          }
        },
        validateTransactionControl: () => _validateScope(lifecycle: true),
      ),
    );
    if (token != null) _transactionCursors.add(cursor);
    return cursor;
  }

  MssqlCursorSync execute(String sql, [Object? parameters]) {
    final current = cursor();
    try {
      return current.execute(sql, parameters);
    } catch (_) {
      current.close();
      rethrow;
    }
  }

  bool disconnect() {
    _validateScope(lifecycle: true);
    final client = _client;
    _client = null;
    client?._close();
    return true;
  }

  void close() => disconnect();
  void commit() {
    _validateScope(lifecycle: true);
    _connected._commit();
  }

  void rollback() {
    _validateScope(lifecycle: true);
    _connected._rollback();
  }

  void setAutocommit(bool value) {
    _validateScope(lifecycle: true);
    final client = _connected;
    if (value == client.autocommit) return;
    if (value) client._commit();
    client._command('SET IMPLICIT_TRANSACTIONS ${value ? 'OFF' : 'ON'}');
    client._autocommit = value;
  }

  /// Callback must be synchronous. Cursors cannot escape the transaction.
  T transaction<T>(T Function(MssqlConnection tx) action) {
    _validateScope(lifecycle: true);
    final client = _connected;
    if (!autocommit) {
      throw StateError('transaction(callback) requires autocommit=true');
    }
    client._command('BEGIN TRAN');
    final token = _transaction = Object();
    try {
      final T result;
      try {
        result = runZoned(
          () => action(this),
          zoneValues: {_transactionKey: token},
        );
        if (result is Future) {
          result.ignore();
          throw StateError('Use MssqlConnectionAsync for async transactions');
        }
      } finally {
        _transaction = null;
        for (final cursor in _transactionCursors) {
          cursor.close();
        }
        _transactionCursors.clear();
      }
      client._command('COMMIT');
      return result;
    } catch (_) {
      _transaction = null;
      if (client.isConnected) {
        try {
          client._command('ROLLBACK');
        } catch (_) {
          client._close();
        }
      }
      rethrow;
    }
  }
}

/// Synchronous, incremental cursor. Iteration does not close the cursor.
class MssqlCursorSync extends Iterable<SqlRow> {
  final _NativeCursor _cursor;
  MssqlCursorSync._(this._cursor);
  bool get isClosed => _cursor.isClosed;
  List<SqlColumn>? get description => _cursor.description;
  List<String>? get columns => _cursor.columns;
  int get rowcount => _cursor.rowcount;
  int get arraysize => _cursor.arraysize;
  set arraysize(int value) => _cursor.arraysize = value;

  MssqlCursorSync execute(String sql, [Object? parameters]) {
    _cursor._callSync(() => _cursor._execute(sql, parameters));
    return this;
  }

  void executemany(String sql, Iterable<Object> parameters) =>
      _cursor._callSync(() => _cursor._executemany(sql, parameters));
  MssqlCursorSync executeProcedure(String name, Map<String, dynamic> params) {
    _cursor._callSync(() => _cursor._executeProcedure(name, params));
    return this;
  }

  int bulkInsert(
    String table,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  }) => _cursor._callSync(
    () => _cursor._bulkInsert(
      table,
      rows,
      columns: columns,
      batchSize: batchSize,
    ),
  );
  SqlRow? fetchone() => _cursor._callSync(
    () => _cursor._native(() => _cursor._fetchRow(_cursor._rows)),
  );
  dynamic fetchval() => fetchone()?[0];
  List<SqlRow> fetchmany([int? size]) =>
      _cursor._callSync(() => _cursor._fetchRows(size ?? arraysize));
  List<SqlRow> fetchall() => _cursor._callSync(() => _cursor._fetchRows(null));
  void skipRows(int count) => _cursor._callSync(() => _cursor._skipRows(count));
  bool nextset() => _cursor._callSync(_cursor._nextset);
  void cancel() => _cursor._callSync(_cursor._cancelResults);
  void close() => _cursor._close();
  void commit() => _cursor._callSync(() {
    _cursor._validateTransactionControl?.call();
    _cursor._client._commit();
  });
  void rollback() => _cursor._callSync(() {
    _cursor._validateTransactionControl?.call();
    _cursor._client._rollback();
  });
  @override
  Iterator<SqlRow> get iterator => _SyncRowIterator(this);
}

class _SyncRowIterator implements Iterator<SqlRow> {
  final MssqlCursorSync cursor;
  _SyncRowIterator(this.cursor);
  SqlRow? _current;
  @override
  SqlRow get current => _current!;
  @override
  bool moveNext() => (_current = cursor.fetchone()) != null;
}
