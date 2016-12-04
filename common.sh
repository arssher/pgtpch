LASTCONF="pgtpch_last.conf"

# =========================== Functions ======================================
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

# Check server is running. Returns 0 if running.
server_running() {
    $PGBINDIR/pg_ctl status -D $PGDATADIR | grep "server is running" -q
}

# Start postgres and save it's pid in PGPID
postgres_start() {
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

# Stop postgres
postgres_stop() {
    $PGBINDIR/pg_ctl stop -D $PGDATADIR
}
