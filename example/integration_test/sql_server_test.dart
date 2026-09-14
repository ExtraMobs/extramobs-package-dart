import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test.dart';

import '../../test/mssql_cursor_integration_test.dart' as cursors;

// Serve test configuration through adb reverse from a local, short-lived HTTP
// endpoint. Credentials stay out of the APK and --dart-define build artifacts.
Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('MSSQL_TEST_CONFIG_URL');
  if (url.isEmpty) throw StateError('MSSQL_TEST_CONFIG_URL is required');
  final client = HttpClient();
  late Map<String, String> configuration;
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    if (response.statusCode != 200) {
      throw StateError('Test configuration unavailable');
    }
    configuration = Map<String, String>.from(
      jsonDecode(await response.transform(utf8.decoder).join()) as Map,
    );
  } finally {
    client.close(force: true);
  }
  cursors.main(configuration: configuration, tablesOnly: true);
}
