\i test/common/prologue.sql

-- a table declared with the wrong number of columns for its type/shape is
-- rejected on first use, for every table type this FDW supports

create foreign table db15_set_bad_shape(key text, value text, extra text)
       server localredis
       options (tabletype 'set', tablekeyprefix 'set_bad_', database '15');

select * from db15_set_bad_shape;

drop foreign table db15_set_bad_shape;

create foreign table db15_list_bad_shape(key text, value text, extra text)
       server localredis
       options (tabletype 'list', tablekeyprefix 'list_bad_', database '15');

select * from db15_list_bad_shape;

drop foreign table db15_list_bad_shape;

create foreign table db15_hash_bad_shape(key text, value text, extra text)
       server localredis
       options (tabletype 'hash', tablekeyprefix 'hash_bad_', database '15');

select * from db15_hash_bad_shape;

drop foreign table db15_hash_bad_shape;

create foreign table db15_zset_bad_shape(key text, value text, extra text, extra2 text)
       server localredis
       options (tabletype 'zset', tablekeyprefix 'zset_bad_', database '15');

select * from db15_zset_bad_shape;

drop foreign table db15_zset_bad_shape;

create foreign table db15_singleton_scalar_bad_shape(a text, b text)
       server localredis
       options (singleton_key 'bad_singleton', database '15');

select * from db15_singleton_scalar_bad_shape;

drop foreign table db15_singleton_scalar_bad_shape;

-- a dropped column must not count toward the declared column count: adding a
-- column and dropping it again leaves the table as valid as it started

create foreign table db15_hash_dropped(key text, value text)
       server localredis
       options (tabletype 'hash', tablekeyprefix 'hash_drop_', database '15');

alter foreign table db15_hash_dropped add column extra text;
alter foreign table db15_hash_dropped drop column extra;

select * from db15_hash_dropped;

drop foreign table db15_hash_dropped;

-- but dropping a column the table type does need is an error, not a table that
-- silently reports NULL for the column that went missing

create foreign table db15_hash_lost_value(key text, value text)
       server localredis
       options (tabletype 'hash', tablekeyprefix 'hash_lost_', database '15');

alter foreign table db15_hash_lost_value drop column value;

select * from db15_hash_lost_value;

drop foreign table db15_hash_lost_value;

-- a dropped column ahead of a live one leaves that live column at a position
-- past the end of the values array the scan builds, so it is rejected as well

create foreign table db15_hash_middrop(key text, mid text, value text)
       server localredis
       options (tabletype 'hash', tablekeyprefix 'hash_mid_', database '15');

alter foreign table db15_hash_middrop drop column mid;

select * from db15_hash_middrop;

drop foreign table db15_hash_middrop;


-- NULL key or value must be rejected with an error, not crash the backend.

create foreign table db15_w_nulls_hash(key text, val text)
       server localredis
       options (singleton_key 'w_nulls_hash', tabletype 'hash', database '15');

insert into db15_w_nulls_hash values (null, 'v');

insert into db15_w_nulls_hash values ('k', null);

create foreign table db15_w_nulls_zset(val text, score numeric)
       server localredis
       options (singleton_key 'w_nulls_zset', tabletype 'zset', database '15');

insert into db15_w_nulls_zset values ('m', null);

create foreign table db15_w_nulls_multi(key text, val text)
       server localredis
       options (tabletype 'hash', database '15');

insert into db15_w_nulls_multi values (null, 'v');

insert into db15_w_nulls_multi values ('k', null);

drop foreign table db15_w_nulls_hash;
drop foreign table db15_w_nulls_zset;
drop foreign table db15_w_nulls_multi;

-- A collection table stores its members in an array-typed value column. A
-- scalar bytea column cannot hold them: unlike scalar text, which yields a
-- PostgreSQL array literal that casts back to an array, bytea has no array
-- literal form. The write path already refuses this shape; the read path
-- must too, rather than silently returning an empty bytea.

\! redis-cli -n 15 rpush bcol_list a b c > /dev/null
\! redis-cli -n 15 sadd  bcol_set  x y   > /dev/null
\! redis-cli -n 15 hset  bcol_hash f1 v1 > /dev/null
\! redis-cli -n 15 zadd  bcol_zset 1 m1  > /dev/null

create foreign table db15_bcol_list(key text, value bytea)
       server localredis
       options (database '15', tabletype 'list', tablekeyprefix 'bcol_list');

select * from db15_bcol_list;

-- the check must sit after the EXPLAIN early return: planning must not error
explain (costs off) select * from db15_bcol_list;

create foreign table db15_bcol_set(key text, value bytea)
       server localredis
       options (database '15', tabletype 'set', tablekeyprefix 'bcol_set');

select * from db15_bcol_set;

create foreign table db15_bcol_hash(key text, value bytea)
       server localredis
       options (database '15', tabletype 'hash', tablekeyprefix 'bcol_hash');

select * from db15_bcol_hash;

create foreign table db15_bcol_zset(key text, value bytea)
       server localredis
       options (database '15', tabletype 'zset', tablekeyprefix 'bcol_zset');

select * from db15_bcol_zset;

-- bytea[] on the same table is the correct shape and must keep working
create foreign table db15_bcol_list_arr(key text, value bytea[])
       server localredis
       options (database '15', tabletype 'list', tablekeyprefix 'bcol_list');

select key, value from db15_bcol_list_arr;

-- a singleton collection with a scalar bytea column is the feature's main
-- use case and must keep working
create foreign table db15_bcol_sing_set(member bytea)
       server localredis
       options (database '15', tabletype 'set', singleton_key 'bcol_set');

select member from db15_bcol_sing_set order by member;

create foreign table db15_bcol_sing_list(member bytea)
       server localredis
       options (database '15', tabletype 'list', singleton_key 'bcol_list');

select member from db15_bcol_sing_list;

-- a scalar table with a bytea value column must keep working
\! redis-cli -n 15 set bcol_scalar_k hello > /dev/null

create foreign table db15_bcol_scalar(key text, value bytea)
       server localredis
       options (database '15', tablekeyprefix 'bcol_scalar');

select key, value from db15_bcol_scalar;

drop foreign table db15_bcol_list;
drop foreign table db15_bcol_set;
drop foreign table db15_bcol_hash;
drop foreign table db15_bcol_zset;
drop foreign table db15_bcol_list_arr;
drop foreign table db15_bcol_sing_set;
drop foreign table db15_bcol_sing_list;
drop foreign table db15_bcol_scalar;

\i test/common/epilogue.sql

