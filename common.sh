LASTCONF="pgtpch_last.conf"
CONFIGFILE="pgtpch.conf"

# =========================== Functions ======================================

# Parses config files written in format 'optname = optvalue'
# Accepts any number of filenames as an argument. The first encountered setting
# is used.
# Files with names containing spaces are not supported at the moment.
read_conf() {
    # concat all arguments
    CONFFILES=""
    for f in "$@"; do
	CONFFILES="$CONFFILES $f"
    done

    echo "Reading configs $CONFFILES..."
    # Now merge the configs
    # sed removes all the comments started with #
    # grep removes all empty lines
    CONFS=`cat $CONFFILES | sed 's/\#.*//' | grep -v -E '^[[:space:]]*$'`
    # awk uses as a separator '=' with any spaces around it. It remembers
    # keys in an array, and prints the setting only if it is not a duplicate.
    CONFS=`echo "$CONFS" | awk -F' *= *' '!($1 in settings) {settings[$1]; print}'`

    SCALE=$(echo "$CONFS" | awk -F' *= *' '/^scale/{print $2}')
    PGINSTDIR=$(echo "$CONFS" | awk -F' *= *' '/^pginstdir/{print $2}')
    PGDATADIR=$(echo "$CONFS" | awk -F' *= *' '/^pgdatadir/{print $2}')
    TPCHTMP=$(echo "$CONFS" | awk -F' *= *' '/^tpchtmp/{print $2}')
    PGPORT=$(echo "$CONFS" | awk -F' *= *' '/^pgport/{print $2}')
    TPCHDBNAME=$(echo "$CONFS" | awk -F' *= *' '/^tpchdbname/{print $2}')
    DBGENPATH=$(echo "$CONFS" | awk -F' *= *' '/^dbgenpath/{print $2}')
    # values for run.sh only
    QUERIES=$(echo "$CONFS" | awk -F' *= *' '/^queries/{print $2}')
    # precmd might contain '=' symbols, so things are different.
    # \s is whitespace, \K ignores part of line matched before \K.
    PRECMD=$(echo "$CONFS" | grep --perl-regexp --only-matching '^precmd\s*=\s*\K.*')
    WARMUPS=$(echo "$CONFS" | awk -F' *= *' '/^warmups/{print $2}')
}

# Calculates elapsed time. Use it like this:
# curr_t = $(timer)
# t_elapsed = $(timer $curr_t)
timer() {
    if [[ $# -eq 0 ]]; then
	echo $(date '+%s')
    else
	local  stime=$1
	etime=$(date '+%s')

	if [[ -z "$stime" ]]; then stime=$etime; fi

	dt=$((etime - stime))
	ds=$((dt % 60))
	dm=$(((dt / 60) % 60))
	dh=$((dt / 3600))
	printf '%d:%02d:%02d' $dh $dm $ds
    fi
}

# To perform checks
die() {
    echo "ERROR: $@"
    exit -1;
}

# Wait for all pending jobs to finish except for Postgres itself; it's pid must
# be in $PGPID.
wait_jobs() {
    for p in $(jobs -p); do
	if [ $p != $PGPID ]; then wait $p; fi
    done
}

# Check server PGBINDIR at PGDATADIR is running. Returns 0 if running.
server_running() {
    $PGBINDIR/pg_ctl status -D $PGDATADIR | grep "server is running" -q
}

# Start postgres PGBINDIR at PGDATADIR on PGPORT and save it's pid in PGPID
postgres_start() {
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

    $PGBINDIR/postgres -D "$PGDATADIR" -p $PGPORT &
    PGPID=$!
    sleep 2
    while ! server_running; do
	echo "Waiting for the Postgres server to start"
	sleep 2
    done
    sleep 3 # To avoid 'the database system is starting up'
    echo "Postgres server started"
}

# Stop postgres PGBINDIR at PGDATADIR
postgres_stop() {
    $PGBINDIR/pg_ctl stop -D $PGDATADIR
}
