#!/usr/bin/python3

import os
import subprocess
import json
import argparse
import pprint
import datetime

# The only job of this script is for each conf:
# * Dump this config to ./tmp_conf.json
# * Set proper LD_LIBRARY_PATH, as different tests
#   potentially can use different libpq versions, and psycopg2 depends on it.
#   In future we should probably add automatic recompilation of psycopg2.
# * Invoke run_single.py to do the rest.

# parse default values in pgtpch.conf
def parse_default_conf():
    conf = {}
    with open("pgtpch.conf", "r") as f:
        for line in f:
            stripped = line.strip()
            if not stripped.startswith('#'):
                splitted = stripped.split('=', 1)
                if len(splitted) == 2:
                    conf[splitted[0].strip()] = splitted[1].strip()
    print("Common (default) conf is")
    pprint.pprint(conf)
    return conf


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="""
    Run some queries against Postgres and does something with them.
    There are two places for configuring the runs: pgtpch.conf
    and json config (by default runconf.json, but can be changed). The former
    specifies common config values for all tests, the latter contains
    list of tests with separate configuration for each one.

    See pgtpch.conf.example to see which options are supported and the meaning
    of each one. See runconf.json.example to see how json config looks like.

    Must be invoked from the project root.

    WARNING: these scripts use psycopg2 (libpq wrapper) to interact with
    Postgres. Different versions of Postgres potentially use different libpqs,
    so we probably should add automatic recompilation of psycopg2 while testing.
    Right now we just set LD_LIBRARY_PATH to pginst_dir/lib, so it would fail
    if libpqs are incompatible.
    """)
    parser.add_argument("--rc", default="runconf.json",
                        help="json file with configs to test, see runconf.json.example")
    args = parser.parse_args()
    this_script_dir = os.path.dirname(os.path.realpath(__file__))

    old_ld_lib_path = os.getenv('LD_LIBRARY_PATH', '')

    default_conf = parse_default_conf()
    # set current datetime as prefix to all res dirs
    curdt = '{0:%Y-%m-%d_%H-%M-%S}'.format(datetime.datetime.now())

    with open(args.rc) as f:
        confs = json.load(f)
        for conf in confs:
            # roll configuration given conf over default one on pgtpch.conf
            merged_conf = default_conf.copy()
            merged_conf.update(conf)
            merged_conf["resdir_prefix"] = curdt

            with open('tmp_conf.json', 'w') as f:
                json.dump(merged_conf, f)

            pglib_path = os.path.join(merged_conf["pginstdir"], "lib")
            os.environ['LD_LIBRARY_PATH'] = "{0}:{1}".format(pglib_path, old_ld_lib_path)
            print("LD_LIBRARY_PATH set to {0}".format(os.environ['LD_LIBRARY_PATH']))

            subprocess.call([os.path.join(this_script_dir, "run_single.py")])
