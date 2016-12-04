Simple scripts to run TPC-H benchmarks. Largely based on
https://github.com/2ndQuadrant/pg-tpch

How to use it:
It is recommended to run
 echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
to disable transparent huge pages.

We use a modified version of DBGEN for PostgreSQL taken from the project
mentioned above. If you want for any reason temporary change it, you can copy
'dbgen' directory to 'dbgen-type_you_name_here', such dirs are ignored by git.
You should then specify it either in pgtpch.config or as an arg to scripts.

prepare.sh creates database cluster with table containing TPC-H data and
generates the queries. See ./prepare.sh -h for usage.

TODO: drop_caches?
