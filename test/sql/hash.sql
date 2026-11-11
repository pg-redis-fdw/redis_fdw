-- Hash tables: reads, singleton and non-singleton forms, tablekeyprefix and
-- tablekeyset, preservation of values containing embedded NULs, and bytea
-- values. Contains the suite's only uses of hstore.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

\! redis-cli < test/redis_setup

-- hash

create foreign table db15_hash_prefix(key text, value text)
       server localredis
       options (tabletype 'hash', tablekeyprefix 'hash', database '15');

create foreign table db15_hash_prefix_array(key text, value text[])
       server localredis
       options (tabletype 'hash', tablekeyprefix 'hash', database '15');

create foreign table db15_hash_keyset_array(key text, value text[])
       server localredis
       options (tabletype 'hash', tablekeyset 'hkeys', database '15');

select * from db15_hash_prefix order by key;
select * from db15_hash_prefix where key = 'hash1';

select * from db15_hash_prefix_array order by key;
select * from db15_hash_prefix_array where key = 'hash1';

select * from db15_hash_keyset_array order by key;
select * from db15_hash_keyset_array where key = 'hash1';

-- a couple of nifty things we an do with hash tables

select key, hstore(value) from db15_hash_prefix_array order by key;

create type atab as (k1 text, k2 text, k3 text);

select key, (populate_record(null::atab, hstore(value))).*
from db15_hash_prefix_array
order by key;


-- singleton hash

create foreign table db15_1key_hash(key text, value text)
       server localredis
       options (tabletype 'hash', singleton_key 'hash1', database '15');

select * from db15_1key_hash order by key;



\! redis-cli < test/redis_teardown

-- singleton hash

create foreign table db15_w_1key_hash(key text, val text)
       server localredis
       options (singleton_key 'w_1key_hash', tabletype 'hash', database '15');

select * from db15_w_1key_hash;

insert into db15_w_1key_hash values ('a','b'), ('c','d'),('e','f');

select * from db15_w_1key_hash order by key;

insert into db15_w_1key_hash values ('a','b');

delete from db15_w_1key_hash where key = 'a';

delete from db15_w_1key_hash where key = 'a';

select * from db15_w_1key_hash order by key;

update db15_w_1key_hash set key = 'x', val = 'y' where key = 'c';

select * from db15_w_1key_hash order by key;

update db15_w_1key_hash set val = 'z' where key = 'e';

select * from db15_w_1key_hash order by key;

update db15_w_1key_hash set key = 'w' where key = 'e';

select * from db15_w_1key_hash order by key;

-- a key-only UPDATE re-stores the existing value using its full Redis length,
-- so a value containing an embedded NUL must survive byte-for-byte (copying it
-- with pstrdup would truncate at the NUL while the length stayed full, reading
-- past the buffer and corrupting the value).  Seed a binary value plus a
-- pristine copy directly in Redis, rename the field via the FDW, then compare
-- server-side.
\! printf 'ab\000cdefghij' | redis-cli -n 15 -x hset w_1key_hash binkey
\! printf 'ab\000cdefghij' | redis-cli -n 15 -x hset w_1key_hash binkey_orig
update db15_w_1key_hash set key = 'binkey2' where key = 'binkey';
\! redis-cli -n 15 eval "return (redis.call('HGET',KEYS[1],ARGV[1]) == redis.call('HGET',KEYS[1],ARGV[2])) and 'value preserved' or 'value CORRUPTED'" 1 w_1key_hash binkey2 binkey_orig

-- emptying a singleton hash removes the Redis key with its last field
delete from db15_w_1key_hash;

select * from db15_w_1key_hash;

-- a rescan must start the scan over, so a singleton hash answers with its own
-- rows on every pass. redisReScanForeignScan() used to reset the row counter
-- and nothing else: a pushed-down field lookup had already marked its single
-- row consumed, so the second and later passes of the first correlated
-- subquery below -- which rescans the foreign scan once per outer row --
-- returned NULL. Issue #71. The cursor-scan and pushed-down-key forms of the
-- same bug live in joins_and_cursors.sql.
--
-- The full scan of the same table is the control: it walks the whole HGETALL
-- reply by row number, so it was already correct before the fix and must stay
-- correct. If it ever fails, suspect this test before the code.
\! redis-cli -n 15 hset rsc_h f1 a f2 b

create foreign table db15_rsc_hs(key text, value text)
       server localredis
       options (tabletype 'hash', singleton_key 'rsc_h', database '15');

