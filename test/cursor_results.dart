import 'package:extramobs/mssql.dart';
import 'package:extramobs/packages/mssql/src/mssql_client.dart';

// Test assertions explicitly materialize cursor results; these are not API types.
class ResultSetSnapshot {
  final List<String> columns;
  final List<List<dynamic>> rows;
  ResultSetSnapshot({required this.columns, required this.rows});
}

class ResultSnapshot {
  final List<ResultSetSnapshot> resultSets;
  final int totalAffectedRows;
  final String? error;
  ResultSnapshot({
    required this.resultSets,
    required this.totalAffectedRows,
    this.error,
  });
}

Future<T> withCursor<T>(
  MssqlCursor cursor,
  Future<T> Function(MssqlCursor) action,
) async {
  try {
    return await action(cursor);
  } finally {
    await cursor.close();
  }
}

Future<ResultSnapshot> collectResults(Future<MssqlCursor> execution) async =>
    withCursor(await execution, (cursor) async {
      final sets = <ResultSetSnapshot>[];
      var affected = 0;
      do {
        if (cursor.description != null) {
          final columns = cursor.columns!.toList();
          final rows = await cursor.fetchall();
          sets.add(
            ResultSetSnapshot(
              columns: columns,
              rows: rows.map((r) => r.values.toList()).toList(),
            ),
          );
        }
        if (cursor.rowcount > 0) affected += cursor.rowcount;
      } while (await cursor.nextset());
      return ResultSnapshot(resultSets: sets, totalAffectedRows: affected);
    });

Future<ResultSnapshot> runSql(
  MssqlConnectionAsync db,
  String sql, [
  Object? parameters,
]) => collectResults(db.execute(sql, parameters));

Future<ResultSnapshot> runProcedure(
  MssqlConnectionAsync db,
  String name,
  Map<String, dynamic> parameters,
) => collectResults(db.cursor().executeProcedure(name, parameters));

Future<int> runBulk(
  MssqlConnectionAsync db,
  String table,
  List<Map<String, dynamic>> rows, {
  List<String>? columns,
  int batchSize = 1000,
}) => withCursor(
  db.cursor(),
  (c) => c.bulkInsert(table, rows, columns: columns, batchSize: batchSize),
);

Future<ResultSnapshot> executeOnClient(
  MssqlClient client,
  String sql, [
  Object? parameters,
]) => collectResults(client.execute(sql, parameters));

Future<ResultSnapshot> procedureOnClient(
  MssqlClient client,
  String name,
  Map<String, dynamic> parameters,
) => collectResults(client.cursor().executeProcedure(name, parameters));

Future<int> bulkOnClient(
  MssqlClient client,
  String table,
  List<Map<String, dynamic>> rows, {
  List<String>? columns,
  int batchSize = 1000,
}) => withCursor(
  client.cursor(),
  (c) => c.bulkInsert(table, rows, columns: columns, batchSize: batchSize),
);
