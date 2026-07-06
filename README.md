Redis Foreign Data Wrapper for PostgreSQL
==========================================

This is a foreign data wrapper (FDW) to connect [PostgreSQL](https://www.postgresql.org/)
to [Redis](http://redis.io/) key/value databases. This FDW works with PostgreSQL 10+
and confirmed with some Redis versions near 6.0.

<img src="img/Postgres.svg" align="center" height="100" alt="PostgreSQL"/>	+	<img src="img/Redis.png" align="center" height="100" alt="Redis"/>

This code was originally experimental, and largely intended as a pet project
for [Dave](#license-and-authors) to experiment with and learn about FDWs in PostgreSQL.
It has now been extended for production use by [Andrew](#license-and-authors).

![image](img/experimental.png)

**By all means use it, but do so entirely at your own risk!** You have been
warned!

Contents
--------

1. [Features](#features)
2. [Supported platforms](#supported-platforms)
3. [Installation](#installation)
4. [Usage](#usage)
5. [Functions](#functions)
6. [Identifier case handling](#identifier-case-handling)
7. [Generated columns](#generated-columns)
8. [Character set handling](#character-set-handling)
9. [Examples](#examples)
10. [Limitations](#limitations)
11. [Tests](#tests)
12. [Contributing](#contributing)
13. [Useful links](#useful-links)
14. [License and authors](#license-and-authors)

Features
--------

### Common features
- `SELECT`
- `INSERT`, `UPDATE`, `DELETE`. There are a few restrictions for the operations:
  - only `INSERT` works for singleton key list tables, due to limitations
  in the Redis API for lists.
  - `INSERT` and `UPDATE` only work for singleton key `ZSET` tables if they have the
  priority column
  - non-singleton non-scalar tables must have an array type for the second column
  - `GEO` tables are only supported with `singleton_key`

### Binary data (bytea) support

`redis_fdw` supports `bytea` columns for storing binary data, including data with embedded NUL bytes. Binary data is handled using Redis's binary-safe commands. The following table types and columns support `bytea`:

| Table Type | Column | bytea Supported |
|------------|--------|-----------------|
| Scalar (singleton) | value | Yes |
| Scalar (non-singleton) | value | Yes |
| Hash (singleton) | value | Yes |
| Hash (singleton) | key/field | No |
| Hash (non-singleton) | value array | Yes (`bytea[]`) |
| Set (singleton) | member | Yes |
| Set (non-singleton) | value array | Yes (`bytea[]`) |
| Zset (singleton) | member | Yes |
| Zset (singleton) | score | No (must be numeric) |
| Zset (non-singleton) | value array | Yes (`bytea[]`) |
| List (singleton) | value | Yes |

### Pushdowning

Not supported, there is no common calculations in Redis.

### Notes about features

Also see [Limitations](#limitations)

Supported platforms
-------------------

`redis_fdw` was developed on Linux and Mac OS X and should run on any
reasonably POSIX-compliant system. [Dave](#license-and-authors) has tested the
original on Mac OS X 10.6 only, and [Andrew](#license-and-authors) on Fedora
and Suse. Other *nix's should also work. Neither of us have tested on Windows,
but the code should be good on MinGW.

Installation
------------

### Package installation

No deb or rpm packages are available.

### Source installation

#### Prerequisites:
- A Redis database accessible from PostgreSQL server.
- Local Redis *only* if you need `redis_fdw` testing.
- [Hiredis C interface](https://github.com/redis/hiredis) installed
on your system. You can checkout the `hiredis` from github or it might be available in [rpm or deb packages for your OS](https://pkgs.org/search/?q=hiredis).
- PostgreSQL development package. For Debian or Ubuntu: `apt-get install postgresql-server-dev-XX -y`, where `XX` matches your postgres version, i.e. `apt-get install postgresql-server-dev-15 -y`

#### Build and install on OS

Ensure `pg_config` is callable without full path, build and install `regis_fdw`
with commands below. Use release you need instead of `{REL}`, for ex.
`REL_15_STABLE`, `REL_16_STABLE`.

```sh
git clone https://github.com/pg-redis-fdw/redis_fdw.git -b {REL}

make USE_PGXS=1
sudo make install USE_PGXS=1
```

Make necessary changes for your PostgreSQL version if needed.
You will need to have the right branch checked out to match the PostgreSQL
release you are building against, as the FDW API has changed from release
to release.

Usage
-----

## CREATE SERVER options

`redis_fdw` accepts the following options via the `CREATE SERVER` command:

- **address** as *string*, optional, default `127.0.0.1`

  The address or hostname of the Redis server.

- **port** as *integer*, optional, default `6379`

  The port number on which the Redis server is listening.

## CREATE USER MAPPING options

`redis_fdw` accepts the following options via the `CREATE USER MAPPING`
command:

- **username** as *string*, optional, no default

  The username to authenticate to the Redis server with, for servers using
  Redis ACLs (`AUTH username password`). If omitted, the legacy
  password-only form (`AUTH password`) is used. Requires **password**: a
  username on its own is rejected, since authentication is only attempted
  when a password is present.

- **password** as *string*, no default

  The password to authenticate to the Redis server with.

## CREATE FOREIGN TABLE options

`redis_fdw` accepts the following table-level options via the
`CREATE FOREIGN TABLE` command:

- **database** as *integer*, optional, default `0`

  The numeric ID of the Redis database to query.

- **tabletype** as *string*, optional, no default

  Can be `hash`, `list`, `set`, `zset` or `geo`. If not provided only look at scalar values.

- **tablekeyprefix** as *string*, optional, no default

  Only get items whose names start with the prefix.
  In a Redis database with  many keys, searching even using `tablekeyprefix` might still be expensive. In that case, you can keep a list of specific keys in a separate set and define it using `tablekeyset`. This way the global keyspace isn't searched at all.

- **tablekeyset** as *string*, optional, no default

  Fetch item names from the named set. In a Redis database with many keys,
searching even using `tablekeyprefix` might still be expensive. In that case,
you can keep a list of specific keys in a separate set and define it using
`tablekeyset`. This way the global keyspace isn't searched at all.
Only the keys in the `tablekeyset` will be mapped in the foreign table.

- **singleton_key** as *string*, optional, no default

  Get all the values in the table from a single named object. If not provided
don't use a single object.

You can only have one of `tablekeyset` and `tablekeyprefix`, and if you use
`singleton_key` you can't have either.

Structured items are returned as `array text`, or, if the value column is a
text array as an array of values. In the case of hash objects this array is
an array of key, value, key, value ...

Non-singleton `zset` tables may optionally declare a third column, an array
type, to hold the score of each member in the value array, in the same order
(i.e. `scores[i]` is the score of `value[i]`). Any element type whose text
output is a valid Redis float works; `numeric[]`, `float8[]` and `text[]` are
all accepted.

The column is writable. `INSERT` and `UPDATE` must supply the members and
scores arrays together, and the two must have the same length:

```sql
	INSERT INTO ztab VALUES ('key', '{a,b,c}', '{10,20,30}');
	UPDATE ztab SET value = '{a,b,d}', scores = '{10,20,40}' WHERE key = 'key';
```

A zset is a Redis object, not an array: reading it back returns members in
score order, not the order they were written in, and a member written more
than once in the same call collapses to a single entry at its last score.
`scores[i]` is the score of `value[i]` only at write time.

Setting only one of the pair is an error. An `UPDATE` replaces the whole
Redis key rather than merging into it, so the arrays supplied are the
complete new contents; a partial update would have to invent the missing
half, and inventing it from the values read earlier can silently revert a
score another client changed in the meantime.

`Infinity` and `-Infinity` are accepted as scores. `NaN` is not: PostgreSQL
allows it in `numeric` and `float8`, but Redis rejects it, so the error comes
from the server. The whole write is rejected before anything changes, so a
row's previous members and scores are left exactly as they were.

Singleton key tables are returned as rows with a single column of text
in the case of lists sets and scalars, rows with key and value text columns
for hashes, and rows with a value text columns and an optional numeric score
column for zsets.

### Geo tables

`tabletype 'geo'` exposes a Redis [geospatial index](https://redis.io/docs/latest/develop/data-types/geospatial/)
(a zset under the hood, with each member's score encoding its coordinates)
as a table of `(member, lat, long)` rows. Only the singleton-key form is
supported:

```sql
CREATE FOREIGN TABLE mygeo (value text, lat double precision, long double precision)
    SERVER redis_server
    OPTIONS (database '0', tabletype 'geo', singleton_key 'mygeo');

INSERT INTO mygeo (value, lat, long) VALUES ('Palermo', 38.115556, 13.361389);

SELECT * FROM mygeo;
```

`UPDATE` supports changing the member name, either coordinate, or both at
once; updating only one coordinate looks up the other via `GEOPOS` so it's
preserved. Note that Redis's internal geohash encoding is not perfectly
exact (sub-meter precision loss), so a coordinate read back may differ
very slightly from what was inserted.

Non-singleton geo tables are not currently supported.

#### Using geo tables with PostGIS

`redis_fdw` itself has no PostGIS dependency — geo tables always expose
plain `double precision` columns. If PostGIS is installed,
a `geometry(Point, 4326)` view can be layered on top with an
`INSTEAD OF` trigger, giving full read/write access via
`ST_Distance`/`ST_DWithin`/etc. without redis_fdw needing to know
PostGIS exists:

```sql
CREATE VIEW mygeo_postgis AS
  SELECT value, ST_SetSRID(ST_MakePoint(long, lat), 4326) AS geom
  FROM mygeo;

CREATE FUNCTION mygeo_postgis_write() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM mygeo WHERE value = OLD.value;
    RETURN OLD;
  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE mygeo SET value = NEW.value, lat = ST_Y(NEW.geom), long = ST_X(NEW.geom)
      WHERE value = OLD.value;
    RETURN NEW;
  ELSE -- INSERT
    INSERT INTO mygeo (value, lat, long) VALUES (NEW.value, ST_Y(NEW.geom), ST_X(NEW.geom));
    RETURN NEW;
  END IF;
END;
$$;

CREATE TRIGGER mygeo_postgis_write
  INSTEAD OF INSERT OR UPDATE OR DELETE ON mygeo_postgis
  FOR EACH ROW EXECUTE FUNCTION mygeo_postgis_write();
```

```sql
INSERT INTO mygeo_postgis (value, geom) VALUES ('Rome', ST_SetSRID(ST_MakePoint(12.4964, 41.9028), 4326));

-- distance in metres between two members, using a geography cast
SELECT a.value, b.value,
       ST_Distance(a.geom::geography, b.geom::geography) AS metres
FROM mygeo_postgis a, mygeo_postgis b
WHERE a.value = 'Rome' AND b.value = 'Palermo';

UPDATE mygeo_postgis SET geom = ST_SetSRID(ST_MakePoint(12.5, 42.0), 4326) WHERE value = 'Rome';

DELETE FROM mygeo_postgis WHERE value = 'Rome';
```

`4326` is WGS84 (plain latitude/longitude, the same coordinate system
`GEOADD`/`GEOPOS` use), so no reprojection is needed going in either
direction.

## IMPORT FOREIGN SCHEMA options

`redis_fdw` **doesn't support** [IMPORT FOREIGN SCHEMA](https://www.postgresql.org/docs/current/sql-importforeignschema.html) and accepts no custom options for this command.
There is no formal storing schema in Redis in oppose to RDBMS.

## TRUNCATE support

`redis_fdw` doesn't implements the foreign data wrapper `TRUNCATE` API, available
from PostgreSQL 14.

Functions
---------

As well as the standard `redis_fdw_handler()` and `redis_fdw_validator()`
functions, `redis_fdw` provides no user-callable utility functions.

Identifier case handling
------------------------

PostgreSQL folds identifiers to lower case by default, Redis is case sensetive by default.
It's important to be aware of potential issues with table and column names.
If there will no proper name quoting in PostgreSQL, access from PostgreSQL foreign tables
with mixedcase or uppercase names to mixedcase or uppercase Redis objects can cause
unexpected results.

Generated columns
-----------------

Redis doesn't provide support for generated columns.

For more details on generated columns see:

- [Generated Columns](https://www.postgresql.org/docs/current/ddl-generated-columns.html)
- [CREATE FOREIGN TABLE](https://www.postgresql.org/docs/current/sql-createforeigntable.html)

Character set handling
----------------------

All strings from Redis are interpreted acording to the PostgreSQL database's server encoding.
Redis supports UTF-8 only data. It's not a problem if the PostgreSQL server encoding is UTF-8.
Behaviour with non-UTF8 PostgreSQL servers is undefined and untested.
It is not recommended to use `redis_fdw` with non UTF-8 PostgreSQL databases.

Examples
--------

### Install the extension:

Once for a database you need, as PostgreSQL superuser.

```sql
	CREATE EXTENSION redis_fdw;
```

### Create a foreign server with appropriate configuration:

Once for a foreign datasource you need, as PostgreSQL superuser.

```sql
	CREATE SERVER redis_server
	FOREIGN DATA WRAPPER redis_fdw
	OPTIONS (
	  address '127.0.0.1',
	  port '6379'
	);
```

### Grant usage on foreign server to normal user in PostgreSQL:

Once for a normal user (non-superuser) in PostgreSQL, as PostgreSQL superuser. It is a good idea to use a superuser only where really necessary, so let's allow a normal user to use the foreign server (this is not required for the example to work, but it's secirity recomedation).

```sql
	GRANT USAGE ON FOREIGN SERVER redis_server TO pguser;
```
Where `pguser` is a sample user for works with foreign server (and foreign tables).

### User mapping

```sql
	CREATE USER MAPPING FOR pguser
	SERVER redis_server
	OPTIONS (
	  password 'secret'
	);
```

If the Redis server uses ACLs, a `username` option can be supplied alongside
`password` to authenticate as a specific ACL user instead of the default
user:

```sql
	CREATE USER MAPPING FOR pguser
	SERVER redis_server
	OPTIONS (
	  username 'redisuser',
	  password 'secret'
	);
```
Where `pguser` is a sample user for works with foreign server (and foreign tables).

### Create foreign table
All `CREATE FOREIGN TABLE` SQL commands can be executed as a normal PostgreSQL user if there were correct `GRANT USAGE ON FOREIGN SERVER`. No need PostgreSQL supersuer for secirity reasons but also works with PostgreSQL supersuer.

#### Simple table

```sql
	CREATE FOREIGN TABLE redis_db0 (
	  key text,
	  val text
	)
	SERVER redis_server
	OPTIONS (
	  database '0'
	);
```

#### Hash table + `tablekeyprefix`

```sql
	CREATE FOREIGN TABLE myredishash (
	  key text,
	  val text[]
	)
	SERVER redis_server
	OPTIONS (
	  database '0',
	  tabletype 'hash',
	  tablekeyprefix 'mytable:'
	);

    INSERT INTO myredishash (key, val)
    VALUES ('mytable:r1','{prop1,val1,prop2,val2}');

    UPDATE myredishash
       SET val = '{prop3,val3,prop4,val4}'
     WHERE key = 'mytable:r1';

    DELETE from myredishash
     WHERE key = 'mytable:r1';
```
#### Hash table + `singleton_key`
```sql
	CREATE FOREIGN TABLE myredis_s_hash (
	  key text,
	  val text
	)
	SERVER redis_server
	OPTIONS (
	  database '0',
	  tabletype 'hash',
	  singleton_key 'mytable'
	);

    INSERT INTO myredis_s_hash (key, val)
    VALUES ('prop1','val1'),('prop2','val2');

    UPDATE myredis_s_hash
       SET val = 'val23'
     WHERE key = 'prop1';

    DELETE from myredis_s_hash
     WHERE key = 'prop2';
```

#### Binary data (bytea) examples

Store binary data with embedded NUL bytes in a scalar table:
```sql
	CREATE FOREIGN TABLE binary_data (
	  key text,
	  val bytea
	)
	SERVER redis_server
	OPTIONS (
	  database '0',
	  tablekeyprefix 'bin_'
	);

    -- Insert binary data with embedded NUL byte
    INSERT INTO binary_data (key, val)
    VALUES ('bin_image', E'\\x89504e470d0a1a0a'::bytea);

    SELECT key, length(val), val FROM binary_data;
```

Store binary members in a singleton set:
```sql
	CREATE FOREIGN TABLE binary_set (
	  member bytea
	)
	SERVER redis_server
	OPTIONS (
	  database '0',
	  tabletype 'set',
	  singleton_key 'binary_members'
	);

    INSERT INTO binary_set VALUES
        (E'data\\000with\\000nulls'::bytea);

    SELECT length(member), member FROM binary_set;
```

Store binary data in a hash value column:
```sql
	CREATE FOREIGN TABLE binary_hash (
	  field text,
	  data bytea
	)
	SERVER redis_server
	OPTIONS (
	  database '0',
	  tabletype 'hash',
	  singleton_key 'binary_hash_key'
	);

    INSERT INTO binary_hash VALUES
        ('file1', E'\\x00\\x01\\x02\\x03'::bytea);
```

Limitations
-----------

### SQL commands
- `COPY` command for foreign tables is not supported.
- `TRUNCATE` is not supported.
- `RETURNING` is not supported.

### Binary data (bytea)
- `bytea` is not supported for hash field/key columns (only hash value columns).
- A non-singleton collection table (hash, list, set, zset) must declare its
  value column as an array type; a scalar `bytea` value column is rejected.

### Other
- Redis has acquired cursors in 2.8+. This is used in all the
  mainline branches from REL9_2_STABLE on, for operations which would otherwise
  either scan the entire Redis database in a single sweep, or scan a single,
  possible large, keyset in a single sweep.

- There is no [MVCC](https://en.wikipedia.org/wiki/Multiversion_concurrency_control),
  which leaves us with no way to atomically query the database for the available
  keys and then fetch each value. So, we get a list of keys to begin with,
  and then fetch whatever records still exist as we build the tuples.

- Nothing written to Redis is transactional. A statement that fails partway
  through may already have applied some of its writes, and neither the failed
  statement nor a surrounding `ROLLBACK` undoes them. If a statement against a
  Redis foreign table errors, treat the affected keys as being in an unknown
  state and repair them explicitly.

- We can only push down a single qual to Redis, which must use the
  `TEXTEQ` operator, and must be on the `key` column.

- Redis cursors have some significant limitations. The Redis docs say:

    *A given element may be returned multiple times. It is up to the
    application to handle the case of duplicated elements, for example only
    using the returned elements in order to perform operations that are safe
    when re-applied multiple times*.

  The FDW makes no attempt to detect this situation. Users should be aware of
  the possibility.

- There was no such thing as a cursor in Redis 2.8- in the SQL sense. Redis
  releases prior to 2.8 are maintained on the REL9_x_STABLE_pre2.8 branches.

Tests
-----

The tests for PostgreSQL assume that you have access to a Redis server
on the local machine with no password, and uses PostgreSQL 15 server with
*english* locale. This database must be empty, and that the `redis-cli` program
is in the `PATH` envireonment variable when tests is run.
The [test](test) script checks that the database is empty before it tries to
populate it, and it cleans up afterwards.

Some tests as `psql` expected outputs can be found in [test/expected](test/expected) directory.

Contributing
------------

Opening issues and pull requests on GitHub are welcome.

Useful links
------------

### Redis selected documentation

- https://redis.io/commands/
- https://redis.io/docs/
- https://redis.io/docs/data-types/
- https://github.com/redis/hiredis/blob/master/README.md

### Source code

- https://github.com/redis/hiredis - hiredis C client library
- https://github.com/redis/redis - redis DB
- https://bitbucket.org/adunstan/redis_wrapper/src/master/ - PostgreSQL extension (not FDW) for Redis (also written by Andrew Dunstan)
- https://github.com/jeffreydwalter/redis_cluster_fdw - Other FDW for Redis

 Reference FDW implementation, `postgres_fdw`
 - https://git.postgresql.org/gitweb/?p=postgresql.git;a=tree;f=contrib/postgres_fdw;hb=HEAD

### General FDW Documentation

 - https://www.postgresql.org/docs/current/ddl-foreign-data.html
 - https://www.postgresql.org/docs/current/sql-createforeigndatawrapper.html
 - https://www.postgresql.org/docs/current/sql-createforeigntable.html
 - https://www.postgresql.org/docs/current/sql-importforeignschema.html
 - https://www.postgresql.org/docs/current/fdwhandler.html
 - https://www.postgresql.org/docs/current/postgres-fdw.html

### Other FDWs

 - https://wiki.postgresql.org/wiki/Fdw
 - https://pgxn.org/tag/fdw/

License and authors
-------
© 2011-2025 The redis-fdw Development Team

* Dave Page dpage@pgadmin.org
* Andrew Dunstan andrew@dunslane.net

Redis FDW is licensed under PostgreSQL license, see the [`License`](License) file for full details.
Provided license based on https://opensource.org/license/postgresql
