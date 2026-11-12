-- Scalar (Redis string) tables: reads, singleton and non-singleton
-- forms, tablekeyprefix and tablekeyset, a name-typed key column, and bytea
-- values.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

\! redis-cli < test/redis_setup

select * from db15 order by key;

select * from db15 where key = 'foo';


-- singleton scalar

create foreign table db15_1key(value text)
       server localredis
       options (singleton_key 'foo', database '15');

select * from db15_1key;


\! redis-cli < test/redis_teardown

-- singleton scalar table

create foreign table db15_w_1key_scalar(val text)
       server localredis
       options (singleton_key 'w_1key_scalar', database '15');

select * from db15_w_1key_scalar;

insert into db15_w_1key_scalar values ('only row');

select * from db15_w_1key_scalar;

insert into db15_w_1key_scalar values ('only row');

delete from db15_w_1key_scalar where val = 'not only row';

select * from db15_w_1key_scalar;

update db15_w_1key_scalar set val = 'new scalar val';

select * from db15_w_1key_scalar;

delete from db15_w_1key_scalar;

select * from db15_w_1key_scalar;

-- a rescan must start the scan over, so the singleton's one row comes back on
-- every pass. redisReScanForeignScan() used to reset the row counter and
-- nothing else, leaving the row it had already marked consumed consumed, so
-- the second and later passes of the correlated subquery below -- which
-- rescans the foreign scan once per outer row -- returned NULL. Issue #71.
-- The cursor-scan and pushed-down-key forms of the same bug live in
-- joins_and_cursors.sql, with the rest of this suite's rescan coverage.
\! redis-cli -n 15 set rsc_scalar v1

create foreign table db15_rsc_single(value text)
       server localredis
       options (singleton_key 'rsc_scalar', database '15');

select g, (select value from db15_rsc_single where g > 0) from generate_series(1, 3) g;

delete from db15_rsc_single;

drop foreign table db15_rsc_single;


-- non-singleton scalar table no prefix no keyset

create foreign table db15_w_scalar(key text, val text)
       server localredis
       options (database '15');

select * from db15_w_scalar;

insert into db15_w_scalar values ('a_ws','b'), ('c_ws','d'),('e_ws','f');

select * from db15_w_scalar order by key;

delete from db15_w_scalar where key = 'a_ws';

select * from db15_w_scalar order by key;

update db15_w_scalar set key = 'x_ws', val='y' where key = 'e_ws';

select * from db15_w_scalar order by key;

update db15_w_scalar set key = 'z_ws' where key = 'c_ws';

select * from db15_w_scalar order by key;

update db15_w_scalar set val = 'z' where key = 'z_ws';

select * from db15_w_scalar order by key;

/*
-- don't delete the whole namespace
 delete from db15_w_scalar;

select * from db15_w_scalar;
*/

-- so name the keys instead: this table has no prefix and no keyset, and an
-- unqualified DELETE through it would take the whole of db 15 with it
delete from db15_w_scalar where key in ('x_ws', 'z_ws');

select * from db15_w_scalar;

-- non-singleton scalar table keyprefix

create foreign table db15_w_scalar_pfx(key text, val text)
       server localredis
       options (database '15', tablekeyprefix 'w_scalar_');

select * from db15_w_scalar_pfx;

insert into db15_w_scalar_pfx values ('w_scalar_a','b'), ('w_scalar_c','d'),('w_scalar_e','f');

insert into db15_w_scalar_pfx values ('x','y'); -- prefix error

-- a key that is a genuine (but shorter) prefix of the table's configured
-- key prefix must still be rejected as a mismatch
insert into db15_w_scalar_pfx values ('w','y'); -- prefix error, key shorter than prefix

insert into db15_w_scalar_pfx values ('w_scalar_a','x'); -- dup error

select * from db15_w_scalar_pfx order by key;

delete from db15_w_scalar_pfx where key = 'w_scalar_a';

select * from db15_w_scalar_pfx order by key;

update db15_w_scalar_pfx set key = 'x', val = 'y' where key = 'w_scalar_c'; -- prefix err
update db15_w_scalar_pfx set key = 'x'  where key = 'w_scalar_c'; -- prefix err

