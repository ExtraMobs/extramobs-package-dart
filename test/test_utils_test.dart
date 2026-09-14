import 'package:mssql/mssql_connection.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  test(
    'test configuration accepts both host formats and preserves passwords',
    () {
      final explicit = TestDbConfig.fromEnv({
        'MSSQL_IP': 'sql-test.invalid',
        'MSSQL_PORT': '1444',
        'MSSQL_USER': 'tester',
        'MSSQL_PASSWORD': ' test-only password ',
      });
      expect(explicit.ip, 'sql-test.invalid');
      expect(explicit.port, 1444);
      expect(explicit.password, ' test-only password ');
      final legacy = TestDbConfig.fromEnv({
        'MSSQL_SERVER': '[::1]:1445',
        'MSSQL_PASS': 'test-only',
      });
      expect(legacy.ip, '::1');
      expect(legacy.port, 1445);
      expect(legacy.password, 'test-only');
    },
  );

  test('response helpers preserve typed values and affected rows', () {
    final response = ResultSnapshot(
      resultSets: [
        ResultSetSnapshot(
          columns: ['id', 'text', 'optional'],
          rows: [
            [1, 'ação\u0000🙂', null],
          ],
        ),
      ],
      totalAffectedRows: 3,
    );
    expect(parseRows(response), [
      {'id': 1, 'text': 'ação\u0000🙂', 'optional': null},
    ]);
    expect(affectedCount(response), 3);
    expect(
      parseRows(ResultSnapshot(resultSets: [], totalAffectedRows: 0)),
      isEmpty,
    );
  });

  test('response helpers do not hide SQL errors or extra result sets', () {
    final failure = ResultSnapshot(
      resultSets: [],
      totalAffectedRows: 0,
      error: 'SQL failed',
    );
    expect(() => parseRows(failure), throwsA(isA<SQLException>()));
    expect(() => affectedCount(failure), throwsA(isA<SQLException>()));
    final set = ResultSetSnapshot(
      columns: ['id'],
      rows: [
        [1],
      ],
    );
    expect(
      () => parseRows(
        ResultSnapshot(resultSets: [set, set], totalAffectedRows: 0),
      ),
      throwsStateError,
    );
  });
}
