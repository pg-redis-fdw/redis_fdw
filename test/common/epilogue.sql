-- Shared epilogue for every redis_fdw test module: leave nothing behind, so
-- the next module starts from nothing and any module can run on its own.

\! redis-cli < test/redis_clean

set client_min_messages = warning;
drop server localredis cascade;
reset client_min_messages;
