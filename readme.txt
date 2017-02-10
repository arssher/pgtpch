Simple scripts to run TPC-H benchmarks on PostgreSQL.
Largely based on
https://github.com/2ndQuadrant/pg-tpch

How to use it:
In short,
   git clone https://github.com/arssher/pgtpch.git
   cd pgtpch
   cp pgtpch.conf.example pgtpch.conf # configure setup here
   cp postgresql.conf.example postgresql.conf # set Postgres options, if you want
   cp runconf.json.example runconf.json  # congifure runs here
   ./prepare.sh
   ./run.py

It is recommended to run
 echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
to disable transparent huge pages.

Each script has "./script -h" help

prepare.sh creates database cluster with table containing TPC-H data and
generates the queries.

gen_queries.h generates the queries.

run.sh runs the queries.

run.py is wrapper around run.sh with following features:
  * It allows to specify multiple configurations to run in json file, see
    runconf.json.example for example;
  * It calculates mean and confidence interval of all exec times;
  * It logs everything to stdout and res/testname/log.txt
Unlike run.sh, one configuration of run.py supports only one query.

Tested only on GNU/Linux, Ubuntu 14.04 and OpenSuse 42.1
