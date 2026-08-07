-- Shared prologue for every redis_fdw test module.
-- psql -a echoes this file into every expected output, so keep it short.

-- Refuse to run against a database that is not empty, rather than risk
-- flushing real data. Expected output is (integer) 0.
\! redis-cli -n 15 dbsize

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
