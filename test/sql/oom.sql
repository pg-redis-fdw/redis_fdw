-- maxmemory update-atomicity tests. CONFIG SET maxmemory is server-global
-- state the db-15 guard cannot see, which is why this module runs last in
-- REGRESS.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

-- Restore first, in case an earlier aborted run left these set: a module
-- that dies between the CONFIG SET below and its restore would otherwise
-- break every module after it, and REGRESS is a serial list.
\! redis-cli config set maxmemory 0 > /dev/null
\! redis-cli config set maxmemory-policy noeviction > /dev/null

-- An UPDATE that fails part way through must leave the row as it was. Redis
-- at maxmemory with the noeviction policy still accepts DEL and HDEL but
-- refuses the writes that would follow them, so an UPDATE that removed the old
-- contents before building the new ones destroyed the row outright.
--
-- The zset row is the control. That path always staged the new contents under
-- a private key and RENAMEd it in, so it survives whether or not the other
-- four do; a zset failure here means this test is wrong, not the code.
--
-- Each case sets maxmemory for one statement only, and restores it
-- immediately, so the window in which the server refuses writes is as narrow
-- as a psql script can make it.

\! redis-cli -n 15 hset oom_h f1 v1 f2 v2 > /dev/null
\! redis-cli -n 15 sadd ooms_1 a b c > /dev/null
\! redis-cli -n 15 rpush ooml_1 a b c > /dev/null
\! redis-cli -n 15 hset oomh_1 f1 v1 > /dev/null
\! redis-cli -n 15 zadd oomz_1 1 a 2 b > /dev/null

create foreign table db15_oom_hs(key text, value text)
       server localredis
       options (database '15', tabletype 'hash', singleton_key 'oom_h');

create foreign table db15_oom_set(key text, value text[])
       server localredis
       options (database '15', tabletype 'set', tablekeyprefix 'ooms_');

create foreign table db15_oom_list(key text, value text[])
       server localredis
       options (database '15', tabletype 'list', tablekeyprefix 'ooml_');

create foreign table db15_oom_hash(key text, value text[])
       server localredis
       options (database '15', tabletype 'hash', tablekeyprefix 'oomh_');

create foreign table db15_oom_zset(key text, value text[])
       server localredis
       options (database '15', tabletype 'zset', tablekeyprefix 'oomz_');

-- SQLSTATE only: the message text is the server's own OOM wording, which is
-- not ours to pin.
\set VERBOSITY sqlstate

-- renaming a field of a singleton hash: both fields must still be there

\! redis-cli config set maxmemory 1 > /dev/null
update db15_oom_hs set key = 'f1_renamed' where key = 'f1';
\! redis-cli config set maxmemory 0 > /dev/null

select * from db15_oom_hs order by key;

-- set

\! redis-cli config set maxmemory 1 > /dev/null
update db15_oom_set set value = '{x,y}' where key = 'ooms_1';
\! redis-cli config set maxmemory 0 > /dev/null

select key, atsort(value) from db15_oom_set;

-- list

\! redis-cli config set maxmemory 1 > /dev/null
update db15_oom_list set value = '{x,y}' where key = 'ooml_1';
\! redis-cli config set maxmemory 0 > /dev/null

select * from db15_oom_list;

-- hash

\! redis-cli config set maxmemory 1 > /dev/null
update db15_oom_hash set value = '{g1,w1}' where key = 'oomh_1';
\! redis-cli config set maxmemory 0 > /dev/null

select * from db15_oom_hash;

-- zset, the control

\! redis-cli config set maxmemory 1 > /dev/null
update db15_oom_zset set value = '{x,y}' where key = 'oomz_1';
\! redis-cli config set maxmemory 0 > /dev/null

select * from db15_oom_zset;

\set VERBOSITY default

-- restore unconditionally, in the state this module found them
\! redis-cli config set maxmemory 0 > /dev/null
\! redis-cli config set maxmemory-policy noeviction > /dev/null

delete from db15_oom_hs;
delete from db15_oom_set;
delete from db15_oom_list;
delete from db15_oom_hash;
delete from db15_oom_zset;

drop foreign table db15_oom_hs;
drop foreign table db15_oom_set;
drop foreign table db15_oom_list;
drop foreign table db15_oom_hash;
drop foreign table db15_oom_zset;

\i test/common/epilogue.sql
