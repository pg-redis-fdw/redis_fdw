-- Set tables: reads, singleton and non-singleton forms, tablekeyprefix and
-- tablekeyset, bytea members and bytea[] array columns. Set members come back
-- in arbitrary order, so results are wrapped in atsort().
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

\! redis-cli < test/redis_setup

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


-- singleton set

create foreign table db15_1key_set(value text)
       server localredis
       options (tabletype 'set', singleton_key 'set1', database '15');

select * from db15_1key_set order by value;



\! redis-cli < test/redis_teardown

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

-- emptying a singleton set removes the Redis key with its last member
delete from db15_w_1key_set;

select * from db15_w_1key_set;


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

\i test/common/epilogue.sql

