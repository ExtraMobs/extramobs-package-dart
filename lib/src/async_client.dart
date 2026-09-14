part of 'mssql_connection.dart';

enum _Op {
  connect,
  disconnect,
  execute,
  procedure,
  many,
  bulk,
  one,
  manyRows,
  all,
  skip,
  next,
  cancel,
  close,
  commit,
  rollback,
  autocommit,
  shutdown,
}

typedef _CursorState = ({
  bool closed,
  List<SqlColumn>? description,
  List<String>? columns,
  int rowcount,
});
typedef _Reply = ({
  Object? value,
  String? errorType,
  String? error,
  String? stack,
  bool connected,
  bool? autocommit,
  _CursorState? cursor,
});

/// One worker per calling isolate; DB-Lib enforces one owner per process.
/// Keep it alive between disconnect/reconnect: native callbacks belong to it.
class _AsyncWorker {
  static SendPort? _commands;
  static ReceivePort? _responses;
  static Future<void>? _starting;
  static Object? _failure;
  static int _nextRequest = 0, nextClient = 0;
  static final _pending = <int, Completer<_Reply>>{};

  static Future<void> _start() async {
    final ready = Completer<SendPort>();
    final responses = _responses = ReceivePort();
    responses.listen((dynamic message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message == null || message is List) {
        final error = StateError('SQL worker stopped: $message');
        if (!ready.isCompleted) ready.completeError(error);
        _fail(error);
      } else {
        final (id, reply) = message as (int, _Reply);
        _pending.remove(id)?.complete(reply);
      }
    });
    try {
      await Isolate.spawn(
        _main,
        responses.sendPort,
        onError: responses.sendPort,
        onExit: responses.sendPort,
      );
      _commands = await ready.future;
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  static void _fail(Object error) {
    _failure = error;
    _commands = null;
    _responses?.close();
    _responses = null;
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    for (final client in _AsyncClient._live.toList()) {
      client._invalidate();
    }
  }

  static Future<_Reply> send(
    int client,
    int? cursor,
    _Op op, [
    List<Object?> args = const [],
  ]) async {
    if (_failure != null) throw _failure!;
    await (_starting ??= _start());
    if (_failure != null) throw _failure!;
    final id = _nextRequest++;
    final pending = Completer<_Reply>();
    _pending[id] = pending;
    try {
      _commands!.send((id, client, cursor, op, args));
    } catch (_) {
      _pending.remove(id);
      rethrow;
    }
    return pending.future;
  }

  static Future<void> shutdown() async {
    if (_starting == null || _failure != null) return;
    final reply = await send(-1, null, _Op.shutdown);
    _fail(
      StateError('SQL worker was shut down; start a new process to reopen it'),
    );
    if (reply.error != null) throw StateError(reply.error!);
  }

  static void _main(SendPort owner) {
    final commands = ReceivePort();
    final sessions = <int, MssqlConnection>{};
    final cursors = <int, Map<int, MssqlCursorSync>>{};
    owner.send(commands.sendPort);
    commands.listen((dynamic raw) {
      final (id, clientId, cursorId, op, args) =
          raw as (int, int, int?, _Op, List<Object?>);
      MssqlConnection? connection = sessions[clientId];
      MssqlCursorSync? cursor;
      Object? value;
      String? errorType, error, stack;
      try {
        if (op == _Op.shutdown) {
          try {
            for (final session in sessions.values) {
              session.close();
            }
          } finally {
            sessions.clear();
            cursors.clear();
            commands.close();
          }
        } else if (op == _Op.connect) {
          final options = args[0] as Map<String, Object?>;
          NativeLoader.libraryDirectory =
              options['libraryDirectory'] as String?;
          connection ??= MssqlConnection();
          sessions[clientId] = connection;
          cursors[clientId] = {};
          final connected = connection.connect(
            ip: options['ip'] as String,
            port: options['port'] as String,
            databaseName: '',
            username: options['username'] as String,
            password: options['password'] as String,
            timeoutInSeconds: options['timeoutInSeconds'] as int,
            queryTimeoutSeconds: options['queryTimeoutSeconds'] as int,
            tls: options['tls'] as TlsConfig?,
            maxResultRows: options['maxResultRows'] as int,
            maxResultBytes: options['maxResultBytes'] as int,
            autocommit: options['autocommit'] as bool,
          );
          value = (
            connected: connected,
            certificate: connection.peerCertificate,
          );
        } else if (op == _Op.disconnect) {
          sessions.remove(clientId)?.close();
          cursors.remove(clientId);
          value = true;
        } else {
          if (connection == null) throw StateError('Not connected');
          if (cursorId != null) {
            cursor = cursors[clientId]!.putIfAbsent(
              cursorId,
              connection.cursor,
            );
          }
          switch (op) {
            case _Op.execute:
              cursor!.execute(args[0] as String, args[1]);
            case _Op.procedure:
              cursor!.executeProcedure(
                args[0] as String,
                args[1] as Map<String, dynamic>,
              );
            case _Op.many:
              cursor!.executemany(args[0] as String, args[1] as List<Object>);
            case _Op.bulk:
              value = cursor!.bulkInsert(
                args[0] as String,
                args[1] as List<Map<String, dynamic>>,
                columns: args[2] as List<String>?,
                batchSize: args[3] as int,
              );
            case _Op.one:
              value = cursor!.fetchone();
            case _Op.manyRows:
              value = cursor!.fetchmany(args[0] as int);
            case _Op.all:
              value = cursor!.fetchall();
            case _Op.skip:
              cursor!.skipRows(args[0] as int);
            case _Op.next:
              value = cursor!.nextset();
            case _Op.cancel:
              cursor!.cancel();
            case _Op.close:
              cursor!.close();
              cursors[clientId]!.remove(cursorId);
            case _Op.commit:
              if (cursor != null) {
                cursor.commit();
              } else {
                connection.commit();
              }
            case _Op.rollback:
              if (cursor != null) {
                cursor.rollback();
              } else {
                connection.rollback();
              }
            case _Op.autocommit:
              connection.setAutocommit(args[0] as bool);
            default:
              throw StateError('Unsupported operation: $op');
          }
        }
      } catch (exception, trace) {
        errorType = switch (exception) {
          SQLException() => 'sql',
          StateError() => 'state',
          RangeError() => 'range',
          ArgumentError() => 'argument',
          FormatException() => 'format',
          UnsupportedError() => 'unsupported',
          _ => 'other',
        };
        error = exception is SQLException
            ? exception.message
            : exception.toString();
        stack = trace.toString();
      }
      final connected = connection?.isConnected == true;
      if (!connected) cursors[clientId]?.clear();
      final _Reply reply = (
        value: value,
        errorType: errorType,
        error: error,
        stack: stack,
        connected: connected,
        autocommit: connected ? connection!.autocommit : null,
        cursor: cursor == null
            ? null
            : (
                closed: cursor.isClosed,
                description: cursor.description,
                columns: cursor.columns,
                rowcount: cursor.rowcount,
              ),
      );
      owner.send((id, reply));
    });
  }
}

class _AsyncClient {
  static final _live = <_AsyncClient>{};
  final int _id = _AsyncWorker.nextClient++;
  final Map<String, Object?> _options;
  final _cursors = <_RemoteCursor>{};
  int _nextCursor = 0;
  bool _connected = false, _autocommit = false;
  TlsCertificate? peerCertificate;
  Future<void> _tail = Future.value();
  _AsyncClient({
    required String server,
    required String username,
    required String password,
    TlsConfig? tls,
    required int queryTimeoutSeconds,
    required int maxResultRows,
    required int maxResultBytes,
    required bool autocommit,
  }) : _options = {
         'ip': server.substring(0, server.lastIndexOf(':')),
         'port': server.substring(server.lastIndexOf(':') + 1),
         'username': username,
         'password': password,
         'tls': tls,
         'queryTimeoutSeconds': queryTimeoutSeconds,
         'maxResultRows': maxResultRows,
         'maxResultBytes': maxResultBytes,
         'autocommit': autocommit,
       };
  bool get isConnected => _connected && _AsyncWorker._failure == null;
  bool get autocommit => _autocommit;

