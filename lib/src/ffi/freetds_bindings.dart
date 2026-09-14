// Low-level FreeTDS DB-Lib bindings (subset) for:
// - init/login/open/close
// - simple SQL execute + results iteration
// - RPC (for parameterized queries via sp_executesql)
// - BCP bulk APIs
//
// Notes:
// - Signatures below are simplified to commonly-used shapes consistent with FreeTDS DB-Lib (sybdb.h).
// - For production, validate against your exact FreeTDS headers used to build the libs.
// - All pointers are treated as opaque; memory ownership must follow DB-Lib semantics.

// ignore_for_file: library_private_types_in_public_api, non_constant_identifier_names, deprecated_member_use, camel_case_types, constant_identifier_names

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../native_logger.dart';

import 'package:ffi/ffi.dart';

import '../native_loader.dart';
import 'freetds_text.dart';

// Opaque types
base class DBPROCESS extends Opaque {}

base class LOGINREC extends Opaque {}

// Common return codes
const int SUCCEED = 1;
const int FAIL = 0;
const int INT_CANCEL = 2;
const int NO_MORE_RESULTS = 2; // dbresults may return NO_MORE_RESULTS

// Row fetch status (dbnextrow) as per FreeTDS sybdb.h
// REG_ROW and MORE_ROWS are -1 (a valid row is available)
// NO_MORE_ROWS is -2 (end of rows), BUF_FULL is -3 (driver buffer full; call again)
const int REG_ROW = -1;
const int MORE_ROWS = -1;
const int NO_MORE_ROWS = -2; // dbnextrow: no more rows
const int BUF_FULL = -3;
// DB-Lib data types (expanded to align with FreeTDS sybdb.h)
const int SYBCHAR = 47; // char
const int SYBVARCHAR = 39; // varchar
const int SYBINTN = 38; // int (variable length)
const int SYBINT1 = 48; // tinyint
const int SYBINT2 = 52; // smallint
const int SYBINT4 = 56; // int
const int SYBINT8 = 127; // bigint
const int SYBFLT8 = 62; // float(53)
const int SYBREAL = 59; // real (float(24))
const int SYBFLTN = 109; // float (variable length)
const int SYBDATETIME = 61; // datetime
const int SYBDATETIME4 = 58; // smalldatetime
const int SYBDATETIMN = 111; // datetime (nullable)
const int SYBMSDATE = 40; // date
const int SYBMSTIME = 41; // time
const int SYBMSDATETIME2 = 42; // datetime2
const int SYBMSDATETIMEOFFSET = 43; // datetimeoffset
const int SYBBIGDATETIME = 187; // big datetime
const int SYBBIGTIME = 188; // big time
const int SYBBIT = 50; // bit
const int SYBBITN = 104; // bit (nullable)
const int SYBMONEY = 60; // money
const int SYBMONEY4 = 122; // smallmoney
const int SYBMONEYN = 110; // money (nullable)
const int SYBDECIMAL = 106; // decimal
const int SYBNUMERIC = 108; // numeric
const int SYBTEXT = 35; // text
const int SYBNTEXT = 99; // ntext
const int SYBNVARCHAR = 103; // nvarchar
const int SYBBINARY = 45; // binary
const int SYBVARBINARY = 37; // varbinary
const int SYBIMAGE = 34; // image
const int SYBDATE = 49; // (sybase) date
const int SYBTIME = 51; // (sybase) time

// BCP direction
const int DB_IN = 1;
// Login option selector (subset)
const int DBSETBCP = 6; // enable BCP on LOGINREC
// dbsetopt option IDs (subset)
const int DBTEXTSIZE = 17; // set text size for large text retrieval
// Per sybdb.h, DBSETUSER and DBSETPWD constants used with dbsetlname()
const int DBSETUSER = 2;
const int DBSETPWD = 3;
const int DBSETCHARSET = 10;
const int DBSETENCRYPTION = 1005;
// Private extensions in the bundled FreeTDS build; older libraries fail closed.
const int DBSETCAFILE = 20001;
const int DBSETCERTIFICATEHOSTNAME = 20002;
const int DBSETTIME = 34;
const int DBRPCEMPTY = 0x80;

// RPC options (per sybdb.h)
// DBRPCRECOMPILE causes the stored procedure to be recompiled before executing.
// DBRPCRESET cancels any pending RPC(s) and resets the internal RPC state.
const int DBRPCRECOMPILE = 0x0001;
const int DBRPCRESET = 0x0002;

// Typedefs
//
// Group: Connection lifecycle (init/login/open/close)
// These map to DB-Lib primitives to initialize the library, create a LOGINREC,
// set credentials, open a DBPROCESS (connection), and cleanly close/exit.
/// C: RETCODE dbinit(void) — Initialize DB-Lib.
typedef _dbinitC = Int32 Function();
typedef _dbinitDart = int Function();

/// C: LOGINREC* dblogin(void) — Allocate a login record handle
typedef _dbloginC = Pointer<LOGINREC> Function();
typedef _dbloginDart = Pointer<LOGINREC> Function();
typedef _dbloginfreeC = Void Function(Pointer<LOGINREC>);
typedef _dbloginfreeDart = void Function(Pointer<LOGINREC>);

// Note: DBSETLUSER/DBSETLPWD are macros in sybdb.h that call dbsetlname()
// with selectors DBSETUSER/DBSETPWD. We bind dbsetlname and add thin wrappers
// below on the DBLib class to keep a 2-arg Dart API.

/// C: RETCODE dbsetlname(LOGINREC*, const char* value, int which)
/// Use with which=DBSETUSER or DBSETPWD; DBSETLUSER/DBSETLPWD are macros.
typedef _dbsetlnameC = Int32 Function(Pointer<LOGINREC>, Pointer<Utf8>, Int32);
typedef _dbsetlnameDart = int Function(Pointer<LOGINREC>, Pointer<Utf8>, int);

