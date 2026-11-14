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

-- The window is bounded by the bytes it holds as well as by the number of
-- keys, so a scan over large values does not hold a thousand of them at once.
-- Issue #83.
--
-- The ramp above counts keys and ignores their size. 1,024 keys is nothing
-- for scalar values of a few bytes and gigabytes for collections of a few MB,
-- none of it charged to work_mem or visible in EXPLAIN. The window now also
-- stops growing once the bytes measured in the previous window say the next
-- one would exceed a budget, and narrows again if the values get larger.
--
-- Values of 3 MB are far enough above the budget that the window cannot hold
-- two of them, so it stays at one key -- and that is what makes this stable
-- enough to assert in expected output. The counts below depend only on the
-- budget and the value size, and 3 MB is nowhere near the boundary at which
-- the cap would come out as 2 rather than 1: the per-reply overhead the
-- measurement adds, which is the only part that varies with the platform and
-- the hiredis version, is a few dozen bytes against a margin of a megabyte.
-- An assertion pinned to a window of, say, 3 keys would not survive that.
--
-- Exact call counts again, with the same caveat as the LIMIT block above: INFO
-- commandstats is server-wide.

create foreign table db15_bv(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'bv_');

-- 15 MB of values, seeded server-side in one round trip rather than pushed
-- through five INSERTs. The quoted argument is a Lua program run by Redis;
-- see test/README.md.
\! redis-cli -n 15 eval "local v = string.rep('x', 3 * 1024 * 1024) for i = 1, 5 do redis.call('set', 'bv_' .. i, v) end return redis.call('dbsize')" 0

-- The rows are still right: every key, and every value whole. count(distinct
-- key) and the aggregates over length(), rather than a dump of the rows, so a
-- key SCAN mentioned twice cannot fail this. See test/README.md.
select count(distinct key), min(length(value)), max(length(value)) from db15_bv;

\! redis-cli config resetstat > /dev/null

-- Two rows, and at a window of one key that is two value commands. Before the
-- window was bounded by bytes it was 1 + 4 = 5, which is the whole 15 MB held
-- at once to answer a query that wanted two rows.
select count(distinct key) from (select key from db15_bv limit 2) s;

\! redis-cli info commandstats | grep -o '^cmdstat_get:calls=[0-9]*'

delete from db15_bv;

drop foreign table db15_bv;

-- An insert asks Redis nothing before writing. A scalar row is a single
-- SET ... NX, which refuses an existing key by itself, so the EXISTS that used
-- to precede the SET to find out whether the key was there is gone.
--
-- Absence again, and for the same reason as the SCAN assertion at the top of
-- this module: the grep drops the call counts, so another client on this
-- server cannot break it, and EXISTS appearing at all means a round trip was
-- spent asking a question the write itself answers.

create foreign table db15_ins(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'ins_');

\! redis-cli config resetstat > /dev/null

insert into db15_ins values ('ins_1', 'one'), ('ins_2', 'two');

\! redis-cli info commandstats | grep -o -E '^cmdstat_(set|exists)' | sort

-- NX refuses the second write, and the error is the one the EXISTS check used
-- to raise, with the value it left in place
insert into db15_ins values ('ins_1', 'again');

select value from db15_ins where key = 'ins_1';

delete from db15_ins;

drop foreign table db15_ins;

-- batch_size sends that many rows' SET ... NX in one pipelined round trip.
-- What is asserted here is the rows that arrive, not a round-trip count:
-- commandstats counts commands, and a batch of 1000 is still 1000 SETs, so
-- the counters cannot tell the two paths apart. The last row of each batch is
-- read back by key, since an off-by-one in the batching would lose exactly
-- those: 2500 rows is two full batches of 1000 and a short one of 500.

create foreign table db15_bins(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'bins_', batch_size '1000');

insert into db15_bins select 'bins_' || g, 'v' || g from generate_series(1, 2500) g;

-- count(distinct key): a 2500-key insert makes a hash-table resize likely, and
-- a resized SCAN may mention a key twice. See test/README.md.
select count(distinct key) from db15_bins;

