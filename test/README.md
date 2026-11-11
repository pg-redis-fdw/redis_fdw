# Writing a redis_fdw test module

The suite is one module per subject, in `sql/`, with expected output in
`expected/`. Six modules cover one Redis table type each end to end; three cover
behaviour that is not specific to a table type (`validation`, `connection`,
`joins_and_cursors`). If you are adding tests, put them in the module whose
subject they belong to rather than at the end of whichever file is nearest.

## The skeleton

Every module starts and ends the same way. Copy this:

```sql
-- One or two lines saying what this module covers, and — where the placement
-- is not obvious — why these tests live here rather than somewhere else.

\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

-- ... your tests ...

\i test/common/epilogue.sql
```

Then add the module name to `REGRESS` in the `Makefile`.

## The four guard lines are not boilerplate you can drop

`prologue.sql` asks Redis for `DBSIZE` and sets `db15_not_empty`, but it cannot
act on it for you. **Nothing a file can do to itself will stop the file that
included it.** A guard placed inside the include would abort the include and
hand control straight back to your module, which would then run on and — if it
seeds the fixture — destroy a database that was never ours to touch.

That is not hypothetical. An earlier version of this suite had the guard inside
the prologue. Running a module against a database holding one unrelated key
destroyed it, and the failure looked like protection because some modules
happened to die at their own first deliberate error before reaching the flush.

Both of the obvious escape hatches really do stop at the include boundary, and
it is worth knowing exactly how, because "put the guard in the prologue" is a
natural thing to propose:

| set where | error/`\q` where | psql |
| --- | --- | --- |
| `\q` in the include | — | include stops, **caller continues**, exit 0 |
| `ON_ERROR_STOP` in the include | in the include | include aborts, **caller continues**, exit 0 |
| `ON_ERROR_STOP` in the caller | in the include | **terminates**, exit 3 |

Only the third row stops psql — and it needs the caller to have set
`ON_ERROR_STOP` first, so it is still per-module boilerplate, just one line
instead of four, and it would trade away the fail-closed property described
below for a guard that depends on an error actually being raised. Not worth it.

So the `\if` / `\q` must sit at the top level of *your* module file, where `\q`
really does stop psql. Nothing checks that you remembered it. If you leave it
out, your module will run against whatever it finds and destroy it.

Two details of the prologue exist because the guard has to fail *closed*, and
are worth knowing before you change it:

- `db15_not_empty` is preset to true and only cleared once an empty keyspace has
  been positively counted. If the count cannot run at all, `\gset` sets nothing,
  and `\if` on an unset variable skips its whole block — `\q` included — so the
  module would carry on. Refusing by default turns every such failure into a
  refusal.
- The count comes from `DBSIZE`, not from `count(*)` over the foreign tables.
  Going through the FDW misses key types it cannot read: a stream, for instance,
  answers `WRONGTYPE`, which the scan loop skips, so a database holding one
  would have been reported empty and then flushed.

## If your module needs the shared fixture

`redis_setup` seeds the five fixture keysets that the read tests expect.
Only modules with tests that read that fixture need it:

```sql
\! redis-cli < test/redis_setup

-- ... tests that read the seeded fixture ...

\! redis-cli < test/redis_teardown

-- ... tests that build their own keys from an empty database ...
```

Modules that seed everything they need inline — `geo`, `validation`,
`connection`, `joins_and_cursors` — omit both calls.

`redis_teardown` deletes the fixture by name, and is the mirror image of
`redis_setup`: same key order, one `del` per group, so a key added to one and
not the other shows up as a lopsided diff between two adjacent files. It is not
a flush, and nothing in this suite flushes — see below.

## Clean up after yourself

Delete the Redis keys your tests create. Nothing will do it for you, and
nothing will cover for you if you forget: `epilogue.sql` asserts that db 15 is
empty and prints every key it finds, so a module that leaves one behind fails
with that key named in its diff.

It used to flush instead. That is worth knowing because it is the reason the
assertion is phrased the way it is. A flush at the end of a module runs whether
the module passed or failed, so the Redis state you need in order to diagnose a
failure is destroyed a moment before you go looking for it — and a module that
never cleaned up still passed, so leftovers accumulated silently until the
flush was the only thing keeping the suite green.

The assertion also puts the failure in the right place. A leaked key fails the
module that left it, naming the key in `regression.diffs`. You get the
downstream refusals too — every later module still finds db 15 dirty and
refuses, and because `\q` skips the epilogue's `drop server`, each one also
emits a few `already exists` errors from the prologue. But the *first* failing
module is the one that leaked, and its diff names the key, so the cause is no
longer buried in whatever ran next.

This is not hypothetical either, and it is why leaks matter more here than
untidiness normally would. `bsc_z` leaked exactly that way: invisible against a
throwaway Redis, because the next run starts from nothing, but the buildfarm
runs every branch against one long-lived server. There, anything left behind
trips the next run's guard — and keeps tripping it, because the guard refuses
to flush a database it did not create. It went unnoticed until it had wedged
every branch of a buildfarm animal.

