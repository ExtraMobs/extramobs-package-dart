part of 'mssql_client.dart';

/// A forward-only cursor. Iteration and fetches share the same position.
/// Close explicitly in finally; breaking iteration does not close the cursor.
class _NativeCursor extends MssqlCursor {
  final MssqlClient _client;
  final DBLib _db;
  final Pointer<DBPROCESS> _proc;
  final void Function()? _validate;
  final Future<T> Function<T>(FutureOr<T> Function())? _schedule;
  final void Function()? _validateTransactionControl;
  final _released = Completer<void>();
  _ResultReader? _reader;
  bool _closed = false;
  int _arraysize = 1;

  _NativeCursor(
    this._client,
    this._db,
    this._proc,
    this._validate,
    this._schedule,
    this._validateTransactionControl,
  );

  @override
  bool get isClosed => _closed;
  @override
  Future<void> get done => _released.future;

  @override
  int get arraysize => _arraysize;
  @override
  set arraysize(int value) {
    if (value <= 0) throw ArgumentError.value(value, 'arraysize');
    _arraysize = value;
  }

  @override
  List<SqlColumn>? get description => _reader?.description;
  @override
  List<String>? get columns => _reader?.columns;

  /// Native affected-row count; -1 when unknown or after executemany.
  @override
  int get rowcount => _reader?.rowcount ?? -1;

  Future<T> _call<T>(T Function() action) {
    try {
      if (_closed) throw StateError('Cursor is closed');
      _validate?.call();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    Future<T> run() => _client._run(() => _callSync(action));
    return _schedule == null ? run() : _schedule(run);
  }

  T _callSync<T>(T Function() action) {
    if (_closed) throw StateError('Cursor is closed');
    _validate?.call();
    if (_client._dbproc != _proc) {
      _finish();
      throw StateError('Cursor session is no longer connected');
    }
    try {
      return action();
    } finally {
      if (_reader?.finished == true && identical(_client._activeCursor, this)) {
        _client._activeCursor = null;
      }
    }
  }

  T _native<T>(T Function() action) => _client._operation((_, _) => action());

  void _claim() {
    final active = _client._activeCursor;
    if (active != null &&
        !identical(active, this) &&
        active._reader?.finished != true) {
      throw StateError(
        'Another cursor has unread results. Fetch, cancel or close it first.',
      );
    }
  }

  /// Executes SQL and returns this cursor. Positional parameters use '?' and a
  /// List. A Map of named '@parameters' remains available as a FreeTDS extension.
  @override
  Future<MssqlCursor> execute(String sql, [Object? parameters]) =>
      _call(() => _execute(sql, parameters));

  MssqlCursor _execute(String sql, Object? parameters) {
    if (sql.contains('\u0000')) throw ArgumentError('SQL cannot contain NUL');
    final values = parameters == null
        ? null
        : _client._sqlParams(sql, parameters);
    _claim();
    _cancelResults();
    _client._activeCursor = this;
    if (values == null) {
      _client._sendSql(sql);
    } else {
      _client._sendRpc('sp_executesql', values);
    }
    _startResults();
    return this;
  }

  /// Executes each parameter sequence lazily. Prior executions may be committed
  /// if a later one fails; use a transaction for an atomic batch. rowcount is -1.
  @override
  Future<void> executemany(String sql, Iterable<Object> parameters) =>
      _call(() => _executemany(sql, parameters));

  void _executemany(String sql, Iterable<Object> parameters) {
    for (final values in parameters) {
      _execute(sql, values);
      _drain();
    }
    _cancelResults();
  }

  /// Direct RPC extension; procedures can also be called with execute('EXEC ...').
  @override
  Future<MssqlCursor> executeProcedure(
    String name,
    Map<String, dynamic> params,
  ) => _call(() => _executeProcedure(name, params));

  MssqlCursor _executeProcedure(String name, Map<String, dynamic> params) {
    final procedure = quoteSqlName(name);
    final values = _normalizeParams(
      params,
    ).entries.map((e) => (e.key, e.value)).toList();
    _claim();
    _cancelResults();
    _client._activeCursor = this;
    _client._sendRpc(procedure, values);
    _startResults();
    return this;
  }

  /// FreeTDS bulk extension. SQL execution and all result ownership remain here.
  @override
  Future<int> bulkInsert(
    String table,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  }) => _call(
    () => _bulkInsert(table, rows, columns: columns, batchSize: batchSize),
  );

