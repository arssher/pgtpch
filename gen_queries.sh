#!/usr/bin/env bash

show_help() {
    cat <<EOF
    Usage: bash ${0##*/} [-g dbgenpath]

     Generate the queries and put them to ./queries

    Options
    The only option is read from $CONFIGFILE file, but you can override
    them in command line args. See it's meaning in that file.
EOF
}

source common.sh
read_conf "$CONFIGFILE"

while getopts "g:h" opt; do
    case $opt in
	h)
	    show_help
	    exit 0
	    ;;
	g)
	    DBGENPATH="$OPTARG"
	    ;;
	\?)
	    show_help >&2
	    exit 1
	    ;;
    esac
done

# directory with this script
BASEDIR=`dirname "$(readlink -f "$0")"`
cd "$BASEDIR"
cd "$DBGENPATH" || die "dbgen directory not found"
DBGENABSPATH=`readlink -f "$(pwd)"`

gen_queries $BASEDIR
