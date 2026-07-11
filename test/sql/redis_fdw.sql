
CREATE OR REPLACE FUNCTION atsort( a text[])
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE  STRICT
AS $function$
  select array(select unnest($1) order by 1)
$function$

;



create server localredis foreign data wrapper redis_fdw;

create user mapping for public server localredis;

-- tables for all 5 data types (4 structured plus scalar)

create foreign table db15(key text, value text)
       server localredis
       options (database '15');

create foreign table db15_hash(key text, value text)
       server localredis
       options (database '15', tabletype 'hash');

create foreign table db15_set(key text, value text)
       server localredis
       options (database '15', tabletype 'set');

create foreign table db15_list(key text, value text)
       server localredis
       options (database '15', tabletype 'list');

create foreign table db15_zset(key text, value text)
       server localredis
       options (database '15', tabletype 'zset');

-- make sure they are all empty - if any are not stop the script right now

\set ON_ERROR_STOP
do $$
  declare
    rows bigint;
  begin
    select into rows
        (select count(*) from db15) +
        (select count(*) from db15_hash) +
        (select count(*) from db15_set) +
        (select count(*) from db15_list) +
        (select count(*) from db15_zset);
    if rows > 0
    then
       raise EXCEPTION 'db 15 not empty';
    end if;
  end;
$$;
\unset ON_ERROR_STOP


-- ok, empty, so now run the setup script

\! redis-cli < test/sql/redis_setup

select * from db15 order by key;

select * from db15 where key = 'foo';

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

-- set

create foreign table db15_set_prefix(key text, value text)
       server localredis
       options (tabletype 'set', tablekeyprefix 'set', database '15');

create foreign table db15_set_prefix_array(key text, value text[])
       server localredis
       options (tabletype 'set', tablekeyprefix 'set', database '15');

create foreign table db15_set_keyset_array(key text, value text[])
       server localredis
       options (tabletype 'set', tablekeyset 'skeys', database '15');

-- need to use atsort() on set results to get predicable output
-- since redis will give them back in arbitrary order
-- means we can't show the actual value for db15_set_prefix which has it as a
-- single text field

select key, atsort(value::text[]) as value from db15_set_prefix order by key;
select key, atsort(value::text[]) as value from db15_set_prefix where key = 'set1';

select key, atsort(value) as value from db15_set_prefix_array order by key;
select key, atsort(value) as value from db15_set_prefix_array where key = 'set1';

select key, atsort(value) as value from db15_set_keyset_array order by key;
select key, atsort(value) as value from db15_set_keyset_array where key = 'set1';

-- list

create foreign table db15_list_prefix(key text, value text)
       server localredis
       options (tabletype 'list', tablekeyprefix 'list', database '15');

create foreign table db15_list_prefix_array(key text, value text[])
       server localredis
       options (tabletype 'list', tablekeyprefix 'list', database '15');

create foreign table db15_list_keyset_array(key text, value text[])
       server localredis
       options (tabletype 'list', tablekeyset 'lkeys', database '15');

select * from db15_list_prefix order by key;
select * from db15_list_prefix where key = 'list1';

select * from db15_list_prefix_array order by key;
select * from db15_list_prefix_array where key = 'list1';

select * from db15_list_keyset_array order by key;
select * from db15_list_keyset_array where key = 'list1';

-- zset

create foreign table db15_zset_prefix(key text, value text)
       server localredis
       options (tabletype 'zset', tablekeyprefix 'zset', database '15');

create foreign table db15_zset_prefix_array(key text, value text[])
       server localredis
       options (tabletype 'zset', tablekeyprefix 'zset', database '15');

create foreign table db15_zset_keyset_array(key text, value text[])
       server localredis
       options (tabletype 'zset', tablekeyset 'zkeys', database '15');

select * from db15_zset_prefix order by key;
select * from db15_zset_prefix where key = 'zset1';

select * from db15_zset_prefix_array order by key;
select * from db15_zset_prefix_array where key = 'zset1';

select * from db15_zset_keyset_array order by key;
select * from db15_zset_keyset_array where key = 'zset1';

-- zset with a parallel scores array column

create foreign table db15_zset_prefix_array_scores(key text, value text[], scores numeric[])
       server localredis
       options (tabletype 'zset', tablekeyprefix 'zset', database '15');

create foreign table db15_zset_keyset_array_scores(key text, value text[], scores numeric[])
       server localredis
       options (tabletype 'zset', tablekeyset 'zkeys', database '15');

select * from db15_zset_prefix_array_scores order by key;
select * from db15_zset_prefix_array_scores where key = 'zset1';

select * from db15_zset_keyset_array_scores order by key;
select * from db15_zset_keyset_array_scores where key = 'zset1';

-- singleton scalar

create foreign table db15_1key(value text)
       server localredis
       options (singleton_key 'foo', database '15');

select * from db15_1key;

-- singleton hash

create foreign table db15_1key_hash(key text, value text)
       server localredis
       options (tabletype 'hash', singleton_key 'hash1', database '15');

select * from db15_1key_hash order by key;


-- singleton set

create foreign table db15_1key_set(value text)
       server localredis
       options (tabletype 'set', singleton_key 'set1', database '15');

select * from db15_1key_set order by value;


-- singleton list

create foreign table db15_1key_list(value text)
       server localredis
       options (tabletype 'list', singleton_key 'list1', database '15');

select * from db15_1key_list order by value;


-- singleton zset

create foreign table db15_1key_zset(value text)
       server localredis
       options (tabletype 'zset', singleton_key 'zset1', database '15');

select * from db15_1key_zset order by value;


-- singleton zset with scores

