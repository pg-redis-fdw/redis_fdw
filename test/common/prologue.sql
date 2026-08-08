-- Shared prologue for every redis_fdw test module.
-- psql -a echoes this file into every expected output.
--
-- Adding a module? See test/README.md. This file cannot guard db 15 on your
-- behalf: it only sets db15_not_empty, and your module must act on it.

-- Refuse by default, and only clear the flag once we have positively counted an
-- empty keyspace. Everything below can fail -- redis-cli missing, redis down --
-- and a \gset that never runs leaves the variable unset, at which point \if
-- skips its entire block, \q included, and the module would run on and flush a
-- database it was meant to protect. Starting from "not empty" makes every such
-- failure refuse instead.
\set db15_not_empty true

-- DBSIZE, rather than counting rows through the foreign tables, for two
-- reasons: it sees keys of every type, including ones this FDW cannot read and
-- would silently skip; and it does not route the safety check through the code
-- under test. \copy runs the program client-side, like the \! calls elsewhere
-- in this suite, so it needs no server-side execution privilege.
create temp table redis_dbsize(n bigint);
\copy redis_dbsize from program 'redis-cli -n 15 dbsize'
select n <> 0 as db15_not_empty from redis_dbsize \gset
drop table redis_dbsize;

create server localredis foreign data wrapper redis_fdw;

create user mapping for public server localredis;

-- the default scalar view of db 15, used by the scalar and joins_and_cursors
-- modules
create foreign table db15(key text, value text)
       server localredis
       options (database '15');

-- set results come back in arbitrary order; atsort() makes them predictable
CREATE OR REPLACE FUNCTION atsort( a text[])
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE  STRICT
AS $function$
  select array(select unnest($1) order by 1)
$function$;
