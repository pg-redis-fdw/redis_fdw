/*-------------------------------------------------------------------------
 *
 *                foreign-data wrapper for Redis
 *
 * Copyright (c) 2011 - 2025, PostgreSQL Global Development Group
 *
 * This software is released under the PostgreSQL Licence
 *
 * Author: Dave Page <dpage@pgadmin.org>
 *
 * IDENTIFICATION
 *                redis_fdw/redis_fdw--2.0.sql
 *
 *-------------------------------------------------------------------------
 */

\echo Use "CREATE EXTENSION redis_fdw" to load this file. \quit

CREATE FUNCTION redis_fdw_handler()
RETURNS fdw_handler
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION redis_fdw_validator(text[], oid)
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FOREIGN DATA WRAPPER redis_fdw
  HANDLER redis_fdw_handler
  VALIDATOR redis_fdw_validator;

CREATE OR REPLACE FUNCTION redis_fdw_version()
RETURNS int
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

COMMENT ON FUNCTION redis_fdw_version()
IS 'Returns Redis FDW code version';

CREATE OR REPLACE FUNCTION redis_fdw_hiredis_version()
RETURNS int
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

COMMENT ON FUNCTION redis_fdw_hiredis_version()
IS 'Returns hiredis library code version';