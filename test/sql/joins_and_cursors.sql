-- The FDW as part of a larger query plan: cursors, UPDATE ... FROM and
-- DELETE ... USING, a forced merge join on the key column, and EXPLAIN.
--
-- Two subjects in one file, which is tolerable at this size. If it grows,
-- split it rather than adding to it.
--
-- The multi-key scan truncation test at the end is a third subject, and it is
-- here for this module's keyspace rather than for its plans: SCAN ... COUNT
-- 1000 walks about a thousand buckets per call, so a sparse MATCH over the
-- ~60,000 keys the cursor tests above already made yields only a handful of
-- matches per batch and therefore many batch boundaries -- which is what that
-- bug needs in order to show up at all. Reproducing it from an empty database
-- would mean seeding ~10,000 keys of its own for the same reliability.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

-- cursor tests

create foreign table db15bigprefixscalar (
       key text not null,
       val text
)
server localredis
options (database '15', tablekeyprefix 'w_scalar_');

create foreign table db15bigkeysetscalar (
       key text not null,
       val text
)
server localredis
options (database '15', tablekeyset 'w_kset');

insert into db15
select 'junk' || x, 'junk'
from generate_series(1,10000) as x;

insert into db15bigprefixscalar
select 'w_scalar_' || x::text, 'val ' || x::text
from generate_series (1,10000) as x;

insert into db15bigkeysetscalar
select 'key_' || x::text, 'val ' || x::text
from generate_series (1,10000) as x;

insert into db15
select 'junk' || x, 'junk'
from generate_series(10001, 20000) as x;

insert into db15bigprefixscalar
select 'w_scalar_' || x::text, 'val ' || x::text
from generate_series (10001, 20000) as x;

insert into db15bigkeysetscalar
select 'key_' || x::text, 'val ' || x::text
from generate_series (10001, 20000) as x;

select count(*) from   db15;

select count(*) from db15bigprefixscalar;

select count(*) from db15bigkeysetscalar;

-- UPDATE ... FROM / DELETE ... USING against a foreign table, including
-- via a forced merge join on the key column. Regression test for:
-- - EXPLAIN of INSERT/UPDATE/DELETE (no ANALYZE) must not crash the backend
-- - a merge join on the key column must not fail with
--   "could not find pathkey item to sort" (caused by a collation mismatch
--   between the key column's row-identity Var and its plain references)

create foreign table db15_joinupd(key text, val text)
       server localredis
       options (tablekeyprefix 'joinupd_', database '15');

insert into db15_joinupd values
       ('joinupd_foo', 'old1'), ('joinupd_bar', 'old2'), ('joinupd_baz', 'old3');

create table joinupd_src(key text, val text);
insert into joinupd_src values ('joinupd_foo', 'new1'), ('joinupd_bar', 'new2');

explain (costs off) update db15_joinupd set val = 'x' where key = 'joinupd_foo';
explain (costs off) delete from db15_joinupd where key = 'joinupd_foo';
explain (costs off) insert into db15_joinupd values ('joinupd_new', 'v');

set enable_hashjoin = off;
set enable_nestloop = off;

explain (costs off) update db15_joinupd r set val = n.val
       from joinupd_src n where r.key = n.key;

update db15_joinupd r set val = n.val
       from joinupd_src n where r.key = n.key;

select * from db15_joinupd order by key;

delete from db15_joinupd r using joinupd_src n where r.key = n.key;

select * from db15_joinupd order by key;

reset enable_hashjoin;
reset enable_nestloop;

delete from db15_joinupd;

drop table joinupd_src;
drop foreign table db15_joinupd;

-- A multi-key scan must not end because a SCAN batch happened to run out of
-- keys while it was skipping unusable ones. A GET against a hash answers
-- WRONGTYPE and a key deleted between the SCAN and the GET answers nil; both
-- are skipped, and when the skipped key is the last matched key of a non-final
-- batch the scan used to return an empty slot, which the executor reads as end
-- of scan. Every remaining batch was then discarded, silently: count(*) came
-- back as a fraction of the rows with no error raised.
--
-- 500 strings rscs_1..rscs_500 interleaved with 500 hashes rscs_h1..rscs_h500
-- under one tablekeyprefix, inside the large keyspace above. That is about a
-- thousand matched keys spread over ~61 sparse SCAN batches, so roughly half
-- the batches end on a hash and the truncation is essentially certain. Seeded
-- server-side for the same reason the cleanup below is: one round trip rather
-- than a thousand. The returned count asserts both halves were written.
\! redis-cli -n 15 eval "local n=0 for i=1,500 do redis.call('set','rscs_'..i,'v'..i) redis.call('hset','rscs_h'..i,'f','v') n=n+2 end return n" 0

create foreign table db15_scan_skip(key text, val text)
       server localredis
       options (database '15', tablekeyprefix 'rscs_');

-- the 500 strings; the 500 hashes are correctly skipped, but skipping them
-- must not stop the scan
select count(*) from db15_scan_skip;

drop foreign table db15_scan_skip;

\! redis-cli -n 15 eval "local n=0 for _,k in ipairs(redis.call('keys','rscs_*')) do redis.call('del',k) n=n+1 end return n" 0

-- The 60k keys the cursor tests made. Deleting them through the FDW costs one
-- Redis round trip per key -- measured at 5.5s, a third of this module's
-- runtime -- to re-cover a delete path that scalar, hash, set and zset already
-- test. This module is about the plan shapes above, and its own delete tests
-- (DELETE ... USING, and db15_joinupd just now) stay as they are.
--
-- So do the loop server-side, in one round trip. THE QUOTED ARGUMENT BELOW IS
-- A LUA SCRIPT: redis-cli does not interpret it, it ships it to the server as
-- a string and the server's own embedded Lua runs it. Nothing Lua is installed
-- or linked by this suite -- EVAL is just a Redis command, present since 2.6.
-- hash.sql reaches past the FDW the same way. See test/README.md.
--
-- The script names the three patterns this module created plus the keyset,
-- which none of them match now that the SREMs that would have emptied it are
-- gone. The count it returns is 20000 three times over plus the keyset, so it
-- asserts the cleanup took exactly what the inserts above made, and nothing
-- else.
--
-- Two constraints this script carries: writing after KEYS makes it a write
-- after a non-deterministic command, which needs effects replication (the
-- default since Redis 5.0); and KEYS inside a script, with no declared keys,
-- is not valid on a cluster node. Neither binds this suite, which is
-- single-node throughout, but both bind anyone copying the idiom.
\! redis-cli -n 15 eval "local n=0 for _,p in ipairs(ARGV) do for _,k in ipairs(redis.call('keys',p)) do redis.call('del',k) n=n+1 end end return n" 0 'junk*' 'w_scalar_*' 'key_*' 'w_kset'

select count(*) from db15;

\i test/common/epilogue.sql

