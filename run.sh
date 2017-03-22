#!/usr/bin/env bash

show_help() {
    cat <<EOF
     Usage: bash ${0##*/} <-s scale> <-i pginstdir> <-d pgdatadir>
       <-p pgport> <-n tpchdbname> <-q queries> <-w warmups> <-t timerruns>
       [-z copydir] [-e extconffile] [-c precmd] [-f precmdfile] [-U pguser]
       <testname>

     Run TPC-H queries on prepared Postgres cluster, measuring
     duration with 'time'.

     The results for each query will be in directory
      ./res/<testname>-<scale>/qXX, old dirs will be removed if exists.  Here
     qXX is the name of the query, directory will contain the following files:
       * File exectimes.txt with execution times: first <warmup> lines are
         warmup times, the last one is the run time with answer output;
       * File answer.txt with computed answer;
       * File qxx.sql with used query;
       * File qxx-timer.sql with query modified for timer statistics run;
       * File timers.txt with timer output.

     Options

     -h display this help and exit

     All other options are set as follows:
       * You can set them as a command line args
       * Otherwise, they are read from pgtpch.conf
     See their descripiton in pgtpch.conf.example.
     FIXME: pguser is not yet added in prepare.sh

     testname
	name of test, part of result's directory name

     Example:
       ./run.sh -q "ss" -w "2" -c "set enable_reverse_exec_hook to off;" \
       -f precmd.sql ss_usual
EOF
}

source common.sh
BASEDIR=`dirname "$(readlink -f "$0")"` # directory with this script
read_conf "$BASEDIR/$CONFIGFILE"

OPTIND=1
while getopts "q:c:z:f:e:t:w:s:n:i:d:p:U:h" opt; do
    case $opt in
	h)
	    show_help
	    exit 0
	    ;;
	q)
	    QUERIES="$OPTARG"
	    ;;
	c)
	    PRECMD="$OPTARG"
	    ;;
	z)
	    COPYDIR="$OPTARG"
	    ;;
	f)
	    PRECMDFILE="$OPTARG"
	    ;;
	e)
	    EXTCONFFILE="$OPTARG"
	    ;;
	t)
	    TIMERRUNS="$OPTARG"
	    ;;
	w)
	    WARMUPS="$OPTARG"
	    ;;
	s)
	    SCALE="$OPTARG"
	    ;;
	n)
	    TPCHDBNAME="$OPTARG"
	    ;;
	i)
	    PGINSTDIR="$OPTARG"
	    ;;
	d)
	    PGDATADIR="$OPTARG"
	    ;;
	p)
	    PGPORT="$OPTARG"
	    ;;
	U)
	    PGUSER="$OPTARG"
	    ;;
	\?)
	    echo "Unknown option"
	    show_help >&2
	    exit 1
	    ;;
    esac
done

