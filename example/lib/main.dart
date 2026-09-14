// ignore_for_file: use_build_context_synchronously

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:mssql/mssql_connection.dart';

void main() {
  runApp(const MyApp());
}

/// Main Root Widget
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "MSSQL Demo",
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1E1E2C),
        primaryColor: Colors.blueAccent,
      ),
      home: const MssqlDemo(),
    );
  }
}

/// Stateful widget to manage tabs & connection
class MssqlDemo extends StatefulWidget {
  const MssqlDemo({super.key});
  @override
  State<MssqlDemo> createState() => _MssqlDemoState();
}

class _MssqlDemoState extends State<MssqlDemo> {
  final MssqlConnectionAsync conn = MssqlConnectionAsync.getInstance();

  int _currentIndex = 0;
  bool _loading = false;
  bool _trustServerCertificate = false;
  String _result = "";

  // Connection fields
  final ipCtrl = TextEditingController(text: "127.0.0.1");
  final portCtrl = TextEditingController(text: "1433");
  final dbCtrl = TextEditingController(text: "master");
  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final caCtrl = TextEditingController(text: 'system');
  final certificateHostCtrl = TextEditingController();

  // Query fields
  final queryCtrl = TextEditingController(text: "SELECT * FROM #Temp");
  final writeCtrl = TextEditingController(
    text: "CREATE TABLE #Temp (id INT PRIMARY KEY, name NVARCHAR(50));",
  );

  // Param query fields
  final paramQueryCtrl = TextEditingController(
    text: "SELECT * FROM #Temp WHERE id=@id",
  );
  final paramExecuteCtrl = TextEditingController(
    text: "insert into #Temp (id, name) values (@id, @name)",
  );
  final paramKeyCtrl = TextEditingController(text: "id");
  final paramValueCtrl = TextEditingController(text: "1");

  /// Store params in a map: key -> controller
  final Map<String, Map<String, TextEditingController>> _params = {
    "query": {"id": TextEditingController()},
    "execute": {"id": TextEditingController(), "name": TextEditingController()},
  };

