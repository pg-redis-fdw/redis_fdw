-- Shared prologue for every redis_fdw test module.
-- psql -a echoes this file into every expected output.
--
-- Adding a module? See test/README.md. This file cannot guard db 15 on your
-- behalf: it only sets db15_not_empty, and your module must act on it.

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

-- Decide whether db 15 is empty, but leave acting on it to the module: psql's
-- \q and ON_ERROR_STOP both terminate only the script they appear in, so a
-- guard placed in this include would abort the include and let the module run
-- on -- seeding and flushing a database it was supposed to protect.

select
    (select count(*) from db15) +
    (select count(*) from db15_hash) +
    (select count(*) from db15_set) +
    (select count(*) from db15_list) +
    (select count(*) from db15_zset) <> 0 as db15_not_empty
\gset