select g, (select value from db15_rsc_hs where key = 'f1' and g > 0) from generate_series(1, 3) g;

select g, (select count(*) from db15_rsc_hs where g > 0) from generate_series(1, 3) g;

-- emptying it removes the Redis key, as above
delete from db15_rsc_hs;

drop foreign table db15_rsc_hs;


-- non-singleton hash table prefix

create foreign table db15_w_hash_pfx(key text, val text[])
       server localredis
       options (database '15', tabletype 'hash', tablekeyprefix 'w_hash_');

select * from db15_w_hash_pfx;

insert into db15_w_hash_pfx values ('w_hash_e','{f,g,h}'); -- error

insert into db15_w_hash_pfx values ('w_hash_e','{}'); -- error

insert into db15_w_hash_pfx values ('w_hash_a','{b,c,d,e}'), ('w_hash_c','{f,g,h,i}'),('w_hash_e','{j,k}');

insert into db15_w_hash_pfx values ('x','{y,z}'); -- prefix error

insert into db15_w_hash_pfx values ('w_hash_a','{y,z}'); -- dup error

select * from db15_w_hash_pfx order by key;

delete from db15_w_hash_pfx where key = 'w_hash_a';

select * from db15_w_hash_pfx order by key;

update db15_w_hash_pfx set key = 'x' where key = 'w_hash_c'; -- prefix err
update db15_w_hash_pfx set key = 'x', val = '{y,z}' where key = 'w_hash_c'; -- prefix err

update db15_w_hash_pfx set key = 'w_hash_x', val = '{x,y,z}' where key = 'w_hash_c'; -- err

update db15_w_hash_pfx set key = 'w_hash_x', val = '{w,x,y,z}' where key = 'w_hash_c';

select key, val from db15_w_hash_pfx order by key;

update db15_w_hash_pfx set key = 'w_hash_z' where key = 'w_hash_x';

select key, val from db15_w_hash_pfx order by key;

update db15_w_hash_pfx set val = '{q,r,s}' where key = 'w_hash_e';

select key, val from db15_w_hash_pfx order by key;

delete from db15_w_hash_pfx;

select * from db15_w_hash_pfx;

--non-singleton hash table keyset

create foreign table db15_w_hash_kset(key text, val text[])
       server localredis
       options (database '15', tabletype 'hash', tablekeyset 'w_hash_kset');

select * from db15_w_hash_kset;

insert into db15_w_hash_pfx values ('e_whk','{f,g,h}'); -- error

insert into db15_w_hash_pfx values ('e_whk','{}'); -- error

insert into db15_w_hash_kset values ('a_whk','{b,c,d,e}'), ('c_whk','{f,g,h,i}'),('e_whk','{j,k}');

insert into db15_w_hash_kset values ('a_whk','{x,y}'); -- dup error

select * from db15_w_hash_kset order by key;

delete from db15_w_hash_kset where key = 'a_whk';

select * from db15_w_hash_kset order by key;

update db15_w_hash_kset set key = 'x_whk', val = '{w,x,y,z}' where key = 'c_whk';

select key, val from db15_w_hash_kset order by key;

update db15_w_hash_kset set key = 'z_whk' where key = 'x_whk';

select key, val from db15_w_hash_kset order by key;

update db15_w_hash_kset set val = '{q,r}' where key = 'e_whk';

select key, val from db15_w_hash_kset order by key;

delete from db15_w_hash_kset;

select * from db15_w_hash_kset;

-- singleton hash table with bytea value column (key must be text)
create foreign table db15_bytea_hash(key text, val bytea)
       server localredis
       options (singleton_key 'bytea_hash', tabletype 'hash', database '15');

select * from db15_bytea_hash;

insert into db15_bytea_hash values
    ('field1', E'hash\\000val1'::bytea),
    ('field2', E'hash\\000val2'::bytea);

select key, length(val), val from db15_bytea_hash order by key;

update db15_bytea_hash set val = E'new\\000hash\\000val'::bytea where key = 'field1';

select key, length(val), val from db15_bytea_hash order by key;

delete from db15_bytea_hash where key = 'field2';

select key, length(val), val from db15_bytea_hash order by key;

delete from db15_bytea_hash;

select * from db15_bytea_hash;

-- test that bytea key column in hash is rejected
create foreign table db15_bytea_hash_bad(key bytea, val text)
       server localredis
       options (singleton_key 'bytea_hash_bad', tabletype 'hash', database '15');

insert into db15_bytea_hash_bad values (E'key'::bytea, 'val');


\i test/common/epilogue.sql

