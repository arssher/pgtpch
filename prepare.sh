#!/usr/bin/env bash
set -e

show_help() {
    cat <<EOF
    Usage: bash ${0##*/} [-s scale] [-i pginstdir] [-d pgdatadir] [-t tpchtmp]
    [-p pgport] [-n tpchdbname] [-g dbgenpath] [-e] [-x] [-h]

    Prepare Postgres cluster for running TPC-H queries:
      * Create Postgres cluster at pgdatadr via initdb from pginstdir
      * Merge configuration from postgresql.conf with default configuration at
      	pgdatadir/postgresql.conf, if the former exists
      * Run the cluster on port pgport
      * Generate *.tbl files with TPC-H data, if needed
      * Create database with TPC-H tables named tpchdbname
      * Fill this tables with generated (or existing) data
      * Remove generated data, if needed
      * Create indexes, if needed
      * Reset Postgres state (vacuum-analyze-checkpoint)
      * Generate the queries and put them to ./queries

    Options
    The first six options are read from $CONFIGFILE file, but you can overwrite
    them in command line args. See their meaning in that file. The rest are:

    -e don't generate *.tbl files, use the existing ones
    -r remove generated files after use, the are not removed by default
    -x don't create indexes, they are created by default
    -h display this help and exit
EOF
    exit 0
}

source common.sh

GENDATA=true
REMOVEGENDATA=false
CREATEINDEXES=true
OPTIND=1
while getopts "s:i:d:t:p:n:g:erxh" opt; do
    case $opt in
	h)
	    show_help
	    exit 0
	    ;;
	s)
	    SCALE="$OPTARG"
	    ;;
	i)
	    PGINSTDIR="$OPTARG"
	    ;;
	d)
	    PGDATADIR="$OPTARG"
	    ;;
	t)
	    TPCHTMP="$OPTARG"
	    ;;
	p)
	    PGPORT="$OPTARG"
	    ;;
	n)
	    TPCHDBNAME="$OPTARG"
	    ;;
	g)
	    DBGENPATH="$OPTARG"
	    ;;
	e)
	    GENDATA=false
	    ;;
	r)
	    REMOVEGENDATA=true
	    ;;
	s)
	    CREATEINDEXES=false
	    ;;
	\?)
	    show_help >&2
	    exit 1
	    ;;
    esac
done

if [ -z "$SCALE" ]; then die "scale is empty"; fi
if [ -z "$PGINSTDIR" ]; then die "pginstdir is empty"; fi
if [ -z "$PGDATADIR" ]; then die "pgdatadir is empty"; fi
if [ -z "$TPCHTMP" ]; then die "tpchtmp is empty"; fi
if [ -z "$PGPORT" ]; then die "pgport is empty"; fi
if [ -z "$TPCHDBNAME" ]; then die "tpchdbname is empty"; fi
# We need dbgenpath even if we don't generate *.tbl files because we always
# generate queries
if [-z "$DBGENPATH" ]; then die "dbgenpath is empty"; fi

# directory with this script
BASEDIR=`dirname "$(readlink -f "$0")"`
PGBINDIR="${PGINSTDIR}/bin"
cd "$BASEDIR"
cd "$DBGENPATH" || die "dbgen directory not found"
DBGENABSPATH=`readlink -f "$(pwd)"`

# ================== Check it's ok to run pgsql server =========================
# Check for the running Postgres; exit if there is any on the given port
PGPORT_PROCLIST="$(lsof -i tcp:$PGPORT | tail -n +2 | awk '{print $2}')"
if [[ $(echo "$PGPORT_PROCLIST" | wc -w) -gt 0 ]]; then
    echo "The following processes have taken port $PGPORT"
    echo "Please terminate them before running this script"
    echo
    for p in $PGPORT_PROCLIST; do ps -o pid,cmd $p; done
    die ""
fi

# Check if a Postgres server is running in the same directory
if server_running; then
    die "Postgres server is already running in the $PGDATADIR directory.";
fi

# ========================== Preparing DB =========================
# Current time
t=$(timer)