update db15_w_scalar_pfx set key = 'w_scalar_x', val = 'y' where key = 'w_scalar_c';

select * from db15_w_scalar_pfx order by key;

update db15_w_scalar_pfx set key = 'w_scalar_z' where key = 'w_scalar_x';

select * from db15_w_scalar_pfx order by key;

update db15_w_scalar_pfx set val = 'w' where key = 'w_scalar_e';

select * from db15_w_scalar_pfx order by key;

delete from db15_w_scalar_pfx;

select * from db15_w_scalar_pfx order by key;

-- a scan that meets a key of another type among its strings still skips it.
-- GET against a hash answers WRONGTYPE, which the scan treats as it treats
-- the nil it gets for a key deleted under it: skip the reply and move on.
-- Worth having here now that the values of a whole window of keys are fetched
-- in one pipelined round trip, because the reply that has to be recognised and
-- freed is one of a batch rather than one fetched on its own.
--
-- The harder case -- skipping the last matched key of a SCAN batch, which used
-- to end the scan -- needs many batch boundaries and lives in
-- joins_and_cursors.sql, with that module's large keyspace.
\! redis-cli -n 15 hset scskip_h f v > /dev/null

create foreign table db15_scskip(key text, val text)
       server localredis
       options (database '15', tablekeyprefix 'scskip_');

insert into db15_scskip values ('scskip_1', 'one'), ('scskip_2', 'two');

-- distinct, because this dumps every row of a prefix scan: SCAN promises only
-- that a key is mentioned at least once, and a repeated mention would be a
-- repeated row. See test/README.md.
select distinct key, val from db15_scskip order by key;

delete from db15_scskip;

-- the scan skips the hash, so the DELETE above could not have taken it: it
-- goes the way it was made
\! redis-cli -n 15 del scskip_h > /dev/null

drop foreign table db15_scskip;

-- a name-typed key column round-trips correctly

create foreign table db15_nametest(key name, val text)
       server localredis
       options (database '15', tablekeyprefix 'nametest_');

insert into db15_nametest values ('nametest_a', 'v1'), ('nametest_b', 'v2');

select * from db15_nametest order by key;

delete from db15_nametest;

drop foreign table db15_nametest;

-- non-singleton scalar table keyset

create foreign table db15_w_scalar_kset(key text, val text)
       server localredis
       options (database '15', tablekeyset 'w_scalar_kset');

select * from db15_w_scalar_kset order by key;

insert into db15_w_scalar_kset values ('a_wsks','b'), ('c_wsks','d'),('e_wsks','f');

insert into db15_w_scalar_kset values ('a_wsks','x'); -- dup error

select * from db15_w_scalar_kset order by key;

delete from db15_w_scalar_kset where key = 'a_wsks';

select * from db15_w_scalar_kset order by key;

update db15_w_scalar_kset set key = 'x_wsks', val = 'y' where key = 'c_wsks';

select * from db15_w_scalar_kset order by key;

update db15_w_scalar_kset set key = 'z_wsks' where key = 'x_wsks';

select * from db15_w_scalar_kset order by key;

update db15_w_scalar_kset set val = 'w' where key = 'e_wsks';

select * from db15_w_scalar_kset order by key;

delete from db15_w_scalar_kset;

select * from db15_w_scalar_kset order by key;



-- =====================================================
-- bytea column tests
-- =====================================================

-- Test that bytea columns work correctly for storing binary data
-- including data with embedded NUL bytes

-- singleton scalar table with bytea value
create foreign table db15_bytea_scalar(val bytea)
       server localredis
       options (singleton_key 'bytea_scalar', database '15');

select * from db15_bytea_scalar;

-- insert binary data with embedded NUL bytes
insert into db15_bytea_scalar values (E'hello\\000world'::bytea);

select * from db15_bytea_scalar;
select length(val), val from db15_bytea_scalar;

-- update with different binary data
update db15_bytea_scalar set val = E'binary\\000data\\000here'::bytea;

select length(val), val from db15_bytea_scalar;

delete from db15_bytea_scalar;

