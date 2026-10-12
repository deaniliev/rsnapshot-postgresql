#!/bin/bash
############################################################################################################################################################################
#
# rsnapshot-postgres.sh
#
# This is a rsnapshot friendly tool to pull all PostgreSQL DBs from a host, One File Per Table.
#
############################################################################################################################################################################
#
#   Ported from rsnapshot-mysql.sh (by Juanga Covas 2015-2018)
#
############################################################################################################################################################################
#
# Features:
#
#   - Handle dumps from local or remote PostgreSQL hosts.
#   - Allows to choose compression type for dumps (none, gzip or bzip2).
#   - Automatically fetches database names from the PostgreSQL host and creates a directory for each database.
#   - Two dump methods (METHOD=table|full in the cnf file):
#       table = one "pg_dump --table=..." call per table/view/matview (one file per table, best for rsnapshot hardlink
#               dedup, but NOT point-in-time consistent across tables).
#       full  = one "pg_dump -Fd" call per database (single consistent snapshot, optionally parallel with JOBS=N),
#               restored with "pg_restore" which resolves object dependencies automatically. gzip only, no bzip2.
#   - Ready to work with "backup_script" feature of rsnapshot, an incremental snapshot utility for local and remote filesystems.
#   - Creates a convenient restore script (BASH) for each database, under each dump directory.
#   - Creates a backup of roles/grants (pg_dumpall --globals-only), and info files with the list of tables and PostgreSQL version.
#
############################################################################################################################################################################

# The main reason to dump tables to individual files, instead of a full file per database, is to save more disk space when using incremental, link-based backup systems.
# This way more files have a chance to be 'the same as previous backup or snapshot', at the cost of a more complicated restore process which is also provided by this script.

## START EDITING VARIABLES HERE:

# Path where a directory <databasename> will be created for each database (no trailing slash).
# If you're using rsnapshot, this directory should be somewhere in the current working directory
BACKUP_DIR="."
# BACKUP_DIR="./pgdumps"

# Dump method:
#   table = loop and dump each table/view/matview with its own "pg_dump --table=..." call (one file per table,
#           best for rsnapshot hardlink dedup, but each table is its own snapshot/transaction so the backup
#           of a database is NOT point-in-time consistent across tables if it changes while dumping).
#   full  = single "pg_dump -Fd" (directory format) call per database, one consistent snapshot for the whole
#           database (optionally parallelized with JOBS), still one file per table inside the dump directory,
#           and restored with "pg_restore" which resolves object dependencies (foreign keys, views...)
#           automatically. bzip2 compression is NOT supported with this method (gzip only).
# Can be overridden per-run by setting METHOD=table or METHOD=full in the credentials (cnf) file.
DUMP_METHOD="table"

# Number of parallel jobs used by pg_dump/pg_restore, only relevant for DUMP_METHOD="full".
# Can be overridden per-run by setting JOBS=N in the credentials (cnf) file.
PGDUMP_JOBS=1

# Define which databases to exclude when fetching database names from the PostgreSQL host
# Normally you always want to exclude the template databases and the "postgres" maintenance database
PG_EXCLUDE_DB="(^postgres$|^template0$|^template1$|^rdsadmin$|^test_|_test$|_bak$|^bak_)"

# Regex to exclude tables/views by "schema.table" name
PG_EXCLUDE_TABLES="(^pg_catalog\.|^information_schema\.)"

# File to hold PGUSER / PGPASSWORD (data source), sourced as a shell script.
# Keep this file readable only by the user running this script (chmod 600).
PG_CNF_FILE="/root/rsnapshot-postgres.cnf"

# This is the format expected for the credentials file (host and port are taken from the command line, not from this file):
#
# PGUSER=db_username
# PGPASSWORD=yourpassword
# METHOD=table
# JOBS=1

# The maintenance database used to list databases and test the connection
PG_MAINT_DB="postgres"