/// C: DBPROCESS* dbopen(LOGINREC*, const char* server) — Open connection
typedef _dbopenC =
    Pointer<DBPROCESS> Function(Pointer<LOGINREC>, Pointer<Utf8>);
typedef _dbopenDart =
    Pointer<DBPROCESS> Function(Pointer<LOGINREC>, Pointer<Utf8>);

typedef _tdsdbopenC =
    Pointer<DBPROCESS> Function(Pointer<LOGINREC>, Pointer<Utf8>, Int32);
typedef _tdsdbopenDart =
    Pointer<DBPROCESS> Function(Pointer<LOGINREC>, Pointer<Utf8>, int);

/// C: void dbclose(DBPROCESS*)
typedef _dbcloseC = Void Function(Pointer<DBPROCESS>);
typedef _dbcloseDart = void Function(Pointer<DBPROCESS>);

/// C: void dbexit(void) — Shutdown DB-Lib (call when done with all DB work)
typedef _dbexitC = Void Function();
typedef _dbexitDart = void Function();

// Group: Command execution and result processing (DML/DDL and row retrieval)
/// C: int dbcmd(DBPROCESS*, const char* sql) — Queue an SQL command string
typedef _dbcmdC = Int32 Function(Pointer<DBPROCESS>, Pointer<Utf8>);
typedef _dbcmdDart = int Function(Pointer<DBPROCESS>, Pointer<Utf8>);

/// C: int dbsqlexec(DBPROCESS*) — Execute previously queued command(s)
typedef _dbsqlexecC = Int32 Function(Pointer<DBPROCESS>);
typedef _dbsqlexecDart = int Function(Pointer<DBPROCESS>);

/// C: int dbresults(DBPROCESS*) — Step through result sets (SUCCEED/NO_MORE_RESULTS)
typedef _dbresultsC = Int32 Function(Pointer<DBPROCESS>);
typedef _dbresultsDart = int Function(Pointer<DBPROCESS>);

/// C: int dbnextrow(DBPROCESS*) — Fetch next row (REG_ROW/-1 for row, NO_MORE_ROWS/-2 end)
typedef _dbnextrowC = Int32 Function(Pointer<DBPROCESS>);
typedef _dbnextrowDart = int Function(Pointer<DBPROCESS>);

/// Cancel all results, or discard only the remaining rows of the current result.
typedef _dbcancelC = Int32 Function(Pointer<DBPROCESS>);
typedef _dbcancelDart = int Function(Pointer<DBPROCESS>);
typedef _dbdeadC = Uint8 Function(Pointer<DBPROCESS>);
typedef _dbdeadDart = int Function(Pointer<DBPROCESS>);

/// C: int dbnumcols(DBPROCESS*) — Column count for current result set
typedef _dbnumcolsC = Int32 Function(Pointer<DBPROCESS>);
typedef _dbnumcolsDart = int Function(Pointer<DBPROCESS>);

/// C: const char* dbcolname(DBPROCESS*, int col) — Column name (1-based index)
typedef _dbcolnameC = Pointer<Utf8> Function(Pointer<DBPROCESS>, Int32);
typedef _dbcolnameDart = Pointer<Utf8> Function(Pointer<DBPROCESS>, int);

/// C: int dbcoltype(DBPROCESS*, int col) — Column DB-Lib type code
typedef _dbcoltypeC = Int32 Function(Pointer<DBPROCESS>, Int32);
typedef _dbcoltypeDart = int Function(Pointer<DBPROCESS>, int);

/// C: int dbdatlen(DBPROCESS*, int col) — Byte length of current row’s column value
typedef _dbdatlenC = Int32 Function(Pointer<DBPROCESS>, Int32);
typedef _dbdatlenDart = int Function(Pointer<DBPROCESS>, int);

/// C: BYTE* dbdata(DBPROCESS*, int col) — Pointer to current row’s column bytes
typedef _dbdataC = Pointer<Uint8> Function(Pointer<DBPROCESS>, Int32);
typedef _dbdataDart = Pointer<Uint8> Function(Pointer<DBPROCESS>, int);

/// C: int dbcount(DBPROCESS*) — Rows affected by last DML/DDL
typedef _dbcountC = Int32 Function(Pointer<DBPROCESS>);
typedef _dbcountDart = int Function(Pointer<DBPROCESS>);

// Group: Timeouts and database selection
/// C: int dbsetlogintime(int seconds) — Login/connect timeout
typedef _dbsetlogintimeC = Int32 Function(Int32);
typedef _dbsetlogintimeDart = int Function(int);

/// C: int dbsettime(int seconds) — Query/statement timeout
typedef _dbsettimeC = Int32 Function(Int32);
typedef _dbsettimeDart = int Function(int);

/// C: int dbuse(DBPROCESS*, const char* db) — Change current database
typedef _dbuseC = Int32 Function(Pointer<DBPROCESS>, Pointer<Utf8>);
typedef _dbuseDart = int Function(Pointer<DBPROCESS>, Pointer<Utf8>);

// Group: LOGINREC options (e.g., enable BCP using DBSETBCP)
/// C: int dbsetlbool(LOGINREC*, int value, int which) — Toggle login options
typedef _dbsetlboolC = Int32 Function(Pointer<LOGINREC>, Int32, Int32);
typedef _dbsetlboolDart = int Function(Pointer<LOGINREC>, int, int);

/// C: int dbsetopt(DBPROCESS*, int option, const char* char_param, int int_param)
typedef _dbsetoptC =
    Int32 Function(Pointer<DBPROCESS>, Int32, Pointer<Utf8>, Int32);
typedef _dbsetoptDart =
    int Function(Pointer<DBPROCESS>, int, Pointer<Utf8>, int);