# set $1 to first mass argument, etc
shift $((OPTIND - 1))
if [ $# -ne 1 ]; then
  echo "Wrong number of mass arguments"
  show_help >&2
  exit 1
fi
TESTNAME="$1"

if [ -z "$TIMERRUNS" ]; then TIMERRUNS=0; fi

if [ -z "$SCALE" ]; then die "scale is empty"; fi
if [ -z "$PGINSTDIR" ]; then die "pginstdir is empty"; fi
if [ -z "$PGDATADIR" ]; then die "pgdatadir is empty"; fi
if [ -z "$PGPORT" ]; then die "pgport is empty"; fi
if [ -z "$QUERIES" ]; then die "queries is empty"; fi
if [ -z "$WARMUPS" ]; then die "warmups is empty"; fi
if [ -z "$TESTNAME" ]; then die "testname is empty"; fi

echo "Disabling transparent hugepages"
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null

if [ -z "$COPYDIR" ]; then
    if [[ -n "$EXTCONFFILE" ]]; then die "Change postgresql.conf in clean data dir in unsupported"; fi
else
    #copy data and change PGDATADIR
    NEWDIR=$COPYDIR/`basename "$(readlink -f "$PGDATADIR")"`
    echo -n "Copying to $NEWDIR ... "
    rm -rf "$NEWDIR"
    cp -r "$PGDATADIR" "$NEWDIR"
    chmod 0700 "$NEWDIR"
    echo "done"
    PGDATADIR=$NEWDIR
    if [[ -n "$EXTCONFFILE" ]] && [[ -f "$BASEDIR/$EXTCONFFILE" ]]; then
	cat "$BASEDIR/$EXTCONFFILE" >> "$NEWDIR/postgresql.conf"
    fi
fi

PGBINDIR="${PGINSTDIR}/bin"
PGLIBDIR="${PGINSTDIR}/lib"

BASICQUERIES=""
for QNUM in $(seq 1 $NUMTPCHQUERIES); do
    ii=$(printf "%02d" $QNUM)
    BASICQUERIES="$BASICQUERIES q$ii"
done

if [ "$QUERIES" = "all" ]; then
    QUERIES=$BASICQUERIES;
fi

echo "Using Postgres at $PGINSTDIR"
echo "Using datadir at $PGDATADIR"
echo "Scale is $SCALE"

TESTDIR="$BASEDIR/res/$TESTNAME-$SCALE"
mkdir -p "$TESTDIR"
for QUERY in $QUERIES; do
    echo "Running query: $QUERY"

    QUERYRESDIR="$TESTDIR/$QUERY"
    rm -rf "$QUERYRESDIR"
    mkdir -p "$QUERYRESDIR"
    cd "$QUERYRESDIR"
    # here we will put used query
    touch "$QUERY.sql"
    # put precmd from file, if it exists
    if [[ -n "$PRECMDFILE" ]] && [[ -f "$BASEDIR/$PRECMDFILE" ]]; then
	cat "$BASEDIR/$PRECMDFILE" >> "$QUERY.sql"
    fi
    echo -e "$PRECMD" >> "$QUERY.sql"

    # put the query itself
    # search in pgdatadir first
    QUERYFILE="$PGDATADIR/queries/$QUERY.sql"
    if [ ! -f "$QUERYFILE" ]; then
	echo "Query $QUERY not found in ${PGDATADIR}/queries, searching in project root"
	QUERYFILE="${BASEDIR}/queries/${QUERY}.sql"
    fi

    cat "$QUERYFILE" >> "$QUERY.sql" || die "query source not found"

    # go-go-go
    touch exectime.txt
    postgres_start 1

    # So-called warmups
    for WNUM in $(seq 1 $WARMUPS); do
	echo -n "Warmup $WNUM..."
	# `which time` to avoid calling bash builtin
	LD_LIBRARY_PATH="$LD_LIBRARY_PATH":"$PGLIBDIR" `which time` -f '%e' \
		       $PGBINDIR/psql -h /tmp -p $PGPORT -d "$TPCHDBNAME" \
		       -U "$PGUSER" <"$QUERYRESDIR/$QUERY.sql" >/dev/null \
		       2>>exectime.txt

        echo "done"
        #small pause
        sleep 1
    done

    # Answer-writing run
    echo -n "GO!.."
    LD_LIBRARY_PATH="$LD_LIBRARY_PATH":"$PGLIBDIR" `which time` -f '%e' \
		   $PGBINDIR/psql -h /tmp -p $PGPORT -d "$TPCHDBNAME" \
                   -U "$PGUSER" <"$QUERYRESDIR/$QUERY.sql" >answer.txt \
		   2>>exectime.txt
    echo "done"

    # Timer runs
    if (( $TIMERRUNS > 0 )); then
	touch timers.txt
	touch "$QUERY-timer.sql"
	echo "set llvm_timer = 1;" >> "$QUERY-timer.sql"
	cat "$QUERY.sql" >> "$QUERY-timer.sql"

	for TNUM in $(seq 1 $TIMERRUNS); do
            #small pause
	    sleep 1
	    echo -n "Timer-run $TNUM..."
	    LD_LIBRARY_PATH="$LD_LIBRARY_PATH":"$PGLIBDIR" \
			   $PGBINDIR/psql -h /tmp -p $PGPORT -d "$TPCHDBNAME" \
			   -U "$PGUSER" <"$QUERYRESDIR/$QUERY-timer.sql" >/dev/null \
			   2>>timers.txt

	    echo "done"
	done
    fi

    #Finish
    postgres_stop 0
done

if [ -n "$COPYDIR" ]; then
    #remove NEWDIR
    echo -n "Removing $NEWDIR ... "
    rm -rf "$NEWDIR"
    echo "done"
fi
