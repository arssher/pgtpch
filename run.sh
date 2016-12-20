#!/usr/bin/env bash

show_help() {
    cat <<EOF
     Usage: bash ${0##*/} [-q queries] [-c precmd] [-f precmd_file] [-w warmups]
      [-s scale] [-n tpchdbname] [-i pginstdir] [-d pgdatadir] [-p pgport]
      [-U pguser] <testname>

     Run TPC-H queries from ./queries on prepared Postgres cluster, measuring
     duration with 'time'. Script relies on previously run ./prepare.sh to get
     info like the scale used while generating data. However, you can still use
     existing (not created by prepare.sh) cluster, just set right options
     yourself.

     The results will be put to directory ./res/testname-scale. Inside it, a dir
     will be created named qxx, where xx is number of the query, with:
       * File exectimes.txt with execution times: first 'warmup' lines are warmup
         times, the last one is the actual run time.
       * File answer.txt with computed answer
       * File qxx.sql with used query.

     Options
     -q queries
       queries to run; if not set it is read from pgtpch.conf, see description
       in pgtpch.conf.example
     -c precmd
        command to run before executing query; if not set it is read from
	pgtpch.conf, see description in pgtpch.conf.example
     -f precmd_file
     	another possibility to run some commands before executing query. The
 	whole file precmd_file will be read and executed before the actual query.
	File path must be relative to this project root.
     -w warmups
        number of warmups; if not set it is read from
	pgtpch.conf, see description in pgtpch.conf.example
     -h display this help and exit

     scale, tpchdbname, pginstdir, pgdatadir, pgport, pguser are all set as
     follows:
       * If prepare.sh was run, it will dump it's conf to pgtpch_last.conf, and
         we read here this file
       * If it doesn't exist, we try to read configs from pgtpch.conf
       * Finally, you can set them as a command line args
     FIXME: pguser is not yet implemented in prepare.sh

     testname
	name of test, part of result's directory name

     Example:
       ./run.sh -q "2 3 4" test
EOF
}

source common.sh
# try to read PRECMD, QUIERIES from CONFIGFILE, and SCALE, TPCHDBNAME, PGINSTDIR,
# PGDATADIR, PGPORT from LASTCONF, saved there by ./prepare.sh
BASEDIR=`dirname "$(readlink -f "$0")"` # directory with this script
if [ -f "$BASEDIR/$LASTCONF" ]; then
    read_conf "$BASEDIR/$LASTCONF" "$BASEDIR/$CONFIGFILE"
else
    read_conf "$BASEDIR/$CONFIGFILE"
fi

OPTIND=1
while getopts "q:c:f:w:i:d:p:U:h" opt; do
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
	f)
	    PRECMDFILE="$OPTARG"
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

if [ -z "$SCALE" ]; then die "scale is empty"; fi
if [ -z "$PGINSTDIR" ]; then die "pginstdir is empty"; fi
if [ -z "$PGDATADIR" ]; then die "pgdatadir is empty"; fi
if [ -z "$PGPORT" ]; then die "pgport is empty"; fi
if [ -z "$QUERIES" ]; then die "queries is empty"; fi
if [ -z "$WARMUPS" ]; then die "warmups is empty"; fi
if [ -z "$TESTNAME" ]; then die "testname is empty"; fi

PGBINDIR="${PGINSTDIR}/bin"
if [ "$QUERIES" = "all" ]; then
    QUERIES=""
    for QNUM in $(seq 1 22); do
        ii=$(printf "%02d" $QNUM)
	QUERIES="$QUERIES q$ii"
    done
fi

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
    cat "$BASEDIR/queries/$QUERY.sql" >> "$QUERY.sql"

    touch exectime.txt
    postgres_start

    for WNUM in $(seq 1 $WARMUPS); do
	echo "Warmup $WNUM..."
	# `which time` to avoid calling bash builtin
	`which time` -f '%e' $PGBINDIR/psql -h /tmp -p $PGPORT -d "$TPCHDBNAME" \
             -U "$PGUSER" <"$QUERYRESDIR/$QUERY.sql" >/dev/null 2>>exectime.txt

	echo "Warmup done"
	sleep 3
    done

    echo "GO!.."
    `which time` -f '%e' $PGBINDIR/psql -h /tmp -p $PGPORT -d "$TPCHDBNAME" \
                 -U "$PGUSER" <"$QUERYRESDIR/$QUERY.sql" >answer.txt \
		 2>>exectime.txt
    echo "done"

    postgres_stop
done