// Group: RPC for parameterized queries (e.g., sp_executesql)
/// C: int dbrpcinit(DBPROCESS*, const char* rpcname, uint16_t options)
typedef _dbrpcinitC = Int32 Function(Pointer<DBPROCESS>, Pointer<Utf8>, Uint16);
typedef _dbrpcinitDart = int Function(Pointer<DBPROCESS>, Pointer<Utf8>, int);

/// C: int dbrpcparam(DBPROCESS*, const char* name, uint8 status,
///                   int type, int maxlen, int datalen, BYTE* value)
typedef _dbrpcparamC =
    Int32 Function(
      Pointer<DBPROCESS>,
      Pointer<Utf8> /*name*/,
      Uint8 /*status*/,
      Int32 /*type*/,
      Int32 /*maxlen*/,
      Int32 /*datalen*/,
      Pointer<Uint8> /*value*/,
    );
typedef _dbrpcparamDart =
    int Function(
      Pointer<DBPROCESS>,
      Pointer<Utf8>,
      int,
      int,
      int,
      int,
      Pointer<Uint8>,
    );

/// C: int dbrpcsend(DBPROCESS*) — Send RPC call with parameters
typedef _dbrpcsendC = Int32 Function(Pointer<DBPROCESS>);
typedef _dbrpcsendDart = int Function(Pointer<DBPROCESS>);

/// C: int dbsqlok(DBPROCESS*) — Finalize send; proceed to dbresults/dbnextrow
typedef _dbsqlokC = Int32 Function(Pointer<DBPROCESS>);
typedef _dbsqlokDart = int Function(Pointer<DBPROCESS>);

// Group: Error and message handlers
/// C: EHANDLEFUNC dberrhandle(EHANDLEFUNC handler)
typedef _errHandlerSigC =
    Int32 Function(
      Pointer<DBPROCESS>,
      Int32 /*severity*/,
      Int32 /*dberr*/,
      Int32 /*oserr*/,
      Pointer<Utf8> /*dberrstr*/,
      Pointer<Utf8> /*oserrstr*/,
    );
typedef _dberrhandleC =
    Pointer<NativeFunction<_errHandlerSigC>> Function(
      Pointer<NativeFunction<_errHandlerSigC>>,
    );
typedef _dberrhandleDart =
    Pointer<NativeFunction<_errHandlerSigC>> Function(
      Pointer<NativeFunction<_errHandlerSigC>>,
    );

/// C: MHANDLEFUNC dbmsghandle(MHANDLEFUNC handler)
typedef _msgHandlerSigC =
    Int32 Function(
      Pointer<DBPROCESS>,
      Int32 /*msgno*/,
      Int32 /*msgstate*/,
      Int32 /*severity*/,
      Pointer<Utf8> /*msgtext*/,
      Pointer<Utf8> /*server*/,
      Pointer<Utf8> /*proc*/,
      Int32 /*line*/,
    );
typedef _dbmsghandleC =
    Pointer<NativeFunction<_msgHandlerSigC>> Function(
      Pointer<NativeFunction<_msgHandlerSigC>>,
    );
typedef _dbmsghandleDart =
    Pointer<NativeFunction<_msgHandlerSigC>> Function(
      Pointer<NativeFunction<_msgHandlerSigC>>,
    );

typedef _wrapperInitC =
    Int32 Function(
      Pointer<NativeFunction<_errHandlerSigC>>,
      Pointer<NativeFunction<_msgHandlerSigC>>,
    );
typedef _wrapperInitDart =
    int Function(
      Pointer<NativeFunction<_errHandlerSigC>>,
      Pointer<NativeFunction<_msgHandlerSigC>>,
    );

// Group: BCP (bulk copy) — high-throughput inserts
/// C: int bcp_init(DBPROCESS*, const char* table, const char* datafile,
///                 const char* errorfile, int direction)
typedef _bcp_initC =
    Int32 Function(
      Pointer<DBPROCESS>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
    );
typedef _bcp_initDart =
    int Function(
      Pointer<DBPROCESS>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
    );

/// C: int bcp_bind(DBPROCESS*, BYTE* varaddr, int prefixlen, int varlen,
///                 BYTE* terminator, int termlen, int type, int varnum)
typedef _bcp_bindC =
    Int32 Function(
      Pointer<DBPROCESS>,
      Pointer<Uint8> /*varaddr*/,
      Int32 /*prefixlen*/,
      Int32 /*varlen*/,
      Pointer<Uint8> /*terminator*/,
      Int32 /*termlen*/,
      Int32 /*type*/,
      Int32 /*varnum*/,
    );
typedef _bcp_bindDart =
    int Function(
      Pointer<DBPROCESS>,
      Pointer<Uint8>,
      int,
      int,
      Pointer<Uint8>,
      int,
      int,
      int,
    );

/// C: int bcp_sendrow(DBPROCESS*) — Send a single bound row
typedef _bcp_sendrowC = Int32 Function(Pointer<DBPROCESS>);
typedef _bcp_sendrowDart = int Function(Pointer<DBPROCESS>);

/// C: int bcp_batch(DBPROCESS*) — Commit current batch; returns rows copied in batch
typedef _bcp_batchC = Int32 Function(Pointer<DBPROCESS>);
typedef _bcp_batchDart = int Function(Pointer<DBPROCESS>);

/// C: int bcp_done(DBPROCESS*) — Finalize BCP; returns total rows copied
typedef _bcp_doneC = Int32 Function(Pointer<DBPROCESS>);
typedef _bcp_doneDart = int Function(Pointer<DBPROCESS>);

// BCP per-row helpers
/// C: int bcp_collen(DBPROCESS*, int newlen, int col) — Set data length for a column
typedef _bcp_collenC = Int32 Function(Pointer<DBPROCESS>, Int32, Int32);
typedef _bcp_collenDart = int Function(Pointer<DBPROCESS>, int, int);

