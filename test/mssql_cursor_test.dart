import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:mssql/mssql.dart';
import 'package:mssql/src/ffi/freetds_bindings.dart';
import 'package:mssql/src/ffi/freetds_text.dart';
import 'package:mssql/src/mssql_client.dart';
import 'package:test/test.dart';

void main() {
  late _CursorDb native;
  late MssqlClient client;
  late MssqlCursor cursor;
  Future<void> open({
    int maxRows = 100000,
    int maxBytes = 64 * 1024 * 1024,
    TlsConfig? tls,
    List<int> certificate = const [],
  }) async {
    native = _CursorDb()..certificate = certificate;
    client = MssqlClient(
      server: 'cursor-test',
      username: 'user',
      password: 'test',
      dbLib: native,
      tls: tls,
      maxResultRows: maxRows,
      maxResultBytes: maxBytes,
    );
    await client.connect();
    cursor = client.cursor();
    final openedCursor = cursor, openedClient = client, openedNative = native;
    addTearDown(() async {
      await openedCursor.close();
      await openedClient.close();
      openedNative.arena.releaseAll();
    });
  }

  test(
    'omitted TLS preserves native defaults; explicit modes set trust',
    () async {
      await open();
      expect(native.loginOptions, isEmpty);
      expect(client.peerCertificate, isNull);
      final cases = <(TlsConfig, String, String?)>[
        (const TlsOff(), 'off', ''),
        (const TlsRequest(), 'request', ''),
        (const TlsRequire(), 'require', ''),
        (const TlsStrict(trust: TlsSystemTrust()), 'strict', 'system'),
        (
          TlsRequire(
            trust: TlsPemTrust(File('ca.pem').absolute.path),
            certificateHostname: 'db.example',
          ),
          'require',
          File('ca.pem').absolute.path,
        ),
      ];
      for (final (policy, mode, ca) in cases) {
        await open(tls: policy);
        expect(native.loginOptions[DBSETENCRYPTION], mode);
        expect(native.loginOptions[DBSETCAFILE], ca);
        expect(
          native.loginOptions[DBSETCERTIFICATEHOSTNAME],
          ca!.isEmpty
              ? null
              : mode == 'strict'
              ? 'cursor-test'
              : 'db.example',
        );
      }
    },
  );

  test(
    'certificate survives native buffer changes and connection close',
    () async {
      final bytes = [1, 2, 3, 4];
      await open(certificate: bytes);
      final saved = client.peerCertificate!;
      bytes[0] = 9;
      await client.close();
      expect(client.peerCertificate, isNull);
      expect(saved.der, [1, 2, 3, 4]);
      native.certificate = [];
      await client.connect();
      expect(client.peerCertificate, isNull);
    },
  );

  test(
    'execute returns cursor without fetching; mixed fetches share one position',
    () async {
      await open();
      expect(cursor.description, isNull);
      expect(cursor.rowcount, -1);
      await expectLater(cursor.fetchone(), throwsStateError);
      await expectLater(cursor.nextset(), throwsStateError);
      native.results = [_Result.numbers(6)];
      expect(await cursor.execute('SELECT id FROM T'), same(cursor));
      expect(native.fetchCalls, 0);
      expect(cursor.columns, ['id']);
      expect(cursor.description!.single.typeCode, SYBINT4);
      final first = (await cursor.fetchone())!;
      expect(first['id'], 1);
      expect(native.fetchCalls, 1);
      expect((await cursor.fetchmany()).single[0], 2);
      cursor.arraysize = 2;
      expect((await cursor.fetchmany()).map((r) => r[0]), [3, 4]);
      expect(await cursor.fetchval(), 5);
      expect((await cursor.fetchall()).single[0], 6);
      expect(first[0], 1);
      expect(cursor.rowcount, 6);
      final calls = native.fetchCalls;
      expect(await cursor.fetchone(), isNull);
      expect(await cursor.fetchval(), isNull);
      expect(await cursor.fetchmany(), isEmpty);
      expect(await cursor.fetchall(), isEmpty);
      expect(native.fetchCalls, calls);
      first.values[0] = 2;
      expect(first['id'], 2);
      expect(() => first['unknown'], throwsArgumentError);
    },
  );

  test('row values can be replaced while columns and length stay fixed', () {
    final columns = ['id', 'name', 'name'];
    final values = <dynamic>[1, 'first', 'second'];
    final row = SqlRow(columns: columns, values: values);
    row[0] = 2;
    row['name'] = 'changed';
    row.values[2] = null;
    expect(row.values, [2, 'changed', null]);
    expect(row['name'], 'changed');
    expect(values, [1, 'first', 'second']);
    columns[0] = 'external';
    expect(row.columns, ['id', 'name', 'name']);
    expect(() => row.values.add(4), throwsUnsupportedError);
    expect(() => row.values.removeAt(0), throwsUnsupportedError);
    expect(() => row.values.length = 0, throwsUnsupportedError);
    expect(() => row.columns[0] = 'other', throwsUnsupportedError);
    expect(() => row['unknown'] = 3, throwsArgumentError);
    expect(() => row[Object()] = 3, throwsArgumentError);
    expect(() => row[-1] = 3, throwsRangeError);
    expect(() => row[3] = 3, throwsRangeError);
    expect(row.values, [2, 'changed', null]);
  });

  test('invalid arguments preserve the cursor position and session', () async {
    await open();
    native.results = [_Result.numbers(2)];
    await cursor.execute('SELECT id FROM T');
    expect(() => cursor.arraysize = 0, throwsArgumentError);
    await expectLater(cursor.fetchmany(-1), throwsArgumentError);
    await expectLater(cursor.skipRows(-1), throwsArgumentError);
    expect(await cursor.fetchmany(0), isEmpty);
    await cursor.skipRows(0);
    await expectLater(cursor.execute('SELECT 1\u0000'), throwsArgumentError);
    await expectLater(cursor.execute('SELECT ?', []), throwsArgumentError);
    await expectLater(cursor.execute('SELECT 1', [1]), throwsArgumentError);
    await expectLater(cursor.execute('SELECT 1', 1), throwsArgumentError);
    await expectLater(
      cursor.execute('SELECT @p', {'p': 1, '@P': 2}),
      throwsArgumentError,
    );
    expect(native.fetchCalls, 0);
    expect(native.cancels, 0);
    expect(await cursor.fetchval(), 1);
    expect(client.isConnected, isTrue);
  });

  test(
    'positional markers ignore quoted text, identifiers and nested comments',
    () async {
      await open();
      const sql =
          "SELECT 'it''s ?' AS [a?]]b], \"a\"\"?b\", ? -- ?\r\n /* ? /* ? */ ? */ WHERE ?=1";
      await cursor.execute(sql, ['text', 7]);
      final sent = utf8.decode(native.params[0].bytes);
      expect(sent, contains("'it''s ?' AS [a?]]b]"));
      expect(sent, contains('"a""?b"'));
      expect(sent, contains('-- ?\r\n /* ? /* ? */ ? */'));
      expect(sent, contains('@__cursor_0'));
      expect(sent, contains('@__cursor_1=1'));
      expect(native.params.length, 4);
      expect(native.params[2].bytes, utf8.encode('text'));
      expect(
        ByteData.sublistView(
          Uint8List.fromList(native.params[3].bytes),
        ).getInt32(0, Endian.host),
        7,
      );
      await cursor.execute("SELECT '@__cursor', ?", [9]);
      expect(utf8.decode(native.params[0].bytes), contains('@__cursor__0'));
    },
  );

  test(
    'positional RPC preserves Unicode, actual NUL, empty and NULL',
    () async {
      await open();
      const text = 'a\u00e7\u00e3o \u4e2d\u6587\u0000';
      await cursor.execute('SELECT ?, ?, ?', [text, '', null]);
      expect(native.params[2].bytes, utf8.encode(text));
      expect(native.params[2].type, SYBNTEXT);
      expect(native.params[3].status, DBRPCEMPTY);
      expect(native.params[4].isNull, isTrue);
      await cursor.executeProcedure('dbo.Echo', {'p': text});
      expect(native.rpcName, '[dbo].[Echo]');
      expect(native.params.single.bytes, utf8.encode(text));
    },
  );

  test(
    'executemany consumes parameter generators incrementally and resets rowcount',
    () async {
      await open();
      var generated = 0;
      Iterable<List<Object?>> values() sync* {
        generated++;
        yield [1];
        expect(native.rpcCalls, 1);
        generated++;
        yield [2];
      }

      await cursor.executemany('INSERT INTO T VALUES (?)', values());
      expect(generated, 2);
      expect(native.rpcCalls, 2);
      expect(cursor.rowcount, -1);
      expect(cursor.description, isNull);
      await expectLater(cursor.fetchone(), throwsStateError);
      await cursor.execute('SELECT 1');
      expect(cursor.isClosed, isFalse);
    },
  );

  test(
    'multiple idle cursors coexist; fully fetched results release native ownership',
    () async {
      await open();
      final second = client.cursor();
      native.results = [_Result.numbers(2)];
      await cursor.execute('SELECT id FROM T');
      await expectLater(second.execute('SELECT 2'), throwsStateError);
      expect(client.isConnected, isTrue);
      expect((await cursor.fetchall()).map((r) => r[0]), [1, 2]);
      await second.execute('SELECT id FROM T');
      expect(cursor.isClosed, isFalse);
      expect(await cursor.fetchone(), isNull);
      expect(await cursor.nextset(), isFalse);
      expect(await second.fetchval(), 1);
      await second.close();
    },
  );

  test(
    'nextset retains prefetched metadata, empty selects and DML counts',
    () async {
      await open();
      native.results = [
        _Result.numbers(2),
        _Result.numbers(0),
        _Result([], [], [], affected: 7),
        _Result.numbers(1),
      ];
      await cursor.execute('SELECT 1; SELECT 2');
      await cursor.fetchone();
      expect(await cursor.nextset(), isTrue);
      expect(native.discards, 1);
      expect(cursor.columns, ['id']);
      expect(await cursor.fetchall(), isEmpty);
      expect(cursor.columns, ['id']);
      final second = client.cursor();
      await expectLater(second.execute('SELECT blocked'), throwsStateError);
      expect(await cursor.nextset(), isTrue);
      expect(cursor.description, isNull);
      expect(cursor.rowcount, 7);
      await expectLater(cursor.fetchall(), throwsStateError);
      expect(await cursor.nextset(), isTrue);
      expect(await cursor.fetchval(), 1);
      expect(await cursor.nextset(), isFalse);
      expect(await cursor.nextset(), isFalse);
      expect(cursor.columns, isNull);
      await second.close();
    },
  );

  test(
    'direct await-for and break leave cursor available for further fetches',
    () async {
      await open();
      native.results = [_Result.numbers(4)];
      await cursor.execute('SELECT id FROM T');
      await for (final row in cursor) {
        expect(row[0], 1);
        break;
      }
      expect(cursor.isClosed, isFalse);
      expect(await cursor.fetchval(), 2);
      await cursor.skipRows(1);
      expect(await cursor.fetchval(), 4);
      expect(await cursor.fetchval(), isNull);
    },
  );

  test(
    'stream pauses stop fetching and canceling a subscription preserves cursor',
    () async {
      await open();
      native.results = [_Result.numbers(100)];
      await cursor.execute('SELECT id FROM T');
      final iterator = StreamIterator(cursor);
      await iterator.moveNext();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(native.fetchCalls, 1);
      await iterator.cancel();
      expect(cursor.isClosed, isFalse);
      expect(native.cancels, 0);
      expect(await cursor.fetchval(), 2);
      await cursor.cancel();
      expect(native.cancels, 1);
      expect(client.isConnected, isTrue);
      expect(cursor.description, isNull);
      await cursor.execute('SELECT id FROM T');
      expect(await cursor.fetchval(), 1);
    },
  );

  test('rows survive native buffer reuse and closing', () async {
    await open();
    native.results = [
      _Result(
        ['text', 'bytes', 'null'],
        [SYBVARCHAR, SYBVARBINARY, SYBVARCHAR],
        [
          [
            '\u00e7\u4e2d\u0000',
            Uint8List.fromList([0, 255]),
            null,
          ],
          ['', Uint8List(0), 'next'],
        ],
      ),
    ];
    await cursor.execute('SELECT * FROM T');
    final rows = await cursor.fetchall();
    await cursor.close();
    expect(rows.first.values, [
      '\u00e7\u4e2d\u0000',
      [0, 255],
      null,
    ]);
    expect(rows.last.values, ['', <int>[], 'next']);
    final bytes = rows.first['bytes'] as Uint8List;
    expect(rows.last['bytes'], isA<Uint8List>());
    expect(() => bytes[0] = 1, throwsUnsupportedError);
    rows.first['bytes'] = Uint8List.fromList([1, 255]);
    expect(rows.first['bytes'], [1, 255]);

    // A fetched binary value can be sent back directly, without Base64 decoding.
    final writer = client.cursor();
    try {
      await writer.execute('SELECT ?', [rows.first['bytes']]);
      expect(native.params.last.type, SYBVARBINARY);
      expect(native.params.last.bytes, [1, 255]);
    } finally {
      await writer.close();
    }
  });

  test(
    'connection close invalidates all cursors, including a paused iterator',
    () async {
      await open();
      final second = client.cursor();
      native.results = [_Result.numbers(3)];
      await cursor.execute('SELECT id FROM T');
      final iterator = StreamIterator(cursor);
      await iterator.moveNext();
      await client.close();
      expect(cursor.isClosed, isTrue);
      expect(second.isClosed, isTrue);
      await expectLater(iterator.moveNext(), throwsStateError);
      await iterator.cancel();
      expect(native.fetchCalls, 1);
    },
  );

  for (final stage in ['execute', 'fetch', 'nextset', 'cancel', 'dead']) {
    test('native $stage failure closes the session and all cursors', () async {
      await open();
      final second = client.cursor();
      native.results = [_Result.numbers(2)];
      if (stage != 'execute') await cursor.execute('SELECT id FROM T');
      native.failure = stage;
      final operation = switch (stage) {
        'execute' => cursor.execute('SELECT id FROM T'),
        'fetch' => cursor.fetchone(),
        'nextset' => cursor.nextset(),
        _ => cursor.close(),
      };
      await expectLater(operation, throwsA(isA<SQLException>()));
      expect(client.isConnected, isFalse);
      expect(cursor.isClosed, isTrue);
      expect(second.isClosed, isTrue);
      expect(native.closes, 1);
      await expectLater(client.execute('SELECT 2'), throwsStateError);
    });
  }

  for (final byteLimit in [false, true]) {
    test('result limits span fetches and result sets ($byteLimit)', () async {
      await open(maxRows: byteLimit ? 100 : 2, maxBytes: byteLimit ? 8 : 1000);
      native.results = [_Result.numbers(1), _Result.numbers(2)];
      await cursor.execute('SELECT 1; SELECT 2');
      await cursor.fetchone();
      await cursor.nextset();
      await cursor.fetchone();
      await expectLater(cursor.fetchone(), throwsA(isA<SQLException>()));
      expect(client.isConnected, isFalse);
    });
  }

  test('invalid UTF-8 during fetch invalidates the session', () async {
    await open();
    native.results = [
      _Result(['text'], [SYBVARCHAR], [
        [
          Uint8List.fromList([0xff]),
        ],
      ]),
    ];
    await cursor.execute('SELECT text FROM T');
    await expectLater(cursor.fetchone(), throwsFormatException);
    expect(client.isConnected, isFalse);
  });

  test('scope validation applies to each queued cursor operation', () async {
    await open();
    var active = true;
    final guarded = client.cursor(
      validate: () {
        if (!active) throw StateError('Transaction ended');
      },
    );
    active = false;
    await expectLater(guarded.execute('SELECT 1'), throwsStateError);
    await guarded.close();
    expect(client.isConnected, isTrue);
  });

  test('queued transaction aliases cannot use a closed cursor', () async {
    await open();
    final closing = cursor.close();
    final committing = cursor.commit();
    final rollingBack = cursor.rollback();
    await expectLater(committing, throwsStateError);
    await expectLater(rollingBack, throwsStateError);
    await closing;
    expect(client.isConnected, isTrue);
  });

  test('native transaction control failure invalidates the session', () async {
    await open();
    native.failure = 'execute';
    await expectLater(cursor.commit(), throwsA(isA<SQLException>()));
    expect(cursor.isClosed, isTrue);
    expect(client.isConnected, isFalse);
  });

  test(
    'unconnected cursor creation fails without starting a queue operation',
    () async {
      final connection = MssqlConnectionAsync();
      expect(connection.cursor, throwsStateError);
      await expectLater(connection.execute('SELECT 1'), throwsStateError);
      expect(await connection.disconnect(), isTrue);
    },
  );
}

