/// Column metadata for the current cursor result. [typeCode] is a DB-Lib code.
class SqlColumn {
  final String name;
  final int typeCode;

  const SqlColumn({required this.name, required this.typeCode});
}

/// A decoded row that remains valid after fetching again or closing the cursor.
/// Values can be replaced, but the column count and names are fixed.
/// Binary SQL values are copied, unmodifiable Uint8List instances; NULL is null.
class SqlRow {
  final List<String> columns;
  final List<dynamic> values;

  SqlRow({required List<String> columns, required List<dynamic> values})
    : columns = List.unmodifiable(columns),
      values = List.of(values, growable: false);

  /// Access by zero-based position or exact column name (first duplicate wins).
  dynamic operator [](Object column) => values[_index(column)];

  /// Replaces a local value; this does not write to the database.
  void operator []=(Object column, dynamic value) =>
      values[_index(column)] = value;

  int _index(Object column) {
    if (column is int) return column;
    if (column is String) {
      final index = columns.indexOf(column);
      if (index >= 0) return index;
    }
    throw ArgumentError.value(column, 'column', 'Unknown column');
  }

  @override
  String toString() => values.toString();
}
