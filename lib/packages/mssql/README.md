# Notice

This package was made entirely with AI, including this document, except for this opening notice.
Because this is a low-level FFI integration project with a very small scope, I used Claude, Codex, and others to build it, requiring them to be very rigorous with testing.

Pull requests and issues will still be reviewed and implemented.

Linux and Android implementations are planned goals.

# mssql

A Flutter/Dart SQL Server client using Dart FFI and bundled FreeTDS 1.5.4.
Its cursor-oriented API is guided by the pyodbc
[Cursor](https://github.com/mkleehammer/pyodbc/wiki/Cursor) and
[Connection](https://github.com/mkleehammer/pyodbc/wiki/Connection) documentation.
It is neither an ODBC driver nor a complete implementation of pyodbc.

## Installation

The package is named `mssql`, version `0.0.1`, and requires Dart `^3.9.0`.
This checkout belongs to the ExtraMobs workspace: initialize its submodules
and run `flutter pub get` from the `extramobs/` directory. The workspace
may require a newer SDK; check its manifest as well.

For an application using the local checkout:

```yaml
dependencies:
  mssql:
    path: ../extramobs/packages/mssql
```

```dart
import 'package:mssql/mssql.dart';
```

The entry point `package:mssql/mssql_connection.dart` is also available.

## Synchronous and asynchronous connections

| Connection               | Execution                                                                        | Cursor                                       |
| ------------------------ | -------------------------------------------------------------------------------- | -------------------------------------------- |
| `MssqlConnection`      | Direct return values, without`Future` or `await`; blocks the calling isolate | `MssqlCursorSync`, an `Iterable<SqlRow>` |
| `MssqlConnectionAsync` | Native calls run in an internal worker isolate; SQL operations return`Future`s | `MssqlCursor`, a `Stream<SqlRow>`        |

Each instance owns an independent session. Both APIs share the native SQL
executor, RPC encoding, result limits, and TLS settings.
`MssqlConnectionAsync.getInstance()` provides a shared connection when needed.

**Choose one mode per process.** The bundled FreeTDS permits a single isolate
to own its native callbacks. Do not mix synchronous and asynchronous
connections in the same process. Create asynchronous connections from one
calling isolate; their sessions share a persistent internal worker. The same
restriction applies to direct use of `MssqlClient` or DB-Lib under `src/`.

Use the synchronous API in synchronous scripts or in an isolate already
managed by the application. The asynchronous API does not require an
application-owned worker.

### Asynchronous example

This complete example uses only a session-local temporary table. Supply
credentials through the environment; they are not printed.

```dart
import 'dart:io';
import 'package:mssql/mssql.dart';

Future<void> main() async {
  final env = Platform.environment;
  String required(String key) =>
      env[key] ?? (throw StateError('Set $key'));
  final db = MssqlConnectionAsync();
  try {
    final connected = await db.connect(
      ip: required('MSSQL_IP'),
      port: env['MSSQL_PORT'] ?? '1433',
      databaseName: env['MSSQL_DB'] ?? 'tempdb',
      username: required('MSSQL_USER'),
      password: required('MSSQL_PASSWORD'),
      autocommit: false,
    );
    if (!connected) throw StateError('Connection failed');

    final cursor = db.cursor(); // Creating an idle cursor needs no await.
    try {
      await cursor.execute(
        'CREATE TABLE #People (id int PRIMARY KEY, name nvarchar(100))',
      );
      await cursor.executemany(
        'INSERT INTO #People (id, name) VALUES (?, ?)',
        [[1, 'Alice'], [2, 'Bob']],
      );
      await db.commit();

      await cursor.execute(
        'SELECT id, name FROM #People WHERE id >= ? ORDER BY id',
        [1],
      );
      await for (final row in cursor) {
        print(row.values);
      }
      await db.rollback(); // End any implicit read transaction.
    } catch (_) {
      await cursor.close();
      if (db.isConnected) await db.rollback();
      rethrow;
    } finally {
      await cursor.close();
    }
  } finally {
    await db.close();
    await MssqlConnectionAsync.shutdownWorker();
  }
}
```

In a standalone Dart program, call `shutdownWorker()` after all database
work to close remaining sessions and stop the worker. This operation is
global and terminal: further asynchronous connections require a new process.
`db.close()` closes only its session and leaves the worker available for
subsequent connections. Flutter applications normally keep the worker alive
throughout their lifetime.

### Synchronous example

Run this in a separate process from the asynchronous example:

```dart
import 'dart:io';
import 'package:mssql/mssql.dart';

void main() {
  final env = Platform.environment;
  String required(String key) =>
      env[key] ?? (throw StateError('Set $key'));
  final db = MssqlConnection();
  try {
    final bool connected = db.connect(
      ip: required('MSSQL_IP'),
      port: env['MSSQL_PORT'] ?? '1433',
      databaseName: env['MSSQL_DB'] ?? 'tempdb',
      username: required('MSSQL_USER'),
      password: required('MSSQL_PASSWORD'),
    );
    if (!connected) throw StateError('Connection failed');

    final cursor = db.execute('SELECT ? AS id', [42]);
    try {
      for (final row in cursor) {
        print(row['id']);
      }
    } finally {
      cursor.close();
    }
  } finally {
    db.close();
  }
}
```

## Connections, TLS, and native loading

Omit `tls` to preserve FreeTDS configuration files, environment settings and
defaults. This FreeTDS implementation uses `request` with TDS 7.1 and newer,
and no encryption with older versions. Without a configured CA source,
FreeTDS does not authenticate the server certificate. `request` permits
plaintext fallback and can encrypt only the login, depending on the server.
When TLS is negotiated, this build requires TLS 1.2 or later.

Both connection APIs accept the same typed policies:

| Policy                    | Negotiation                                    | Trust source       |
| ------------------------- | ---------------------------------------------- | ------------------ |
| `TlsOff()`              | Advertises no TLS support                      | Not accepted       |
| `TlsRequest(...)`       | Requests TLS; permits plaintext fallback       | Optional           |
| `TlsRequire(...)`       | Requires server TLS support                    | Optional           |
| `TlsStrict(trust: ...)` | TLS before PRELOGIN; requires a TDS 8.0 server | Required, non-null |

Encryption policy and certificate trust are separate. `TlsSystemTrust()`
uses the native TLS library's CA store; with OpenSSL this is not necessarily
the operating system's certificate store. `TlsPemTrust(absolutePath)` uses
a PEM file of trusted certificates. The `TlsWithTrust` and
`TlsWithRequiredTrust` mixins express the capabilities of the sealed policy
types. Missing/null strict trust, a trust argument on `TlsOff`, and a string
in place of a trust source are compilation errors. File paths and string
contents still require runtime validation.

```dart
// Pass one of these as connect(tls: ...).
const encrypted = TlsRequire(); // Accepts self-signed peers without validation.
const authenticated = TlsRequire(trust: TlsSystemTrust());
final strict = TlsStrict(
  trust: TlsPemTrust(File('trusted-ca.pem').absolute.path),
  certificateHostname: 'sql.example.com',
);
```

Explicit policies override native encryption/CA settings. Omitting `trust`
in `request` or `require` explicitly disables certificate validation.
With a trust source, `certificateHostname` overrides the expected server
name; it otherwise defaults to the connection host. It has no effect
without a trust source. `strict` means **TDS 8.0**, not TLS 8.0.

After a successful connection, `db.peerCertificate` contains the received
leaf certificate, or `null` if none was received. It is available even when
FreeTDS ends TLS after the login. `TlsCertificate` owns read-only DER bytes
and provides a PEM getter; it does not parse or authenticate the certificate.

```dart
final certificate = db.peerCertificate;
if (certificate != null) {
  await File('server.pem').writeAsString(certificate.pem);
  // certificate.der is an owned, unmodifiable Uint8List.
}
```

Closing or invalidating the connection clears its getter. A certificate
already saved in a variable remains valid. Receiving or saving a certificate
does not prove its authenticity; establish trust before reusing it as a
trusted certificate. The server's private key is never exposed.

The native library must contain this package's FreeTDS extensions; older
libraries without them are rejected. The loader resolves installed
application paths, not the working directory or `PATH`. For Dart development
outside a packaged application, set `NativeLoader.libraryDirectory` to an
absolute trusted directory before the first connection.

| Connection option       | Default                                 |
| ----------------------- | --------------------------------------- |
| `timeoutInSeconds`    | 15 seconds for login                    |
| `queryTimeoutSeconds` | 30 seconds for native commands          |
| `autocommit`          | `false`                               |
| `maxResultRows`       | 100,000 rows per execution              |
| `maxResultBytes`      | 64 MiB of decoded payload per execution |

## Cursors and results

`db.execute(sql, [parameters])` creates, executes, and returns a new cursor.
`cursor.execute(sql, [parameters])` reuses the same cursor and discards its
previous results. Both accept SELECT, DML, DDL, and EXEC.

The table below applies to both cursor types. Asynchronous operations return
`Future`s; synchronous operations return values directly. Metadata getters
are immediate in both modes.

| Cursor API                                                | Contract                                                                                                                      |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `execute(sql, [parameters])`                            | Returns the cursor after execution and initial metadata are available                                                         |
| `executemany(sql, iterable)`                            | Consumes parameter lists/maps progressively, including`sync*` generators; returns void and leaves `rowcount = -1`         |
| `executeProcedure(name, params)`                        | Executes a procedure using named RPC parameters and returns the cursor                                                        |
| `bulkInsert(table, rows, columns: ..., batchSize: ...)` | Returns the inserted row count; see bulk behavior below                                                                       |
| `fetchone()`                                            | Next`SqlRow`, or `null` at the end of the current result                                                                  |
| `fetchval()`                                            | First column of the next row, or`null` for SQL NULL/end                                                                     |
| `fetchmany([size])`                                     | Up to`size` remaining rows; defaults to `arraysize`, initially 1; zero returns an empty list, negative sizes are rejected |
| `fetchall()`                                            | Materializes the remaining rows of the current result in memory                                                               |
| `nextset()`                                             | Discards unread rows and advances to the next result; returns`false` when none remain                                       |
| `skipRows(count)`                                       | Discards up to`count` rows; distinct from Dart's `Stream.skip`                                                            |
| `description` / `columns`                             | `SqlColumn(name, typeCode)` metadata / column names; `null` for results without columns                                   |
| `rowcount`                                              | Native count for the current result, or`-1` if unknown; may become available only at EOF                                    |
| `cancel()`                                              | Discards pending results and leaves the cursor reusable                                                                       |
| `close()`                                               | Discards results and closes the cursor; idempotent; does not commit or roll back                                              |
| `commit()` / `rollback()`                             | Apply to the entire connection, not just this cursor                                                                          |

Use `await for` with `MssqlCursor`, and `for` with `MssqlCursorSync`.
`MssqlCursor.fetchStream()` returns the cursor itself. Fetches and iteration
share the same position. They never advance to another result automatically.
Pausing a stream suspends further fetches; breaking iteration or cancelling
the stream subscription does not close the cursor. Always close it in
`finally`. FreeTDS and the network still maintain internal buffers.

Fetching rows from a result without columns throws `StateError`. An empty
SELECT retains its metadata. Metadata uses DB-Lib type codes, not the
seven-field ODBC description.

```dart
// db is an open MssqlConnectionAsync.
final cursor = await db.execute('SELECT 1 AS first; SELECT 2 AS second');
try {
  do {
    if (cursor.description != null) {
      await for (final row in cursor) {
        print(row.values);
      }
    }
    print('Row count: ${cursor.rowcount}');
  } while (await cursor.nextset());
} finally {
  await cursor.close();
}
```

`SqlRow` supports index and exact-name access: `row[0]`, `row['name']`,
`row.values`, and `row.columns`. Duplicate names resolve to the first
column. Values can be replaced through indexing or `values`; the column
count is fixed, and names/metadata are immutable. Changes are local and do
not write to SQL Server. Rows remain valid after further fetches or closing
the cursor.

## Transactions and concurrency

**Manual commit is the default.** With `autocommit: false`, SQL Server uses
`IMPLICIT_TRANSACTIONS ON`; statements including SELECTs against tables
can start a transaction. There is no public `beginTransaction()` method.

Commit and rollback affect every cursor on the connection. Closing the
connection rolls back pending work and invalidates all its cursors.
Closing a cursor alone does neither. Finish read transactions as well as writes.

`setAutocommit(true)` commits pending work before enabling per-statement
commit. `setAutocommit(false)` restores manual mode. Read `db.autocommit`
to inspect the setting; do not change `IMPLICIT_TRANSACTIONS` through SQL.
CREATE/DROP DATABASE requires autocommit.

The callback extension requires an open connection with `autocommit: true`:

```dart
await db.transaction((tx) async {
  final cursor = tx.cursor();
  await cursor.execute(
    'UPDATE dbo.Accounts SET balance = balance - ? WHERE id = ?', [10, 1],
  );
  await cursor.execute(
    'UPDATE dbo.Accounts SET balance = balance + ? WHERE id = ?', [10, 2],
  );
});
```

Success commits; exceptions roll back. The asynchronous callback reserves
the connection's queue across awaits. Outside operations wait. Nested
transactions, manual transaction control, and connection/mode changes inside
the callback are rejected. Cursors created inside close on exit and must
not escape the scope. Await every operation started in the callback.
For `MssqlConnection`, the callback must be synchronous; returning a
`Future` is rejected and the transaction is rolled back.

Multiple idle or completed cursors may coexist, but only **one command may
have pending results per session**; MARS is not supported. Before another
cursor executes, or before transaction control, consume all results, cancel,
or close the active cursor. Otherwise the operation throws `StateError`.
At EOF the reader checks the next result's metadata to determine whether it
can release the session while preserving `nextset()`.

The asynchronous driver serializes individual calls, not an arbitrary
sequence of execute/fetch/close calls. Do not use one cursor concurrently.
Use independent connections for independent units of work, or serialize
complete operations in the application. Manual transaction mode does not
reserve a connection for one consumer.

## Parameters, types, and bulk insert

Use a `List` for positional `?` markers or a `Map` for named parameters
such as `@id`. Values travel through RPC rather than SQL interpolation.
Markers inside strings, identifiers, and comments are ignored. Table and
column names cannot be parameterized. Do not mix parameter styles in one
call; duplicate normalized names such as `id` and `@ID` are rejected.

Named parameters, direct `executeProcedure`, and `bulkInsert` are FreeTDS
extensions to the cursor-oriented API.

| Type                          | Representation                                                                                           |
| ----------------------------- | -------------------------------------------------------------------------------------------------------- |
| Text                          | UTF-8 in the client and Unicode in RPC; invalid result UTF-8 throws`FormatException`                   |
| `int`, `double`, `bool` | Corresponding binary types; NaN and infinity are rejected                                                |
| MONEY / DECIMAL results       | Exact decimal strings                                                                                    |
| `DateTime` parameters       | Binary`datetimeoffset(7)`, preserving the instant, offset, and Dart microseconds                       |
| Date/time results             | ISO strings, up to seven fractional digits for modern types; values without an offset do not gain a`Z` |
| `Uint8List`                 | Sent as`varbinary(max)`; BINARY/VARBINARY/IMAGE results are owned, read-only byte copies               |

Empty values and SQL NULL remain distinct. SQL text, names, and credentials
reject NUL; parameter values preserve it. Returned binary values survive
cursor reuse/closure and can be sent as parameters again.
Use `Uint8List.fromList(bytes)` for an editable copy.
Binary RPC parameters above 8,000 bytes use FreeTDS's MAX format.

Dart `null` carries no SQL type. Where needed, supply one in SQL, for example
`CAST(? AS varbinary(max))`. Bulk NULL values obtain their type from the
destination column.

`executemany` consumes its iterable progressively without materializing
the whole input, executes each parameter set, and does not aggregate results.
In autocommit mode, earlier writes can remain committed if a later write fails.

`bulkInsert` uses a parameterized INSERT per row for manual transactions,
explicit transactions, text, dates, NULL, objects converted to text, and
temporary tables. This path does not batch statements using `batchSize`.
BCP is used only with autocommit, no active transaction, and non-null
numeric/binary data in the full destination-column order. With autocommit,
a later failure can leave earlier rows or batches committed.

## Errors and limits

SQL, native, and decoding failures throw exceptions and invalidate the
session and its cursors. Earlier rows may already have been delivered during
incremental reads; do not treat an interrupted result as complete.
Reconnect explicitly. The driver never reconnects or repeats writes automatically.
A communication failure during commit can leave its outcome uncertain;
check server state before retrying the operation.

`maxResultRows` and `maxResultBytes` accumulate across fetches and result
sets within one execution. They measure decoded payload, not all native
memory. Exceeding a limit closes the session. Configure larger limits
explicitly when needed. Query timeout is enforced by the native library;
a Dart `Future.timeout` alone does not cancel native work.

## Platforms and native builds

Windows x64, Linux x64, and Android (arm64-v8a, armeabi-v7a, x86_64) are
registered in the manifest. Linux and Android were implemented after the
plans recorded in the opening notice. iOS and macOS remain deferred;
see [TODO.md](TODO.md). Web is not supported. Windows ARM64 and Linux ARM64
have not been validated.

### Windows

CMake bundles `windows/Libraries/bin/sybdb.dll`, built with statically
linked OpenSSL. `scripts/fetch-openssl.py` pins OpenSSL 3.5.8 and verifies
its SHA-256 checksum. Use `scripts/build-openssl.ps1` and
`scripts/build-windows.ps1` to rebuild; inspect their parameters first.
Keep the FreeTDS extensions and ABI intact when replacing native artifacts.

### Linux x64

The supplied library was built with bundled FreeTDS 1.5.4 and static
OpenSSL 3.5.8. It requires glibc >= 2.38. The Flutter application also requires
GTK3 and the standard Flutter Linux dependencies.

From the package root on Linux:

```sh
sudo apt-get install build-essential clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev autoconf automake libtool gettext python3 \
  perl curl git unzip ca-certificates
bash scripts/build-openssl.sh linux-x86_64 "$PWD/out-linux-openssl"
OPENSSL_ROOT_DIR="$PWD/out-linux-openssl/prefix" \
  bash scripts/build-posix.sh "$PWD/third_party/freetds-1.5.4" "$PWD/out-linux"
cp -L out-linux/lib/libsybdb.so linux/Libraries/lib/libsybdb.so
cd example
flutter pub get
flutter build linux --release
```

Distribute the entire `example/build/linux/x64/release/bundle/` directory.
CMake includes `lib/libsybdb.so`, which the loader resolves relative to
the executable.

### Android

The plugin includes the INTERNET permission and native libraries for its
three registered ABIs. The supplied binaries were built with NDK
28.2.13676358 and static OpenSSL 3.5.8.
Use `scripts/build-openssl.sh` and `scripts/build-android.sh` to rebuild;
each ABI requires a matching `OPENSSL_ROOT_DIR` and `ANDROID_NDK`.

```sh
cd example
flutter pub get
flutter build apk --release
flutter build appbundle --release
```

The example uses debug signing even for release builds. Configure production
signing before publishing. Its Gradle 8.14.3 / AGP 8.11.1 setup worked with
the tested Flutter version, which warns that future releases require an upgrade.

## Validation

From the ExtraMobs workspace, run `flutter analyze`. From the package
directory, run each native suite in its own process because FFI callbacks
have a single owning isolate:

```sh
dart test test/tls_test.dart test/mssql_cursor_test.dart test/freetds_text_test.dart test/test_utils_test.dart
dart test test/native_library_test.dart
dart test test/mssql_cursor_integration_test.dart
dart test test/freetds_text_integration_test.dart
dart test test/mssql_sync_integration_test.dart
dart test test/mssql_async_execution_test.dart
```

`test/tls_test.dart` compiles valid and deliberately invalid configurations
and checks DER ownership and PEM encoding. The local handshake fixture uses
Python 3 and the OpenSSL CLI, generates disposable certificates, and does not
contact a database. Run both APIs in separate processes:

```sh
MSSQL_TEST_TLS=1 dart test test/tls_native_test.dart
MSSQL_TEST_TLS=1 MSSQL_TEST_ASYNC=true dart test test/tls_native_test.dart
```

In PowerShell set these environment variables with `$env:NAME = 'value'`.
`MSSQL_TEST_PYTHON` and `MSSQL_TEST_OPENSSL` can select executable paths.
These checks passed on Windows x64 and Linux x64: default/plaintext behavior,
login-only and full TLS, strict with PEM/system trust, incorrect CA/hostname
rejection, exact DER capture and certificate lifetime. Android libraries were
rebuilt for arm64-v8a, armeabi-v7a and x86_64; this TLS matrix has not been run
on Android devices.

SQL integration suites require explicit `MSSQL_IP`, `MSSQL_USER`, and
`MSSQL_PASSWORD`. Optional settings include `MSSQL_PORT`, `MSSQL_DB`,
`MSSQL_CA_FILE`, `MSSQL_CERTIFICATE_HOSTNAME`, and
`MSSQL_TRUST_SERVER_CERTIFICATE`. They are skipped without configuration.
For native tests outside a packaged app, use an absolute `MSSQL_NATIVE_DIR`
pointing to `windows/Libraries/bin` or `linux/Libraries/lib`.

The cursor, text, and sync/async integration suites use temporary objects.
Other helpers, particularly `tool/integration_db_lifecycle.dart` and suites
using `test/test_utils.dart`, can create and drop databases. Inspect their
operations and target before running them. Performance suites are opt-in:
without `PERF_SIZES`, the benchmark attempts 1, 5, and 10 million rows.

Recorded validation before this documentation consolidation:

- Windows: 48 cursor/codec tests, 13 asynchronous cursor integration tests,
  7 synchronous integration tests, and 3 asynchronous execution tests passed.
  WAITFOR tests verify blocking in synchronous mode and continued timers
  in asynchronous mode. The Windows application also built successfully.
- Linux x64 and Android x86_64: earlier native-library and SQL integration
  checks passed, with 13 SQL integration tests on each platform.
  Linux release, APK, and AAB builds succeeded. APK ELF/zip alignment checks
  passed for 16 KB pages; the AAB declared `PAGE_ALIGNMENT_16K`.
  These checks predate the separate synchronous/asynchronous connection APIs.
- End-to-end validation with a trusted CA/hostname, BCP on permanent tables,
  and execution on ARM devices remains pending. Recorded SQL integrations
  accepted self-signed certificates without validation.

For Flutter native-library checks, run the example's
`integration_test/native_library_test.dart` with `-d linux` or an Android
device ID. On headless Linux, use `xvfb-run -a`.

To run the Android SQL integration without embedding credentials in the APK,
store its environment keys in a private JSON file outside the repository:

```sh
adb reverse tcp:38765 tcp:38765
python tool/serve_integration_config.py /private/path/connection.json
# In another terminal, substitute the URL printed by the server:
cd example
flutter test integration_test/sql_server_test.dart -d emulator-5554 \
  --dart-define=MSSQL_TEST_CONFIG_URL=PRINTED_URL
adb reverse --remove tcp:38765
```

The configuration server serves one local request and exits without printing
credentials. Delete the private configuration file when finished.

## License and origin

This project is maintained by ExtraMobs and derives from `mssql_connection`.
The original copyright and MIT terms are preserved in [LICENSE](LICENSE).
FreeTDS has its own [LGPL license](third_party/freetds-1.5.4/COPYING_LIB.txt).
Keep the applicable FreeTDS/OpenSSL notices and comply with their licenses
when distributing sources or native binaries.
