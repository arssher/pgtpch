#!/usr/bin/python3

# Test single Postgres installation. Supposed to be invoked from run.py.
# Proper libpq.so must be in runtime linker search path when you invoke this
# script. The script must be run from the project root directory. Config to
# run must be in ./tmp_conf.json

import os
import datetime
import time
import signal
import pathlib
import shutil
import subprocess
import json
import psycopg2
import math
import getpass
from glob import glob

import plumbum
from plumbum import local
from plumbum.cmd import cp, rm, cat, echo, sudo, tee, perf, kill, sync, chmod, chown

# check for scipy and numpy availability to calc confidence intervals
try:
    from scipy.stats import t
    from numpy import average, std
    scipy_loaded = True
except ImportError:
    scipy_loaded = False
    print("scipy or numpy is not available, results will not be summarized")

class QueryNotFoundError(Exception):
    pass


# convert any unknown types to string in json.dumps
class Stringifier(json.JSONEncoder):
    def default(self, obj):
        return str(obj)


# parsed conf values
class PgtpchConf:
    # conf is dict of opts
    def __init__(self, conf):
        self.conf_dict = conf

        # we don't care in this script about the number itself, so stringify it
        self.conf_dict["scale"] = str(self["scale"])
        # and we do care about number of warmups
        self.conf_dict["warmups"] = int(self["warmups"])
        self.numruns = self["warmups"] + 1

        if self.get("pguser") is None:
            self.conf_dict["pguser"] = getpass.getuser()

        self.pg_bin = os.path.join(self["pginstdir"], "bin")
        if self.get("copydir") is None:
            self.real_pgdatadir = self["pgdatadir"]
        else:
            pgdd_name = os.path.basename(os.path.normpath(self["pgdatadir"]))
            self.real_pgdatadir = os.path.join(self["copydir"], pgdd_name)

        if self["queries"] == "all":
            self.queries = ["q{}".format(xx.zfill(2)) for xx in range(1, 23)]
        else:
            self.queries = self["queries"].split()

    def __getitem__(self, key):
        return self.conf_dict[key]

    def get(self, key, default=None):
        return self.conf_dict.get(key, default)

    def to_run_command(self):
        run_cmd = ["./run.sh", "-s", self["scale"], "-i", self["pginstdir"], "-d",
                   self["pgdatadir"], "-p", self["pgport"], "-n", self["tpchdbname"],
                   "-q", self["queries"], "-w", str(self["warmups"])]
        if self["precmd"] is not None:
            run_cmd.extend(["-c", self["precmd"]])
        if self["precmdfile"] is not None:
            run_cmd.extend(["-f", self["precmdfile"]])
        if self["pguser"] is not None:
            run_cmd.extend(["-U", self["pguser"]])
        if self["extconffile"] is not None:
            run_cmd.extend(["-e", self["extconffile"]])
        if self["pguser"] is not None:
            run_cmd.extend(["-t", self["timerruns"]])

        run_cmd.append(self["testname"])

        return run_cmd

    # Returns path to file with query. Searches for it in pgdatadir/queries
    # first, then in ./queries.
    def get_query_path(self, query):
        query_sql = "{}.sql".format(query)
        pgdd_path = os.path.join(self["pgdatadir"], "queries", query_sql)
        local_path = os.path.join("queries", query_sql)
        if os.path.isfile(pgdd_path):
            return pgdd_path
        elif os.path.isfile(local_path):
            return local_path
        raise QueryNotFoundError(query)

    # if 'copydir' option is set, copy pgdatadir to the specified directory
    def copydir(self):
        if self.get("copydir") is not None:
            print("Copying {0} to {1} ...".format(self["pgdatadir"], self.real_pgdatadir))
            (rm["-rf", self.real_pgdatadir])()
            (cp["-r", self["pgdatadir"], self.real_pgdatadir])()
            print("Copy done")
            if self.get("extconffile") is not None:
                if os.path.isfile(self["extconffile"]):
                    (cat[self["extconffile"]] >> os.path.join(self.real_pgdatadir, "postgresql.conf"))()
                    print("extconffile appended")
                else:
                    print("WARN: extconffile specified, but doesn't exists")
            # postgres will complain if permissions are too wide
            (chmod["0700", self.real_pgdatadir])()

    # start postgres, copying pgdatadir if needed
    def postgres_start(self, drop_caches=True):
        if drop_caches:
            print("Dropping caches")
            sync()
            (echo["3"] | sudo[tee["/proc/sys/vm/drop_caches"]] > "/dev/null")()
        self.copydir()
        subprocess.check_call([os.path.join(self.pg_bin, "pg_ctl"),
                               "-w",
                               "-D", self.real_pgdatadir,
                               '-o "-p {}"'.format(self["pgport"]),
                               "start"])
        time.sleep(2)

    # stop postgres, removing pgdatadir if needed
    def postgres_stop(self):
        subprocess.check_call([os.path.join(self.pg_bin, "pg_ctl"),
                               "-w",
                               "-D", self.real_pgdatadir,
                               '-o "-p {}"'.format(self["pgport"]),
                               "stop"])
        if self["copydir"] is not None:
            (rm["-rf", self.real_pgdatadir])()

    # open connection, returns psycopg2 connection object
    def connect(self):
        return psycopg2.connect(
            "host=localhost port={0} user={1} dbname={2}".format(self["pgport"],
                                                                 self["pguser"],
                                                                 self["tpchdbname"]))

