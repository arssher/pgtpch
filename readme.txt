Simple scripts to run TPC-H benchmarks. Partly based on
https://github.com/2ndQuadrant/pg-tpch

How to use it:
First of all, prepare dbgen and qgen programs. You can use tvondra's instructions
here:
https://github.com/tvondra/pg_tpch
Eventually you must have directory with programs 'dbgen' and 'qgen' inside. By
default it is assumed that this directory is called 'dbgen' and located in the
root of this project, but you can change it in pgtpch.config.

It is recommended to run
 echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
to disable transparent huge pages.

prepare.sh creates database cluster with table containing TPC-H data and
generates the queries. See ./prepare.sh -h for usage
