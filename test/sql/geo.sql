-- Geo tables: both supported column shapes -- (text, float8, float8) for
-- separate latitude and longitude, and (text, text) for an EWKT point -- plus
-- rename semantics, shape validation and dropped-column handling.
\i test/common/prologue.sql

\if :db15_not_empty
\echo 'db 15 is not empty - refusing to run rather than destroy data'
\q
\endif

-- singleton geo table

create foreign table db15_w_1key_geo(value text, lat double precision, long double precision)
       server localredis
       options (singleton_key 'w_1key_geo', tabletype 'geo', database '15');

select * from db15_w_1key_geo;

insert into db15_w_1key_geo (value, lat, long) values
       ('Palermo', 38.115556, 13.361389),
       ('Catania', 37.502669, 15.087269);

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- duplicate member is rejected
insert into db15_w_1key_geo (value, lat, long) values ('Palermo', 0, 0);

-- update just one coordinate - the other must be preserved
update db15_w_1key_geo set lat = 40 where value = 'Palermo';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- update both coordinates at once
update db15_w_1key_geo set lat = 41, long = 14 where value = 'Catania';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- rename a member; its position must carry over
update db15_w_1key_geo set value = 'Palermo2' where value = 'Palermo';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- rename a member and change a coordinate in the same update
update db15_w_1key_geo set value = 'Catania2', lat = 42 where value = 'Catania';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- a rename whose coordinates Redis rejects must leave the old member alone
-- rather than deleting it on the way to a failed add
update db15_w_1key_geo set value = 'Catania3', lat = 99 where value = 'Catania2';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

delete from db15_w_1key_geo where value = 'Palermo2';

select value, round(lat::numeric, 4) as lat, round(long::numeric, 4) as long
from db15_w_1key_geo order by value;

-- NULL coordinates are rejected, not silently stored as 0 (and not a crash)
insert into db15_w_1key_geo (value, lat, long) values ('NullLat', NULL, 5);
insert into db15_w_1key_geo (value, lat, long) values ('NullLong', 5, NULL);

delete from db15_w_1key_geo;

-- geo tables require singleton_key
create foreign table db15_geo_no_singleton(key text, lat double precision, long double precision)
       server localredis
       options (tabletype 'geo', database '15');

select * from db15_geo_no_singleton;

drop foreign table db15_geo_no_singleton;

-- singleton geo table, EWKT shape (PostGIS-friendly variant of geo, chosen
-- by the declared column shape rather than a separate tabletype)

create foreign table db15_w_1key_geo_ewkt(value text, point text)
       server localredis
       options (singleton_key 'w_1key_geo_ewkt', tabletype 'geo', database '15');

select * from db15_w_1key_geo_ewkt;

insert into db15_w_1key_geo_ewkt (value, point) values
       ('Palermo', 'SRID=4326;POINT(13.361389 38.115556)'),
       ('Catania', 'SRID=4326;POINT(15.087269 37.502669)');

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo_ewkt order by value;

-- duplicate member is rejected
insert into db15_w_1key_geo_ewkt (value, point) values ('Palermo', 'SRID=4326;POINT(0 0)');

-- a plain WKT point with no SRID prefix is accepted (SRID 4326 is implied)
insert into db15_w_1key_geo_ewkt (value, point) values ('Messina', 'POINT(15.556349 38.193299)');

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo_ewkt order by value;

-- a point with a non-4326 SRID is rejected
insert into db15_w_1key_geo_ewkt (value, point) values ('Rome', 'SRID=3857;POINT(1391469 5146449)');

-- malformed point text is rejected
insert into db15_w_1key_geo_ewkt (value, point) values ('Bad', 'not a point');

-- a NULL point is rejected (regression: previously a NULL-pointer crash)
insert into db15_w_1key_geo_ewkt (value, point) values ('Null', NULL);

delete from db15_w_1key_geo_ewkt where value = 'Messina';

-- update the whole point at once (partial-coordinate update, as with plain
-- geo, isn't meaningful here since there's only one point column)
update db15_w_1key_geo_ewkt set point = 'SRID=4326;POINT(14 41)' where value = 'Catania';

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo_ewkt order by value;

-- rename a member; its position must carry over
update db15_w_1key_geo_ewkt set value = 'Palermo2' where value = 'Palermo';

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo_ewkt order by value;

-- rename a member and change its point in the same update
update db15_w_1key_geo_ewkt set value = 'Catania2', point = 'SRID=4326;POINT(14.5 41.5)' where value = 'Catania';

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo_ewkt order by value;

delete from db15_w_1key_geo_ewkt where value = 'Palermo2';

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_w_1key_geo_ewkt order by value;

delete from db15_w_1key_geo_ewkt;

-- geo tables (either shape) require singleton_key
create foreign table db15_geo_ewkt_no_singleton(key text, point text)
       server localredis
       options (tabletype 'geo', database '15');

select * from db15_geo_ewkt_no_singleton;

drop foreign table db15_geo_ewkt_no_singleton;

-- geo tables must have one of the two supported column shapes: (text, text)
-- for an EWKT point, or (text, double precision, double precision) for
-- separate lat/long columns
-- the member column must be text as well: the shape error has always
-- advertised (text, ...), and a bytea member would otherwise reach the bytea
-- tuple path, which fills columns from data - never populated by a geo scan

create foreign table db15_geo_bytea_member(value bytea, lat double precision, long double precision)
       server localredis
       options (singleton_key 'w_1key_geo', tabletype 'geo', database '15');

select * from db15_geo_bytea_member;

drop foreign table db15_geo_bytea_member;

create foreign table db15_geo_bad_shape(value text, foo text, bar text)
       server localredis
       options (singleton_key 'w_1key_geo_bad_shape', tabletype 'geo', database '15');

select * from db15_geo_bad_shape;

drop foreign table db15_geo_bad_shape;

-- a column count that is neither geo shape is rejected by the count check,
-- with the count message rather than the shape message
create foreign table db15_geo_too_many_cols(value text, lat double precision,
                                            long double precision, extra text)
       server localredis
       options (singleton_key 'w_1key_geo', tabletype 'geo', database '15');

select * from db15_geo_too_many_cols;

drop foreign table db15_geo_too_many_cols;

-- a trailing dropped column does not change the shape: this is still the
-- two-column EWKT geo table it was declared as, for both read and write
create foreign table db15_geo_dropped_trailing(value text, point text, junk int)
       server localredis
       options (singleton_key 'w_1key_geo_ewkt', tabletype 'geo', database '15');

alter table db15_geo_dropped_trailing drop column junk;

insert into db15_geo_dropped_trailing (value, point) values
       ('Palermo', 'SRID=4326;POINT(13.361389 38.115556)');

select value,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[1]::numeric, 4) as long,
       round((regexp_match(point, 'POINT\(([-0-9.eE]+) ([-0-9.eE]+)\)'))[2]::numeric, 4) as lat
from db15_geo_dropped_trailing order by value;

delete from db15_geo_dropped_trailing;

drop foreign table db15_geo_dropped_trailing;

-- a dropped column among the columns the table type uses is rejected, since
-- the scan fills values[] by position
create foreign table db15_geo_dropped_interleaved(value text, junk int, point text)
       server localredis
       options (singleton_key 'w_1key_geo_ewkt', tabletype 'geo', database '15');

alter table db15_geo_dropped_interleaved drop column junk;

select * from db15_geo_dropped_interleaved;

drop foreign table db15_geo_dropped_interleaved;


\i test/common/epilogue.sql