/// C: int bcp_colptr(DBPROCESS*, BYTE* data, int col) — Attach data pointer for a column
typedef _bcp_colptrC =
    Int32 Function(Pointer<DBPROCESS>, Pointer<Uint8>, Int32);
typedef _bcp_colptrDart = int Function(Pointer<DBPROCESS>, Pointer<Uint8>, int);

// Group: Type conversion helper
/// C: int dbconvert(DBPROCESS*, int srctype, BYTE* src, int srclen,
///                  int desttype, BYTE* dest, int destlen)
// Used as a fallback to stringify or coerce DECIMAL/NUMERIC/etc.
typedef _dbconvertC =
    Int32 Function(
      Pointer<DBPROCESS>,
      Int32 /*srctype*/,
      Pointer<Uint8> /*src*/,
      Int32 /*srclen*/,
      Int32 /*desttype*/,
      Pointer<Uint8> /*dest*/,
      Int32 /*destlen*/,
    );
typedef _dbconvertDart =
    int Function(
      Pointer<DBPROCESS>,
      int,
      Pointer<Uint8>,
      int,
      int,
      Pointer<Uint8>,
      int,
    );

// Loader of symbols from libsybdb
class DBLib {
  /*
  DBLib
  
  A thin, low-level loader and holder of FreeTDS DB-Lib (libsybdb) symbols.
  
  Summary:
  - Provides typed Dart FFI entry points for connection lifecycle, SQL exec/result
    iteration, RPC (parameterized queries), BCP bulk copy, and value conversion.
  - Exposes thin wrappers (dbsetluser/dbsetlpwd) that map to dbsetlname with
    DBSETUSER/DBSETPWD selectors to keep a simple 2-arg API for credentials.
  
  Contract (conventions):
  - Return codes mirror DB-Lib (SUCCEED=1, FAIL=0). Some functions use special
    codes (e.g., dbresults may return NO_MORE_RESULTS=2; dbnextrow returns
    REG_ROW=-1, NO_MORE_ROWS=-2, etc.).
  - All pointers are opaque; the caller owns higher-level resource semantics
    (create LOGINREC with dblogin, open DBPROCESS with dbopen, close with dbclose,
    and shut down library with dbexit when done).
  
  Typical lifecycle:
  1) dbinit()
  2) final login = dblogin(); dbsetluser(login, user), dbsetlpwd(login, pass);
  3) final dbproc = dbopen(login, server);
  4) dbcmd/dbsqlexec -> dbresults loop -> dbnextrow iteration -> dbcount, etc.
  5) dbclose(dbproc); dbexit();
  
  Notes:
  - DBSETLUSER/DBSETLPWD are macros in sybdb.h; use dbsetlname under the hood.
  - Use dbsetlogintime/dbsettime for timeouts and dbuse to change database.
  - For high-throughput inserts, use BCP APIs (bcp_init/bind/sendrow/batch/done).
  */
  final DynamicLibrary _lib;
  late final _dbinitDart dbinit;
  late final _wrapperInitDart initialize;
  late final int Function(Pointer<DBPROCESS>, Pointer<Uint8>, int)
  peerCertificate;
  late final _dbloginDart dblogin;
  late final _dbloginfreeDart dbloginfree;
  late final _dbsetlnameDart dbsetlname;
  late final _dbopenDart dbopen;
  late final _dbcloseDart dbclose;
  late final _dbexitDart dbexit;

  late final _dbcmdDart dbcmd;
  late final _dbsqlexecDart dbsqlexec;
  late final _dbresultsDart dbresults;
  late final _dbnextrowDart dbnextrow;
  late final _dbcancelDart dbcancel;
  late final _dbcancelDart dbcanquery;
  late final _dbdeadDart dbdead;
  late final _dbnumcolsDart dbnumcols;
  late final _dbcolnameDart dbcolname;
  late final _dbcoltypeDart dbcoltype;
  late final _dbdatlenDart dbdatlen;
  late final _dbdataDart dbdata;
  late final _dbcountDart dbcount;

  late final _dbsetlogintimeDart dbsetlogintime;
  late final _dbsettimeDart dbsettime;
  late final _dbuseDart dbuse;
  late final _dbsetlboolDart dbsetlbool;
  late final _dbsetoptDart dbsetopt;

  late final _dbrpcinitDart dbrpcinit;
  late final _dbrpcparamDart dbrpcparam;
  late final _dbrpcsendDart dbrpcsend;
  late final _dbsqlokDart dbsqlok;
  late final _dberrhandleDart dberrhandle;
  late final _dbmsghandleDart dbmsghandle;

  late final _bcp_initDart bcp_init;
  late final _bcp_bindDart bcp_bind;
  late final _bcp_sendrowDart bcp_sendrow;
  late final _bcp_batchDart bcp_batch;
  late final _bcp_doneDart bcp_done;
  late final _bcp_collenDart bcp_collen;
  late final _bcp_colptrDart bcp_colptr;
  late final _dbconvertDart dbconvert;

