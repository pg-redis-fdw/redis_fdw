Redis Foreign Data Wrapper for PostgreSQL
==========================================

This is a foreign data wrapper (FDW) to connect [PostgreSQL](https://www.postgresql.org/)
to [Redis](http://redis.io/) key/value databases. This FDW works with PostgreSQL 10+
and confirmed with some Redis versions near 6.0.

<img src="Postgres.svg" align="center" height="100" alt="PostgreSQL"/>	+	<img src="Redis.png" align="center" height="100" alt="Redis"/>

This code was originally experimental, and largely intended as a pet project
for [Dave](#license-and-authors) to experiment with and learn about FDWs in PostgreSQL.
It has now been extended for production use by [Andrew](#license-and-authors).

![image](experimental.png)

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

No deb or rpm packages are avalillable.

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

- **password** as *string*, no default

  The password to authenticate to the Redis server with.

## CREATE FOREIGN TABLE options

`redis_fdw` accepts the following table-level options via the
`CREATE FOREIGN TABLE` command:

- **database** as *integer*, optional, default `0`

  The numeric ID of the Redis database to query.

- **tabletype** as *string*, optional, no default

  Can be `hash`, `list`, `set` or `zset`. If not provided only look at scalar values.

- **tablekeyprefix** as *string*, optional, no default

  Only get items whose names start with the prefix.

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

Singleton key tables are returned as rows with a single column of text
in the case of lists sets and scalars, rows with key and value text columns
for hashes, and rows with a value text columns and an optional numeric score
column for zsets.

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

Limitations
-----------

### SQL commands
- `COPY` command for foreign tables is not supported.
- `TRUNCATE` is not supported.
- `RETURNING` is not supported.

### Other
- Redis has acquired cursors in 2.8+. This is used in all the
  mainline branches from REL9_2_STABLE on, for operations which would otherwise
  either scan the entire Redis database in a single sweep, or scan a single,
  possible large, keyset in a single sweep.

- There is no [MVCC](https://en.wikipedia.org/wiki/Multiversion_concurrency_control),
  which leaves us with no way to atomically query the database for the available
  keys and then fetch each value. So, we get a list of keys to begin with,
  and then fetch whatever records still exist as we build the tuples.

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
* Dave Page dpage@pgadmin.org
* Andrew Dunstan andrew@dunslane.net