select value from db15_bins where key = 'bins_1000';
select value from db15_bins where key = 'bins_2000';
select value from db15_bins where key = 'bins_2500';

-- A key already in Redis fails the statement, and the rest of the batch stays
-- written: Redis has no rollback, and a batch widens the window in which that
-- shows. The five new keys are all there, and the duplicate's existing value
-- is untouched. See README.md.
insert into db15_bins select 'bins_x' || g, 'v' || g from generate_series(1, 5) g
  union all select 'bins_7', 'dup';

select count(distinct key) from db15_bins where key like 'bins_x%';

select value from db15_bins where key = 'bins_7';

drop foreign table db15_bins;

-- 2505 keys, deleted in one server-side pass rather than one round trip each.
-- The quoted argument is a Lua program run by Redis; see test/README.md.
\! redis-cli -n 15 eval "local n=0 for _,k in ipairs(redis.call('keys','bins_*')) do redis.call('del',k) n=n+1 end return n" 0

-- batch_size on a table whose insert cannot be batched must be inert, not
-- half-applied: every row still has to arrive, exactly once, with the value it
-- was given.
--
-- Two cases the batch-size callback declines to batch. RETURNING is the one
-- postgres_fdw declines for, and this FDW refuses it outright a step earlier,
-- when the modify is planned -- so the callback's RETURNING check can never
-- fire here and the option cannot make RETURNING any more or less supported
-- than it was. A row trigger is the reachable case: it needs each row as it is
-- inserted, so the rows go one at a time however large the table's batch_size
-- is.

create foreign table db15_rins(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'rins_', batch_size '100');

insert into db15_rins values ('rins_1', 'one') returning key, value;

create function rins_note() returns trigger language plpgsql as $$
begin
  raise notice 'before insert of %', new.key;
  return new;
end $$;

create trigger rins_trg before insert on db15_rins
  for each row execute function rins_note();

insert into db15_rins values ('rins_1', 'one'), ('rins_2', 'two'), ('rins_3', 'three');

select value from db15_rins where key = 'rins_2';

select count(distinct key) from db15_rins;

drop trigger rins_trg on db15_rins;

delete from db15_rins;

drop function rins_note();

drop foreign table db15_rins;

-- A cached connection is checked out without a round trip. The check that a
-- cached connection is still usable polls its socket, with no wait; it was a
-- PING, which cost a round trip on the first checkout in every transaction --
-- in autocommit, before every statement. So no PING is sent at all.
--
-- The connection the two lookups below check out is the one the INSERT above
-- them opened, and it is already in the cache by the time the counters are
-- reset, so both lookups validate it. A PING from either is counted.
--
-- Absence again, in the same spirit as the SCAN assertion at the top of this
-- module: the grep drops the call counts, so another client moving the
-- counters cannot break this, and a cmdstat_ping line appearing at all means
-- the round trip is back.

create foreign table db15_ping(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'ping_');

insert into db15_ping values ('ping_1', 'one');

\! redis-cli config resetstat > /dev/null

select value from db15_ping where key = 'ping_1';

select value from db15_ping where key = 'ping_1';

\! printf 'cmdstat_ping entries: '; redis-cli info commandstats | grep -c '^cmdstat_ping:'

-- the fail-closed companion, exactly as for the SCAN assertion above, and the
-- second INFO of this reset window for the same reason: a command is counted
-- only once it has finished, so the first INFO cannot see itself.
\! printf 'cmdstat_info entries: '; redis-cli info commandstats | grep -c '^cmdstat_info:'

delete from db15_ping;

drop foreign table db15_ping;

