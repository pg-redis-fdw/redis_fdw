
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

\! redis-cli < test/redis_clean

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

\! redis-cli < test/redis_clean

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
\! redis-cli < test/redis_clean

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

delete from db15_ssc;

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

-- Every test above is expected to leave db 15 as it found it. Listing the
-- keyspace here asserts that, and names anything left behind: a leak becomes a
-- failure attributed to the commit that caused it, with the offending keys
-- recorded in regression.diffs, instead of a "db 15 not empty" failure in
-- whatever runs next, pointing at innocent code. bsc_z leaked exactly that way
-- and went unnoticed until it had wedged every branch of a buildfarm animal.
--
-- Deliberately non-destructive: the database is left as the failing run left
-- it, so it can be inspected. Like the guard at the top of this file, this
-- reports rather than flushes.

\! redis-cli -n 15 keys '*' | sort
