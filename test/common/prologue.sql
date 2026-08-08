-- Shared prologue for every redis_fdw test module.
-- psql -a echoes this file into every expected output, so keep it short.

-- Refuse to run against a database that is not empty, rather than risk
-- destroying real data: ON_ERROR_STOP makes the exception terminate the script
-- before the epilogue's flush can run. DBSIZE counts keys of every type, so
-- this is stricter than counting rows through a handful of foreign tables.
\set ON_ERROR_STOP
create temp table redis_dbsize(n bigint);
copy redis_dbsize from program 'redis-cli -n 15 dbsize';
do $$
  begin
    if (select n from redis_dbsize) <> 0
    then
       raise EXCEPTION 'db 15 not empty';
    end if;
  end;
$$;
drop table redis_dbsize;
\unset ON_ERROR_STOP

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