  DBLib(this._lib) {
    // Required symbol also rejects binaries predating the TLS configuration API.
    peerCertificate = _lib
        .lookupFunction<
          Int32 Function(Pointer<DBPROCESS>, Pointer<Uint8>, Int32),
          int Function(Pointer<DBPROCESS>, Pointer<Uint8>, int)
        >('sql_server_wrapper_peer_certificate');
    initialize = _lib.lookupFunction<_wrapperInitC, _wrapperInitDart>(
      'sql_server_wrapper_init',
    );
    // Lookups: Connection lifecycle (init/login/open/close)
    dbinit = _lib.lookupFunction<_dbinitC, _dbinitDart>(
      'dbinit',
    ); // Initialize DB-Lib
    dblogin = _lib.lookupFunction<_dbloginC, _dbloginDart>(
      'dblogin',
    ); // Create LOGINREC
    dbloginfree = _lib.lookupFunction<_dbloginfreeC, _dbloginfreeDart>(
      'dbloginfree',
    );
    // DBSETLUSER/DBSETLPWD are macros -> bind the underlying function dbsetlname
    dbsetlname = _lib.lookupFunction<_dbsetlnameC, _dbsetlnameDart>(
      'dbsetlname',
    ); // Set LOGINREC field by selector
    try {
      dbopen = _lib.lookupFunction<_dbopenC, _dbopenDart>('dbopen');
    } catch (_) {
      final open = _lib.lookupFunction<_tdsdbopenC, _tdsdbopenDart>(
        'tdsdbopen',
      );
      dbopen = (login, server) => open(login, server, 1);
    }
    dbclose = _lib.lookupFunction<_dbcloseC, _dbcloseDart>(
      'dbclose',
    ); // Close DBPROCESS
    dbexit = _lib.lookupFunction<_dbexitC, _dbexitDart>(
      'dbexit',
    ); // Shutdown DB-Lib

    // Lookups: Command execution and results iteration (DML/DDL + rows)
    dbcmd = _lib.lookupFunction<_dbcmdC, _dbcmdDart>('dbcmd'); // Queue SQL text
    dbsqlexec = _lib.lookupFunction<_dbsqlexecC, _dbsqlexecDart>(
      'dbsqlexec',
    ); // Execute queued SQL
    dbresults = _lib.lookupFunction<_dbresultsC, _dbresultsDart>(
      'dbresults',
    ); // Iterate result sets
    dbnextrow = _lib.lookupFunction<_dbnextrowC, _dbnextrowDart>(
      'dbnextrow',
    ); // Fetch next row
    dbcancel = _lib.lookupFunction<_dbcancelC, _dbcancelDart>('dbcancel');
    dbcanquery = _lib.lookupFunction<_dbcancelC, _dbcancelDart>('dbcanquery');
    dbdead = _lib.lookupFunction<_dbdeadC, _dbdeadDart>('dbdead');
    dbnumcols = _lib.lookupFunction<_dbnumcolsC, _dbnumcolsDart>(
      'dbnumcols',
    ); // Column count
    dbcolname = _lib.lookupFunction<_dbcolnameC, _dbcolnameDart>(
      'dbcolname',
    ); // Column name
    dbcoltype = _lib.lookupFunction<_dbcoltypeC, _dbcoltypeDart>(
      'dbcoltype',
    ); // Column type code
    dbdatlen = _lib.lookupFunction<_dbdatlenC, _dbdatlenDart>(
      'dbdatlen',
    ); // Current value byte length
    dbdata = _lib.lookupFunction<_dbdataC, _dbdataDart>(
      'dbdata',
    ); // Current value pointer
    dbcount = _lib.lookupFunction<_dbcountC, _dbcountDart>(
      'dbcount',
    ); // Rows affected

    // Lookups: Timeouts and database selection
    dbsetlogintime = _lib.lookupFunction<_dbsetlogintimeC, _dbsetlogintimeDart>(
      'dbsetlogintime',
    ); // Login timeout
    dbsettime = _lib.lookupFunction<_dbsettimeC, _dbsettimeDart>(
      'dbsettime',
    ); // Statement timeout
    dbuse = _lib.lookupFunction<_dbuseC, _dbuseDart>(
      'dbuse',
    ); // Change database
    dbsetlbool = _lib.lookupFunction<_dbsetlboolC, _dbsetlboolDart>(
      'dbsetlbool',
    ); // Toggle login options (e.g., BCP)
    dbsetopt = _lib.lookupFunction<_dbsetoptC, _dbsetoptDart>(
      'dbsetopt',
    ); // Set session options (e.g., DBTEXTSIZE)

    // Lookups: RPC for parameterized queries
    dbrpcinit = _lib.lookupFunction<_dbrpcinitC, _dbrpcinitDart>(
      'dbrpcinit',
    ); // Start RPC (e.g., sp_executesql)
    dbrpcparam = _lib.lookupFunction<_dbrpcparamC, _dbrpcparamDart>(
      'dbrpcparam',
    ); // Add RPC parameter
    dbrpcsend = _lib.lookupFunction<_dbrpcsendC, _dbrpcsendDart>(
      'dbrpcsend',
    ); // Send RPC
    dbsqlok = _lib.lookupFunction<_dbsqlokC, _dbsqlokDart>(
      'dbsqlok',
    ); // Finalize send

    // Lookups: error and message handlers
    dberrhandle = _lib.lookupFunction<_dberrhandleC, _dberrhandleDart>(
      'dberrhandle',
    );
    dbmsghandle = _lib.lookupFunction<_dbmsghandleC, _dbmsghandleDart>(
      'dbmsghandle',
    );

    // Lookups: BCP (bulk copy) high-throughput inserts
    bcp_init = _lib.lookupFunction<_bcp_initC, _bcp_initDart>(
      'bcp_init',
    ); // Init bulk copy
    bcp_bind = _lib.lookupFunction<_bcp_bindC, _bcp_bindDart>(
      'bcp_bind',
    ); // Bind program variables
    bcp_sendrow = _lib.lookupFunction<_bcp_sendrowC, _bcp_sendrowDart>(
      'bcp_sendrow',
    ); // Send row
    bcp_batch = _lib.lookupFunction<_bcp_batchC, _bcp_batchDart>(
      'bcp_batch',
    ); // Commit batch
    bcp_done = _lib.lookupFunction<_bcp_doneC, _bcp_doneDart>(
      'bcp_done',
    ); // Finalize bulk copy
    bcp_collen = _lib.lookupFunction<_bcp_collenC, _bcp_collenDart>(
      'bcp_collen',
    ); // Set column length
    bcp_colptr = _lib.lookupFunction<_bcp_colptrC, _bcp_colptrDart>(
      'bcp_colptr',
    ); // Set column pointer

    // Lookup: Type conversion helper
    dbconvert = _lib.lookupFunction<_dbconvertC, _dbconvertDart>(
      'dbconvert',
    ); // Convert values (fallback)
  }