  int _bulkInsert(
    String table,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  }) {
    _claim();
    _cancelResults();
    return _client._bulkInsert(
      table,
      rows,
      columns: columns,
      batchSize: batchSize,
    );
  }

  void _startResults() {
    _reader = _ResultReader(_client, _db, _proc);
    _native(_reader!.nextset);
    if (_reader!.finished) _client._activeCursor = null;
  }

  _ResultReader get _rows {
    final reader = _reader;
    if (reader == null || reader.description == null) {
      throw StateError('The current command has no row result');
    }
    return reader;
  }

  @override
  Future<SqlRow?> fetchone() => _call(() {
    final reader = _rows;
    return _native(() => _fetchRow(reader));
  });

  @override
  Future<List<SqlRow>> fetchmany([int? size]) =>
      _call(() => _fetchRows(size ?? arraysize));

  @override
  Future<List<SqlRow>> fetchall() => _call(() => _fetchRows(null));

  SqlRow? _fetchRow(_ResultReader reader) {
    final values = reader.fetchone();
    return values == null
        ? null
        : SqlRow(columns: reader.columns!, values: values);
  }

  List<SqlRow> _fetchRows(int? count) {
    if (count != null && count < 0) throw ArgumentError.value(count, 'size');
    final reader = _rows;
    return _native(() {
      final rows = <SqlRow>[];
      while (count == null || rows.length < count) {
        final row = _fetchRow(reader);
        if (row == null) break;
        rows.add(row);
      }
      return rows;
    });
  }

  /// Discards at most count rows, sharing the current fetch position.
  @override
  Future<void> skipRows(int count) => _call(() => _skipRows(count));

  void _skipRows(int count) {
    if (count < 0) throw ArgumentError.value(count, 'count');
    final reader = _rows;
    _native(() {
      for (var i = 0; i < count; i++) {
        if (reader.fetchone() == null) break;
      }
    });
  }

  @override
  Future<bool> nextset() => _call(_nextset);

  bool _nextset() {
    final reader = _reader;
    if (reader == null) throw StateError('Execute a command first');
    return _native(reader.nextset);
  }

  void _drain() {
    final reader = _reader;
    if (reader == null) return;
    _native(() {
      while (reader.nextset()) {}
    });
    if (identical(_client._activeCursor, this)) _client._activeCursor = null;
  }

  /// Discards this command's pending results, keeping the cursor reusable.
  @override
  Future<void> cancel() => _call(_cancelResults);

  /// Commits the connection's transaction, including writes by other cursors.
  @override
  Future<void> commit() => _call(() {
    _validateTransactionControl?.call();
    _client._commit();
  });

  /// Rolls back the connection's transaction, including writes by other cursors.
  @override
  Future<void> rollback() => _call(() {
    _validateTransactionControl?.call();
    _client._rollback();
  });

  void _cancelResults() {
    if (_reader != null && !_reader!.finished) {
      _native(() {
        _client._check('dbcancel', () => _db.dbcancel(_proc));
        // FreeTDS 1.5.4's dbcancel does not propagate transport failures.
        _client._checked(
          'dbcancel session',
          () => _db.dbdead(_proc),
          (v) => v == 0,
        );
      });
    }
    _reader = null;
    if (identical(_client._activeCursor, this)) _client._activeCursor = null;
  }

  @override
  Future<void> close() => _client._run(_close);

  void _close() {
    if (_closed) return;
    try {
      if (_client._dbproc == _proc) _cancelResults();
    } finally {
      _finish();
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    _reader = null;
    _client._cursors.remove(this);
    if (identical(_client._activeCursor, this)) _client._activeCursor = null;
    _released.complete();
  }
}

typedef _ResultInfo = ({
  List<SqlColumn>? description,
  List<String>? columns,
  int rowcount,
});

/// Peeks only at the next result's metadata after EOF. This lets fully consumed
/// commands release the native session while preserving nextset semantics.
class _ResultReader {
  final MssqlClient client;
  final DBLib db;
  final Pointer<DBPROCESS> proc;
  _ResultInfo? _current, _next;
  bool _peeked = false, _rowsDone = true;
  int _rowCount = 0, _bytes = 0;

  _ResultReader(this.client, this.db, this.proc);
  List<SqlColumn>? get description => _current?.description;
  List<String>? get columns => _current?.columns;
  int get rowcount => _current?.rowcount ?? -1;
  bool get finished => _peeked && _next == null;

  _ResultInfo? _readResult() {
    final result = client._checked(
      'dbresults',
      () => db.dbresults(proc),
      (rc) => rc == SUCCEED || rc == NO_MORE_RESULTS,
    );
    if (result == NO_MORE_RESULTS) return null;
    final count = db.dbnumcols(proc);
    if (count < 0) throw SQLException('Invalid column count');
    final description = count == 0
        ? null
        : List<SqlColumn>.unmodifiable([
            for (var i = 1; i <= count; i++)
              SqlColumn(
                name: fromNativeFreeTdsText(db.dbcolname(proc, i)),
                typeCode: db.dbcoltype(proc, i),
              ),
          ]);
    return (
      description: description,
      columns: description == null
          ? null
          : List<String>.unmodifiable(description.map((c) => c.name)),
      rowcount: db.dbcount(proc),
    );
  }

  void _peek() {
    _next = _readResult();
    _peeked = true;
  }

  bool nextset() {
    if (_peeked) {
      _current = _next;
      _next = null;
      _peeked = false;
    } else {
      if (!_rowsDone) client._check('dbcanquery', () => db.dbcanquery(proc));
      _current = _readResult();
    }
    _rowsDone = description == null;
    if (_current == null) {
      _peeked = true;
      return false;
    }
    if (_rowsDone) _peek();
    return true;
  }

  List<dynamic>? fetchone() {
    if (_rowsDone) return null;
    final next = client._checked(
      'dbnextrow',
      () => db.dbnextrow(proc),
      (rc) => rc == REG_ROW || rc == NO_MORE_ROWS,
    );
    if (next == NO_MORE_ROWS) {
      _rowsDone = true;
      _current = (
        description: description,
        columns: columns,
        rowcount: db.dbcount(proc),
      );
      _peek();
      return null;
    }
    if (++_rowCount > client.maxResultRows) {
      throw SQLException('Result row limit exceeded');
    }
    final values = <dynamic>[];
    for (var i = 1; i <= description!.length; i++) {
      final len = db.dbdatlen(proc, i);
      if (len < 0) throw SQLException('Invalid column length');
      _bytes += len;
      if (_bytes > client.maxResultBytes) {
        throw SQLException('Result byte limit exceeded');
      }
      values.add(
        decodeDbValueWithFallback(
          db,
          proc,
          description![i - 1].typeCode,
          db.dbdata(proc, i),
          len,
        ),
      );
    }
    return values;
  }
}