# Suffix to database name for the restore script (so you do not accidentally restore tables over the existing database).
# The restore script will try to create databasename plus RESTOREDB_SUFFIX.
# If you do not want a suffix, just comment the following line or leave the string empty
RESTOREDB_SUFFIX="_restored"

# If CLEAN_DUMP_DIRS is set to 1, all files inside each databasename directory will be deleted before the dumps
# When using rsnapshot tool, CLEAN_DUMP_DIRS=0 is OK since all files and dirs created by this script at working dir. will be moved
CLEAN_DUMP_DIRS=0

# uncomment this line if you want to run pg_amcheck against each database before dumping (requires PostgreSQL 14+ and enough privileges)
#CHECK_TABLES="please"

##
# normally you don't want to touch anything else beyond this point of the script
##


# Get a display date for the current date and time
TIMESTAMP=$(date +"%Y-%m-%d-%H.%M")

# number of failed dumps, the script exits with an error at the end if any
DUMP_ERRORS=0

# show banner
echo "-----------------------------------------------------------------------------------------"
echo "rsnapshot-postgres.sh"
echo " "
echo " Rsnapshot friendly tool to pull all PostgreSQL DBs from a host, One File Per Table."
echo " "

# show detailed help
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]] ;then
	cat <<-HELPEOF

	Usage:
	  rsnapshot-postgres.sh pghost compression port [file.cnf] [test]
	  rsnapshot-postgres.sh --help | -h

	Parameters:
	  pghost        Hostname or IP of the PostgreSQL server (e.g. localhost, db.example.com)
	  compression   Compression for the dump files: none | gz | bz2
	                (bz2 only works with METHOD=table, see below)
	  port          PostgreSQL port (usually 5432)
	  file.cnf      Optional path to the credentials file (defaults to: $PG_CNF_FILE)
	  test          Optional. Pass any value (e.g. "test") to do a dry run: lists
	                what would be dumped, without connecting for real dumps or writing files.

	Examples:
	  rsnapshot-postgres.sh localhost none 5432 rsnapshot-postgres.cnf
	  rsnapshot-postgres.sh db.internal gz 5432 /root/rsnapshot-postgres.cnf test

	Credentials file (file.cnf / default.cnf):

	  A small shell-sourced file (chmod 600 it, it holds a plaintext password).
	  Recognized keys:

	    PGUSER=db_username       (required) role used to connect
	    PGPASSWORD=yourpassword  (required) password for PGUSER

	    METHOD=table|full        (optional, default: table)
	                               table = one "pg_dump --table=..." call per table/view/matview.
	                                       One file per table, best for rsnapshot's hardlink-based
	                                       space savings, but NOT point-in-time consistent across
	                                       tables if the database changes while dumping.
	                               full  = one "pg_dump -Fd" call per database: a single consistent
	                                       snapshot, optionally parallelized with JOBS=N, restored
	                                       with "pg_restore" which resolves object dependencies
	                                       (foreign keys, views, sequences...) automatically.
	                                       Only none/gz compression works with this method.

	    JOBS=N                   (optional, default: 1) parallel jobs for pg_dump/pg_restore,
	                               only used when METHOD=full.

	  Host and port are NOT read from this file, they always come from the pghost/port command
	  line arguments above, so the same cnf file can be reused against different servers.

	  Example file:

	    PGUSER=backupuser
	    PGPASSWORD=s3cr3t
	    METHOD=full
	    JOBS=4

	See README.md for more details (restore scripts, known limitations, etc).

	HELPEOF
	exit 0
fi

# show usage if not enough arguments are given
if [ -z "$3" ] ;then
	echo " "
	echo "Required parameters: pghost      compression   port  [file.cnf]	[test]"
	echo "            Example: localhost   none|gz|bz2   5432  default.cnf	test"
	echo " "
	echo "  Will try to connect using credentials from file.cnf (defaults to: $PG_CNF_FILE)"
	echo "  Run with --help for a detailed explanation of all parameters and the cnf file."
	exit 1;
fi