  /// Set the username on a LOGINREC using the DBSETUSER selector.
  ///
  /// Parameters:
  /// - login: LOGINREC* obtained from [dblogin]. Must be non-null.
  /// - username: UTF-8 pointer to the username string (null-terminated).
  ///
  /// Returns: SUCCEED (1) on success, FAIL (0) on error.
  ///
  /// Notes:
  /// - This is a convenience wrapper over [dbsetlname] with `which=DBSETUSER`.
  /// - The underlying C function is `dbsetlname(LOGINREC*, const char*, int)`.
  int dbsetluser(Pointer<LOGINREC> login, Pointer<Utf8> username) =>
      dbsetlname(login, username, DBSETUSER);

  /// Set the password on a LOGINREC using the DBSETPWD selector.
  ///
  /// Parameters:
  /// - login: LOGINREC* obtained from [dblogin]. Must be non-null.
  /// - password: UTF-8 pointer to the password string (null-terminated).
  ///
  /// Returns: SUCCEED (1) on success, FAIL (0) on error.
  ///
  /// Notes:
  /// - This is a convenience wrapper over [dbsetlname] with `which=DBSETPWD`.
  /// - The underlying C function is `dbsetlname(LOGINREC*, const char*, int)`.
  int dbsetlpwd(Pointer<LOGINREC> login, Pointer<Utf8> password) =>
      dbsetlname(login, password, DBSETPWD);

  /// Set the charset on a LOGINREC using the DBSETCHARSET selector.
  int dbsetlcharset(Pointer<LOGINREC> login, Pointer<Utf8> charset) =>
      dbsetlname(login, charset, DBSETCHARSET);

  static DBLib load() => DBLib(NativeLoader.loadDBLib());

  // Capture synchronously: a failed dbopen may report a temporary DBPROCESS
  // in its callbacks but return nullptr, making per-pointer lookup impossible.
  static (T, List<String>) captureDiagnostics<T>(T Function() action) {
    final previous = _DbLibErrorStore.capture;
    final messages = <String>[];
    _DbLibErrorStore.capture = messages;
    try {
      return (action(), messages);
    } finally {
      _DbLibErrorStore.capture = previous;
    }
  }

  // Expose latest DB-Lib error/message captured by installed handlers.
  // These are per-DBPROCESS (or 0 for library-level) and are cleared on read.
  static String? takeLastError(Pointer<DBPROCESS>? dbproc) =>
      _DbLibErrorStore.takeLastError(dbproc);
  static String? takeLastMessage(Pointer<DBPROCESS>? dbproc) =>
      _DbLibErrorStore.takeLastMessage(dbproc);
}

// Simple global store for the latest error/message per DBPROCESS.
class _DbLibErrorStore {
  static List<String>? capture;
  static final Map<int, String> _lastError = <int, String>{};
  static final Map<int, String> _lastMessage = <int, String>{};
  static String? takeLastError(Pointer<DBPROCESS>? dbproc) {
    final k = dbproc == null || dbproc == nullptr ? 0 : dbproc.address;
    return _lastError.remove(k);
  }

  static void setLastError(Pointer<DBPROCESS>? dbproc, String msg) {
    if (capture != null) {
      capture!.add(msg);
      return;
    }
    final k = dbproc == null || dbproc == nullptr ? 0 : dbproc.address;
    _lastError[k] = msg;
  }

  static String? takeLastMessage(Pointer<DBPROCESS>? dbproc) {
    final k = dbproc == null || dbproc == nullptr ? 0 : dbproc.address;
    return _lastMessage.remove(k);
  }

  static void setLastMessage(Pointer<DBPROCESS>? dbproc, String msg) {
    if (capture != null) {
      capture!.add(msg);
      return;
    }
    final k = dbproc == null || dbproc == nullptr ? 0 : dbproc.address;
    _lastMessage[k] = msg;
  }
}

// Dart-side error handlers (installed via dberrhandle/dbmsghandle).
// Diagnostics must not throw through a native callback. Malformed sequences
// become U+FFFD here only; result data is decoded strictly with the same codec.
String _decodeDiagnostic(Pointer<Utf8> text) {
  if (text == nullptr) return '';
  try {
    final bytes = text.cast<Uint8>();
    var length = 0;
    while (length < 4096 && bytes[length] != 0) {
      length++;
    }
    return freeTdsTextCodec.decode(
      bytes.asTypedList(length),
      allowMalformed: true,
    );
  } catch (_) {
    return '';
  }
}

int _dartDbErrHandler(
  Pointer<DBPROCESS> dbproc,
  int severity,
  int dberr,
  int oserr,
  Pointer<Utf8> dberrstr,
  Pointer<Utf8> oserrstr,
) {
  final msg =
      '[severity=$severity dberr=$dberr oserr=$oserr] '
      '${_decodeDiagnostic(dberrstr)}'
      '${oserrstr == nullptr ? '' : ' | ${_decodeDiagnostic(oserrstr)}'}';
  _DbLibErrorStore.setLastError(dbproc, msg);
  try {
    MssqlLogger.e('DB-Lib callback | $msg');
  } catch (_) {
    // Logging must not throw through a native callback.
  }
  return INT_CANCEL;
}

int _dartDbMsgHandler(
  Pointer<DBPROCESS> dbproc,
  int msgno,
  int msgstate,
  int severity,
  Pointer<Utf8> msgtext,
  Pointer<Utf8> server,
  Pointer<Utf8> proc,
  int line,
) {
  final msg =
      '[msgno=$msgno state=$msgstate severity=$severity line=$line] '
      '${_decodeDiagnostic(msgtext)}';
  _DbLibErrorStore.setLastMessage(dbproc, msg);
  try {
    MssqlLogger.i('SQL Server callback | $msg');
  } catch (_) {
    // Logging must not throw through a native callback.
  }
  return 0;
}

