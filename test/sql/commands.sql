-- Command-statistics assertions. CONFIG RESETSTAT is server-global, so one
-- module containing it beats five.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

\i test/common/epilogue.sql