# create our own vars from arguments
PG_HOST=$1
COMPRESSION=$2
PG_PORT=$3
CLIENT_CNF=$4
TEST_RUN=$5

if [ ! -z "$CLIENT_CNF" ] ;then
	PG_CNF_FILE=$CLIENT_CNF
fi

# check the provided file for postgres credentials
if [ ! -f "$PG_CNF_FILE" ] ;then
	echo "ERROR: Cannot read: $PG_CNF_FILE"
	exit 1
fi
if [ ! -s "$PG_CNF_FILE" ] ;then
	echo "ERROR: File is empty: $PG_CNF_FILE"
	exit 1
fi

# source credentials file (expects PGUSER= and PGPASSWORD=, optionally METHOD= and JOBS=) and export them for psql/pg_dump/pg_dumpall
set -a
source "$PG_CNF_FILE"
set +a

# host and port always come from the command line, overriding anything set in the cnf file
export PGHOST=$PG_HOST
export PGPORT=$PG_PORT

# METHOD=/JOBS= from the cnf file (if present) override the defaults set at the top of this script
if [ ! -z "$METHOD" ] ;then
	DUMP_METHOD=$METHOD
fi
if [ ! -z "$JOBS" ] ;then
	PGDUMP_JOBS=$JOBS
fi

if [[ "$DUMP_METHOD" != "table" ]] && [[ "$DUMP_METHOD" != "full" ]] ;then
	echo "ERROR: valid METHOD is table|full (got: $DUMP_METHOD)"
	exit 1;
fi

# make sure client tools never block waiting for a tty password prompt
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"

echo "Will try to dump databases from [$PGHOST:$PGPORT] to: [$BACKUP_DIR] using [$PG_CNF_FILE] (user: $PGUSER)"
if [[ "$DUMP_METHOD" == "full" ]] ;then
	echo "Dump method: full (single pg_dump -Fd per database, consistent snapshot, $PGDUMP_JOBS job(s), restored with pg_restore)"
else
	echo "Dump method: table (one pg_dump call per table/view, restored with psql)"
fi
echo " "
if [ ! -z "$TEST_RUN" ] ;then
	echo "(TEST RUN) Will NOT dump anything."
	echo " "
fi

if [[ $COMPRESSION == "gz" ]] ;then
	echo "Compress to .sql.gz (gzip)"
else
	if [[ $COMPRESSION == "bz2" ]] ;then
		echo "Compress to .sql.bz2 (bzip2)"
		if [[ "$DUMP_METHOD" == "full" ]] ;then
			echo "ERROR: bz2 compression is not supported with METHOD=full (pg_dump -Fd only supports gzip). Use none or gz, or switch to METHOD=table."
			exit 1;
		fi
	else
		if [[ $COMPRESSION == "none" ]] ;then
			echo "No compression: .sql"
		else
			echo "ERROR: valid compression parameter is none|gz|bz2"
			exit 1;
		fi
	fi
fi

# try to create the given BACKUP_DIR, no errors, recursive
mkdir -p "$BACKUP_DIR"

# test connection to the given PostgreSQL host
echo " "
printf 'Testing connection to PostgreSQL ... '

RESULT=$(psql -X -q -At -d "$PG_MAINT_DB" -c "SELECT 1;" 2>/dev/null)
if [[ "$RESULT" == "1" ]]; then
	printf "OK.\n"
else
	printf "ERROR: Cannot connect to PostgreSQL server. Aborting. Using credentials from: $PG_CNF_FILE\n\n"
	exit 1;
fi

# dump postgres host version info
echo " "
echo "PostgreSQL version info"
if [ -z "$TEST_RUN" ]; then
	psql -X -q -At -d "$PG_MAINT_DB" -c "SHOW server_version;" > "$BACKUP_DIR/postgres-version-$PG_HOST.txt"
fi
psql -X -q -At -d "$PG_MAINT_DB" -c "SHOW server_version;"
echo " "

