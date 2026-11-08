-- The Redis connection itself: cache reuse and invalidation, recovery from a
-- statement abort and from a server-side CLIENT KILL, and username/password
-- and ACL authentication.
--
-- Glob-metacharacter escaping in tablekeyprefix is here rather than with the
-- per-type keyprefix tests because the prefix is embedded in the pattern this
-- connection sends to KEYS/SCAN. The self-join that opens the file is likewise
-- about two scans sharing one cache entry, not about joins.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

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

delete from db15_cachetest;

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

-- seeded from outside, and the metacharacters are part of the key names, so
-- delete them literally rather than through a table whose prefix is a pattern
\! redis-cli -n 15 del 'g*b_star' 'gXb_other' 'gzzb_two' 'q?b_quest' 'qQb_other' 'c[xy]b_class' 'cxb_other' > /dev/null

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

delete from db15_conntest;

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
\! redis-cli -n 15 del acltest_k > /dev/null

\i test/common/epilogue.sql

