-- Testcase 001:
CREATE EXTENSION hstore;
-- Testcase 002:
CREATE EXTENSION redis_fdw;

-- Testcase 003:
select redis_fdw_version();
-- Testcase 004:
select redis_fdw_hiredis_version();

-- Testcase 005:
CREATE OR REPLACE FUNCTION atsort( a text[])
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE  STRICT
AS $function$
  select array(select unnest($1) order by 1)
$function$;

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

\! redis-cli < test/redis_setup

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

\! redis-cli < test/redis_clean

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

\! redis-cli < test/redis_clean

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

-- all done, so now blow everything in the db away again

\! redis-cli < test/redis_clean

DROP EXTENSION redis_fdw CASCADE;
DROP EXTENSION hstore;