# check tables?
if [ ! -z "$CHECK_TABLES" ]; then
	if command -v pg_amcheck >/dev/null 2>&1; then
		echo "Doing a pg_amcheck --all against $PGHOST:$PGPORT"
		pg_amcheck -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --all 2>&1 | while read line; do
			echo "WARNING: $line"
		done
	else
		echo "NOTICE: pg_amcheck not found in PATH, skipping table checks."
	fi
	echo " "
fi

# dump roles / grants (global objects, not tied to a single database)
if [ -z "$TEST_RUN" ]; then
	echo "Dumping roles/grants to $BACKUP_DIR/postgres-grants-$PG_HOST.sql"
	grants_file="$BACKUP_DIR/postgres-grants-$PG_HOST.sql"
	if ! pg_dumpall -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --globals-only > "$grants_file" 2>/dev/null ;then
		# a non-superuser cannot read pg_authid (role password hashes), --no-role-passwords reads pg_roles instead
		echo "WARNING: pg_dumpall failed (is $PGUSER a superuser?), retrying with --no-role-passwords: role password hashes will NOT be in the backup."
		if ! pg_dumpall -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" --globals-only --no-role-passwords > "$grants_file" ;then
			rm -f "$grants_file"
			DUMP_ERRORS=$((DUMP_ERRORS + 1))
			echo "ERROR: could not dump roles/grants."
		fi
	fi
else
	echo "(TEST RUN) Skipping roles/grants dump"
fi
echo " "


# get database list
echo "Getting database list to dump ... "
echo " "