class StandardRunner(object):
    def __init__(self, pc):
        assert (isinstance(pc, PgtpchConf))
        self.pc = pc

        # per-query state
        self.query = None
        self.exectime_path = None

        print("Disabling transparent hugepages")
        (echo["never"] | sudo[tee["/sys/kernel/mm/transparent_hugepage/defrag"]] > "/dev/null")()

    def run(self):
        print("Queries are {}".format(pc.queries))
        for query in pc.queries:
            try:
                self.run_query(query)
            except QueryNotFoundError as e:
                print("Query not found: {}".format(e.args[0]))

        self.postrun()

    # Run one query (several times)
    def run_query(self, query):
        print("Running query {}".format(query))
        self.query = query

        # Ensure that res dir exists and empty
        res_dir = self.get_res_dir()
        print("Creating directory {}".format(res_dir))
        shutil.rmtree(res_dir, True)
        os.makedirs(res_dir)

        self.exectime_path = os.path.join(res_dir, "exectime.txt")

        # prepare the query
        ready_query_path = os.path.join(res_dir, "{}.sql".format(query))
        (cat[self.pc.get_query_path(query)] > ready_query_path)()

        self.pc.postgres_start()
        try:
            conn = self.pc.connect()
            self.conn_created_hook(conn)

            if (pc.get("precmdfile") is not None):
                self.log("Running precmdfile {}".format(pc["precmdfile"]))
                with conn.cursor() as curs:
                    curs.execute(cat[pc["precmdfile"]]())
                conn.commit()

            for runnum in range(1, self.pc.numruns + 1):
                self.log("Run {}...".format(runnum))
                self.preexecute_hook(runnum)

                starttime = time.time()
                with conn.cursor() as curs:
                    curs.execute(cat[ready_query_path]())
                    if runnum != self.pc.numruns:
                        # not last run, don't record the answer
                        conn.commit()
                    else:
                        # last run, record the answer
                        answer = curs.fetchall()
                        answer_json = json.dumps(answer, indent=4, cls=Stringifier)
                        (echo[answer_json] > os.path.join(res_dir, "answer.json"))()
                # log exectime
                exectime = time.time() - starttime
                (echo[exectime] >> self.exectime_path)()

                self.postexecute_hook(runnum)
                time.sleep(1)  # small pause

            conn.close()
            self.conn_closed_hook()
        finally:
            self.pc.postgres_stop()

    # Executed after running all queries
    def postrun(self):
        pass

    # Executed when connection was created, conn is psycopg2 conn object
    def conn_created_hook(self, conn):
        pass

    # Executed when connection was closed
    def conn_closed_hook(self):
        self.summary_exectime()

    # Executed before the query execution
    def preexecute_hook(self, runnum):
        pass

    # Executed after the query execution
    def postexecute_hook(self, runnum):
        pass

    # get res dir of current query
    def get_res_dir(self):
        if self.pc.get("resdir_prefix") is not None:
            prefix = "{}-".format(self.pc["resdir_prefix"])
        else:
            prefix = ''

        return os.path.join("res", "{0}{1}-{2}-{3}".format(
            prefix,
            self.pc["testname"], self.query, self.pc["scale"]))

    # log to stdout and 'log.txt' of current query
    def log(self, msg):
        msg_fmt = '{0:%Y-%m-%d %H:%M:%S} '.format(datetime.datetime.now()) + msg
        print(msg_fmt)
        (echo[msg_fmt] >> os.path.join(self.get_res_dir(), "log.txt"))()

    # Calculate avg and error and log them
    def summary_exectime(self):
        if not scipy_loaded:
            return
        exectimes = []
        with open(self.exectime_path) as f:
            for line in f:
                exectimes.append(float(line))

        # calculate 0.95 confidence interval, assuming T-student distribution
        exectimes_mean = average(exectimes)
        standard_deviation = std(exectimes, ddof=1)
        t_bounds = t.interval(0.95, len(exectimes) - 1)
        ci = [exectimes_mean + crit_val * standard_deviation / math.sqrt(len(exectimes))
              for crit_val in t_bounds]
        self.log("Mean exec time: {0:.2f}".format(exectimes_mean))
        self.log("0.95 confidence interval, assuming T-student distribution: {0:.2f}, {1:.2f}\n".format(ci[0], ci[1]))