// Exposed pointers for installation; keep them alive for the process lifetime.
final Pointer<NativeFunction<_errHandlerSigC>> kErrHandlerPtr =
    Pointer.fromFunction<_errHandlerSigC>(_dartDbErrHandler, INT_CANCEL);
final Pointer<NativeFunction<_msgHandlerSigC>> kMsgHandlerPtr =
    Pointer.fromFunction<_msgHandlerSigC>(_dartDbMsgHandler, 0);

// Helpers to marshal bytes for dbdata()

/// Returns an int value clamped within [min]..[max].
int _clampInt(int v, int min, int max) => v < min ? min : (v > max ? max : v);

/// Cheap ByteData view over the foreign memory pointed to by [ptr] for [len] bytes.
/// Creates a Uint8List view first, then wraps it with ByteData for endian-safe reads.
ByteData _asByteData(Pointer<Uint8> ptr, int len) {
  final bytes = ptr.asTypedList(len);
  return ByteData.view(bytes.buffer, bytes.offsetInBytes, len);
}

/// Decode a DB-Lib value pointed by [ptr]/[len] given its DB-Lib [type].
///
/// - This performs pragmatic, alignment-safe decoding for common scalar types
///   (integers, floats, money, datetime), basic text (char/varchar/ntext/nvarchar),
///   and binary (copied, unmodifiable Uint8List).
/// - For complex types (DECIMAL/NUMERIC and newer SQL Server date/time types),
///   prefer [decodeDbValueWithFallback] which can call `dbconvert` to produce
///   exact decimal strings.
/// - Returns null if [ptr] is null; empty text/binary values remain distinct.
dynamic decodeDbValue(int type, Pointer<Uint8> ptr, int len) {
  if (ptr == nullptr) return null;
  if (len < 0) throw FormatException('Negative DB-Lib value length');
  if (type == SYBBINARY || type == SYBVARBINARY || type == SYBIMAGE) {
    return Uint8List.fromList(ptr.asTypedList(len)).asUnmodifiableView();
  }
  if (len == 0) {
    if ([SYBCHAR, SYBVARCHAR, SYBTEXT, SYBNTEXT, SYBNVARCHAR].contains(type)) {
      return '';
    }
    throw FormatException('Empty fixed-size DB-Lib value (type=$type)');
  }
  final bd =
      (type == SYBINT1 ||
          type == SYBCHAR ||
          type == SYBVARCHAR ||
          type == SYBTEXT ||
          type == SYBNTEXT ||
          type == SYBNVARCHAR)
      ? null
      : _asByteData(
          ptr,
          len,
        ); // avoid ByteData for simple 1-byte or string types
  switch (type) {
    case SYBINTN:
      // Variable-length int: length tells the actual width (1,2,4,8)
      switch (len) {
        case 1:
          return ptr.cast<Uint8>().value;
        case 2:
          return _asByteData(ptr, 2).getInt16(0, Endian.host);
        case 4:
          return _asByteData(ptr, 4).getInt32(0, Endian.host);
        case 8:
          return _asByteData(ptr, 8).getInt64(0, Endian.host);
        default:
          return ptr.asTypedList(len);
      }
    case SYBINT1:
      return ptr.cast<Uint8>().value;
    case SYBINT2:
      return bd!.getInt16(0, Endian.host);
    case SYBINT4:
      return bd!.getInt32(0, Endian.host);
    case SYBINT8:
      return bd!.getInt64(0, Endian.host);
    case SYBREAL:
      return bd!.getFloat32(0, Endian.host);
    case SYBFLT8:
      return bd!.getFloat64(0, Endian.host);
    case SYBFLTN:
      // infer by length
      if (len == 4) return _asByteData(ptr, 4).getFloat32(0, Endian.host);
      if (len == 8) return _asByteData(ptr, 8).getFloat64(0, Endian.host);
      return ptr.asTypedList(len);
    case SYBBIT:
      return ptr.cast<Uint8>().value != 0;
    case SYBBITN:
      return len == 0 ? null : (ptr.cast<Uint8>().value != 0);
    case SYBMONEY:
      {
        // DBMONEY stores its high word first, independently of host endianness.
        final value =
            (BigInt.from(bd!.getInt32(0, Endian.host)) << 32) +
            BigInt.from(bd.getUint32(4, Endian.host));
        return _scaledMoney(value);
      }
    case SYBMONEY4:
      {
        return _scaledMoney(BigInt.from(bd!.getInt32(0, Endian.host)));
      }
    case SYBDATETIME:
      {
        // DBDATETIME: days since 1900-01-01, time in 1/300 sec units
        final days = bd!.getInt32(0, Endian.host);
        final time300 = bd.getInt32(4, Endian.host);
        final base = DateTime.utc(1900, 1, 1);
        final date = base.add(Duration(days: days));
        final micros = (time300 * 1000000) ~/ 300;
        final dt = date.add(Duration(microseconds: micros));
        return dt.toIso8601String().replaceFirst('Z', '');
      }
    case SYBDATETIME4:
      {
        // DBDATETIME4: USMALLINT days since 1900-01-01, USMALLINT minutes since midnight
        final days = bd!.getUint16(0, Endian.host);
        final minutes = bd.getUint16(2, Endian.host);
        final base = DateTime.utc(1900, 1, 1);
        final dt = base.add(Duration(days: days, minutes: minutes));
        return dt.toIso8601String().replaceFirst('Z', '');
      }
    case SYBDATETIMN:
      {
        if (len == 8) {
          final days = bd!.getInt32(0, Endian.host);
          final time300 = bd.getInt32(4, Endian.host);
          final base = DateTime.utc(1900, 1, 1);
          final date = base.add(Duration(days: days));
          final micros = (time300 * 1000000) ~/ 300;
          final dt = date.add(Duration(microseconds: micros));
          return dt.toIso8601String().replaceFirst('Z', '');
        } else if (len == 4) {
          final days = bd!.getUint16(0, Endian.host);
          final minutes = bd.getUint16(2, Endian.host);
          final base = DateTime.utc(1900, 1, 1);
          final dt = base.add(Duration(days: days, minutes: minutes));
          return dt.toIso8601String().replaceFirst('Z', '');
        }
        return null;
      }
    case SYBMSDATE:
    case SYBMSTIME:
    case SYBMSDATETIME2:
    case SYBMSDATETIMEOFFSET:
      return _decodeDateTimeAll(type, bd!);
    case SYBCHAR:
    case SYBVARCHAR:
    case SYBTEXT:
    case SYBNTEXT:
    case SYBNVARCHAR:
      {
        final bytes = ptr.asTypedList(len);
        return freeTdsTextCodec.decode(bytes);
      }
    // For DECIMAL/NUMERIC/DATETIME, you may need proper conversion against TDS metadata.
    default:
      return ptr.asTypedList(len); // fallback raw bytes
  }
}

