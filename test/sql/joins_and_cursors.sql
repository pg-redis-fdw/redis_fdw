-- The FDW as part of a larger query plan: cursors, UPDATE ... FROM and
-- DELETE ... USING, a forced merge join on the key column, and EXPLAIN.
--
-- Two subjects in one file, which is tolerable at this size. If it grows,
-- split it rather than adding to it.
\i test/common/prologue.sql

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

drop table joinupd_src;
drop foreign table db15_joinupd;


\i test/common/epilogue.sql

