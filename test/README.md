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
act on it for you. **psql's `\q` and `ON_ERROR_STOP` both terminate only the script they
appear in.** A guard placed inside the include would abort the include and hand
control straight back to your module, which would then run on and — if it seeds
the fixture — flush a database that was never ours to flush.

That is not hypothetical. An earlier version of this suite had the guard inside
the prologue. Running a module against a database holding one unrelated key
destroyed it, and the failure looked like protection because some modules
happened to die at their own first deliberate error before reaching the flush.

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

\! redis-cli < test/redis_clean

-- ... tests that build their own keys from an empty database ...
```

Modules that seed everything they need inline — `geo`, `validation`,
`connection`, `joins_and_cursors` — omit both calls.

## Clean up after yourself

Delete the Redis keys your tests create, using `delete from <foreign table>`
before you drop the table. `epilogue.sql` also flushes db 15, so a module that
forgets will still pass — do not rely on that. The flush runs whether the module
succeeded or failed, so a module that leans on it destroys the very state you
would need to diagnose its own failure. Write yours to leave db 15 empty on its
own.

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
