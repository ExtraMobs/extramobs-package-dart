import 'dart:ffi';
import 'dart:io';
import 'dart:async';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:extramobs/packages/mssql/src/ffi/freetds_bindings.dart';
import 'package:extramobs/packages/mssql/src/ffi/freetds_text.dart';
import 'package:extramobs/packages/mssql/src/native_loader.dart';
import 'package:extramobs/packages/mssql/src/mssql_client.dart';
import 'package:extramobs/packages/mssql/src/sql_exception.dart';
import 'package:extramobs/packages/mssql/src/tls_config.dart';
import 'package:test/test.dart';

// Run in a separate dart test invocation: DB-Lib callbacks have one owning isolate.
void main({bool useBundledLibrary = false}) {
  setUpAll(() {
    // Android must resolve the library packaged in the application's jniLibs.
    if (useBundledLibrary || Platform.isAndroid) return;
    NativeLoader.libraryDirectory =
        Platform.environment['MSSQL_NATIVE_DIR'] ??
        Directory(
          Platform.isWindows
              ? 'windows/Libraries/bin'
              : Platform.isMacOS
              ? 'macos/Libraries/lib'
              : 'linux/Libraries/lib',
        ).absolute.path;
  });
  test('bundled ABI, secure login fields and native error cancellation', () {
    final db = DBLib.load();
    expect(db.initialize(kErrHandlerPtr, kMsgHandlerPtr), SUCCEED);
    final login = db.dblogin();
    expect(login, isNot(nullptr));
    try {
      using((arena) {
        final ca = toNativeFreeTdsText('system', allocator: arena);
        expect(db.dbsetlname(login, ca, DBSETCAFILE), SUCCEED);
        expect(
          db.dbsetlname(
            login,
            toNativeFreeTdsText('localhost', allocator: arena),
            DBSETCERTIFICATEHOSTNAME,
          ),
          SUCCEED,
        );
        expect(
          db.dbsetlname(
            login,
            toNativeFreeTdsText('require', allocator: arena),
            DBSETENCRYPTION,
          ),
          SUCCEED,
        );
        expect(
          db.dbsetlcharset(
            login,
            toNativeFreeTdsText('UTF-8', allocator: arena),
          ),
          SUCCEED,
        );
        // This invokes a real error callback with NULL DBPROCESS. INT_EXIT would
        // terminate this test process instead of returning FAIL.
        expect(
          db.dbcmd(nullptr, toNativeFreeTdsText('SELECT 1', allocator: arena)),
          FAIL,
        );
        expect(DBLib.takeLastError(nullptr), isNotNull);
      });
    } finally {
      db.dbloginfree(login);
    }
  });

  test('a second isolate cannot replace the native callback owner', () async {
    final db = DBLib.load();
    expect(db.initialize(kErrHandlerPtr, kMsgHandlerPtr), SUCCEED);
    final result = await _initializeAnotherIsolate(
      NativeLoader.libraryDirectory,
    );
    expect(result, FAIL);
    using((arena) {
      expect(
        db.dbcmd(nullptr, toNativeFreeTdsText('SELECT 1', allocator: arena)),
        FAIL,
      );
      expect(DBLib.takeLastError(nullptr), isNotNull);
    });
  });

  test(
    'server without TLS is rejected before a login packet is sent',
    () async {
      final messages = ReceivePort();
      final ready = Completer<int>();
      var loginSent = false;
      final subscription = messages.listen((message) {
        if (message is int && !ready.isCompleted) ready.complete(message);
        if (message == 'login') loginSent = true;
      });
      final server = await Isolate.spawn(_unencryptedServer, messages.sendPort);
      final client = MssqlClient(
        server: '127.0.0.1:${await ready.future}',
        username: 'dummy',
        password: 'dummy',
        tls: const TlsRequire(),
      );
      try {
        await expectLater(
          client.connect(loginTimeoutSeconds: 3),
          throwsA(isA<SQLException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(loginSent, isFalse);
        expect(client.isConnected, isFalse);
      } finally {
        await client.close();
        server.kill(priority: Isolate.immediate);
        await subscription.cancel();
        messages.close();
      }
    },
  );
}

Future<int> _initializeAnotherIsolate(String? directory) => Isolate.run(() {
  NativeLoader.libraryDirectory = directory;
  return DBLib.load().initialize(kErrHandlerPtr, kMsgHandlerPtr);
});

// Local protocol fixture; no SQL Server, credentials or database side effects.
void _unencryptedServer(SendPort parent) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  parent.send(server.port);
  server.listen((socket) {
    final pending = <int>[];
    socket.listen(
      (bytes) {
        pending.addAll(bytes);
        if (pending.length < 8) return;
        final length = pending[2] * 256 + pending[3];
        if (pending.length < length) return;
        if (pending.first == 0x12) {
          // TDS PRELOGIN reply: encryption is not supported (2).
          socket.add([4, 1, 0, 15, 0, 0, 1, 0, 1, 0, 6, 0, 1, 255, 2]);
        } else {
          parent.send('login');
          socket.destroy();
        }
        pending.clear();
      },
      onError: (Object _) {
        socket.destroy();
      },
    );
  });
}
