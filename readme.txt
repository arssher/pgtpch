Simple scripts to run TPC-H benchmarks on PostgreSQL.
Largely based on
https://github.com/2ndQuadrant/pg-tpch

How to use it:
In short,
   git clone https://github.com/arssher/pgtpch.git
   cd pgtpch
   cp pgtpch.conf.example pgtpch.conf # configure here
   cp postgresql.conf.example postgresql.conf # set Postgres options, if you want
   ./prepare.sh
   ./run.sh test

It is recommended to run
 echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
to disable transparent huge pages.

prepare.sh creates database cluster with table containing TPC-H data and
generates the queries. See ./prepare.sh -h for usage.

run.sh runs the queries, see ./run.sh -h for usage.

Tested only on GNU/Linux, Ubuntu 14.04
