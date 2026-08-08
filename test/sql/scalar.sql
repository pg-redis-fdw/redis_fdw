\i test/common/prologue.sql

\! redis-cli < test/redis_setup

select * from db15 order by key;

select * from db15 where key = 'foo';


-- singleton scalar

create foreign table db15_1key(value text)
       server localredis
       options (singleton_key 'foo', database '15');

select * from db15_1key;


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


\i test/common/epilogue.sql

