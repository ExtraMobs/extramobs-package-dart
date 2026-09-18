import 'dart:async';

import 'sql_row.dart';

/// A forward-only cursor. Fetches and stream iteration share one position.
/// Close in finally; breaking iteration does not close the cursor.
abstract class MssqlCursor extends Stream<SqlRow> {
  bool get isClosed;
  Future<void> get done;
  int get arraysize;
  set arraysize(int value);
  List<SqlColumn>? get description;
  List<String>? get columns;
  int get rowcount;
  Future<MssqlCursor> execute(String sql, [Object? parameters]);
  Future<void> executemany(String sql, Iterable<Object> parameters);
  Future<MssqlCursor> executeProcedure(
    String name,
    Map<String, dynamic> params,
  );
  Future<int> bulkInsert(
    String table,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
    int batchSize = 1000,
  });
  Future<SqlRow?> fetchone();
  Future<dynamic> fetchval() async => (await fetchone())?[0];
  Future<List<SqlRow>> fetchmany([int? size]);
  Future<List<SqlRow>> fetchall();
  Future<void> skipRows(int count);
  Future<bool> nextset();
  Future<void> cancel();
  Future<void> close();
  Future<void> commit();
  Future<void> rollback();
  Stream<SqlRow> fetchStream() => this;

  Stream<SqlRow> _iterate() async* {
    while (true) {
      final row = await fetchone();
      if (row == null) return;
      yield row;
    }
  }

  @override
  StreamSubscription<SqlRow> listen(
    void Function(SqlRow)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _iterate().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
