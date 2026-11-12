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
-- from SQL is Redis's own command counters: a pushed-down lookup issues the
-- command that reads one key's value, while a fall-through issues SCAN.
-- Issue #67.
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

-- A pushed-down key is read in one round trip. The command that fetches the
-- value goes out straight away: no EXISTS ahead of it to find out whether the
-- key is there -- a missing key is recognised from the value reply itself --
-- and no DBSIZE while the lookup is planned, since a key = <text constant>
-- restriction finds at most one row and needs no table size. A tablekeyset
-- table still has its membership to check, and the SISMEMBER for it is
-- pipelined with the value command rather than paying for a round trip of its
-- own.
--
-- Absence assertions again, in the same spirit as the SCAN one above: the grep
-- drops the call counts, so another client moving the counters cannot break
-- this, and what is asserted is that EXISTS and DBSIZE are gone while the
-- value command and SISMEMBER are still issued.

\! redis-cli -n 15 set fk_1 one > /dev/null
\! redis-cli -n 15 set fk_2 two > /dev/null
\! redis-cli -n 15 hset fk_h f v > /dev/null
\! redis-cli -n 15 sadd fkeys fk_1 fk_2 > /dev/null

create foreign table db15_fk(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'fk_');

create foreign table db15_fk_set(key text, value text)
       server localredis
       options (database '15', tablekeyset 'fkeys');

\! redis-cli config resetstat > /dev/null

-- a key that is there, a key that is not, a keyset member, and a key outside
-- the keyset: one round trip each, and the two misses must not cost an extra
-- one to discover
select value from db15_fk where key = 'fk_1';

select value from db15_fk where key = 'fk_3';

select value from db15_fk_set where key = 'fk_2';

select value from db15_fk_set where key = 'fk_h';

\! redis-cli info commandstats | grep -o -E '^cmdstat_(get|sismember|exists|dbsize)' | sort

-- all four keys were made with redis-cli, since two of them have to be a hash
-- and a set, so they all go the same way
\! redis-cli -n 15 del fk_1 fk_2 fk_h fkeys > /dev/null

drop foreign table db15_fk;
drop foreign table db15_fk_set;

-- A scan fetches the values of a window of keys in one pipelined round trip,
-- and the window starts at one key and quadruples. So a query that stops early
-- does not pay for the values of a whole SCAN batch: one value command for
-- LIMIT 1 -- what the scan cost before this was pipelined at all -- and
-- 1 + 4 + 16 = 21 for LIMIT 6.
--
-- UNLIKE EVERY OTHER ASSERTION IN THIS MODULE, this one asserts exact call
-- counts rather than the presence or absence of a command. INFO commandstats
-- is server-wide, so anything else talking to this Redis while this runs --
-- another client, a second copy of this suite -- moves the counter and fails
-- it. See the warning about concurrent runs in test/README.md.

create foreign table db15_fl(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'fl_');

-- enough keys that one SCAN batch holds far more than the 21 the widest window
-- below reaches, so the counts measure the window and not the batch
insert into db15_fl select 'fl_' || x, 'v' from generate_series(1, 200) x;

\! redis-cli config resetstat > /dev/null

-- count(distinct key), as everywhere this suite counts a scan. Under a LIMIT
-- it answers what count(*) would: the rows come from a single SCAN call, which
-- cannot mention a key twice.
select count(distinct key) from (select key from db15_fl limit 1) s;

\! redis-cli info commandstats | grep -o '^cmdstat_get:calls=[0-9]*'

\! redis-cli config resetstat > /dev/null

select count(distinct key) from (select key from db15_fl limit 6) s;

\! redis-cli info commandstats | grep -o '^cmdstat_get:calls=[0-9]*'

delete from db15_fl;

drop foreign table db15_fl;

\i test/common/epilogue.sql