  @override
  void dispose() {
    for (final controller in [
      ipCtrl,
      portCtrl,
      dbCtrl,
      userCtrl,
      passCtrl,
      caCtrl,
      certificateHostCtrl,
      queryCtrl,
      writeCtrl,
      paramQueryCtrl,
      paramExecuteCtrl,
      paramKeyCtrl,
      paramValueCtrl,
      tableNameCtrl,
      columnsCtrl,
      for (final params in _params.values) ...params.values,
      for (final row in _bulkRows) ...row.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Glassmorphic card wrapper
  Widget _glassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }

  /// Neumorphic styled button
  Widget _neuButton(
    String text,
    VoidCallback onPressed, {
    Color color = Colors.blueAccent,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              offset: const Offset(4, 4),
              blurRadius: 8,
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.1),
              offset: const Offset(-4, -4),
              blurRadius: 8,
            ),
          ],
        ),
        child: Center(
          child: Text(
            text,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  /// Utility for async calls with loader & result
  Future<void> _execute(Future<dynamic> Function() action) async {
    setState(() => _loading = true);
    try {
      final res = await action();
      final text = res is MssqlCursor ? await _readCursor(res) : res.toString();
      if (mounted) setState(() => _result = text);
    } catch (e) {
      setState(() => _result = "❌ Error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color.fromARGB(255, 238, 0, 0),
          duration: const Duration(seconds: 5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
          content: Row(
            children: [
              const Icon(Icons.sentiment_dissatisfied, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "Uh‑oh! That didn’t work 🤹‍♂️\n$e",
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: "OK",
            textColor: Colors.white,
            onPressed: () {},
          ),
        ),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<String> _readCursor(MssqlCursor cursor) async {
    try {
      final output = StringBuffer();
      do {
        if (cursor.description != null) {
          output.writeln(cursor.columns!.join(', '));
          await for (final row in cursor) {
            output.writeln(row.values.join(', '));
          }
        }
        if (cursor.rowcount >= 0) {
          output.writeln('Affected rows: ${cursor.rowcount}');
        }
      } while (await cursor.nextset());
      return output.toString();
    } finally {
      await cursor.close();
    }
  }

  Future<int> _bulkInsert(
    String table,
    List<Map<String, dynamic>> rows, {
    List<String>? columns,
  }) async {
    final cursor = conn.cursor();
    try {
      return await cursor.bulkInsert(table, rows, columns: columns);
    } finally {
      await cursor.close();
    }
  }

  /// Connect Tab
  Widget _buildConnectTab() {
    return _glassCard(
      child: Column(
        children: [
          TextField(
            controller: ipCtrl,
            decoration: const InputDecoration(labelText: "IP"),
          ),
          TextField(
            controller: portCtrl,
            decoration: const InputDecoration(labelText: "Port"),
          ),
          TextField(
            controller: dbCtrl,
            decoration: const InputDecoration(labelText: "Database"),
          ),
          TextField(
            controller: userCtrl,
            decoration: const InputDecoration(labelText: "Username"),
          ),
          TextField(
            controller: passCtrl,
            decoration: const InputDecoration(labelText: "Password"),
            obscureText: true,
          ),
          TextField(
            controller: caCtrl,
            decoration: const InputDecoration(
              labelText: 'Trusted CA: absolute PEM path or system',
            ),
          ),
          SwitchListTile(
            title: const Text('Trust server certificate'),
            subtitle: const Text(
              'Keep TLS; skip certificate and hostname validation',
            ),
            value: _trustServerCertificate,
            onChanged: (value) =>
                setState(() => _trustServerCertificate = value),
          ),
          TextField(
            controller: certificateHostCtrl,
            decoration: const InputDecoration(
              labelText:
                  'Certificate hostname (optional when connecting by name)',
            ),
          ),
          const SizedBox(height: 16),
          _neuButton("Connect", () {
            _execute(
              () => conn
                  .connect(
                    ip: ipCtrl.text,
                    port: portCtrl.text,
                    databaseName: dbCtrl.text,
                    username: userCtrl.text,
                    password: passCtrl.text,
                    tls: TlsRequire(
                      trust: _trustServerCertificate
                          ? null
                          : caCtrl.text.trim() == 'system'
                          ? const TlsSystemTrust()
                          : TlsPemTrust(caCtrl.text.trim()),
                      certificateHostname:
                          certificateHostCtrl.text.trim().isEmpty
                          ? null
                          : certificateHostCtrl.text.trim(),
                    ),
                  )
                  .then((connected) {
                    if (connected) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Connected Successfully"),
                          backgroundColor: Colors.green,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text("Connection Failed"),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                    return connected;
                  }),
            );
          }),
          _neuButton(
            "Disconnect",
            () => _execute(() => conn.disconnect()),
            color: Colors.redAccent,
          ),
        ],
      ),
    );
  }

  /// Query Tab
  Widget _buildQueryTab() {
    return Column(
      children: [
        _glassCard(
          child: Column(
            children: [
              TextField(
                controller: queryCtrl,
                decoration: const InputDecoration(labelText: "SQL Query"),
              ),
              const SizedBox(height: 16),
              _neuButton(
                "Get Data",
                () => _execute(() => conn.execute(queryCtrl.text)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _glassCard(
          child: Column(
            children: [
              TextField(
                controller: writeCtrl,
                decoration: const InputDecoration(labelText: "SQL Query"),
              ),
              const SizedBox(height: 16),
              _neuButton(
                "Write Data",
                () => _execute(() => conn.execute(writeCtrl.text)),
                color: Colors.green,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Param Query Tab
  Widget _buildParamQueryTab() {
    return Column(
      children: [
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: paramQueryCtrl,
                decoration: const InputDecoration(
                  labelText: "SQL with Params (@key)",
                ),
                onChanged: (_) =>
                    _updateParamsFromQuery(paramQueryCtrl.text, "query"),
              ),
              const SizedBox(height: 16),
              ..._paramRows("query"),
              const SizedBox(height: 16),
              _neuButton(
                "Get Data with Params",
                () => _execute(
                  () => conn.execute(paramQueryCtrl.text, {
                    for (var e in _params["query"]!.entries)
                      e.key: e.value.text,
                  }),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: paramExecuteCtrl,
                decoration: const InputDecoration(
                  labelText: "SQL with Params (@key)",
                ),
                onChanged: (_) =>
                    _updateParamsFromQuery(paramExecuteCtrl.text, "execute"),
              ),
              const SizedBox(height: 16),
              ..._paramRows("execute"),
              const SizedBox(height: 16),
              _neuButton(
                "Write Data with Params",
                () => _execute(
                  () => conn.execute(paramExecuteCtrl.text, {
                    for (var e in _params["execute"]!.entries)
                      e.key: e.value.text,
                  }),
                ),
                color: Colors.green,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Extract params from SQL and sync with map
  void _updateParamsFromQuery(String query, String type) {
    final regex = RegExp(r'@(\w+)');
    final matches = regex.allMatches(query);

    // Collect found keys
    final foundKeys = matches.map((m) => m.group(1)!).toSet();

    // Remove params not in query anymore
    _params[type]!.keys.where((k) => !foundKeys.contains(k)).toList().forEach((
      k,
    ) {
      _params[type]!.remove(k);
    });

    // Add new params
    for (var key in foundKeys) {
      if (!_params[type]!.containsKey(key)) {
        _params[type]![key] = TextEditingController();
      }
    }

    setState(() {});
  }

  /// Build param input rows
  List<Widget> _paramRows(String type) {
    return _params[type]!.entries.map((entry) {
      return Row(
        children: [
          // Disabled param key
          Expanded(
            child: TextField(
              enabled: false,
              decoration: InputDecoration(
                labelText: "Param",
                hintText: entry.key,
              ),
              controller: TextEditingController(text: entry.key),
            ),
          ),
          const SizedBox(width: 10),
          // Editable value
          Expanded(
            child: TextField(
              controller: entry.value,
              decoration: const InputDecoration(labelText: "Value"),
            ),
          ),
        ],
      );
    }).toList();
  }

  // Bulk Insert Tab State
  final tableNameCtrl = TextEditingController(text: "#Temp");
  final columnsCtrl = TextEditingController(text: "id, name");

  List<Map<String, TextEditingController>> _bulkRows = [];

  /// Bulk Insert Tab (newbie friendly)
  Widget _buildBulkInsertTab() {
    // Parse column names
    final columns = columnsCtrl.text
        .split(',')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();

    // Ensure we have at least 1 row
    if (_bulkRows.isEmpty) {
      _bulkRows.add({for (var col in columns) col: TextEditingController()});
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Step 1: Table & Columns",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tableNameCtrl,
                decoration: const InputDecoration(labelText: "Table Name"),
                onChanged: (_) => setState(() {}), // rebuild on change
              ),
              TextField(
                controller: columnsCtrl,
                decoration: const InputDecoration(
                  labelText: "Columns (comma separated)",
                ),
                onChanged: (_) {
                  // Reset rows when columns change
                  setState(() {
                    _bulkRows = [
                      {for (var c in columns) c: TextEditingController()},
                    ];
                  });
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Step 2: Enter row values
        _glassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Step 2: Enter Row Values",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ..._bulkRows.asMap().entries.map((entry) {
                final rowIndex = entry.key;
                final controllers = entry.value;

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  color: Colors.black26,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Text(
                          "Row ${rowIndex + 1}",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blueAccent,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...columns.map((col) {
                          if (!controllers.containsKey(col)) {
                            controllers[col] = TextEditingController();
                          }
                          return TextField(
                            controller: controllers[col],
                            decoration: InputDecoration(labelText: col),
                          );
                        }),
                        if (_bulkRows.length > 1)
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () {
                                setState(() => _bulkRows.removeAt(rowIndex));
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
              _neuButton("➕ Add Row", () {
                setState(() {
                  _bulkRows.add({
                    for (var c in columns) c: TextEditingController(),
                  });
                });
              }),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Step 3: Insert Button
        _glassCard(
          child: Column(
            children: [
              const Text(
                "Step 3: Insert Rows",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _neuButton("🚀 Insert Data", () {
                final rows = _bulkRows.map((rowCtrls) {
                  return {
                    for (var entry in rowCtrls.entries)
                      entry.key: entry.value.text,
                  };
                }).toList();

                _execute(
                  () => _bulkInsert(tableNameCtrl.text, rows, columns: columns),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  /// Transactions Tab
  Widget _buildTransactionsTab() {
    final connected = conn.isConnected;
    final automatic = connected && conn.autocommit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Autocommit'),
          value: automatic,
          onChanged: !connected || _loading
              ? null
              : (value) async {
                  if (value) {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Commit pending changes?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Commit'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !mounted) return;
                  }
                  await _execute(() async {
                    await conn.setAutocommit(value);
                    return value
                        ? 'Autocommit enabled'
                        : 'Manual commit enabled';
                  });
                },
        ),
        Wrap(
          spacing: 12,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('Commit'),
              onPressed: !connected || automatic || _loading
                  ? null
                  : () => _execute(() async {
                      await conn.commit();
                      return 'Transaction committed';
                    }),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.undo),
              label: const Text('Rollback'),
              onPressed: !connected || automatic || _loading
                  ? null
                  : () => _execute(() async {
                      await conn.rollback();
                      return 'Transaction rolled back';
                    }),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Callback transaction'),
              onPressed: !automatic || _loading
                  ? null
                  : () => _execute(
                      () => conn.transaction((tx) async {
                        return _readCursor(
                          await tx.execute('SELECT 1 AS transaction_example'),
                        );
                      }),
                    ),
            ),
          ],
        ),
      ],
    );
  }

  /// Tab content builder
  Widget _buildTab() {
    switch (_currentIndex) {
      case 0:
        return _buildConnectTab();
      case 1:
        return _buildQueryTab();
      case 2:
        return _buildParamQueryTab();
      case 3:
        return _buildBulkInsertTab();
      case 4:
        return _buildTransactionsTab();
      default:
        return const SizedBox();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("MSSQL Client Demo"),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Center(child: SingleChildScrollView(child: _buildTab())),
          if (_loading)
            Container(
              color: Colors.black.withValues(alpha: 0.4),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.black.withValues(alpha: 0.7),
        selectedItemColor: Colors.blueAccent,
        unselectedItemColor: Colors.grey,
        currentIndex: _currentIndex,
        onTap: (i) {
          if (i > 0 && !conn.isConnected) {
            // show snackbar if not connected
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("⚠️ Please connect to the server first!"),
                backgroundColor: Colors.redAccent,
                behavior: SnackBarBehavior.floating,
              ),
            );
            return; // don’t switch tab
          }
          setState(() => _currentIndex = i);
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.cloud), label: "Connect"),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: "Queries"),
          BottomNavigationBarItem(icon: Icon(Icons.code), label: "Params"),
          BottomNavigationBarItem(icon: Icon(Icons.table_chart), label: "Bulk"),
          BottomNavigationBarItem(
            icon: Icon(Icons.compare_arrows),
            label: "Tx",
          ),
        ],
      ),
      floatingActionButton: _result.isNotEmpty
          ? FloatingActionButton(
              backgroundColor: Colors.blueAccent,
              child: const Icon(Icons.output),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text("Result"),
                    content: SingleChildScrollView(
                      child: Text(
                        _result,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    actions: [
                      TextButton(
                        child: const Text("Close"),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                );
              },
            )
          : null,
    );
  }
}
