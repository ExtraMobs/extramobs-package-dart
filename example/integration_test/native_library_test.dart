import 'package:integration_test/integration_test.dart';

import '../../test/native_library_test.dart' as native;

// Uses the installed application's libraries, including Android's linker
// namespace and Linux's lib/ bundle. No external SQL Server is required.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  native.main(useBundledLibrary: true);
}
