#!/usr/bin/env bash
set -e

show_help() {
    cat <<EOF
     Usage: bash ${0##*/} [-q queries] [-c precmd] [-w warmups] [-i pginstdir]
     [-d pgdatadir] [-p pgport] <testname>

     Run TPC-H queries from ./queries on prepared Postgres cluster, measuring
     duration with 'time'. Script relies on previously run ./prepare.sh to get
     info like the scale used while generating data.
     The results will be put to directory ./res/testname-scale. Inside it, a dir
     will be created named qxx, where xx is number of the query, with:
       * File exectimes.txt with execution times
       * File answer.txt with computed answer
       * File qxx.sql with used query.

     Options
     -q queries
       queries to run; if not set it is read from pgtpch.conf, see description
       in pgtpch.conf.example
     -c precmd
        command to run before executing query; if not set it is read from
	pgtpch.conf, see description in pgtpch.conf.example
     -w warmups
        number of warmups; if not set it is read from
	pgtpch.conf, see description in pgtpch.conf.example
     pginstdir, pgdatadir, pgport are all set by default to the values used last
       time by ./prepare.sh, but you can override them here.
     -h display this help and exit
     testname
	name of test, part of result's directory name

     Example:
       ./run.sh -q "2 3 4" test
EOF
}

source common.sh
# read PRECMD, QUIERIES from CONFIGFILE, and SCALE, TPCHDBNAME, PGINSTDIR,
# PGDATADIR, PGPORT from LASTCONF, saved there by ./prepare.sh
BASEDIR=`dirname "$(readlink -f "$0")"` # directory with this script
read_conf "$BASEDIR/$CONFIGFILE" "$BASEDIR/$LASTCONF"

OPTIND=1
while getopts "q:c:w:i:d:p:h" opt; do
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
	w)
	    WARMUPS="$OPTARG"
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
    QUERIES=$(seq 1 22)
fi

TESTDIR="$BASEDIR/res/$TESTNAME-$SCALE"
mkdir -p "$TESTDIR"
for QNUM in $QUERIES; do
    echo "Running query: $QNUM"

    ii=$(printf "%02d" $QNUM)
    QUERYRESDIR="$TESTDIR/q${ii}"
    rm -rf "$QUERYRESDIR"
    mkdir -p "$QUERYRESDIR"
    cd "$QUERYRESDIR"
    # here we will put used query
    touch "q${ii}.sql"
    echo -e "$PRECMD" >> "q${ii}.sql"
    # put the query itself
    cat "$BASEDIR/queries/q${ii}.sql" >> "q${ii}.sql"

    touch exectime.txt
    postgres_start

    for WNUM in $(seq 1 $WARMUPS); do
	echo "Warmup $WNUM..."
	# `which time` to avoid calling bash builtin
	`which time` -f '%e' $PGBINDIR/psql -h /tmp -p $PGPORT -d "$TPCHDBNAME" \
             <"$QUERYRESDIR/q${ii}.sql" >/dev/null 2>>exectime.txt

	echo "Warmup done"
	sleep 3
    done

    echo "GO!.."
    `which time` -f '%e' $PGBINDIR/psql -h /tmp -p $PGPORT -d "$TPCHDBNAME" \
                 <"$QUERYRESDIR/q${ii}.sql" >answer.txt 2>>exectime.txt
    echo "done"

    postgres_stop
done