create foreign table db15_1key_zset_scores(value text, score numeric)
       server localredis
       options (tabletype 'zset', singleton_key 'zset1', database '15');

select * from db15_1key_zset_scores order by score desc;


-- insert delete update

-- first clean the database again

\! redis-cli < test/sql/redis_clean

-- singleton scalar table

create foreign table db15_w_1key_scalar(val text)
       server localredis
       options (singleton_key 'w_1key_scalar', database '15');

select * from db15_w_1key_scalar;

insert into db15_w_1key_scalar values ('only row');

select * from db15_w_1key_scalar;

insert into db15_w_1key_scalar values ('only row');

delete from db15_w_1key_scalar where val = 'not only row';

select * from db15_w_1key_scalar;

update db15_w_1key_scalar set val = 'new scalar val';

select * from db15_w_1key_scalar;

delete from db15_w_1key_scalar;

select * from db15_w_1key_scalar;

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

-- singleton list

create foreign table db15_w_1key_list(val text)
       server localredis
       options (singleton_key 'w_1key_list', tabletype 'list', database '15');

select * from db15_w_1key_list;

insert into db15_w_1key_list values ('a'), ('c'),('e');

-- for lists the order should (must) be determinate

select * from db15_w_1key_list /* order by val */ ;

delete from db15_w_1key_list where val = 'a';

delete from db15_w_1key_list where val = 'z';

insert into db15_w_1key_list values ('b'), ('d'),('f'),('a'); -- dups allowed here

select * from db15_w_1key_list /* order by val */;

update db15_w_1key_list set val = 'y';

-- singleton set

create foreign table db15_w_1key_set(key text)
       server localredis
       options (singleton_key 'w_1key_set', tabletype 'set', database '15');

select * from db15_w_1key_set;

insert into db15_w_1key_set values ('a'), ('c'),('e');

select * from db15_w_1key_set order by key;

insert into db15_w_1key_set values ('a'); -- error - dup

delete from db15_w_1key_set where key = 'c';

select * from db15_w_1key_set order by key;

update db15_w_1key_set set key = 'x' where key = 'e';

select * from db15_w_1key_set order by key;

-- singleton zset with scores

create foreign table db15_w_1key_zset(key text, priority numeric)
       server localredis
       options (singleton_key 'w_1key_zset', tabletype 'zset', database '15');

select * from db15_w_1key_zset;

insert into db15_w_1key_zset values ('a',1), ('c',5),('e',-5), ('h',10);

select * from db15_w_1key_zset order by priority;

insert into db15_w_1key_zset values ('a',99);

delete from db15_w_1key_zset where key = 'a';

select * from db15_w_1key_zset order by priority;

delete from db15_w_1key_zset where priority = '5';

select * from db15_w_1key_zset order by priority;

update db15_w_1key_zset set key = 'x', priority = 99 where priority = '-5';

select * from db15_w_1key_zset order by priority;

update db15_w_1key_zset set key = 'y' where key = 'h';

select * from db15_w_1key_zset order by priority;

update db15_w_1key_zset set priority = 20 where key = 'y';

select * from db15_w_1key_zset order by priority;

-- singleton zset no scores
-- use set from last step
delete from db15_w_1key_zset;

insert into db15_w_1key_zset values ('e',-5);

create foreign table db15_w_1key_zsetx(key text)
       server localredis
       options (singleton_key 'w_1key_zset', tabletype 'zset', database '15');

select * from db15_w_1key_zsetx;

insert into db15_w_1key_zsetx values ('a'), ('c'),('e'); -- can't insert

update db15_w_1key_zsetx set key = 'z' where key = 'e';

select * from db15_w_1key_zsetx order by key;

delete from db15_w_1key_zsetx where key = 'z';

select * from db15_w_1key_zsetx order by key;

-- singleton geo table

create foreign table db15_w_1key_geo(value text, lat double precision, long double precision)
       server localredis
       options (singleton_key 'w_1key_geo', tabletype 'geo', database '15');

select * from db15_w_1key_geo;

insert into db15_w_1key_geo (value, lat, long) values
       ('Palermo', 38.115556, 13.361389),
       ('Catania', 37.502669, 15.087269);

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- duplicate member is rejected
insert into db15_w_1key_geo (value, lat, long) values ('Palermo', 0, 0);

-- update just one coordinate - the other must be preserved
update db15_w_1key_geo set lat = 40 where value = 'Palermo';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- update both coordinates at once
update db15_w_1key_geo set lat = 41, long = 14 where value = 'Catania';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- rename a member; its position must carry over
update db15_w_1key_geo set value = 'Palermo2' where value = 'Palermo';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- rename a member and change a coordinate in the same update
update db15_w_1key_geo set value = 'Catania2', lat = 42 where value = 'Catania';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

delete from db15_w_1key_geo where value = 'Palermo2';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

delete from db15_w_1key_geo;

-- geo tables require singleton_key
create foreign table db15_geo_no_singleton(key text, lat double precision, long double precision)
       server localredis
       options (tabletype 'geo', database '15');

select * from db15_geo_no_singleton;

drop foreign table db15_geo_no_singleton;

-- singleton geo4326 table (PostGIS-friendly EWKT variant of geo)

create foreign table db15_w_1key_geo4326(value text, point text)
       server localredis
       options (singleton_key 'w_1key_geo4326', tabletype 'geo4326', database '15');

select * from db15_w_1key_geo4326;

insert into db15_w_1key_geo4326 (value, point) values
       ('Palermo', 'SRID=4326;POINT(13.361389 38.115556)'),
       ('Catania', 'SRID=4326;POINT(15.087269 37.502669)');

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo4326 order by value;

