-- maxmemory update-atomicity tests. CONFIG SET maxmemory is server-global
-- state the db-15 guard cannot see, which is why this module runs last in
-- REGRESS.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

\i test/common/epilogue.sql