/// Decode with dbconvert fallback: for any unhandled type, try to stringify to SYBVARCHAR.
///
/// Strategy:
/// - First, call [decodeDbValue] for fast-path common types.
/// - Binary SQL types keep their Uint8List. For unhandled types returning raw
///   bytes, attempt conversion via `dbconvert(..., SYBVARCHAR, ...)`.
/// - DECIMAL/NUMERIC stay exact decimal strings; never round them to double.
/// - As a last resort, base64-encode raw bytes for JSON-safety.
dynamic decodeDbValueWithFallback(
  DBLib db,
  Pointer<DBPROCESS> dbproc,
  int type,
  Pointer<Uint8> ptr,
  int len,
) {
  // Prefer native decode first
  final v = decodeDbValue(type, ptr, len);
  if (v is Uint8List &&
      type != SYBBINARY &&
      type != SYBVARBINARY &&
      type != SYBIMAGE) {
    final s = tryConvertToString(db, dbproc, type, ptr, len);
    if (s != null) {
      return s;
    }
    if (type == SYBDECIMAL || type == SYBNUMERIC) {
      throw FormatException('Cannot decode an exact SQL decimal value');
    }
    // Last resort: base64 the raw bytes for JSON-safety
    return base64.encode(v);
  }
  return v;
}

/// Attempt to stringify a value of any DB-Lib type using `dbconvert -> SYBVARCHAR`.
///
/// - Useful for complex/driver-specific encodings (e.g., DECIMAL/NUMERIC, DATE/TIME/DT2/OFFSET)
///   where manual decoding would require TDS metadata (scale/precision).
/// - Returns a UTF-8 Dart String on success; null if conversion fails.
String? tryConvertToString(
  DBLib db,
  Pointer<DBPROCESS> dbproc,
  int srcType,
  Pointer<Uint8> src,
  int srcLen,
) {
  if (src == nullptr || srcLen <= 0) return null;
  // Heuristic buffer size: up to 4x source length plus headroom, capped.
  final int maxLen = _clampInt(srcLen * 4 + 64, 128, 65536);
  final dest = malloc<Uint8>(maxLen);
  try {
    final outLen = db.dbconvert(
      dbproc,
      srcType,
      src,
      srcLen,
      SYBVARCHAR,
      dest,
      maxLen,
    );
    if (outLen <= 0) return null;
    if (outLen > maxLen) {
      throw FormatException('Native text conversion exceeded its buffer');
    }
    final bytes = dest.asTypedList(outLen);
    return freeTdsTextCodec.decode(bytes);
  } on FormatException {
    rethrow;
  } catch (_) {
    return null;
  } finally {
    malloc.free(dest);
  }
}

String _scaledMoney(BigInt value) {
  final digits = value.abs().toString().padLeft(5, '0');
  return '${value.isNegative ? '-' : ''}${digits.substring(0, digits.length - 4)}.${digits.substring(digits.length - 4)}';
}

// DBDATETIMEALL: uint64 ticks (100 ns), int32 days, int16 offset, flags.
// The protocol stores datetimeoffset date/time in UTC; present its civil time.
String _decodeDateTimeAll(int type, ByteData data) {
  if (data.lengthInBytes != 16) {
    throw FormatException('Invalid DBDATETIMEALL length');
  }
  final ticks = data.getUint64(0, Endian.host);
  final days = data.getInt32(8, Endian.host);
  final offset = type == SYBMSDATETIMEOFFSET
      ? data.getInt16(12, Endian.host)
      : 0;
  if (ticks >= 864000000000 || offset.abs() > 840) {
    throw FormatException('Invalid DBDATETIMEALL value');
  }
  final civil = DateTime.utc(
    1900,
    1,
    1,
  ).add(Duration(days: days, microseconds: ticks ~/ 10, minutes: offset));
  final date =
      '${civil.year.toString().padLeft(4, '0')}-${civil.month.toString().padLeft(2, '0')}-${civil.day.toString().padLeft(2, '0')}';
  if (type == SYBMSDATE) return date;
  final time =
      '${civil.hour.toString().padLeft(2, '0')}:${civil.minute.toString().padLeft(2, '0')}:${civil.second.toString().padLeft(2, '0')}.${(ticks % 10000000).toString().padLeft(7, '0')}';
  if (type == SYBMSTIME) return time;
  final zone = type == SYBMSDATETIMEOFFSET
      ? '${offset < 0 ? '-' : '+'}${(offset.abs() ~/ 60).toString().padLeft(2, '0')}:${(offset.abs() % 60).toString().padLeft(2, '0')}'
      : '';
  return '${date}T$time$zone';
}