databaselist=$(psql -X -q -At -d "$PG_MAINT_DB" -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;" | grep -Ev "$PG_EXCLUDE_DB")

# begin to dump

# loop all database names
for db in $databaselist; do

	# create a sub-directory using database name, no errors, recursive
	mkdir -p "$BACKUP_DIR/$db"

	if test $CLEAN_DUMP_DIRS -eq 1 ;then
		echo "Cleaning files: $BACKUP_DIR/$db/{*.sql*,*.txt}"
		rm -f "$BACKUP_DIR"/"$db"/*.sql* "$BACKUP_DIR"/"$db"/*.txt
	fi

	if [ ! -z "$TEST_RUN" ]; then
		printf 'Found DB: %s \n' "$db"
	else
		printf 'Dumping DB: %s \n' "$db"
	fi

	# get a list of schema.table.relkind (r=table, p=partitioned table, v=view, m=materialized view, f=foreign table)
	# ordered so that tables are restored before views/matviews that may select from them
	db_table_kind_list=$(psql -X -q -At -d "$db" -c "
		SELECT n.nspname || '.' || c.relname || '.' || c.relkind::text
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relkind IN ('r','p','v','m','f')
		AND n.nspname NOT IN ('pg_catalog','information_schema')
		ORDER BY CASE c.relkind WHEN 'r' THEN 1 WHEN 'p' THEN 1 WHEN 'f' THEN 2 WHEN 'v' THEN 3 WHEN 'm' THEN 4 ELSE 5 END, n.nspname, c.relname;
	" | grep -Ev "$PG_EXCLUDE_TABLES")

	db_table_list=$(echo "$db_table_kind_list" | sed -E 's/\.[a-z]$//')

	# save the db table list
	echo "$db_table_list" > "$BACKUP_DIR/$db/$db-tablelist.txt"
	echo "$db_table_kind_list" > "$BACKUP_DIR/$db/$db-kind-table-list.txt"

	# prepare first chunk of the bash restore script
	restore_file="$BACKUP_DIR/restore-$db.sh"
	dbr="${db}${RESTOREDB_SUFFIX}"

	if [[ "$DUMP_METHOD" == "table" ]] ;then
		FILECHECK="ls $db/$db-*.sql* 1> /dev/null 2>&1"
		FILECHECK_ERR="Cannot find $db-*.sql* files. Please execute the script under its directory."
		NOTICE1="Each table/view file was dumped with --clean --if-exists, so restore will DROP each object before recreating it."
		NOTICE2="Tables are restored before views/matviews, but foreign keys BETWEEN base tables may still fail if the referenced table happens to load later (each table is its own independent file/transaction). Data is unaffected; just re-add the constraint manually afterwards if that happens."
	else
		FILECHECK="test -d $db/pgdump"
		FILECHECK_ERR="Cannot find the $db/pgdump directory. Please execute the script under its directory."
		NOTICE1="This database was dumped in one consistent snapshot with pg_dump -Fd (directory format)."
		NOTICE2="pg_restore resolves object dependencies automatically (foreign keys, views, sequences...), so no manual fixups should be needed."
	fi

	echo "#!/bin/bash

	#########################################################################
	#
	#	Database Restore Script
	#
	#	    Backup done from host: $PG_HOST:$PG_PORT
	#		         Database: $db
	#		      Backup date: $TIMESTAMP
	#		           Method: $DUMP_METHOD
	#
	#########################################################################

	#RESTOREDB=\"$db\"
	RESTOREDB=\"$dbr\"

	PGHOST=\$1
	PGPORT=\${2:-$PG_PORT}
	PG_CNF_FILE=\"$PG_CNF_FILE\"

	# checks

	if [ -z \"\$BASH_VERSION\" ] ;then
	    echo \"Please execute the script using bash\"
	    exit 1;
	fi
	if [ -z \"\$1\" ] ;then
		echo \"Expecting target postgresql host as parameter (optionally followed by port)\"
		exit 1
	fi
	if $FILECHECK; then
	    echo \"File check OK\"
	else
	    echo \"$FILECHECK_ERR\"
	    exit 1
	fi
	if [ ! -f \"\$PG_CNF_FILE\" ] ;then
		echo \"Cannot read: \$PG_CNF_FILE\"
		exit 1
	fi
	if [ ! -s \"\$PG_CNF_FILE\" ] ;then
		echo \"File is empty: \$PG_CNF_FILE\"
		exit 1
	fi

	set -a
	source \"\$PG_CNF_FILE\"
	set +a
	export PGHOST=\"\$PGHOST\"
	export PGPORT=\"\$PGPORT\"

	echo \" \"
	echo \"Database Restore Script\"
	echo \" \"
	echo \" Backup done from host: $PG_HOST:$PG_PORT\"
	echo \"              Database: $db\"
	echo \"           Backup date: $TIMESTAMP\"
	echo \" \"
	echo \"RESTORE TO HOST: \$PGHOST:\$PGPORT\"
	echo \"  RESTORE TO DB: \$RESTOREDB\"
	echo \" \"
	echo \"#########################################################################\"
	echo \"NOTICE! $NOTICE1\"
	echo \"NOTICE! $NOTICE2\"
	echo \" \"
	for DBTBK in \`cat $db/$db-kind-table-list.txt\`; do
		schema=\`echo \${DBTBK} | awk -F. '{print \$1}'\`
		table=\`echo \${DBTBK} | awk -F. '{print \$2}'\`
		kind=\`echo \${DBTBK} | awk -F. '{print \$3}'\`
		echo \"        \$kind: \$schema.\$table\"
	done
	echo \" \"

	echo \"Checking target PostgreSQL server: \$PGHOST:\$PGPORT\"
	RESULT=\`psql -X -q -At -d postgres -c \"SELECT 1;\" 2>/dev/null\`
	if [ \"\$RESULT\" != \"1\" ]; then
		echo \"ERROR: Cannot connect to postgresql server at \$PGHOST:\$PGPORT\"
		exit 1
	fi
	echo \"PostgreSQL connection OK.\"
	echo \" \"

	echo \"READY TO GO ... RESTORE TO DB: \$RESTOREDB on \$PGHOST:\$PGPORT\"
	echo \" \"
	read -p \"Press [Enter] to confirm injection of ALL the scheduled files\"
	echo \" \"
	echo \"psql> CREATE DATABASE \$RESTOREDB;\"
	psql -X -q -At -d postgres -c \"CREATE DATABASE \$RESTOREDB;\" 2>/dev/null

	RESULT=\`psql -X -q -At -d postgres -c \"SELECT 1 FROM pg_database WHERE datname='\$RESTOREDB';\" 2>/dev/null\`
	if [ \"\$RESULT\" != \"1\" ]; then
		echo \"Could connect, but could NOT find/create database: \$RESTOREDB using credentials from: \$PG_CNF_FILE\"
		exit 1
	fi
	echo \"OK. Database \$RESTOREDB is ready.\"
	echo \" \"
	" >"$restore_file"

	if [[ "$DUMP_METHOD" == "table" ]] ;then

		# loop all tables/views in database

		while IFS= read -r DBTBK; do

			[ -z "$DBTBK" ] && continue

			schema=$(echo "${DBTBK}" | awk -F. '{print $1}')
			table=$(echo "${DBTBK}" | awk -F. '{print $2}')
			kind=$(echo "${DBTBK}" | awk -F. '{print $3}')

			case "$kind" in
				r) kindlabel="TABLE" ;;
				p) kindlabel="PARTITIONED TABLE" ;;
				v) kindlabel="VIEW" ;;
				m) kindlabel="MATVIEW" ;;
				f) kindlabel="FOREIGN TABLE" ;;
				*) kindlabel="UNKNOWN" ;;
			esac

			if [ ! -z "$TEST_RUN" ]; then
				printf '          %s: %s.%s' "$kindlabel" "$schema" "$table"
			else
				printf '            Dumping %s as: %s.%s.sql' "$kindlabel" "$schema" "$table"
			fi

			# reminders for pg_dump options used below:
			# --clean --if-exists   so the restore script can DROP each object before recreating it
			# --no-owner --no-privileges   keep the per-table dump free of role-specific ALTER/GRANT statements (roles/grants are handled separately, see postgres-grants-*.sql)
			# --table='schema.table'   dump only the given relation (its owned sequence, if any, is included automatically)

			# --table takes a psql-style pattern where unquoted names are folded to lower case (so "Account" would
			# not match), therefore both identifiers are double-quoted, doubling any embedded double quote
			table_pattern="\"${schema//\"/\"\"}\".\"${table//\"/\"\"}\""
			PGDUMP_OPT=(--clean --if-exists --no-owner --no-privileges "--table=${table_pattern}")

			if [ -z "$TEST_RUN" ]; then

				# dump the table/view and add lines to the restore script (only if the dump succeeded)

				if [[ $COMPRESSION == "gz" ]] ;then
					printf '.gz ... '
					filedump="$BACKUP_DIR/$db/$db-$schema.$table.sql.gz"
					restorefiledump=$(basename "$filedump")
					if [ ! -f "$filedump" ] ;then
						pg_dump -d "$db" "${PGDUMP_OPT[@]}" | gzip -9 > "$filedump"
						if [ "${PIPESTATUS[0]}" -ne 0 ] ;then
							rm -f "$filedump"
							DUMP_ERRORS=$((DUMP_ERRORS + 1))
							printf 'FAILED. '
						fi
					fi
					if [ -f "$filedump" ] ;then
						echo "
						echo \"Running $restorefiledump ...\"
						zcat $db/$restorefiledump | psql -X -q \$RESTOREDB" >>"$restore_file"
					fi
				fi

				if [[ $COMPRESSION == "bz2" ]] ;then
					printf '.bz2 ... '
					filedump="$BACKUP_DIR/$db/$db-$schema.$table.sql.bz2"
					restorefiledump=$(basename "$filedump")
					if [ ! -f "$filedump" ] ;then
						pg_dump -d "$db" "${PGDUMP_OPT[@]}" | bzip2 -cq9 > "$filedump"
						if [ "${PIPESTATUS[0]}" -ne 0 ] ;then
							rm -f "$filedump"
							DUMP_ERRORS=$((DUMP_ERRORS + 1))
							printf 'FAILED. '
						fi
					fi
					if [ -f "$filedump" ] ;then
						echo "
						echo \"Running $restorefiledump ...\"
						bunzip2 < $db/$restorefiledump | psql -X -q \$RESTOREDB" >>"$restore_file"
					fi
				fi

				if [[ $COMPRESSION == "none" ]] ;then
					printf ' ... '
					filedump="$BACKUP_DIR/$db/$db-$schema.$table.sql"
					restorefiledump=$(basename "$filedump")
					if [ ! -f "$filedump" ] ;then
						if ! pg_dump -d "$db" "${PGDUMP_OPT[@]}" > "$filedump" ;then
							rm -f "$filedump"
							DUMP_ERRORS=$((DUMP_ERRORS + 1))
							printf 'FAILED. '
						fi
					fi
					if [ -f "$filedump" ] ;then
						echo "
						echo \"Running $restorefiledump ...\"
						cat $db/$restorefiledump | psql -X -q \$RESTOREDB" >>"$restore_file"
					fi
				fi

			fi

			printf '\n'

		done <<< "$db_table_kind_list"

	else

		# full method: one consistent pg_dump -Fd (directory format) call for the whole database

		dumpdir="$BACKUP_DIR/$db/pgdump"

		if [[ $COMPRESSION == "gz" ]] ;then
			ZLEVEL=9
		else
			ZLEVEL=0
		fi

		# reminders for pg_dump options used below:
		# -Fd -j JOBS      directory format, one consistent snapshot shared by all parallel jobs
		# -Z LEVEL         per-file gzip compression level (0 disables compression)
		# --clean --if-exists   let pg_restore DROP each object before recreating it (harmless on a fresh empty database)
		# --no-owner --no-privileges   keep the dump free of role-specific ALTER/GRANT statements (roles/grants are handled separately, see postgres-grants-*.sql)

		if [ ! -z "$TEST_RUN" ]; then
			printf '          Would pg_dump -Fd (consistent snapshot, %s job(s), %s)\n' "$PGDUMP_JOBS" "$COMPRESSION"
		else
			printf '            Dumping (pg_dump -Fd, consistent snapshot, %s job(s)) ... ' "$PGDUMP_JOBS"
			rm -rf "$dumpdir"
			if pg_dump -d "$db" -Fd -j "$PGDUMP_JOBS" -Z "$ZLEVEL" --no-owner --no-privileges -f "$dumpdir" ;then
				printf 'done.\n'
				echo "
					echo \"Running pg_restore on $db/pgdump ...\"
					pg_restore -j $PGDUMP_JOBS --no-owner --no-privileges --clean --if-exists -d \"\$RESTOREDB\" $db/pgdump" >>"$restore_file"
			else
				rm -rf "$dumpdir"
				DUMP_ERRORS=$((DUMP_ERRORS + 1))
				printf 'FAILED.\n'
			fi
		fi

	fi

	# finish restore script
	echo "
		echo \" \"
		echo \"Finished.\"
		echo \" \"
		echo \" \"
		echo \"    Host: \$PGHOST:\$PGPORT\"
		psql -X -d \"\$RESTOREDB\" -c \"\\\\dt\"
		echo \" \"

	" >>"$restore_file"

	chmod +x "$restore_file"

	if [ -z "$TEST_RUN" ]; then
		echo "            RESTORE bash script created: restore-$db.sh"
	fi

	# uncomment the following line if you want to test just dumping the first database on list
	# exit 1;

done

echo " "
echo "Finished."
echo "Remember that I also created some special files: postgres-grants*.sql, postgres-version*.txt and, for each database, the file: restore-*.sh"

if [ "$DUMP_ERRORS" -gt 0 ] ;then
	echo "ERROR: $DUMP_ERRORS dump(s) FAILED, this backup is INCOMPLETE. Check the errors above."
	exit 1
fi

exit 0
