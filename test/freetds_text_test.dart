import 'cursor_results.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:extramobs/packages/mssql/src/ffi/freetds_bindings.dart';
import 'package:extramobs/packages/mssql/src/ffi/freetds_text.dart';
import 'package:extramobs/packages/mssql/src/mssql_client.dart';
import 'package:extramobs/packages/mssql/src/native_logger.dart';
import 'package:extramobs/packages/mssql/src/sql_exception.dart';
import 'package:test/test.dart';

const sample = 'João ação € “aspas” 中文 مرحبا 🙂';

void main() {
  test('failed decimal conversion cannot become a base64 result', () {
    final db = _RecordingDb()..convertLength = -1;
    using((arena) {
      for (final type in [SYBDECIMAL, SYBNUMERIC]) {
        expect(
          () => decodeDbValueWithFallback(
            db,
            nullptr,
            type,
            arena<Uint8>(33),
            33,
          ),
          throwsFormatException,
        );
      }
    });
  });

  test('timeouts cannot overflow the native signed integer', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await expectLater(
      client.connect(loginTimeoutSeconds: 0x80000000),
      throwsArgumentError,
    );
    final oversizedQuery = MssqlClient(
      server: 'test',
      username: 'test',
      password: 'test',
      queryTimeoutSeconds: 0x80000000,
      dbLib: db,
    );
    await expectLater(oversizedQuery.connect(), throwsArgumentError);
    expect(db.freedLogins, 0);
  });

  test('login records are freed on success and failure', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await client.connect();
    expect(db.freedLogins, 1);
    await client.close();
    db.failOpen = true;
    await expectLater(client.connect(), throwsA(isA<SQLException>()));
    expect(db.freedLogins, 2);
  });

  test('empty values are distinct from NULL on input and output', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await client.connect();
    await procedureOnClient(client, 'dbo.Values', {
      'a': '',
      'b': Uint8List(0),
      'c': null,
    });
    expect(db.params.map((p) => p.length), [0, 0, 0]);
    expect(db.params.map((p) => p.status), [DBRPCEMPTY, DBRPCEMPTY, 0]);
    expect(db.params.map((p) => p.isNull), [false, false, true]);
    using((arena) {
      final p = arena<Uint8>();
      expect(decodeDbValue(SYBVARCHAR, p, 0), '');
      expect(
        decodeDbValue(SYBVARBINARY, p, 0),
        isA<Uint8List>().having((v) => v.length, 'length', 0),
      );
      expect(decodeDbValue(SYBVARCHAR, nullptr, 0), isNull);
    });
  });

  test(
    'identifiers cannot inject SQL and parameter aliases cannot collide',
    () async {
      expect(quoteSqlName('dbo.[A]]B]'), '[dbo].[A]]B]');
      expect(quoteSqlName('#tmp'), '[#tmp]');
      for (final name in ['T; DELETE FROM T', 'dbo..T', '[T', 'T.', '[T]--']) {
        expect(() => quoteSqlName(name), throwsArgumentError);
      }
      final db = _RecordingDb();
      final client = _clientWith(db);
      await client.connect();
      await expectLater(
        executeOnClient(client, 'SELECT @p', {'p': 1, '@P': 2}),
        throwsArgumentError,
      );
      await expectLater(
        executeOnClient(client, 'SELECT @p', {'p int);--': 1}),
        throwsArgumentError,
      );
      expect(db.procedures, isEmpty);
    },
  );

  test('money layout and datetimeoffset retain exact precision', () {
    using((arena) {
      final p = arena<Uint8>(16);
      p.asTypedList(16).fillRange(0, 16, 0);
      final bytes = ByteData.sublistView(p.asTypedList(16));
      bytes.setUint32(4, 10000, Endian.host);
      expect(decodeDbValue(SYBMONEY, p, 8), '1.0000');
      bytes.setInt32(0, -1, Endian.host);
      bytes.setUint32(4, 0xffffffff, Endian.host);
      expect(decodeDbValue(SYBMONEY, p, 8), '-0.0001');
      bytes.setUint64(0, 1234567, Endian.host);
      bytes.setInt32(8, 0, Endian.host);
      bytes.setInt16(12, 60, Endian.host);
      expect(
        decodeDbValue(SYBMSDATETIMEOFFSET, p, 16),
        '1900-01-01T01:00:00.1234567+01:00',
      );
    });
  });

  test('unexpected row failures close the session instead of returning partial success', () async {
    final db = _RecordingDb()..rowResult = FAIL;
    final client = _clientWith(db);
    await client.connect();
    await expectLater(
      executeOnClient(client, 'SELECT TOP (0) * FROM T'),
      throwsA(isA<SQLException>()),
    );
    expect(client.isConnected, isFalse);
    expect(db.closed, isTrue);
  });

  test(
    'failed login exposes callbacks from temporary handles without logs',
    () async {
      final db = _RecordingDb()..failOpen = true;
      final client = _clientWith(db);
      await expectLater(
        client.connect(),
        throwsA(
          isA<SQLException>().having(
            (e) => e.message,
            'diagnostic',
            contains('Login failed for test user'),
          ),
        ),
      );
      expect(client.isConnected, isFalse);
      db.failOpen = false;
      expect(await client.connect(), isTrue);
    },
  );

  test(
    'failed login without callback has fallback and no stale diagnostic',
    () async {
      final db = _RecordingDb()
        ..failOpen = true
        ..emitLoginDiagnostic = false;
      await expectLater(
        _clientWith(db).connect(),
        throwsA(
          isA<SQLException>().having(
            (e) => e.message,
            'diagnostic',
            'dbopen failed.',
          ),
        ),
      );
    },
  );
  test('Dart UTF-16 code units become exact UTF-8 bytes without cleaning', () {
    final text = String.fromCharCodes([
      0x0041,
      0x00e7,
      0x00e3,
      0x006f,
      0xd83d,
      0xde42,
    ]);
    const expected = [
      0x41,
      0xc3,
      0xa7,
      0xc3,
      0xa3,
      0x6f,
      0xf0,
      0x9f,
      0x99,
      0x82,
    ];
    expect(text, 'Ação🙂');
    expect(text.codeUnits, isNot(contains(0)));
    expect(utf8.encode(text), expected);
    expect(freeTdsTextCodec.encode(text), expected);
    using((arena) {
      final pointer = toNativeFreeTdsText(text, allocator: arena);
      // Inspect the complete allocation directly, including the C terminator.
      // No decoder, strlen or NUL removal is involved in this assertion.
      expect(pointer.cast<Uint8>().asTypedList(expected.length + 1), [
        ...expected,
        0,
      ]);
    });
  });

  test('misreading UTF-16LE creates NULs before UTF-8 encoding', () {
    const utf16le = [0x41, 0, 0x42, 0, 0x43, 0];
    // Deliberately use the wrong decoder to reproduce the suspected failure.
    final wrong = utf8.decode(utf16le);
    expect(wrong.codeUnits, [0x41, 0, 0x42, 0, 0x43, 0]);
    expect(utf8.encode(wrong), utf16le);
    expect(freeTdsTextCodec.encode(wrong), utf16le);

    // Actual NUL and the literal characters backslash-x-zero-zero differ.
    expect(utf8.encode('A\u0000B'), [0x41, 0, 0x42]);
    expect(utf8.encode(r'A\x00B'), [0x41, 0x5c, 0x78, 0x30, 0x30, 0x42]);
  });

  test('sets the UTF-8 client charset before opening the connection', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    expect(await client.connect(), isTrue);
    expect(db.loginEvents, ['UTF-8', 'bcp:1:6', 'open']);
  });

  test('does not open a connection when the charset cannot be set', () async {
    final db = _RecordingDb()..charsetResult = FAIL;
    await expectLater(_clientWith(db).connect(), throwsA(isA<SQLException>()));
    expect(db.loginEvents, ['UTF-8']);
  });

  test('SQL, RPC, procedures and text bulk inserts share UTF-8', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await client.connect();

    final sql = "SELECT N'$sample' AS [Descrição]";
    await executeOnClient(client, sql);
    expect(db.commands.last, utf8.encode(sql));
    const ddl = 'CREATE TABLE #Ação (Id INT)';
    await executeOnClient(client, ddl);
    expect(db.commands.last, utf8.encode(ddl));

    for (final value in [sample, 'A\u0000BC', List.filled(5000, 'é').join()]) {
      await executeOnClient(client, 'SELECT @texto AS [Descrição]', {
        'texto': value,
      });
      expect(db.params.last.type, SYBNTEXT);
      expect(db.params.last.bytes, utf8.encode(value));
      expect(db.params.last.length, utf8.encode(value).length);

      await procedureOnClient(client, 'dbo.Operação', {'texto': value});
      expect(db.procedures.last, '[dbo].[Operação]');
      expect(db.params.last.type, SYBNTEXT);
      expect(db.params.last.bytes, utf8.encode(value));

      // The native BCP path is deliberately absent from this fake: text must use RPC.
      expect(
        await bulkOnClient(client, 'dbo.Textos', [
          {'Descrição': value},
        ]),
        1,
      );
      expect(db.procedures.last, 'sp_executesql');
      expect(db.params.last.bytes, utf8.encode(value));
      expect(db.params.last.name, '');
    }
  });

  test('RPC keeps numeric, binary and NULL types', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await client.connect();
    final bytes = Uint8List.fromList([0, 0xff, 0x80]);
    await procedureOnClient(client, 'dbo.Values', {
      'integer': 42,
      'bigint': 1 << 40,
      'boolean': true,
      'float': 1.5,
      'binary': bytes,
      'null': null,
    });
    expect(db.params.map((p) => p.type), [
      SYBINT4,
      SYBINT8,
      SYBBIT,
      SYBFLT8,
      SYBVARBINARY,
      SYBNTEXT,
    ]);
    expect(db.params.map((p) => p.length), [4, 8, 1, 8, 3, 0]);
    expect(db.params[4].bytes, bytes);
  });

  test(
    'large binary RPC inputs use MAX without changing byte lengths',
    () async {
      final db = _RecordingDb();
      final client = _clientWith(db);
      await client.connect();
      for (final length in [8000, 8001, 16385]) {
        final bytes = Uint8List.fromList(List.generate(length, (i) => i % 256));
        for (final send in <Future<void> Function()>[
          () async {
            await executeOnClient(client, 'SELECT @v', {'v': bytes});
          },
          () async {
            await procedureOnClient(client, 'dbo.BinaryEcho', {'v': bytes});
          },
          () async {
            await bulkOnClient(client, '#Binary', [
              {'v': bytes},
            ]);
          },
        ]) {
          await send();
          expect(db.params.last.type, length > 8000 ? SYBIMAGE : SYBVARBINARY);
          expect(db.params.last.length, length);
          expect(db.params.last.bytes, bytes);
        }
      }
      await client.close();
    },
  );

  test('numeric and binary loads keep BCP batching', () async {
    final db = _RecordingDb();
    final client = _clientWith(db);
    await client.connect();
    expect(
      await bulkOnClient(client, 'dbo.Values', [
        {
          'Id': 1,
          'Bytes': Uint8List.fromList([0, 255]),
        },
        {
          'Id': 0x100000000,
          'Bytes': Uint8List.fromList([128]),
        },
      ], batchSize: 1),
      2,
    );
    expect(db.bcpRows, 2);
    expect(db.bcpTypes, [SYBINT8, SYBVARBINARY]);
    expect(db.procedures, isEmpty);
  });

  test(
    'manual and explicit transactions keep numeric bulk inside RPC',
    () async {
      for (final automatic in [false, true]) {
        final db = _RecordingDb()..transactionDepth = automatic ? 1 : 0;
        final client = _clientWith(db, autocommit: automatic);
        await client.connect();
        try {
          expect(
            await bulkOnClient(client, 'dbo.Values', [
              {
                'Id': 1,
                'Bytes': Uint8List.fromList([255]),
              },
            ]),
            1,
          );
          expect(db.bcpRows, 0);
          expect(db.procedures, ['sp_executesql']);
        } finally {
          await client.close();
        }
      }
    },
  );

  test(
    'reordered columns and quoted temporary tables use named INSERTs',
    () async {
      for (final table in ['dbo.Values', '[#Values]']) {
        final db = _RecordingDb();
        final client = _clientWith(db);
        await client.connect();
        final columns = table.startsWith('dbo')
            ? ['Bytes', 'Id']
            : ['Id', 'Bytes'];
        await bulkOnClient(client, table, [
          {
            'Id': 1,
            'Bytes': Uint8List.fromList([255]),
          },
        ], columns: columns);
        expect(db.bcpRows, 0);
        expect(db.procedures, ['sp_executesql']);
        final statement = utf8.decode(db.params.first.bytes);
        expect(statement, contains(columns.map((c) => '[$c]').join(', ')));
        if (table.startsWith('[#')) {
          expect(
            db.commands.map(utf8.decode),
            isNot(contains(startsWith('SELECT TOP (0)'))),
          );
        }
      }
    },
  );

  test('text results preserve Unicode and actual NUL characters', () {
    for (final value in [sample, 'A\u0000BC', 'A\u0000n\u0000a']) {
      using((arena) {
        final bytes = utf8.encode(value);
        final pointer = arena<Uint8>(bytes.length);
        pointer.asTypedList(bytes.length).setAll(0, bytes);
        for (final type in [
          SYBCHAR,
          SYBVARCHAR,
          SYBTEXT,
          SYBNTEXT,
          SYBNVARCHAR,
        ]) {
          expect(decodeDbValue(type, pointer, bytes.length), value);
        }
        expect(decodeDbValue(SYBVARBINARY, pointer, bytes.length), bytes);
      });
    }
  });

  test(
    'binary decoders return owned read-only bytes, including empty and NULL',
    () {
      final db = _RecordingDb();
      for (final type in [SYBBINARY, SYBVARBINARY, SYBIMAGE]) {
        for (final length in [0, 256, 16385]) {
          final expected = Uint8List.fromList(
            List.generate(length, (i) => i % 256),
          );
          final decoded = using((arena) {
            final pointer = arena<Uint8>(length == 0 ? 1 : length);
            pointer.asTypedList(length).setAll(0, expected);
            final direct = decodeDbValue(type, pointer, length) as Uint8List;
            final fallback = decodeDbValueWithFallback(
              db,
              nullptr,
              type,
              pointer,
              length,
            ) as Uint8List;
            pointer.asTypedList(length).fillRange(0, length, 42);
            expect(decodeDbValue(type, nullptr, 0), isNull);
            expect(
              decodeDbValueWithFallback(db, nullptr, type, nullptr, 0),
              isNull,
            );
            expect(
              () => decodeDbValue(type, pointer, -1),
              throwsFormatException,
            );
            return [direct, fallback];
          });
          for (final bytes in decoded) {
            expect(bytes, expected);
            if (length > 0) {
              expect(() => bytes[0] = 1, throwsUnsupportedError);
              expect(
                () => bytes.buffer.asUint8List()[0] = 1,
                throwsUnsupportedError,
              );
            }
          }
        }
      }
    },
  );

  test('invalid UTF-8 fails instead of guessing Latin-1 or UTF-16', () {
    using((arena) {
      final pointer = arena<Uint8>(1)..value = 0xe9;
      expect(
        () => decodeDbValue(SYBVARCHAR, pointer, 1),
        throwsFormatException,
      );
      expect(
        () =>
            tryConvertToString(_RecordingDb(), nullptr, SYBNUMERIC, pointer, 1),
        throwsFormatException,
      );
    });
  });

  test('C strings use UTF-8 and reject NUL instead of truncating SQL', () {
    using((arena) {
      final pointer = toNativeFreeTdsText(sample, allocator: arena);
      expect(fromNativeFreeTdsText(pointer), sample);
      expect(pointer.length, utf8.encode(sample).length);
      expect(
        () => toNativeFreeTdsText(
          'SELECT 1\u0000; DELETE FROM T',
          allocator: arena,
        ),
        throwsArgumentError,
      );
    });
  });

  test('native diagnostics replace invalid UTF-8 without throwing', () {
    using((arena) {
      final text = arena<Uint8>(2);
      text.asTypedList(2).setAll(0, [0xe9, 0]);
      final callback = kMsgHandlerPtr
          .asFunction<
            int Function(
              Pointer<DBPROCESS>,
              int,
              int,
              int,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              int,
            )
          >();
      final logs = <String>[];
      final wasEnabled = MssqlLogger.enabled;
      MssqlLogger.enabled = true;
      try {
        runZoned(
          () => expect(
            callback(nullptr, 1, 0, 16, text.cast(), nullptr, nullptr, 1),
            0,
          ),
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => logs.add(line),
          ),
        );
      } finally {
        MssqlLogger.enabled = wasEnabled;
      }
      expect(logs.single, contains('SQL Server callback'));
      expect(logs.single, endsWith('\uFFFD'));
      expect(DBLib.takeLastMessage(nullptr), endsWith('\uFFFD'));
    });
  });
}

