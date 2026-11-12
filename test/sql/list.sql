-- List tables: reads, singleton and non-singleton forms, tablekeyprefix and
-- tablekeyset, and bytea values. Unlike sets, list order is determinate and is
-- asserted directly.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

\! redis-cli < test/redis_setup

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


-- singleton list

create foreign table db15_1key_list(value text)
       server localredis
       options (tabletype 'list', singleton_key 'list1', database '15');

select * from db15_1key_list order by value;



\! redis-cli < test/redis_teardown

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

-- the FDW cannot delete from a SINGLETON list table (see below), so this key
-- has to go from outside. The non-singleton list tables further down clean up
-- through the FDW, since deleting a whole key is supported.
\! redis-cli -n 15 del w_1key_list > /dev/null


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

\! redis-cli -n 15 del bytea_list > /dev/null

-- a bytea key column on a non-singleton table is rejected for DELETE too,
-- not just INSERT/UPDATE

create foreign table db15_bytea_key_ns(key bytea, val text)
       server localredis
       options (database '15');

delete from db15_bytea_key_ns where key = E'anything'::bytea; -- bytea key error

drop foreign table db15_bytea_key_ns;

-- A list row is written with one variadic RPUSH rather than one RPUSH per
-- element. RPUSH appends, so the elements must come back in the order they
-- were given, including a repeat -- which a list keeps and a set would not.
-- This is the assertion a reordering inside the variadic argument vector
-- would fail and nothing else in this suite would catch.

create foreign table db15_ins_list(key text, val text[])
       server localredis
       options (database '15', tabletype 'list', tablekeyprefix 'insl_');

insert into db15_ins_list values ('insl_1', '{c,a,b,a}');

select key, val from db15_ins_list where key = 'insl_1';

-- a key that is already there is refused, and the list it holds is untouched
insert into db15_ins_list values ('insl_1', '{d}');

select key, val from db15_ins_list where key = 'insl_1';

delete from db15_ins_list;

select * from db15_ins_list;

drop foreign table db15_ins_list;


\i test/common/epilogue.sql