-- duplicate member is rejected
insert into db15_w_1key_geo4326 (value, point) values ('Palermo', 'SRID=4326;POINT(0 0)');

-- a plain WKT point with no SRID prefix is accepted (SRID 4326 is implied)
insert into db15_w_1key_geo4326 (value, point) values ('Messina', 'POINT(15.556349 38.193299)');

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo4326 order by value;

-- a point with a non-4326 SRID is rejected
insert into db15_w_1key_geo4326 (value, point) values ('Rome', 'SRID=3857;POINT(1391469 5146449)');

-- malformed point text is rejected
insert into db15_w_1key_geo4326 (value, point) values ('Bad', 'not a point');

delete from db15_w_1key_geo4326 where value = 'Messina';

-- update the whole point at once (partial-coordinate update, as with plain
-- geo, isn't meaningful here since there's only one point column)
update db15_w_1key_geo4326 set point = 'SRID=4326;POINT(14 41)' where value = 'Catania';

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo4326 order by value;

-- rename a member; its position must carry over
update db15_w_1key_geo4326 set value = 'Palermo2' where value = 'Palermo';

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo4326 order by value;

-- rename a member and change its point in the same update
update db15_w_1key_geo4326 set value = 'Catania2', point = 'SRID=4326;POINT(14.5 41.5)' where value = 'Catania';

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo4326 order by value;

delete from db15_w_1key_geo4326 where value = 'Palermo2';

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo4326 order by value;

delete from db15_w_1key_geo4326;

-- geo4326 tables require singleton_key
create foreign table db15_geo4326_no_singleton(key text, point text)
       server localredis
       options (tabletype 'geo4326', database '15');

select * from db15_geo4326_no_singleton;

drop foreign table db15_geo4326_no_singleton;

-- non-singleton scalar table no prefix no keyset

create foreign table db15_w_scalar(key text, val text)
       server localredis
       options (database '15');

select * from db15_w_scalar;

insert into db15_w_scalar values ('a_ws','b'), ('c_ws','d'),('e_ws','f');

select * from db15_w_scalar order by key;

delete from db15_w_scalar where key = 'a_ws';

select * from db15_w_scalar order by key;

update db15_w_scalar set key = 'x_ws', val='y' where key = 'e_ws';

select * from db15_w_scalar order by key;

update db15_w_scalar set key = 'z_ws' where key = 'c_ws';

select * from db15_w_scalar order by key;

update db15_w_scalar set val = 'z' where key = 'z_ws';

select * from db15_w_scalar order by key;

/*
-- don't delete the whole namespace
 delete from db15_w_scalar;

select * from db15_w_scalar;
*/

-- non-singleton scalar table keyprefix

create foreign table db15_w_scalar_pfx(key text, val text)
       server localredis
       options (database '15', tablekeyprefix 'w_scalar_');

select * from db15_w_scalar_pfx;

insert into db15_w_scalar_pfx values ('w_scalar_a','b'), ('w_scalar_c','d'),('w_scalar_e','f');

insert into db15_w_scalar_pfx values ('x','y'); -- prefix error

-- a key that is a genuine (but shorter) prefix of the table's configured
-- key prefix must still be rejected as a mismatch
insert into db15_w_scalar_pfx values ('w','y'); -- prefix error, key shorter than prefix

insert into db15_w_scalar_pfx values ('w_scalar_a','x'); -- dup error

select * from db15_w_scalar_pfx order by key;

delete from db15_w_scalar_pfx where key = 'w_scalar_a';

select * from db15_w_scalar_pfx order by key;

update db15_w_scalar_pfx set key = 'x', val = 'y' where key = 'w_scalar_c'; -- prefix err
update db15_w_scalar_pfx set key = 'x'  where key = 'w_scalar_c'; -- prefix err

update db15_w_scalar_pfx set key = 'w_scalar_x', val = 'y' where key = 'w_scalar_c';

select * from db15_w_scalar_pfx order by key;

update db15_w_scalar_pfx set key = 'w_scalar_z' where key = 'w_scalar_x';

select * from db15_w_scalar_pfx order by key;

update db15_w_scalar_pfx set val = 'w' where key = 'w_scalar_e';

select * from db15_w_scalar_pfx order by key;

delete from db15_w_scalar_pfx;

select * from db15_w_scalar_pfx order by key;

-- a name-typed key column round-trips correctly

create foreign table db15_nametest(key name, val text)
       server localredis
       options (database '15', tablekeyprefix 'nametest_');

insert into db15_nametest values ('nametest_a', 'v1'), ('nametest_b', 'v2');

select * from db15_nametest order by key;

delete from db15_nametest;

drop foreign table db15_nametest;

-- non-singleton scalar table keyset

create foreign table db15_w_scalar_kset(key text, val text)
       server localredis
       options (database '15', tablekeyset 'w_scalar_kset');

select * from db15_w_scalar_kset order by key;

insert into db15_w_scalar_kset values ('a_wsks','b'), ('c_wsks','d'),('e_wsks','f');

insert into db15_w_scalar_kset values ('a_wsks','x'); -- dup error

select * from db15_w_scalar_kset order by key;

delete from db15_w_scalar_kset where key = 'a_wsks';

select * from db15_w_scalar_kset order by key;

update db15_w_scalar_kset set key = 'x_wsks', val = 'y' where key = 'c_wsks';

select * from db15_w_scalar_kset order by key;

update db15_w_scalar_kset set key = 'z_wsks' where key = 'x_wsks';

select * from db15_w_scalar_kset order by key;

update db15_w_scalar_kset set val = 'w' where key = 'e_wsks';

