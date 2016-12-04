#!/usr/bin/env bash
set -e

show_help() {
    cat <<EOF
     Usage: bash ${0##*/}
EOF
    exit 0
}

# restore config used by prepare.sh
CONFIGFILE="$LASTCONF"
source read_conf.sh
source common.sh