// Exercise the internal client without loading DLLs or contacting a server.
MssqlClient _clientWith(DBLib db, {bool autocommit = true}) => MssqlClient(
  server: 'codec-test',
  username: 'user',
  password: 'test',
  dbLib: db,
  autocommit: autocommit,
);

class _RecordingDb implements DBLib {
  final _arena = Arena();
  bool metadata = false;
  bool transactionCount = false;
  bool transactionRowRead = false;
  int transactionDepth = 0;
  int freedLogins = 0;
  bool closed = false;
  int rowResult = NO_MORE_ROWS;
  _RecordingDb() {
    addTearDown(_arena.releaseAll);
  }

  bool failOpen = false;
  bool emitLoginDiagnostic = true;
  int charsetResult = SUCCEED;
  int convertLength = 1;
  final loginEvents = <String>[];
  final commands = <List<int>>[];
  final procedures = <String>[];
  final params =
      <
        ({
          String name,
          int type,
          int length,
          List<int> bytes,
          int status,
          bool isNull,
        })
      >[];
  bool _result = false;
  int bcpRows = 0;
  final bcpTypes = <int>[];
  int _batchRows = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final Function callback = switch (invocation.memberName) {
      #dbinit => () => SUCCEED,
      #initialize => (dynamic a, dynamic b) => SUCCEED,
      #peerCertificate => (dynamic p, dynamic b, dynamic n) => 0,
      #dbloginfree => (dynamic p) {
        freedLogins++;
      },
      #dbclose => (dynamic p) {
        closed = true;
      },
      #dbsetlname => (dynamic login, dynamic value, dynamic which) => SUCCEED,
      #dbsetopt => (
        dynamic process,
        dynamic option,
        dynamic text,
        dynamic number,
      ) => SUCCEED,
      #dberrhandle => (dynamic pointer) => kErrHandlerPtr,
      #dbmsghandle => (dynamic pointer) => kMsgHandlerPtr,
      #dbsetlogintime => (dynamic seconds) => SUCCEED,
      #dblogin => () => Pointer<LOGINREC>.fromAddress(1),
      #dbsetlcharset => (dynamic login, Pointer<Utf8> charset) {
        loginEvents.add(charset.toDartString());
        return charsetResult;
      },
      #dbsetluser || #dbsetlpwd => (dynamic login, dynamic text) => SUCCEED,
      #dbsetlbool => (dynamic login, int value, int which) {
        loginEvents.add('bcp:$value:$which');
        return value == 1 && which == DBSETBCP ? SUCCEED : FAIL;
      },
      #dbopen => (dynamic login, dynamic server) {
        loginEvents.add('open');
        if (failOpen) {
          if (emitLoginDiagnostic) {
            using((arena) {
              final callback = kMsgHandlerPtr
                  .asFunction<
                    int Function(
                      Pointer<DBPROCESS>,
                      int,
                      int,
                      int,
                      Pointer<Utf8>,
                      Pointer<Utf8>,
                      Pointer<Utf8>,
                      int,
                    )
                  >();
              callback(
                Pointer<DBPROCESS>.fromAddress(99),
                18456,
                1,
                14,
                toNativeFreeTdsText(
                  'Login failed for test user',
                  allocator: arena,
                ),
                nullptr,
                nullptr,
                1,
              );
            });
          }
          return nullptr.cast<DBPROCESS>();
        }
        return Pointer<DBPROCESS>.fromAddress(2);
      },
      #dbcmd => (dynamic process, Pointer<Utf8> text) {
        metadata = text.toDartString().startsWith('SELECT TOP (0)');
        transactionCount = text.toDartString() == 'SELECT @@TRANCOUNT';
        transactionRowRead = false;
        commands.add(text.cast<Uint8>().asTypedList(text.length).toList());
        return SUCCEED;
      },
      #dbsqlexec || #dbrpcsend || #dbsqlok => (dynamic process) => SUCCEED,
      #dbresults => (dynamic process) {
        _result = !_result;
        return _result ? SUCCEED : NO_MORE_RESULTS;
      },
      #dbnumcols => (
        dynamic process,
      ) => transactionCount ? 1 : (metadata ? 2 : 0),
      #dbcoltype => (dynamic process, dynamic col) => SYBINT4,
      #dbcolname => (dynamic process, int col) => toNativeFreeTdsText(
        ['Id', 'Bytes'][col - 1],
        allocator: _arena,
      ),
      #dbnextrow => (dynamic process) {
        if (transactionCount && !transactionRowRead) {
          transactionRowRead = true;
          return REG_ROW;
        }
        return rowResult;
      },
      #dbdatlen => (dynamic process, dynamic col) => 4,
      #dbdata => (
        dynamic process,
        dynamic col,
      ) => (_arena<Int32>()..value = transactionDepth).cast<Uint8>(),
      #dbcanquery => (dynamic process) => SUCCEED,
      #dbcancel => (dynamic process) {
        _result = false;
        return SUCCEED;
      },
      #dbdead => (dynamic process) => 0,
      #dbcount => (dynamic process) => 1,
      #bcp_init => (
        dynamic process,
        dynamic table,
        dynamic data,
        dynamic errors,
        dynamic direction,
      ) => SUCCEED,
      #bcp_bind =>
        (
          dynamic process,
          dynamic address,
          dynamic prefix,
          dynamic length,
          dynamic terminator,
          dynamic terminatorLength,
          dynamic type,
          dynamic column,
        ) {
          bcpTypes.add(type as int);
          return SUCCEED;
        },
      #bcp_collen ||
      #bcp_colptr => (dynamic process, dynamic data, dynamic column) => SUCCEED,
      #bcp_sendrow => (dynamic process) {
        bcpRows++;
        _batchRows++;
        return SUCCEED;
      },
      #bcp_batch || #bcp_done => (dynamic process) {
        final rows = _batchRows;
        _batchRows = 0;
        return rows;
      },
      #dbrpcinit => (dynamic process, Pointer<Utf8> name, dynamic options) {
        procedures.add(name.toDartString());
        return SUCCEED;
      },
      #dbrpcparam =>
        (
          dynamic process,
          Pointer<Utf8> name,
          dynamic status,
          int type,
          dynamic maxlen,
          int length,
          Pointer<Uint8> data,
        ) {
          params.add((
            name: name.toDartString(),
            type: type,
            length: length,
            status: status as int,
            isNull: data == nullptr,
            bytes: data.asTypedList(length).toList(),
          ));
          return SUCCEED;
        },
      #dbconvert =>
        (
          dynamic process,
          dynamic sourceType,
          dynamic source,
          dynamic sourceLength,
          dynamic targetType,
          Pointer<Uint8> target,
          dynamic targetLength,
        ) {
          target.value = 0xe9;
          return convertLength;
        },
      _ => throw StateError(
        'Unexpected DB-Lib operation: ${invocation.memberName}',
      ),
    };
    return invocation.isGetter
        ? callback
        : Function.apply(callback, invocation.positionalArguments);
  }
}