select * from db15_w_scalar_kset order by key;

delete from db15_w_scalar_kset;

select * from db15_w_scalar_kset order by key;


-- non-singleton set table no prefix no keyset

-- non-array case -- fails
create foreign table db15_w_set_nonarr(key text, val text)
       server localredis
       options (database '15', tabletype 'set');

insert into db15_w_set_nonarr values ('nkseta','{b,c,d}'), ('nksetc','{d,e,f}'),('nksete','{f,g,h}');

/*
-- namespace too polluted for this case
create foreign table db15_w_set(key text, val text[])
       server localredis
       options (database '15', tabletype 'set');

select * from db15_w_set;

insert into db15_w_set values ('nkseta','{b,c,d}'), ('nksetc','{d,e,f}'),('nksete','{f,g,h}');

select * from db15_w_set;

delete from db15_w_set where key = 'nkseta';

select * from db15_w_set;

delete from db15_w_set;

select * from db15_w_set;

*/

-- non-singleton set table keyprefix

create foreign table db15_w_set_pfx(key text, val text[])
       server localredis
       options (database '15', tabletype 'set', tablekeyprefix 'w_set_');

select * from db15_w_set_pfx;

insert into db15_w_set_pfx values ('w_set_a','{b,c,d}'), ('w_set_c','{d,e,f}'),('w_set_e','{f,g,h}');

insert into db15_w_set_pfx values ('x','{y}'); -- prefix error

insert into db15_w_set_pfx values ('w_set_a','{x,y,z}'); -- dup error

select key, atsort(val) as val from db15_w_set_pfx order by key;

delete from db15_w_set_pfx where key = 'w_set_a';

select key, atsort(val) as val from db15_w_set_pfx order by key;

update db15_w_set_pfx set key = 'x' where key = 'w_set_c'; -- prefix err
update db15_w_set_pfx set key = 'x', val = '{y}' where key = 'w_set_c'; -- prefix err

update db15_w_set_pfx set key = 'w_set_x', val = '{x,y,z}' where key = 'w_set_c';

select key, atsort(val) as val from db15_w_set_pfx order by key;

update db15_w_set_pfx set key = 'w_set_z' where key = 'w_set_x';

select key, atsort(val) as val from db15_w_set_pfx order by key;

update db15_w_set_pfx set val = '{q,r,s}' where key = 'w_set_e';

select key, atsort(val) as val from db15_w_set_pfx order by key;

delete from db15_w_set_pfx;

select key, atsort(val) as val from db15_w_set_pfx order by key;


-- non-singleton set table keyset

create foreign table db15_w_set_kset(key text, val text[])
       server localredis
       options (database '15', tabletype 'set', tablekeyset 'w_set_kset');

select * from db15_w_set_kset;

insert into db15_w_set_kset values ('a_wsk','{b,c,d}'), ('c_wsk','{d,e,f}'),('e_wsk','{f,g,h}');

insert into db15_w_set_kset values ('a_wsk','{x}'); -- dup error

select key, atsort(val) as val from db15_w_set_kset order by key;

delete from db15_w_set_kset where key = 'a_wsk';

select key, atsort(val) as val from db15_w_set_kset order by key;

update db15_w_set_kset set key = 'x_wsk', val = '{x,y,z}' where key = 'c_wsk';

select key, atsort(val) as val from db15_w_set_kset order by key;

update db15_w_set_kset set key = 'z_wsk' where key = 'x_wsk';

select key, atsort(val) as val from db15_w_set_kset order by key;

update db15_w_set_kset set val = '{q,r,s}' where key = 'e_wsk';

select key, atsort(val) as val from db15_w_set_kset order by key;

delete from db15_w_set_kset;

select * from db15_w_set_kset;


-- non-singleton list table keyprefix

create foreign table db15_w_list_pfx(key text, val text[])
       server localredis
       options (database '15', tabletype 'list', tablekeyprefix 'w_list_');

select * from db15_w_list_pfx;

insert into db15_w_list_pfx values ('w_list_a','{b,c,d}'), ('w_list_c','{d,e,f}'),('w_list_e','{f,g,h}');

insert into db15_w_list_pfx values ('x','{y}'); -- prefix error

insert into db15_w_list_pfx values ('w_list_a','{x,y,z}'); -- dup error

select * from db15_w_list_pfx order by key;

delete from db15_w_list_pfx where key = 'w_list_a';

select * from db15_w_list_pfx order by key;

update db15_w_list_pfx set key = 'x' where key = 'w_list_c'; -- prefix err
update db15_w_list_pfx set key = 'x', val = '{y}' where key = 'w_list_c'; -- prefix err

update db15_w_list_pfx set key = 'w_list_x', val = '{x,y,z}' where key = 'w_list_c';

select key, atsort(val) as val from db15_w_list_pfx order by key;

update db15_w_list_pfx set key = 'w_list_z' where key = 'w_list_x';

select key, atsort(val) as val from db15_w_list_pfx order by key;

update db15_w_list_pfx set val = '{q,r,s}' where key = 'w_list_e';

select key, atsort(val) as val from db15_w_list_pfx order by key;

delete from db15_w_list_pfx;

select * from db15_w_list_pfx;

-- non-singleton list table keyset

create foreign table db15_w_list_kset(key text, val text[])
       server localredis
       options (database '15', tabletype 'list', tablekeyset 'w_list_kset');

select * from db15_w_list_kset;

insert into db15_w_list_kset values ('a_wlk','{b,c,d}'), ('c_wlk','{d,e,f}'),('e_wlk','{f,g,h}');

insert into db15_w_list_kset values ('a_wlk','{x}'); -- dup error

