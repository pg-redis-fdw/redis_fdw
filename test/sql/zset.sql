-- Sorted-set tables: reads, the scores column read and written, singleton
-- forms with and without scores, tablekeyprefix and tablekeyset, bytea
-- members, numeric[] scores, and infinite scores.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

\! redis-cli < test/redis_setup

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


\! redis-cli < test/redis_teardown

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

-- named, not unqualified: this table has no prefix and no keyset, so an
-- unqualified DELETE would take every zset in db 15
delete from db15_zsnum where key = 'zsnumrenamed';

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

delete from db15_zs3 where key in ('zs3renamed', 'zs3inf');
delete from db15_zs2 where key = 'zs2';
-- zs1 was seeded from outside, but the singleton table can still empty it, and
-- a zset loses its key with its last member
delete from db15_szs;

drop foreign table db15_zs3;
drop foreign table db15_zs2;
drop foreign table db15_szs;

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

\i test/common/epilogue.sql

