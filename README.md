Redis FDW for PostgreSQL 9.1+
==============================

This PostgreSQL extension implements a Foreign Data Wrapper (FDW) for
the Redis key/value database: http://redis.io/

This code was originally experimental, and largely intended as a pet project
for Dave to experiment with and learn about FDWs in PostgreSQL. It has now been
extended for production use by Andrew.

By all means use it, but do so entirely at your own risk! You have been
warned!

Building
--------

To build the code, you need the hiredis C interface to Redis installed
on your system. You can checkout the hiredis from
https://github.com/redis/hiredis
or it might be available for your OS as it is for Fedora, for example.

Once that's done, the extension can be built with:

    PATH=/usr/local/pgsql91/bin/:$PATH make USE_PGXS=1
    sudo PATH=/usr/local/pgsql91/bin/:$PATH make USE_PGXS=1 install

(assuming you have PostgreSQL 9.1 in /usr/local/pgsql91).

Make necessary changes for 9.2 and later.

You will need to have the right branch checked out to match the PostgreSQL
release you are building against, as the FDW API has changed from release
to release.

Dave has tested the original on Mac OS X 10.6 only, and Andrew on Fedora and
Suse. Other *nix's should also work.
Neither of us have tested on Windows, but the code should be good on MinGW.

Limitations
-----------

- There's no such thing as a cursor in Redis in the SQL sense,
  nor MVCC, which leaves us
  with no way to atomically query the database for the available keys
  and then fetch each value. So, we get a list of keys to begin with,
  and then fetch whatever records still exist as we build the tuples.

- We can only push down a single qual to Redis, which must use the
  TEXTEQ operator, and must be on the 'key' column.

- There is no support for non-scalar datatypes in Redis
  such as lists, for PostgreSQL 9.1. There is such support for later releases.

- Redis has acquired cursors as of Release 2.8. This is used in all the
  mainline branches from REL9_2_STABLE on, for operations which would otherwise
  either scan the entire Redis database in a single sweep, or scan a single,
  possible large, keyset in a single sweep. Redis Releases prior to 2.8 are
  maintained on the REL9_x_STABLE_pre2.8 branches.

- Redis cursors have some significant limitations. The Redis docs say:

    A given element may be returned multiple times. It is up to the
    application to handle the case of duplicated elements, for example only
    using the returned elements in order to perform operations that are safe
    when re-applied multiple times.

  The FDW makes no attempt to detect this situation. Users should be aware of
  the possibility.

Usage
-----

The following parameters can be set on a Redis foreign server:

address:	The address or hostname of the Redis server.
	 	Default: 127.0.0.1

port:		The port number on which the Redis server is listening.
     		Default: 6379

The following parameters can be set on a Redis foreign table:

database:	The numeric ID of the Redis database to query.
	  	Default: 0

(9.2 and later) tabletype: can be 'hash', 'list', 'set' or 'zset'
	    Default: none, meaning only look at scalar values.

(9.2 and later) tablekeyprefix: only get items whose names start with the prefix
        Default: none

(9.2 and later) tablekeyset: in a Redis database with  many keys, searching even using "tablekeyprefix" might still be expensive. In that case, you can keep a list of specific keys in a separate set and define it using "tablekeyset". This way the global keyspace isn't searched at all. Only the keys in the "tablekeyset" will be mapped in the foreign table.
        Default: none

(9.2 and later) singleton_key: get all the values in the table from a single
named object.
	    Default: none, meaning don't just use a single object.

You can only have one of tablekeyset and tablekeyprefix, and if you use
singleton_key you can't have either.

Structured items are returned as array text, or, if the value column is a
text array as an array of values. In the case of hash objects this array is
an array of key, value, key, value ...

Singleton key tables are returned as rows with a single column of text
in the case of lists sets and scalars, rows with key and value text columns
for hashes, and rows with a value text columns and an optional numeric score
column for zsets.

The following parameter can be set on a user mapping for a Redis
foreign server:

password:	The password to authenticate to the Redis server with.
     Default: <none>

Insert, Update and Delete
-------------------------

PostgreSQL acquired support for modifying foreign tables in release 9.3, and
now the Redis Foreign Data Wrapper supports these too, for 9.3 and later
PostgreSQL releases. There are a few restriction on this:

- only INSERT works for singleton key list tables, due to limitations
  in the Redis API for lists.
- INSERT and UPDATE only work for singleton key ZSET tables if they have the
  priority column
- non-singleton non-scalar tables must have an array type for the second column

Example
-------

	CREATE EXTENSION redis_fdw;

	CREATE SERVER redis_server
		FOREIGN DATA WRAPPER redis_fdw
		OPTIONS (address '127.0.0.1', port '6379');

	CREATE FOREIGN TABLE redis_db0 (key text, val text)
		SERVER redis_server
		OPTIONS (database '0');

	CREATE USER MAPPING FOR PUBLIC
		SERVER redis_server
		OPTIONS (password 'secret');

	CREATE FOREIGN TABLE myredishash (key text, val text[])
		SERVER redis_server
		OPTIONS (database '0', tabletype 'hash', tablekeyprefix 'mytable:');

    INSERT INTO myredishash (key, val)
       VALUES ('mytable:r1,'{prop1,val1,prop2,val2}');

    UPDATE myredishash
        SET val = '{prop3,val3,prop4,val4}'
        WHERE key = 'mytable:r1';

    DELETE from myredishash
        WHERE key = 'mytable:r1';

	CREATE FOREIGN TABLE myredis_s_hash (key text, val text)
		SERVER redis_server
		OPTIONS (database '0', tabletype 'hash',  singleton_key 'mytable');

    INSERT INTO myredis_s_hash (key, val)
       VALUES ('prop1','val1'),('prop2','val2');

    UPDATE myredis_s_hash
        SET val = 'val23'
        WHERE key = 'prop1';

    DELETE from myredis_s_hash
        WHERE key = 'prop2';

Testing
-------

The tests for 9.2 and later assume that you have access to a redis server
on the localmachine with no password, and uses database 15, which must be empty,
and that the redis-cli program is in the PATH when it is run.
The test script checks that the database is empty before it tries to
populate it, and it cleans up afterwards.


Authors
-------

Dave Page
dpage@pgadmin.org

Andrew Dunstan
andrew@dunslane.net
