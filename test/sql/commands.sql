-- Command-statistics assertions. CONFIG RESETSTAT is server-global, so one
-- module containing it beats five.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

-- key = <expression> has to be pushed down as a single-key lookup, not
-- answered by walking the keyspace. Nothing in the result of such a query says
-- which happened -- both give the same rows -- so the only witness available
-- from SQL is Redis's own command counters: a pushed-down lookup issues EXISTS
-- and GET for one key, while a fall-through issues SCAN. Issue #67.
--
-- Assert the ABSENCE of SCAN, and never a count of anything else. INFO
-- commandstats is server-wide, not per-backend, so any other client talking to
-- this server would move every counter; absence is the only assertion that
-- survives that, and it is the one that matters, since SCAN appearing at all
-- means the lookup was not pushed down.

create foreign table db15_cmd(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'cmd_');

insert into db15_cmd values ('cmd_1', 'one'), ('cmd_2', 'two'), ('cmd_3', 'three');

-- A generic plan, so the key reaches redisGetQual as a PARAM_EXTERN Param and
-- not as a Const folded in by the planner.
set plan_cache_mode = force_generic_plan;

prepare cmd_lookup(text) as select value from db15_cmd where key = $1;

-- The EXPLAIN is part of the test: $1 rather than 'cmd_1'::text in the filter
-- is what makes the executions below a pushdown of an expression rather than
-- of a constant. If this ever printed a literal, the counter assertion would
-- still pass and would be testing master's Const path.
explain (costs off) execute cmd_lookup('cmd_1');

-- Reset as late as possible. Everything above is counted too -- the SETs from
-- the insert, a DBSIZE per plan -- and none of that is what is being asserted,
-- but a SCAN from the seeding would be indistinguishable from a failed
-- pushdown. Equally, the cleanup at the end of this module must stay below the
-- assertion: an unqualified DELETE through a prefixed table enumerates its
-- keys, and enumeration is SCAN.
\! redis-cli config resetstat > /dev/null

execute cmd_lookup('cmd_1');
execute cmd_lookup('cmd_2');
execute cmd_lookup('cmd_3');
execute cmd_lookup('cmd_1');

-- The shape from the issue report: the key is 'prefix' || i, which is not a
-- Const either, and is not a parameter on its own. Each SELECT INTO is its own
-- executor run, so this exercises the once-per-scan evaluation three times
-- over rather than exercising a rescan.
do $$
declare v text;
begin
  for i in 1..3 loop
    select value into v from db15_cmd where key = 'cmd_' || i;
    raise notice 'i=% v=%', i, coalesce(v, '<NULL>');
  end loop;
end $$;

-- The assertion. Zero, or the lookups above walked the keyspace.
\! printf 'cmdstat_scan entries: '; redis-cli info commandstats | grep -c '^cmdstat_scan:'

-- And the same question asked of a command that certainly was issued, so that
-- the assertion above fails closed: redis-cli unreachable, or commandstats
-- empty, would make it report no SCAN because it had nothing to read rather
-- than because nothing scanned. INFO is itself a counted command, so this
-- depends on nothing the FDW did -- but it has to be the *second* INFO of the
-- module, because a command is counted only once it has finished and the first
-- INFO therefore cannot see itself.
\! printf 'cmdstat_info entries: '; redis-cli info commandstats | grep -c '^cmdstat_info:'

deallocate cmd_lookup;
reset plan_cache_mode;

delete from db15_cmd;
drop foreign table db15_cmd;

\i test/common/epilogue.sql