class _Result {
  final List<String> columns;
  final List<int> types;
  final List<List<Object?>> rows;
  final int affected;
  _Result(this.columns, this.types, this.rows, {this.affected = -1});
  factory _Result.numbers(int count) =>
      _Result(['id'], [SYBINT4], List.generate(count, (i) => [i + 1]));
}

// A deterministic DB-Lib boundary, with counters and reused native storage.
class _CursorDb implements DBLib {
  final arena = Arena();
  final loginOptions = <int, String>{};
  List<int> certificate = [];
  late final _buffer = arena<Uint8>(16384);
  List<_Result> results = [];
  List<_Result> _active = [];
  int _set = -1, _row = -1;
  int fetchCalls = 0, cancels = 0, discards = 0, closes = 0;
  String? failure;
  String rpcName = '';
  int rpcCalls = 0;
  final params = <({int type, List<int> bytes, int status, bool isNull})>[];
  _Result get current => _active[_set];

  List<int> _bytes(int col) {
    final value = current.rows[_row][col - 1];
    if (value == null) return [];
    if (value is int) {
      return (ByteData(
        4,
      )..setInt32(0, value, Endian.host)).buffer.asUint8List();
    }
    if (value is Uint8List) return value;
    return utf8.encode(value as String);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final Function callback = switch (invocation.memberName) {
      #initialize => (dynamic a, dynamic b) => SUCCEED,
      #peerCertificate => (dynamic p, Pointer<Uint8> buffer, int length) {
        if (buffer != nullptr) {
          buffer.asTypedList(length).setAll(0, certificate);
        }
        return certificate.length;
      },
      #dbsetlogintime => (dynamic seconds) => SUCCEED,
      #dblogin => () => Pointer<LOGINREC>.fromAddress(1),
      #dbloginfree => (dynamic p) {},
      #dbsetlcharset ||
      #dbsetluser ||
      #dbsetlpwd => (dynamic p, dynamic v) => SUCCEED,
      #dbsetlname => (dynamic p, Pointer<Utf8> v, int k) {
        loginOptions[k] = fromNativeFreeTdsText(v);
        return SUCCEED;
      },
      #dbsetlbool => (dynamic p, dynamic v, dynamic k) => SUCCEED,
      #dbsetopt => (dynamic p, dynamic o, dynamic v, dynamic n) => SUCCEED,
      #dbopen => (dynamic p, dynamic s) => Pointer<DBPROCESS>.fromAddress(2),
      #dbclose => (dynamic p) {
        closes++;
      },
      #dbcmd => (dynamic p, dynamic sql) => SUCCEED,
      #dbsqlexec || #dbsqlok => (dynamic p) {
        _active = results;
        _set = -1;
        _row = -1;
        return failure == 'execute' ? FAIL : SUCCEED;
      },
      #dbresults => (dynamic p) {
        if (failure == 'nextset') return FAIL;
        _row = -1;
        return ++_set < _active.length ? SUCCEED : NO_MORE_RESULTS;
      },
      #dbnumcols => (dynamic p) => current.columns.length,
      #dbcolname => (dynamic p, int c) => toNativeFreeTdsText(
        current.columns[c - 1],
        allocator: arena,
      ),
      #dbcoltype => (dynamic p, int c) => current.types[c - 1],
      #dbcount =>
        (dynamic p) => current.columns.isEmpty
            ? current.affected
            : _row >= current.rows.length
            ? current.rows.length
            : -1,
      #dbnextrow => (dynamic p) {
        fetchCalls++;
        if (failure == 'fetch') return FAIL;
        return ++_row < current.rows.length ? REG_ROW : NO_MORE_ROWS;
      },
      #dbdatlen => (dynamic p, int c) => _bytes(c).length,
      #dbdata => (dynamic p, int c) {
        if (current.rows[_row][c - 1] == null) return nullptr.cast<Uint8>();
        final bytes = _bytes(c);
        _buffer.asTypedList(bytes.length).setAll(0, bytes);
        return _buffer;
      },
      #dbcancel => (dynamic p) {
        cancels++;
        return failure == 'cancel' ? FAIL : SUCCEED;
      },
      #dbdead => (dynamic p) => failure == 'dead' ? 1 : 0,
      #dbcanquery => (dynamic p) {
        discards++;
        _row = current.rows.length;
        return SUCCEED;
      },
      #dbrpcinit => (dynamic p, Pointer<Utf8> name, dynamic flags) {
        rpcCalls++;
        rpcName = fromNativeFreeTdsText(name);
        params.clear();
        return SUCCEED;
      },
      #dbrpcparam =>
        (
          dynamic p,
          dynamic name,
          int status,
          int type,
          int maxlen,
          int len,
          Pointer<Uint8> ptr,
        ) {
          params.add((
            type: type,
            bytes: ptr.asTypedList(len).toList(),
            status: status,
            isNull: ptr == nullptr,
          ));
          return SUCCEED;
        },
      #dbrpcsend => (dynamic p) => SUCCEED,
      _ => throw StateError('Unexpected native call: ${invocation.memberName}'),
    };
    return invocation.isGetter
        ? callback
        : Function.apply(callback, invocation.positionalArguments);
  }
}
