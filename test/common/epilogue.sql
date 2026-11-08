-- Shared epilogue for every redis_fdw test module: assert that the module left
-- db 15 empty, so the next module starts from nothing and any module can run on
-- its own.
--
-- This asserts rather than flushes. A flush would make the assertion true by
-- destroying the evidence a failing module left behind. Every key printed below
-- is a line that is not in the expected file, so the module that leaked is the
-- first to fail and names the key, instead of the cause being buried in a
-- refusal from whatever runs next. KEYS, like the prologue's DBSIZE, sees keys
-- of every type. LC_ALL so a leak of several keys reads the same on every
-- machine; the passing output is empty either way. See test/README.md.

\! redis-cli -n 15 keys '*' | LC_ALL=C sort

set client_min_messages = warning;
drop server localredis cascade;
reset client_min_messages;