# create database cluster
rm -r "$PGDATADIR"
mkdir -p "$PGDATADIR"
$PGBINDIR/initdb -D "$PGDATADIR" --encoding=UTF-8 --locale=C

# copy postgresql settings
if [ -f "$BASEDIR/postgresql.conf" ]; then
    # Merge our config with a default one.
    # sed removes all the comments started with #
    # grep removes all empty lines
    # awk uses as a separator '=' with any spaces around it. It remembers
    # settings in an array, and prints the setting only if it is not a duplicate.
    # in fact, we don't need all this stuff because Postgres will use the last
    # read setting anyway...
    cat "$BASEDIR/postgresql.conf" "$PGDATADIR/postgresql.conf" |
	sed 's/\#.*//' |
	grep -v -E '^[[:space:]]*$' |
	awk -F' *= *' '!($1 in settings) {settings[$1] = $2; print}' \
	    > "$PGDATADIR/postgresql.conf"
    echo "Postgres config applied"
else
    echo "Config file postgresql.conf not found, using the default"
fi

# Start a new instance of Postgres
postgres_start

# create db with this user's name to give access
$PGBINDIR/createdb -h /tmp -p $PGPORT `whoami` --encoding=UTF-8 --locale=C;

echo "Current settings are"
$PGBINDIR/psql -h /tmp -p $PGPORT -c "select name, current_setting(name) from
pg_settings where name in('debug_assertions', 'wal_level',
'checkpoint_segments', 'shared_buffers', 'wal_buffers', 'fsync',
'maintenance_work_mem', 'checkpoint_completion_target', 'max_connections');"

WAL_LEVEL_MINIMAL=`$PGBINDIR/psql -h /tmp -p $PGPORT -c 'show wal_level' -t | grep minimal | wc -l`
DEBUG_ASSERTIONS=`$PGBINDIR/psql -h /tmp -p $PGPORT -c 'show debug_assertions' -t | grep on | wc -l`
if [ $WAL_LEVEL_MINIMAL != 1 ] ; then die "Postgres wal_level is not set to
minimal; 'Elide WAL traffic' optimization cannot be used"; fi
if [ $DEBUG_ASSERTIONS = 1 ] ; then die "Option debug_assertions is enabled"; fi

# generate *.tbl files, if needed
if [ "$GENDATA" = true ]; then
    make -j4 # build dbgen
    if ! [ -x "$DBGENABSPATH/dbgen" ] || ! [ -x "$DBGENABSPATH/qgen" ]; then
	die "Can't find dbgen or qgen.";
    fi

    mkdir -p "$TPCHTMP" || die "Failed to create temporary directory: '$TPCHTMP'"
    cd "$TPCHTMP"
    # needed by ./dbgen
    cp "$DBGENABSPATH/dists.dss" . || die "dists.dss not found"
    cp "$DBGENABSPATH/dss.ddl" . || die "dss.ddl not found" # table definitions
    # foreign & primary keys
    cp "$DBGENABSPATH/dss.ri" . || die "dss.ri not found"

    # Create table files separately to have better IO throughput
    # -v is verbose, -f for overwrtiting existing files, -T <letter> is
    # "generate only table <letter>"
    for TABLENAME in c s n r O L P s; do
	"$DBGENABSPATH/dbgen" -s $SCALE -f -v -T $TABLENAME &
    done
    wait_jobs
    # It seems that it is neccessary to convert the files before importing them
    for i in `ls *.tbl`; do sed 's/|$//' $i > $i; echo "Converting $i ..."; done;
    echo "TPC-H data *.tbl files generated at $TPCHTMP"
fi

$PGBINDIR/createdb -h /tmp -p $PGPORT $TPCHDBNAME --encoding=UTF-8 --locale=C
if [ $? != 0 ]; then die "Error: Can't proceed without database"; fi
TIME=`date`
$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME -c "comment on database
$TPCHDBNAME is 'TPC-H data, created at $TIME'"
echo "TPC-H database created"

$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME < "$TPCHTMP/dss.ddl"
echo "TPCH-H tables created"

cd "$TPCHTMP"
TBLFILESNUM=`find . -maxdepth 1 -type f -name '*.tbl' | wc -l`
if [ "$TBLFILESNUM" -eq "0" ]; then
    die "No *.tbl files found"