select * from db15_bytea_scalar;

-- non-singleton scalar table with bytea value column
create foreign table db15_bytea_scalar_ns(key text, val bytea)
       server localredis
       options (database '15', tablekeyprefix 'bscalar_');

select * from db15_bytea_scalar_ns;

insert into db15_bytea_scalar_ns values
    ('bscalar_a', E'binary\\000a'::bytea),
    ('bscalar_b', E'binary\\000b'::bytea);

select key, length(val), val from db15_bytea_scalar_ns order by key;

update db15_bytea_scalar_ns set val = E'updated\\000val'::bytea where key = 'bscalar_a';

select key, length(val), val from db15_bytea_scalar_ns order by key;

delete from db15_bytea_scalar_ns where key = 'bscalar_a';

select key, length(val), val from db15_bytea_scalar_ns order by key;

delete from db15_bytea_scalar_ns;

select * from db15_bytea_scalar_ns;

-- Bytes that are not valid in the database encoding must not reach a text
-- column. Array elements were always checked, but the scalar key and value
-- became text through CStringGetTextDatum() or BuildTupleFromCStrings(),
-- neither of which checks, so the bytes landed in a text column -- and
-- anything that copied them into a table stored them, leaving a table no
-- pg_dump of it can restore. Issue #66.
--
-- One key, read three ways. Through a prefixed table, where the value fills
-- column 1 of the scan that serves tables of many keys; through a singleton
-- table, where it fills column 0 of the other scan function altogether; and
-- through a bytea column, which is where bytes that are not text belong and
-- which must still hand them back untouched.
--
-- Whether the first two are an error depends on the database encoding, and
-- there is one expected file for every encoding this suite may run under.
-- pg_verifymbstr() rejects these bytes under UTF8 and accepts every byte
-- under SQL_ASCII, which has no invalid ones; both are right. So each read is
-- compared against what its own encoding demands and only the verdict is
-- printed, the same verdict either way. The message cannot be printed: it
-- names UTF8, and a SQL_ASCII run has no message at all. It is asserted
-- inside the procedure instead, where a changed one still fails. The bytea
-- read needs none of this and is asserted directly, in hex, which reads the
-- same under every encoding.

\! printf '\206\244name' | redis-cli -n 15 -x set enc_1 > /dev/null

create foreign table db15_enc(key text, value text)
       server localredis
       options (database '15', tablekeyprefix 'enc_');

create foreign table db15_enc_single(value text)
       server localredis
       options (database '15', singleton_key 'enc_1');

create foreign table db15_enc_bytea(key text, value bytea)
       server localredis
       options (database '15', tablekeyprefix 'enc_');

-- Only character_not_in_repertoire is caught: any other error is this
-- procedure failing to test what it claims, and is better seen than
-- swallowed.
create procedure enc_case(q text) language plpgsql as $$
declare
  must_reject boolean := current_setting('server_encoding') = 'UTF8';
  msg         text := null;
begin
  begin
    execute q;
  exception when character_not_in_repertoire then
    msg := sqlerrm;
  end;

  if (msg is not null) <> must_reject then
    raise notice 'FAILED: % under server_encoding %',
      case when msg is null then 'accepted' else 'rejected' end,
      current_setting('server_encoding');
  elsif must_reject and
        msg <> 'invalid byte sequence for encoding "UTF8": 0x86' then
    raise notice 'FAILED: rejected with an unexpected message: %', msg;
  else
    raise notice 'as the database encoding requires';
  end if;
end $$;

-- key = <value>, so neither read enumerates the keyspace
call enc_case($q$select value from db15_enc where key = 'enc_1'$q$);

call enc_case($q$select value from db15_enc_single$q$);

select key, encode(value, 'hex') from db15_enc_bytea where key = 'enc_1';

drop procedure enc_case(text);

drop foreign table db15_enc;
drop foreign table db15_enc_single;
drop foreign table db15_enc_bytea;

-- seeded with redis-cli because of the bytes it holds, and only ever read, so
-- it goes the way it was made
\! redis-cli -n 15 del enc_1 > /dev/null


\i test/common/epilogue.sql

