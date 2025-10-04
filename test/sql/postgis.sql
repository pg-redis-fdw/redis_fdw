-- Testcase 001
CREATE EXTENSION postgis;
-- Testcase 002
CREATE EXTENSION hstore;
-- Testcase 003
CREATE EXTENSION redis_fdw;

-- Testcase 004
create server localredis foreign data wrapper redis_fdw;
-- Testcase 005
create user mapping for public server localredis;

-- Testcase 006
-- \! redis-cli < test/redis_gis_ini


-- Testcase 098
-- all done, so now blow everything in the db away again
\! redis-cli < test/redis_clean

-- Testcase 099
DROP EXTENSION redis_fdw CASCADE;
-- Testcase 100
DROP EXTENSION hstore CASCADE;
-- Testcase 101
DROP EXTENSION postgis CASCADE;
