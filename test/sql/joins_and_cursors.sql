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

-- count(distinct key), not count(*), on every one of these: SCAN and SSCAN
-- promise only that a key present throughout the iteration is returned at
-- *least* once, and they do return some of them twice when the keyspace or the
-- keyset is resized mid-iteration -- which a bulk insert or delete makes likely,
-- and this module does both. The FDW does not deduplicate (see the dedup issue),
-- so count(*) counts how many times SCAN mentioned a key, which is not an
-- invariant this suite owns. The number of distinct keys is.
select count(distinct key) from   db15;

select count(distinct key) from db15bigprefixscalar;

select count(distinct key) from db15bigkeysetscalar;

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
-- must not stop the scan. count(distinct key) for the reason given above the
-- first count in this file: this is a prefix scan, so SCAN may mention a key
-- more than once and count(*) would assert something it does not promise.
select count(distinct key) from db15_scan_skip;

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

-- A rescan must start the scan over from the beginning. A foreign scan on the
-- inner side of a nested loop, in a LATERAL join, or in a correlated subquery
-- as below, is rescanned once per outer row. redisReScanForeignScan() used to
-- reset the row counter and nothing else, so a cursor scan carried on from
-- whichever SCAN batch it had ended on, and a pushed-down key lookup had
-- already marked its single row consumed. The second and later passes
-- therefore returned one trailing batch, or nothing at all, with no error.
-- Issue #71.
--
-- Here rather than with the per-type modules because this module owns rescan
-- and plan-shape behaviour -- and after the 60k cleanup above rather than
-- among it, because 2,500 keys in an otherwise empty keyspace take exactly
-- three SCAN batches of COUNT 1000. That makes the batch boundaries the bug
-- needs certain without the sparse-match seeding the truncation test above
-- requires. Do not move it back up; it would still fail, but for a count that
-- depends on how the 60k keys happen to be spread over buckets.
--
-- rsc_h is a hash, deliberately seeded under the key prefix of a *scalar*
-- table. A differently-typed key answers WRONGTYPE and has to be skipped --
-- but skipping it must not end the scan early, which was issue #78 (fixed in
-- 683c3c4); this incidental fixture, carried over from the PR for #71, is what
-- exposed it. So the count below reads 2500 rather than 2501 only because the
-- hash is skipped, and reads 2500 rather than some fraction only because
-- skipping it does not truncate the scan. It is live coverage of both, not
-- noise: leave it in place.
\! redis-cli -n 15 eval "for i=1,2500 do redis.call('set','rsc_'..i,'v'..i) end redis.call('hset','rsc_h','f1','a','f2','b') return redis.call('dbsize')" 0

create foreign table db15_rsc(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'rsc_');

-- Every pass must see all 2,500 keys, not just the batch the pass before it
-- happened to stop on.
--
-- count(distinct key), not count(*): SCAN promises only that a key present
-- throughout is returned at *least* once, and it returns some of them twice
-- while the keyspace dict is rehashing -- which it is here, shrinking from the
-- 60,000 keys deleted just above. count(*) came back as 2505 on this machine.
-- The number of distinct keys is the invariant; how many times SCAN mentions
-- each is not ours to assert.
select g, (select count(distinct key) from db15_rsc where g > 0) from generate_series(1, 3) g;

-- and a pushed-down key qual must find its row again on every pass
select g, (select value from db15_rsc where key = 'rsc_1' and g > 0) from generate_series(1, 3) g;

drop foreign table db15_rsc;

-- Bulk again, so server-side in one round trip, for the reason given above.
-- The returned count is the 2,500 strings plus the hash, so it asserts the
-- cleanup took exactly what was seeded and nothing else.
\! redis-cli -n 15 eval "local n=0 for _,k in ipairs(redis.call('keys','rsc_*')) do redis.call('del',k) n=n+1 end return n" 0

\i test/common/epilogue.sql

