#!/usr/bin/python3

import sys
import subprocess
import os
import json
import pprint
import argparse

from scipy.stats import t
from numpy import average, std
from math import sqrt


# parsed conf values
class RunConf:
    # conf is dict of opts needed to run run.sh
    # all params except the last 3 are required
    def __init__(self, conf):
        # [] access raises KeyError if key not found while .get() returns None, which is handy for us
        self.scale = str(conf["scale"])  # we don't care in this script about the number itself, so stringify it
        self.pginstdir = conf["pginstdir"]
        self.pgdatadir = conf["pgdatadir"]
        self.pgport = conf["pgport"]
        self.tpchdbname = conf["tpchdbname"]
        self.query = conf["query"]
        self.warmups = int(conf["warmups"])
        self.testname = conf["testname"]

        self.precmd = conf.get("precmd")
        self.precmd_file = conf.get("precmdfile")
        self.pguser = conf.get("pguser")

        self.res_dir = os.path.join("res", "{0}-{1}".format(self.testname, self.scale))

    def to_run_command(self):
        run_cmd = ["./run.sh", "-s", self.scale, "-i", self.pginstdir, "-d", self.pgdatadir, "-p", self.pgport,
                   "-n", self.tpchdbname, "-q", self.query, "-w", str(self.warmups)]
        if self.precmd is not None:
            run_cmd.extend(["-c", self.precmd])
        if self.precmd_file is not None:
            run_cmd.extend(["-f", self.precmd_file])
        if self.pguser is not None:
            run_cmd.extend(["-U", self.pguser])
        run_cmd.append(self.testname)

        return run_cmd


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


def tee(sinks, msg):
    for sink in sinks:
        sink.write(msg)


# Calculate avg and error and log them
def analyze_result(conf, sinks):
    assert (isinstance(conf, RunConf))
    exectimes = []
    exectimes_parsed = 0
    n_runs = conf.warmups + 1
    exectime_f_path = os.path.join(conf.res_dir, conf.query, "exectime.txt")
    with open(exectime_f_path) as f:
        for line in f:
            try:
                exectimes.append(float(line))
                exectimes_parsed += 1
            except ValueError:
                pass

    if exectimes_parsed != n_runs:
        tee("There were {0} runs, but {1} exec times were found, aborting analyzing\n".format(n_runs, exectimes_parsed))
        return

    # calculate 0.95 confidence interval, assuming T-student distribution
    exectimes_mean = average(exectimes)
    standard_deviation = std(exectimes, ddof=1)
    t_bounds = t.interval(0.95, len(exectimes) - 1)
    ci = [exectimes_mean + crit_val * standard_deviation / sqrt(len(exectimes)) for crit_val in t_bounds]
    tee(sinks, "Mean exec time:\n")
    tee(sinks, str(exectimes_mean) + "\n")
    tee(sinks, "0.95 confidence interval, assuming T-student distribution:\n")
    tee(sinks, str(ci[0]) + ", " + str(ci[1]) + "\n")


# Run run.sh one time
def run_conf(conf):
    assert (isinstance(conf, RunConf))
    if not os.path.exists(conf.res_dir):
        os.makedirs(conf.res_dir)
    # log to run.py stdout as well as to log file
    sinks = [open(os.path.join(conf.res_dir, "log.txt"), "w"), sys.stdout]
    tee(sinks, "Running\n")
    tee(sinks, ' '.join(conf.to_run_command()) + '\n')

    p = subprocess.Popen(conf.to_run_command(),
                         stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT
                         )
    chunksize = 16
    while True:
        log_chunk = p.stdout.read(chunksize)
        if log_chunk:
            tee(sinks, log_chunk.decode(sys.stdout.encoding))
        else:
            break
    retcode = p.wait()
    if retcode == 0:
        analyze_result(conf, sinks)
    tee(sinks, "run.sh ended with retcode {}\n".format(retcode))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--rc", default="runconf.json", help="json file with configs to run, see runconf.json.example")
    parser.parse_args()

    default_conf = parse_default_conf()
    with open("runconf.json") as f:
        confs = json.load(f)
        for conf in confs:
            # roll configuration given in runconf.json over default one on pgtpch.conf
            merged_conf = default_conf.copy()
            merged_conf.update(conf)
            try:
                rc = RunConf(merged_conf)
                run_conf(rc)
            except KeyError as e:
                print("The key {} is missing, skipping this conf:".format(str(e)))
                pprint.pprint(conf)