fi
for f in *.tbl; do
    # bf is f without .tbl extensions. Since unquoted names are case insensitive
    # in Postgres, bf is basically a table name.
    bf="$(basename $f .tbl)"
    # We truncate the empty table in the sames transaction to enable Postgres to
    # safely skip WAL-logging. See
    # http://www.postgresql.org/docs/current/static/populate.html#POPULATE-PITR
    echo "truncate $bf;
    	  COPY $bf FROM '$(pwd)/$f' WITH DELIMITER AS '|'" |
	$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME &
done
wait_jobs
echo "TPC-H tables are populated with data"

$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME < "dss.ri"
echo "primary and foreign keys added"

if [ "$REMOVEGENDATA" = true ]; then
    cd && rm -rf "$TPCHTMP"
    echo "tpch tmp directory removed"
fi

if [ "$CREATEINDEXES" = true ]; then
    declare -a INDEXCMDS=(
	# Pg does not create indexed on foreign keys, create them manually
	"CREATE INDEX i_n_regionkey ON nation (n_regionkey);"	#& #unused on 1GB
	"CREATE INDEX i_s_nationkey ON supplier (s_nationkey);"	#&
	"CREATE INDEX i_c_nationkey ON customer (c_nationkey);"	#&
	"CREATE INDEX i_ps_suppkey ON partsupp (ps_suppkey);"	#&
	"CREATE INDEX i_ps_partkey ON partsupp (ps_partkey);"	#&
	"CREATE INDEX i_o_custkey ON orders (o_custkey);"	#&
	"CREATE INDEX i_l_orderkey ON lineitem (l_orderkey);"	#&
	"CREATE INDEX i_l_suppkey_partkey ON lineitem (l_partkey, l_suppkey);"	#&
        # other indexes
	"CREATE INDEX i_l_shipdate ON lineitem (l_shipdate);"	#&
	"CREATE INDEX i_l_partkey ON lineitem (l_partkey);"	#&
	"CREATE INDEX i_l_suppkey ON lineitem (l_suppkey);"	#&
	"CREATE INDEX i_l_receiptdate ON lineitem (l_receiptdate);"	#&
	"CREATE INDEX i_l_orderkey_quantity ON lineitem (l_orderkey, l_quantity);"	#&
	"CREATE INDEX i_o_orderdate ON orders (o_orderdate);"	#&
	"CREATE INDEX i_l_commitdate ON lineitem (l_commitdate);"	#& #unused on 1GB
    )
    for cmd in "${INDEXCMDS[@]}"; do
	echo "Running $cmd"
	$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME -c "$cmd"
    done
    wait_jobs
    echo "Indexes created"
else
    echo "Indexes will not be created"
fi

# Always analyze after bulk-loading; when hacking Postgres, typically Postgres
# is run with autovacuum turned off.
echo "Running vacuum freeze analyze checkpoint..."
$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME -c "vacuum freeze"
$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME -c "analyze"
# Checkpoint, so we have a "clean slate". Just in-case.
$PGBINDIR/psql -h /tmp -p $PGPORT -d $TPCHDBNAME -c "checkpoint"

# Generate queries and put them to $BASEDIR/queries/qxx.sql, where xx is a number
# of the query. Also generates qxx.explain.sql and qxx.analyze.sql.
cd "$DBGENABSPATH"
for i in $(seq 1 22); do
    ii=$(printf "%02d" $i)
    mkdir -p "$BASEDIR/queries"
    # DSS_QUERY points to dir with queries that qgen uses to build the actual
    # queries
    DSS_QUERY=queries ./qgen $i > "$BASEDIR/queries/q${ii}.sql"
    sed 's/^select/explain select/' "$BASEDIR/queries/q${ii}.sql" > \
	"$BASEDIR/queries/q${ii}.explain.sql"
    sed 's/^select/explain analyze select/' "$BASEDIR/queries/q${ii}.sql" > \
	"$BASEDIR/queries/q${ii}.analyze.sql"
done
echo "Queries generated"