  void _invalidate() {
    peerCertificate = null;
    _connected = false;
    _live.remove(this);
    for (final cursor in _cursors.toList()) {
      cursor._finish();
    }
  }

  Future<bool> connect({int loginTimeoutSeconds = 15}) async {
    // Preserve the existing false result for DNS/unreachable hosts, without FFI.
    final host = (_options['ip'] as String).replaceAll(RegExp(r'^\[|\]$'), '');
    try {
      final socket = await Socket.connect(
        host,
        int.parse(_options['port'] as String),
        timeout: Duration(seconds: loginTimeoutSeconds),
      );
      socket.destroy();
    } on SocketException {
      return false;
    }
    final options = {
      ..._options,
      'timeoutInSeconds': loginTimeoutSeconds,
      'libraryDirectory': NativeLoader.libraryDirectory,
    };
    final result =
        await _send(null, _Op.connect, [options])
            as ({bool connected, TlsCertificate? certificate});
    peerCertificate = result.certificate;
    return result.connected;
  }

  Future<Object?> _send(
    _RemoteCursor? cursor,
    _Op op, [
    List<Object?> args = const [],
  ]) {
    final next = _tail.then((_) async {
      try {
        final reply = await _AsyncWorker.send(_id, cursor?._id, op, args);
        _connected = reply.connected;
        _autocommit = reply.autocommit ?? _autocommit;
        if (cursor != null && reply.cursor != null) {
          cursor._state = reply.cursor!;
        }
        if (!reply.connected) {
          _invalidate();
        } else {
          _live.add(this);
          if (cursor?.isClosed == true) cursor!._finish();
        }
        if (reply.error != null) {
          final error = switch (reply.errorType) {
            'sql' => SQLException(reply.error!),
            'state' => StateError(reply.error!),
            'range' => RangeError(reply.error!),
            'argument' => ArgumentError(reply.error!),
            'format' => FormatException(reply.error!),
            'unsupported' => UnsupportedError(reply.error!),
            _ => Exception(reply.error!),
          };
          Error.throwWithStackTrace(error, StackTrace.fromString(reply.stack!));
        }
        return reply.value;
      } catch (_) {
        if (_AsyncWorker._failure != null) {
          _invalidate();
        }
        rethrow;
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  MssqlCursor cursor({
    void Function()? validate,
    Future<T> Function<T>(FutureOr<T> Function())? schedule,
    void Function()? validateTransactionControl,
  }) {
    if (!isConnected) throw StateError('Not connected');
    final cursor = _RemoteCursor(
      this,
      _nextCursor++,
      validate,
      schedule,
      validateTransactionControl,
    );
    _cursors.add(cursor);
    return cursor;
  }

  Future<MssqlCursor> execute(String sql) async {
    final current = cursor();
    try {
      return await current.execute(sql);
    } catch (_) {
      await current.close();
      rethrow;
    }
  }

  Future<void> close() async {
    _options
        .clear(); // Do not retain credentials after a connection is discarded.
    if (_AsyncWorker._starting != null && _AsyncWorker._failure == null) {
      await _send(null, _Op.disconnect);
    }
    _invalidate();
  }

  Future<void> commit() async {
    await _send(null, _Op.commit);
  }

  Future<void> rollback() async {
    await _send(null, _Op.rollback);
  }

  Future<void> setAutocommit(bool value) async {
    await _send(null, _Op.autocommit, [value]);
  }
}

class _RemoteCursor extends MssqlCursor {
  final _AsyncClient _client;
  final int _id;
  final void Function()? _validate, _validateTransactionControl;
  final Future<T> Function<T>(FutureOr<T> Function())? _schedule;
  final _released = Completer<void>();
  _CursorState _state = (
    closed: false,
    description: null,
    columns: null,
    rowcount: -1,
  );
  int _arraysize = 1;
  _RemoteCursor(
    this._client,
    this._id,
    this._validate,
    this._schedule,
    this._validateTransactionControl,
  );
  @override
  bool get isClosed => _state.closed;
  @override
  Future<void> get done => _released.future;
  @override
  List<SqlColumn>? get description => _state.description;
  @override
  List<String>? get columns => _state.columns;
  @override
  int get rowcount => _state.rowcount;
  @override
  int get arraysize => _arraysize;
  @override
  set arraysize(int value) {
    if (value <= 0) throw ArgumentError.value(value, 'arraysize');
    _arraysize = value;
  }

  Future<T> _call<T>(Future<T> Function() action) {
    void validate() {
      if (isClosed) throw StateError('Cursor is closed');
      _validate?.call();
    }

    try {
      validate();
    } catch (e, s) {
      return Future.error(e, s);
    }
    Future<T> run() {
      validate();
      return action();
    }

    return _schedule == null ? Future.sync(run) : _schedule(run);
  }

  @override
  Future<MssqlCursor> execute(String sql, [Object? parameters]) =>
      _call(() async {
        await _client._send(this, _Op.execute, [sql, parameters]);
        return this;
      });
  @override
  Future<MssqlCursor> executeProcedure(
    String name,
    Map<String, dynamic> params,
  ) => _call(() async {
    await _client._send(this, _Op.procedure, [name, params]);
    return this;
  });
  @override
  Future<void> executemany(String sql, Iterable<Object> parameters) =>
      _call(() async {
        for (final row in parameters) {
          await _client._send(this, _Op.many, [
            sql,
            [row],
          ]);
        }
        await _client._send(this, _Op.many, [sql, <Object>[]]);
      });
  @override
  Future<int> bulkInsert(
    String table,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  }) => _call(
    () async =>
        await _client._send(this, _Op.bulk, [table, rows, columns, batchSize])
            as int,
  );
  @override
  Future<SqlRow?> fetchone() =>
      _call(() async => await _client._send(this, _Op.one) as SqlRow?);
  @override
  Future<List<SqlRow>> fetchmany([int? size]) => _call(
    () async =>
        await _client._send(this, _Op.manyRows, [size ?? arraysize])
            as List<SqlRow>,
  );
  @override
  Future<List<SqlRow>> fetchall() =>
      _call(() async => await _client._send(this, _Op.all) as List<SqlRow>);
  @override
  Future<void> skipRows(int count) => _call(() async {
    await _client._send(this, _Op.skip, [count]);
  });
  @override
  Future<bool> nextset() =>
      _call(() async => await _client._send(this, _Op.next) as bool);
  @override
  Future<void> cancel() => _call(() async {
    await _client._send(this, _Op.cancel);
  });
  @override
  Future<void> commit() => _call(() async {
    _validateTransactionControl?.call();
    await _client._send(this, _Op.commit);
  });
  @override
  Future<void> rollback() => _call(() async {
    _validateTransactionControl?.call();
    await _client._send(this, _Op.rollback);
  });
  @override
  Future<void> close() async {
    if (isClosed) return;
    await _client._send(this, _Op.close);
  }

  void _finish() {
    _state = (closed: true, description: null, columns: null, rowcount: -1);
    _client._cursors.remove(this);
    if (!_released.isCompleted) _released.complete();
  }
}