select * from db15_w_list_kset order by key;

delete from db15_w_list_kset where key = 'a_wlk';

select * from db15_w_list_kset order by key;

update db15_w_list_kset set key = 'x_wlk', val = '{x,y,z}' where key = 'c_wlk';

select key, atsort(val) as val from db15_w_list_kset order by key;

update db15_w_list_kset set key = 'z_wlk' where key = 'x_wlk';

select key, atsort(val) as val from db15_w_list_kset order by key;

update db15_w_list_kset set val = '{q,r,s}' where key = 'e_wlk';

select key, atsort(val) as val from db15_w_list_kset order by key;

delete from db15_w_list_kset;

select * from db15_w_list_kset;



-- non-singleton zset table keyprefix

create foreign table db15_w_zset_pfx(key text, val text[])
       server localredis
       options (database '15', tabletype 'zset', tablekeyprefix 'w_zset_');

select * from db15_w_zset_pfx;

insert into db15_w_zset_pfx values ('w_zset_a','{b,c,d}'), ('w_zset_c','{d,e,f}'),('w_zset_e','{f,g,h}');

insert into db15_w_zset_pfx values ('x','{y}'); -- prefix error

insert into db15_w_zset_pfx values ('w_zset_a','{x,y,z}'); -- dup error

select * from db15_w_zset_pfx order by key;

delete from db15_w_zset_pfx where key = 'w_zset_a';

select * from db15_w_zset_pfx order by key;

update db15_w_zset_pfx set key = 'x' where key = 'w_zset_c'; -- prefix err
update db15_w_zset_pfx set key = 'x', val = '{y}' where key = 'w_zset_c'; -- prefix err

update db15_w_zset_pfx set key = 'w_zset_x', val = '{x,y,z}' where key = 'w_zset_c';

select key, atsort(val) as val from db15_w_zset_pfx order by key;

update db15_w_zset_pfx set key = 'w_zset_z' where key = 'w_zset_x';

select key, atsort(val) as val from db15_w_zset_pfx order by key;

update db15_w_zset_pfx set val = '{q,r,s}' where key = 'w_zset_e';

select key, atsort(val) as val from db15_w_zset_pfx order by key;

delete from db15_w_zset_pfx;

select * from db15_w_zset_pfx;

-- a three-column zset table requires the scores column on INSERT, and a
-- tablekeyprefix does not change that

create foreign table db15_w_zset_pfx_scores(key text, val text[], scores numeric[])
       server localredis
       options (database '15', tabletype 'zset', tablekeyprefix 'w_zset_');

insert into db15_w_zset_pfx_scores (key, val, scores) values ('w_zset_a','{b,c,d}','{1,2,3}');

select key, val, scores from db15_w_zset_pfx_scores order by key;

-- the "set both together" error names this table's own columns, not the
-- generic "members"/"scores"
update db15_w_zset_pfx_scores set val = '{b,c,e}' where key = 'w_zset_a';

delete from db15_w_zset_pfx_scores;

drop foreign table db15_w_zset_pfx_scores;

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

-- non-singleton zset table keyset

create foreign table db15_w_zset_kset(key text, val text[])
       server localredis
       options (database '15', tabletype 'zset', tablekeyset 'w_zset_kset');

select * from db15_w_zset_kset;

insert into db15_w_zset_kset values ('a_wzk','{b,c,d}'), ('c_wzk','{d,e,f}'),('e_wzk','{f,g,h}');

insert into db15_w_zset_kset values ('a_wzk','{x}'); -- dup error

select * from db15_w_zset_kset order by key;

delete from db15_w_zset_kset where key = 'a_wzk';

select * from db15_w_zset_kset order by key;

update db15_w_zset_kset set key = 'x_wlk', val = '{x,y,z}' where key = 'c_wzk';

select key, atsort(val) as val from db15_w_zset_kset order by key;

update db15_w_zset_kset set key = 'z_wzk' where key = 'x_wzk';

select key, atsort(val) as val from db15_w_zset_kset order by key;

update db15_w_zset_kset set val = '{q,r,s}' where key = 'e_wzk';

select key, atsort(val) as val from db15_w_zset_kset order by key;

delete from db15_w_zset_kset;

select * from db15_w_zset_kset;

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

-- now clean up for the cursor tests

\! redis-cli < test/sql/redis_clean

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
-- a self-join opens two concurrent ForeignScans sharing the same cache key
-- (same connection options); results must be correct regardless.
-- ALTER SERVER (even a no-op value change) exercises the connection cache's
-- invalidation path; queries against the table must keep working afterwards.

create foreign table db15_cachetest(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'cachetest_');

insert into db15_cachetest values
       ('cachetest_a', '1'), ('cachetest_b', '2'), ('cachetest_c', '3');

select count(*) from db15_cachetest t1 join db15_cachetest t2
       on t1.key <> t2.key;

alter server localredis options (add address '127.0.0.1');

select value from db15_cachetest where key = 'cachetest_a';

drop foreign table db15_cachetest;

-- A tablekeyprefix is a literal prefix, not a glob pattern. It is embedded in
-- the KEYS/SCAN MATCH pattern used to find the table's keys, so any glob
-- metacharacter in it must be escaped or the table returns keys belonging to
-- other prefixes.

\! redis-cli -n 15 set 'g*b_star'  v > /dev/null
\! redis-cli -n 15 set 'gXb_other' v > /dev/null
\! redis-cli -n 15 set 'gzzb_two'  v > /dev/null

create foreign table db15_glob_star(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'g*b');

select key from db15_glob_star order by key;

