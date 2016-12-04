# Parse config file written in format 'optname = optvalue'
# Variable CONFIGFILE must be set

if [ -f $CONFIGFILE ]; then
    echo "Reading $CONFIGFILE..."
    SCALE=$(awk '/^scale/{print $3}' "${CONFIGFILE}")
    PGINSTDIR=$(awk '/^pginstdir/{print $3}' "${CONFIGFILE}")
    PGDATADIR=$(awk '/^pgdatadir/{print $3}' "${CONFIGFILE}")
    TPCHTMP=$(awk '/^tpchtmp/{print $3}' "${CONFIGFILE}")
    PGPORT=$(awk '/^pgport/{print $3}' "${CONFIGFILE}")
    TPCHDBNAME=$(awk '/^tpchdbname/{print $3}' "${CONFIGFILE}")
    DBGENPATH=$(awk '/^dbgenpath/{print $3}' "${CONFIGFILE}")
else
    echo "Config file $CONFIGFILE doesn't exist and will not be read"
fi
