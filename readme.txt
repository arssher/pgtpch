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

Scripts use the following tee commands, it is recommended to setup sudoers to
run them without password prompt:
  * echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
  * echo 3 | sudo tee /proc/sys/vm/drop_caches
First disables transparent huge pages, second drops kernel fs caches.
And even more commands, if you use perf:
  * echo 0 | sudo tee /proc/sys/kernel/kptr_restrict
  * sudo perf record
  * sudo kill -2 'perf record pid'
  * sudo perf script


Each script has "./script -h" help

prepare.sh creates database cluster with database containing TPC-H data and
generates the queries folder inside cluster directory.

gen_queries.h generates the 'queries' dir with TPC-H queries in the current
directory.

run.sh runs the queries. It is kind of deprecated, run.py should be used instead.

run.py tests multiple configurations. See its help and pgtpch.conf.example
for details. Usually I run it like

nohup ./run.py > logs/`date "+%Y-%m-%d-%H-%M"`.out &

Tested only on GNU/Linux, Ubuntu 14.04 and OpenSuse 42.2