\! redis-cli -n 15 set 'q?b_quest' v > /dev/null
\! redis-cli -n 15 set 'qQb_other' v > /dev/null

create foreign table db15_glob_quest(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'q?b');

select key from db15_glob_quest order by key;

\! redis-cli -n 15 set 'c[xy]b_class' v > /dev/null
\! redis-cli -n 15 set 'cxb_other'    v > /dev/null

create foreign table db15_glob_class(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'c[xy]b');

select key from db15_glob_class order by key;

-- an ordinary prefix with no metacharacters must be unaffected
create foreign table db15_glob_plain(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'gzz');

select key from db15_glob_plain order by key;

drop foreign table db15_glob_star;
drop foreign table db15_glob_quest;
drop foreign table db15_glob_class;
drop foreign table db15_glob_plain;
-- An aborted statement must not wedge the backend's Redis connection.
-- The abort skips the executor End nodes, so anything the FDW expects those
-- nodes to clean up is never cleaned up; a connection cache that relies on
-- them will hand out a dead socket for the rest of the session.

create foreign table db15_conntest(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'conntest_');

insert into db15_conntest values ('conntest_a', 'notanumber');

-- abort a statement partway through a scan
select value::int from db15_conntest;

-- Kill the backend's cached Redis connection from the server side. CLIENT
-- KILL defaults to SKIPME yes, so redis-cli spares its own connection. Like
-- the rest of this suite, this assumes redis-cli runs on the same host as
-- the PostgreSQL server.
\! redis-cli CLIENT KILL TYPE normal > /dev/null

-- must reconnect rather than reuse the dead socket
select value from db15_conntest;

-- A connection lost mid-transaction is re-established without ending the
-- transaction, and a subtransaction abort needs no special handling.
begin;
select value from db15_conntest;
\! redis-cli CLIENT KILL TYPE normal > /dev/null
savepoint s;
-- the error text comes from hiredis and varies by version, so normalise it
do $$
begin
  perform value from db15_conntest;
  raise notice 'unexpectedly succeeded on a dead socket';
exception when others then
  raise notice 'connection loss detected';
end
$$;
rollback to s;
select value from db15_conntest;
commit;

drop foreign table db15_conntest;

-- A username with no password must be rejected. Authentication is gated on
-- the password being set, so accepting a lone username would silently connect
-- unauthenticated while the operator believed ACL auth was configured.

create server authtest foreign data wrapper redis_fdw;

create user mapping for public server authtest options (username 'u');

-- both together are fine
create user mapping for public server authtest options (username 'u', password 'p');

-- and dropping just the password must be rejected too
alter user mapping for public server authtest options (drop password);

drop user mapping for public server authtest;

-- the legacy password-only form is still accepted
create user mapping for public server authtest options (password 'p');

drop user mapping for public server authtest;

drop server authtest;

-- ACL authentication end to end. The suite's default Redis user is
-- unauthenticated, so the test can provision its own ACL user. "reset" makes
-- the setup idempotent: a plain SETUSER merges into an existing user rather
-- than replacing it, so a run that aborted before cleaning up would otherwise
-- leave a user with two passwords and stale rules.

\! redis-cli ACL SETUSER fdwtest reset on '>secret' '~*' '+@all' > /dev/null
\! redis-cli -n 15 set acltest_k hello > /dev/null

create server aclsrv foreign data wrapper redis_fdw;

create user mapping for public server aclsrv
       options (username 'fdwtest', password 'secret');

create foreign table db15_acl(key text, value text)
       server aclsrv
       options (database '15', tablekeyprefix 'acltest_');

select * from db15_acl order by key;

-- A wrong password must be refused. This is the case that carries the weight:
-- were AUTH skipped altogether, the connection would fall back to the
-- unauthenticated default user and the query would succeed. The message comes
-- from the server and is not a stable contract, so assert only the failure.

create server aclbad foreign data wrapper redis_fdw;

create user mapping for public server aclbad
       options (username 'fdwtest', password 'wrongpw');

create foreign table db15_aclbad(key text, value text)
       server aclbad
       options (database '15', tablekeyprefix 'acltest_');

do $$
begin
  perform * from db15_aclbad;
  raise notice 'unexpectedly connected with a bad password';
exception when others then
  raise notice 'authentication refused as expected';
end
$$;

drop foreign table db15_acl;
drop foreign table db15_aclbad;
drop server aclsrv cascade;
drop server aclbad cascade;

\! redis-cli ACL DELUSER fdwtest > /dev/null
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
-- Writable zset scores. The write path used to ignore the scores column and
-- store the array index as the score, so an INSERT silently discarded the
-- supplied scores and an UPDATE of the scores column wrote the score values
-- as members.

create foreign table db15_zs3(key text, members text[], scores text[])
       server localredis
       options (database '15', tabletype 'zset');

-- INSERT must store the supplied scores, not 0,1,2
insert into db15_zs3 values ('zs3', '{a,b,c}', '{10,20,30}');

select * from db15_zs3 where key = 'zs3';

-- UPDATE setting both arrays rewrites members and scores together
update db15_zs3 set members = '{a,b,d}', scores = '{11,21,41}' where key = 'zs3';

select * from db15_zs3 where key = 'zs3';

-- a rename touches neither array and stays legal
update db15_zs3 set key = 'zs3renamed' where key = 'zs3';

select * from db15_zs3 where key = 'zs3renamed';

-- setting only one of the pair is rejected
update db15_zs3 set members = '{x,y,z}' where key = 'zs3renamed';

update db15_zs3 set scores = '{1,2,3}' where key = 'zs3renamed';

