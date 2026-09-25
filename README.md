# rsnapshot-postgres

This is a bash script that allows to automatically pull ALL databases from a PostgreSQL server, remote or local, for backup purposes, creating "One Dump File Per Table/View" and a convenient restore script for each database. Plus, this script is [rsnapshot](https://github.com/rsnapshot/rsnapshot)-friendly, meaning you can use it with the "backup_script" feature of *rsnapshot*.

Ported from [rsnapshot-mysql](https://github.com/), keeping the same design and usage pattern, adapted to `psql` / `pg_dump` / `pg_dumpall`.

Features:
  - Handle dumps from local or remote PostgreSQL hosts.
  - Allows to choose compression type for dumps (none, gzip or bzip2).
  - Automatically fetches database names from the server and creates a directory for each database.
  - Two dump methods, selectable via `METHOD=table|full` in the credentials file:
    - `table` (default): dump each table, view, materialized view and foreign table to its own file (.sql, .sql.gz or .sql.bz2) under a directory named as the database. Best for rsnapshot's hardlink-based space savings, but each table is dumped in its own transaction/snapshot, so the backup of a database is **not** point-in-time consistent across tables if it changes while dumping.
    - `full`: a single `pg_dump -Fd` (directory format) call per database — one consistent snapshot for the whole database, optionally parallelized with `JOBS=N`. Still one file per table inside the dump directory (rsnapshot still benefits from hardlinking unchanged tables), but restored with `pg_restore`, which resolves object dependencies (foreign keys, views, sequences...) automatically. Only `none`/`gz` compression is supported with this method (no bzip2).
  - Ready to work with the "backup_script" feature of rsnapshot, an incremental snapshot utility for local and remote filesystems.
  - Creates a convenient restore script (BASH) for each database, under each dump directory.
  - Creates a backup of roles/grants (`pg_dumpall --globals-only`), and info files with the list of tables and PostgreSQL version.

## Usage

```
./rsnapshot-postgres.sh pghost compression port [file.cnf] [test]
./rsnapshot-postgres.sh localhost none 5432 rsnapshot-postgres.cnf
./rsnapshot-postgres.sh --help
```

Run `./rsnapshot-postgres.sh --help` for a full explanation of every parameter and of what goes in the credentials (cnf) file.

- `pghost`: hostname or IP of the PostgreSQL server (`localhost` works too).
- `compression`: `none`, `gz` or `bz2`.
- `port`: PostgreSQL port (usually `5432`).
- `file.cnf`: optional path to the credentials file (defaults to `/root/rsnapshot-postgres.cnf`).
- `test`: pass any value (e.g. `test`) to only list what would be dumped, without writing anything.

## Credentials file

The script expects a small shell-sourced file with `PGUSER` and `PGPASSWORD` (host and port always come from the command line). It can also optionally set `METHOD` and `JOBS`:

```
PGUSER=db_username
PGPASSWORD=yourpassword
METHOD=table
JOBS=1
```

Keep it readable only by the user running the script: `chmod 600 rsnapshot-postgres.cnf`.

## Restoring

Each database gets its own `restore-<db>.sh` script next to its dump directory. Run it from the directory that contains both the script and the `<db>/` folder:

```
./restore-mydb.sh target_host [target_port]
```

It creates `<db>_restored` (configurable via `RESTOREDB_SUFFIX`).

- With `METHOD=table`, it replays every per-table/view dump file in order (tables and foreign tables first, then views, then materialized views).
- With `METHOD=full`, it runs a single `pg_restore` against the dump directory, which figures out the correct object order itself.

### Known limitation (METHOD=table only)

Because each table/view is dumped and restored as an independent file, a `FOREIGN KEY` constraint between two base tables can fail to apply if the referenced table happens to be restored after the one that references it (this only affects the constraint statement itself — the tables and their data are still created correctly). If that happens, just re-add the constraint manually once both tables exist. This mirrors the same limitation in the original rsnapshot-mysql script when dumping InnoDB tables with foreign keys one table at a time. `METHOD=full` does not have this limitation, since `pg_restore` restores objects in dependency order.
