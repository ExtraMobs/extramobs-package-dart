# SQL Server Cursor Demo

Run from this directory:

```sh
flutter run -d windows
```

The app opens a connection with autocommit disabled. Queries and writes execute through cursors; the Tx tab provides Commit, Rollback and an Autocommit switch. Enabling Autocommit asks for confirmation because it commits pending writes. Callback transactions are available only with Autocommit enabled. Disconnect rolls back uncommitted work.

Certificate validation is enabled by default. Supply a trusted CA PEM path where needed; only enable Trust server certificate intentionally for a known server. Never embed credentials in source.

`lib/mssql_connection_example.dart` is a second executable example using a reusable cursor, positional parameters, a generator, direct await-for and explicit commit/rollback. It uses only a session-temporary table and reads MSSQL_IP, MSSQL_USER, MSSQL_PASSWORD and optional MSSQL_PORT/MSSQL_DB/TLS settings from the environment.

See [EXAMPLE.md](../EXAMPLE.md) for the public API and migration details. Active platform: Windows x64; this is not a web app.