Keys are not the only shared state on such a server, and the rest of it is
outside what db 15's guard and this epilogue can see. `connection.sql` runs
`CLIENT KILL TYPE normal`, which kills every normal client on the whole server
across all 16 databases, and provisions a server-global ACL user `fdwtest`.
Within one run that is safe, because `REGRESS` is a serial list. Two runs of
this suite against the same server at the same time would interfere — one
run's `ACL DELUSER` pulling the user out from under the other, and each
killing the other's connections at arbitrary points. Do not run the suite
concurrently against a shared server.

The flush could not simply be made conditional: pg_regress decides pass or fail
by diffing *after* the script has finished, so the SQL has no way to know its
own outcome.

Prefer `delete from <foreign table>` — it cleans up through the code under
test:

- An unqualified `delete from <table>` is already targeted when the table has a
  `tablekeyprefix` or a `tablekeyset`, since it can only see its own keys.
- A table with neither covers the whole of db 15, so name the keys:
  `delete from <table> where key in (...)`. An unqualified DELETE through one of
  those is a flush wearing a disguise.
- Emptying a collection removes its Redis key with the last member, so
  `delete from <singleton table>` is enough for a singleton.
- **Singleton list tables support neither UPDATE nor DELETE** (a Redis API
  limitation), so a module that creates singleton list keys has to drop them
  with `\! redis-cli -n 15 del ...`. Non-singleton list tables are fine —
  `delete from db15_w_list_pfx;` and `delete from db15_w_list_kset;` both work,
  because those delete whole keys rather than elements within one.
- Keys seeded with `\! redis-cli` and only ever read through a rejection case
  are best deleted the same way they were made.
- **Bulk is the exception.** A DELETE through the FDW costs one Redis round
  trip per key, so cleaning up tens of thousands of them is seconds of runtime
  spent re-testing a path the per-type modules already cover.
  `joins_and_cursors` deletes its 60k keys with a single `redis-cli eval`
  instead, which does the loop server-side in one round trip and takes 33ms
  rather than 5.5s. Reach for that only at that scale.

Keep cleanup to `redis-cli` and the FDW. It is tempting to pipe a key list into
`xargs`, but `xargs -r` is a GNU extension and the suite depends on no such
thing: its entire external surface is `redis-cli`, `printf` and `sort`. `eval`
does the same job in one process wherever `redis-cli` runs at all.

## `eval`: the quoted argument is a Lua script, run by the server

Two places call `redis-cli eval` — the bulk cleanup in `joins_and_cursors.sql`
and the binary-value comparison in `hash.sql`. In both, **that long quoted
string is a Lua program**, and it is worth being explicit about where it runs,
because it looks like a dependency the suite does not actually have:

```
psql \!  ->  /bin/sh  ->  redis-cli eval "<lua script>" <numkeys> [args]
                               |
                               +- sends EVAL over the wire; the script text is
                                  just a string argument
                                        |
                                        +- the server's *embedded* Lua
                                           interpreter runs it
```

Nothing Lua is installed, linked or shipped with this suite, and `redis-cli`
does not interpret the script — it hands it to the server. So the requirement
is a *server capability*, not a package: `EVAL` has existed since Redis 2.6 and
is in every Valkey.

Three consequences that are easy to miss when editing one of these scripts:

- Inside the script, `KEYS` and `ARGV` are Lua tables, 1-based, and every
  element is a string. `redis.call()` returns Redis replies converted to Lua
  values — importantly, **a missing key or field comes back as `false`**, not
  `nil`, which is how `hash.sql`'s comparison can report success when *both*
  fields are absent.
- `joins_and_cursors`' script writes (`DEL`) after a non-deterministic read
  (`KEYS`). That needs effects replication, the default since Redis 5.0 — a
  higher floor than the rest of the suite requires.
- Neither script is cluster-safe: `KEYS` inside a script, and `EVAL ... 0` with
  no declared keys, are rejected on a cluster node. The FDW has no cluster
  support, so nothing here depends on it, but do not copy the idiom somewhere
  that does.

## Generating expected output

Create the expected file **empty** before the first run:

```sh
: > test/expected/mymodule.out
redis-cli -n 15 flushdb
make installcheck
cp test/results/mymodule.out test/expected/mymodule.out
make installcheck          # now green
```

The empty file matters. A *missing* expected file makes pg_regress's internal
`diff` fail and abort the entire run, so later modules never execute and their
results files are stale or absent.

## Before you propose it

```sh
redis-cli -n 15 flushdb && make installcheck                 # whole suite
redis-cli -n 15 flushdb && make installcheck REGRESS=mymodule # on its own
```

Every module must pass standalone. That is what the shared prologue and
epilogue buy, and it is how you know your module does not depend on keys some
earlier module happened to leave behind.

Also check the guard: seed a key, run your module, and confirm the key is still
there afterwards.

```sh
redis-cli -n 15 flushdb
redis-cli -n 15 set canary v
make installcheck REGRESS=mymodule   # must fail
redis-cli -n 15 get canary           # must still print v
redis-cli -n 15 flushdb
```