class PerfRunner(StandardRunner):
    def __init__(self, pc):
        self.backend_pid = None
        self.perf_record_log = None
        self.perf_popen = None

        print("Exposing kernel pointers for seamless perfing")
        (echo["0"] | sudo[tee["/proc/sys/kernel/kptr_restrict"]] > "/dev/null")()

        super().__init__(pc)

    def conn_created_hook(self, conn):
        super(PerfRunner, self).conn_created_hook(conn)
        self.backend_pid = str(conn.get_backend_pid())
        perf_record_log_path  = os.path.join(self.get_res_dir(), "perf_record_log.txt")
        self.perf_record_log = open(perf_record_log_path, 'w')
        print("Backend pid is {0}".format(self.backend_pid))

    # start perf
    def preexecute_hook(self, runnum):
        super(PerfRunner, self).preexecute_hook(runnum)
        assert(self.backend_pid is not None)
        perf_record_cmd = ["sudo", "perf", "record", "-p", self.backend_pid,
                           "-o", self.get_perfdata_path(runnum)]
        if (self.pc.get("perfrecopts") is not None):
            perf_record_cmd.extend(self.pc["perfrecopts"].split())
        self.log("Running {}".format(' '.join(perf_record_cmd)))
        self.perf_popen = subprocess.Popen(perf_record_cmd,
                                           stdout=self.perf_record_log,
                                           stderr=subprocess.STDOUT)
        time.sleep(1)  # let perf start up

    # stop perf
    def postexecute_hook(self, runnum):
        super(PerfRunner, self).postexecute_hook(runnum)
        assert(self.backend_pid is not None)
        sudo[kill["-2", self.perf_popen.pid]]()
        self.perf_popen.wait()
        self.log("Perf record stopped")
        if (self.pc.get("perfscript") == "true" or self.pc.get("flamegraph") == "true"):
            self.generate_perfscript(runnum)
            if (self.pc.get("flamegraph") == "true"):
                self.generate_flamegraph(runnum)


    # close perf log
    def conn_closed_hook(self):
        super(PerfRunner, self).conn_closed_hook()
        self.perf_record_log.close()

    def get_res_dir(self):
        if self.pc.get("resdir_prefix") is not None:
            prefix = "{}-".format(self.pc["resdir_prefix"])
        else:
            prefix = ''

        return os.path.join("perf_res", "{0}{1}-{2}-{3}".format(
            prefix,
            self.pc["testname"], self.query, self.pc["scale"]))

    # perf.data file path for run number runnum
    def get_perfdata_path(self, runnum):
        return os.path.join(self.get_res_dir(), "perf-{}.data".format(runnum))

    # run perf script and put it to out-<runnum>.perf-script
    def generate_perfscript(self, runnum):
        fl_log = os.path.join(self.get_res_dir(), "fg_log.txt")
        perfdata = self.get_perfdata_path(runnum)

        (sudo[chown[getpass.getuser(), perfdata]])()
        cmd = (perf["script", "-i", perfdata] > "out-{0}.perf-script".format(runnum))
        self.log("Running {}".format(cmd))
        # seemingly plumbum doesn't allows to append-redirect stderr to file,
        # so we will capture it and send to log manually
        retcode, out, script_stderr = cmd.run(retcode=None)
        (echo[script_stderr] >> fl_log)()

    # generate flamegraph and put it to <query>-<runnum>.svg
    def generate_flamegraph(self, runnum):
        fl_log = os.path.join(self.get_res_dir(), "fg_log.txt")

        # stackcollapse
        st_pl = os.path.join(self.pc["fg_path"], "stackcollapse-perf.pl")
        perfdata = self.get_perfdata_path(runnum)
        folded = "out.perf-folded"

        fold = cat["out-{0}.perf-script".format(runnum)] | local[st_pl] > folded
        self.log("Running {}".format(fold))
        # seemingly plumbum doesn't allows to append-redirect stderr to file,
        # so we will capture it and send to log manually
        retcode, out, fold_stderr = fold.run(retcode=None)
        (echo[fold_stderr] >> fl_log)()

        # remove perf.data, if needed
        if (self.pc.get("rmperfdata")  == "true"):
            rm("-f", perfdata)
        if retcode != 0:
            self.log("stackcollapse-perf failed, check out fg_log.txt")
            return

        # and generate
        fl_pl = os.path.join(self.pc["fg_path"], "flamegraph.pl")
        svg = os.path.join(self.get_res_dir(), "{0}-{1}.svg".format(self.query, runnum))
        fl = local[fl_pl][folded] > svg
        self.log("Running {}".format(fl))
        retcode, out, fl_stderr = fl.run(retcode=None)
        (echo[fl_stderr] >> fl_log)()
        rm(folded)
        if retcode != 0:
            self.log("flamegraph failed, check out fg_log.txt")


if __name__ == "__main__":
    with open("tmp_conf.json") as f:
        conf = json.load(f)
    rm("tmp_conf.json")
    pc = PgtpchConf(conf)

    if pc["runner"] == "standard":
        runner = StandardRunner(pc)
    elif pc["runner"] == "perfer":
        runner = PerfRunner(pc)
    else:
        print("Wrong runner: {}".format(pc["runner"]))
        sys.exit(1)

    runner.run()