-- and the rejected updates must leave the key untouched, since the update
-- path only replaces the key once the new contents are known to be valid
select * from db15_zs3 where key = 'zs3renamed';

-- mismatched array lengths are rejected, on UPDATE and on INSERT
update db15_zs3 set members = '{a,b}', scores = '{1,2,3}' where key = 'zs3renamed';

select * from db15_zs3 where key = 'zs3renamed';

-- an invalid score is rejected by Redis itself, not by anything client
-- side, so it is caught deep inside the rebuild; it must still leave the
-- key exactly as it was rather than destroying part of the row
update db15_zs3 set members = '{a,b,d}', scores = '{1,abc,3}' where key = 'zs3renamed';

select * from db15_zs3 where key = 'zs3renamed';

-- NaN is likewise rejected by Redis, and likewise must not touch the row
update db15_zs3 set members = '{a,b,d}', scores = '{1,NaN,3}' where key = 'zs3renamed';

select * from db15_zs3 where key = 'zs3renamed';

insert into db15_zs3 values ('zs3bad', '{a,b,c}', '{1,2}');

-- infinite scores round-trip; Redis accepts the spelling PostgreSQL emits
insert into db15_zs3 values ('zs3inf', '{lo,mid,hi}', '{-Infinity,5,Infinity}');

select * from db15_zs3 where key = 'zs3inf';

-- an INSERT that omits the scores column is rejected rather than falling
-- back to positional scores
insert into db15_zs3 (key, members) values ('zs3partial', '{a,b}');

-- a scores column that isn't an array is rejected outright, not
-- reinterpreted as an array datum
create foreign table db15_zsbad(key text, members text[], scores text)
       server localredis
       options (database '15', tabletype 'zset');

insert into db15_zsbad values ('zsbadkey', '{a,b,c}', '{1,2,3}');

drop foreign table db15_zsbad;

-- a numeric[] scores column exercises a non-text output function on
-- UPDATE, not just INSERT; renaming the key in the same statement that
-- sets both arrays shifts scores_pidx from 2 to 3
create foreign table db15_zsnum(key text, members text[], scores numeric[])
       server localredis
       options (database '15', tabletype 'zset');

insert into db15_zsnum values ('zsnum', '{a,b,c}', '{1,2,3}');

update db15_zsnum set key = 'zsnumrenamed', members = '{a,b,d}', scores = '{4,5,6}' where key = 'zsnum';

select * from db15_zsnum where key = 'zsnumrenamed';

drop foreign table db15_zsnum;

-- a two-column non-singleton zset is unaffected: members-only UPDATE is
-- still allowed and scores are still positional
create foreign table db15_zs2(key text, members text[])
       server localredis
       options (database '15', tabletype 'zset');

insert into db15_zs2 values ('zs2', '{p,q,r}');

update db15_zs2 set members = '{p,q,s}' where key = 'zs2';

select * from db15_zs2 where key = 'zs2';

\! redis-cli -n 15 zrange zs2 0 -1 withscores

-- and a singleton zset is unaffected: its score column stays writable on
-- its own
\! redis-cli -n 15 zadd zs1 10 a 20 b > /dev/null

create foreign table db15_szs(value text, score numeric)
       server localredis
       options (database '15', tabletype 'zset', singleton_key 'zs1');

insert into db15_szs values ('c', 99);

update db15_szs set score = 55 where value = 'a';

update db15_szs set value = 'bb' where value = 'b';

select * from db15_szs order by score;

drop foreign table db15_zs3;
drop foreign table db15_zs2;
drop foreign table db15_szs;

-- all done, so now blow everything in the db away again

\! redis-cli < test/sql/redis_clean

-- =====================================================
-- bytea column tests
-- =====================================================

-- Test that bytea columns work correctly for storing binary data
-- including data with embedded NUL bytes

-- singleton scalar table with bytea value
create foreign table db15_bytea_scalar(val bytea)
       server localredis
       options (singleton_key 'bytea_scalar', database '15');

select * from db15_bytea_scalar;

-- insert binary data with embedded NUL bytes
insert into db15_bytea_scalar values (E'hello\\000world'::bytea);

select * from db15_bytea_scalar;
select length(val), val from db15_bytea_scalar;

-- update with different binary data
update db15_bytea_scalar set val = E'binary\\000data\\000here'::bytea;

select length(val), val from db15_bytea_scalar;

delete from db15_bytea_scalar;

select * from db15_bytea_scalar;

-- non-singleton scalar table with bytea value column
create foreign table db15_bytea_scalar_ns(key text, val bytea)
       server localredis
       options (database '15', tablekeyprefix 'bscalar_');

select * from db15_bytea_scalar_ns;

insert into db15_bytea_scalar_ns values
    ('bscalar_a', E'binary\\000a'::bytea),
    ('bscalar_b', E'binary\\000b'::bytea);

select key, length(val), val from db15_bytea_scalar_ns order by key;

update db15_bytea_scalar_ns set val = E'updated\\000val'::bytea where key = 'bscalar_a';

select key, length(val), val from db15_bytea_scalar_ns order by key;

delete from db15_bytea_scalar_ns where key = 'bscalar_a';

select key, length(val), val from db15_bytea_scalar_ns order by key;

delete from db15_bytea_scalar_ns;

select * from db15_bytea_scalar_ns;

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

-- singleton set table with bytea member
create foreign table db15_bytea_set(member bytea)
       server localredis
       options (singleton_key 'bytea_set', tabletype 'set', database '15');

select * from db15_bytea_set;

insert into db15_bytea_set values
    (E'set\\000member1'::bytea),
    (E'set\\000member2'::bytea),
    (E'set\\000member3'::bytea);