-- A key lookup under a NONDETERMINISTIC collation must not be pushed down.
-- Issue #82.
--
-- The pushdown sends the comparison value to Redis as a byte-exact key, but
-- text equality under a nondeterministic collation is not byte-exact: two
-- strings PostgreSQL calls equal can differ in bytes. So the one lookup asks
-- for a key that does not exist and the row is never fetched -- and the qual
-- retained as a filter cannot rescue it, because a filter discards rows that
-- were fetched and cannot produce one that was never asked for. The fix is to
-- refuse the pushdown and walk the keyspace instead, letting PostgreSQL's own
-- equality decide.
--
-- This lives in the command-statistics module because it is a pushdown
-- decision: what the fix changes is which commands the FDW sends, and the
-- assertion that matters -- that an ordinary deterministic lookup still sends
-- no SCAN -- needs this module's CONFIG RESETSTAT window and can live nowhere
-- else. Keeping both halves here also keeps the ICU guard in one place.

\! redis-cli -n 15 set nd_1 one > /dev/null

-- A nondeterministic collation needs a usable ICU provider, which not every
-- PostgreSQL build and database has. Guarded the way scalar.sql guards on
-- server_encoding: a procedure printing one verdict line, because psql's \if
-- echoes the lines of the branch it skips and they would diff anyway.
--
-- One verdict line means exactly that: the same text whether the collation
-- could be created or not. It must not name which build this is, because
-- there is more than one way to lack a usable provider and each says so
-- differently -- a build configured without ICU reports "ICU is not supported
-- in this build", while an ICU build running a database in an encoding ICU
-- cannot use reports "current database's encoding is not supported with this
-- provider". Interpolating sqlerrm here put three possible outputs behind one
-- expected file, and the buildfarm produces all three: it broke every branch
-- on crake, which runs installcheck in the C locale. Like enc_case, this
-- trades knowing that the case was skipped for an expected file that holds
-- everywhere; a real failure still prints FAILED and still diffs.
--
-- Only the CREATE COLLATION is allowed to fail quietly. Everything after it
-- runs unguarded, so a real failure is seen rather than swallowed.
create procedure nd_case() language plpgsql as $$
declare
  n int;
begin
  begin
    execute $c$create collation nd_ci
               (provider = icu, locale = 'und-u-ks-level2',
                deterministic = false)$c$;
  exception when others then
    raise notice 'nondeterministic collation: as the build allows';
    return;
  end;

  execute $c$create foreign table db15_nd(key text collate nd_ci, value text)
             server localredis
             options (database '15', tablekeyprefix 'nd_')$c$;

  -- 'ND_1' = 'nd_1' is true at this collation's strength, and md5() of the
  -- two differs, so a byte-exact lookup for 'ND_1' finds nothing.
  -- count(distinct key) rather than count(*): the refused pushdown means
  -- this enumerates the keyspace. See test/README.md.
  execute $c$select count(distinct key) from db15_nd where key = 'ND_1'$c$
    into n;

  if n = 1 then
    raise notice 'nondeterministic collation: as the build allows';
  else
    raise notice 'FAILED: nondeterministic collation: % rows, not 1', n;
  end if;

  execute 'drop foreign table db15_nd';
  execute 'drop collation nd_ci';
end $$;

call nd_case();

drop procedure nd_case();

-- The other half, and the one that stops a regression: the check must refuse
-- only an explicitly nondeterministic collation. The database default and
-- InvalidOid are deterministic, so an ordinary key = <constant> lookup on an
-- ordinary text column must still be pushed down and must still issue no
-- SCAN. Absence assertion, for the reasons given at the top of this module.

create foreign table db15_nd_det(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'nd_');

\! redis-cli config resetstat > /dev/null

select value from db15_nd_det where key = 'nd_1';

\! printf 'cmdstat_scan entries: '; redis-cli info commandstats | grep -c '^cmdstat_scan:'

-- the fail-closed companion, and the second INFO of this reset window, for
-- the reasons given at the top of this module
\! printf 'cmdstat_info entries: '; redis-cli info commandstats | grep -c '^cmdstat_info:'

drop foreign table db15_nd_det;

-- seeded with redis-cli and only ever read, so it goes the way it was made
\! redis-cli -n 15 del nd_1 > /dev/null

\i test/common/epilogue.sql