select length(member), member from db15_bytea_set order by member;

delete from db15_bytea_set where member = E'set\\000member2'::bytea;

select length(member), member from db15_bytea_set order by member;

-- update member
update db15_bytea_set set member = E'set\\000updated'::bytea where member = E'set\\000member1'::bytea;

select length(member), member from db15_bytea_set order by member;

delete from db15_bytea_set;

select * from db15_bytea_set;

-- singleton zset table with bytea member and scores
create foreign table db15_bytea_zset(member bytea, score numeric)
       server localredis
       options (singleton_key 'bytea_zset', tabletype 'zset', database '15');

select * from db15_bytea_zset;

insert into db15_bytea_zset values
    (E'zset\\000m1'::bytea, 1),
    (E'zset\\000m2'::bytea, 2),
    (E'zset\\000m3'::bytea, 3);

select length(member), member, score from db15_bytea_zset order by score;

delete from db15_bytea_zset where member = E'zset\\000m2'::bytea;

select length(member), member, score from db15_bytea_zset order by score;

update db15_bytea_zset set score = 10 where member = E'zset\\000m1'::bytea;

select length(member), member, score from db15_bytea_zset order by score;

delete from db15_bytea_zset;

select * from db15_bytea_zset;

-- non-singleton set table with bytea[] array column
create foreign table db15_bytea_set_arr(key text, val bytea[])
       server localredis
       options (database '15', tabletype 'set', tablekeyprefix 'bset_');

select * from db15_bytea_set_arr;

insert into db15_bytea_set_arr values
    ('bset_a', array[E'a\\000'::bytea, E'b\\000'::bytea, E'c\\000'::bytea]);

select key, val from db15_bytea_set_arr order by key;

delete from db15_bytea_set_arr;

select * from db15_bytea_set_arr;

-- non-singleton zset table with bytea[] array column
create foreign table db15_bytea_zset_arr(key text, val bytea[])
       server localredis
       options (database '15', tabletype 'zset', tablekeyprefix 'bzset_');

select * from db15_bytea_zset_arr;

insert into db15_bytea_zset_arr values
    ('bzset_a', array[E'x\\000'::bytea, E'y\\000'::bytea, E'z\\000'::bytea]);

select key, val from db15_bytea_zset_arr order by key;

delete from db15_bytea_zset_arr;

select * from db15_bytea_zset_arr;

-- singleton list table with bytea value
-- note: UPDATE and DELETE not supported for list tables (Redis API limitation)
create foreign table db15_bytea_list(val bytea)
       server localredis
       options (singleton_key 'bytea_list', tabletype 'list', database '15');

select * from db15_bytea_list;

insert into db15_bytea_list values
    (E'list\\000item1'::bytea),
    (E'list\\000item2'::bytea),
    (E'list\\000item3'::bytea);

select length(val), val from db15_bytea_list;

-- a bytea key column on a non-singleton table is rejected for DELETE too,
-- not just INSERT/UPDATE

create foreign table db15_bytea_key_ns(key bytea, val text)
       server localredis
       options (database '15');

delete from db15_bytea_key_ns where key = E'anything'::bytea; -- bytea key error

drop foreign table db15_bytea_key_ns;

-- updating a singleton set member to a bytea value that already exists in
-- the set is rejected as a duplicate

create foreign table db15_bytea_set_dup(member bytea)
       server localredis
       options (singleton_key 'bytea_set_dup', tabletype 'set', database '15');

insert into db15_bytea_set_dup values
    (E'dup\\000existing'::bytea), (E'other\\000member'::bytea);

update db15_bytea_set_dup set member = E'dup\\000existing'::bytea
       where member = E'other\\000member'::bytea; -- must fail: key already exists

select length(member), member from db15_bytea_set_dup order by member;

delete from db15_bytea_set_dup;

drop foreign table db15_bytea_set_dup;

-- clean up bytea tests
\! redis-cli < test/sql/redis_clean

-- bytea[] members with a scores column: binary members must survive intact and
-- keep their scores. Neither PR could express this shape on its own.

-- -x reads the member from stdin, which is the only way to get real binary
-- through redis-cli: an escape passed via argv arrives as literal characters.
\! printf 'bin\001a' | redis-cli -n 15 -x zadd bsc_z 1 > /dev/null
\! printf 'bin\002b' | redis-cli -n 15 -x zadd bsc_z 2 > /dev/null

create foreign table db15_bsc(key text, value bytea[], scores numeric[])
       server localredis
       options (database '15', tabletype 'zset', tablekeyprefix 'bsc_');

select key, scores from db15_bsc;

select octet_length(value[1]) as len1, octet_length(value[2]) as len2 from db15_bsc;

drop foreign table db15_bsc;

-- a scores column beside a scalar text members column: legal, because the
-- scores column requires only zset, non-singleton and three columns

create foreign table db15_ssc(key text, value text, scores numeric[])
       server localredis
       options (database '15', tabletype 'zset', tablekeyprefix 'bsc_');

select * from db15_ssc;

drop foreign table db15_ssc;

-- infinite scores round-trip both ways. numeric has accepted inf since PG 14,
-- and Redis accepts PostgreSQL's Infinity rendering back again.

\! redis-cli -n 15 zadd inf_z inf a -inf b 2.5 c > /dev/null

create foreign table db15_inf(key text, value text[], scores numeric[])
       server localredis
       options (database '15', tabletype 'zset', tablekeyprefix 'inf_');

select * from db15_inf;

insert into db15_inf values ('inf_z2', '{x,y}', '{inf,-inf}');

select * from db15_inf order by key;

delete from db15_inf;

drop foreign table db15_inf;
