##########################################################################
#
#                foreign-data wrapper for Redis
#
# Copyright (c) 2011 - 2025, PostgreSQL Global Development Group
#
# This software is released under the PostgreSQL Licence
#
# Authors: Dave Page <dpage@pgadmin.org>
#          Andrew Dunstan <andrew@dunslane.net>
#
# IDENTIFICATION
#                 redis_fdw/Makefile
# 
##########################################################################

MODULE_big = redis_fdw
OBJS = redis_fdw.o

EXTENSION = redis_fdw
DATA = redis_fdw--1.0.sql redis_fdw--2.0.sql redis_fdw--1.0--2.0.sql

ifdef ENABLE_GIS
override PG_CFLAGS += -DREDIS_FDW_GIS_ENABLE
GISTEST=postgis
else
GISTEST=nogis
endif

ifndef REGRESS
REGRESS = redis_fdw $(GISTEST)
#encodings # future test modules
endif

REGRESS_OPTS = --encoding=utf8 --inputdir=test --outputdir=test

EXTRA_CLEAN = sql/redis_fdw.sql expected/redis_fdw.out

SHLIB_LINK += -lhiredis

USE_PGXS = 1

ifeq ($(USE_PGXS),1)
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/redis_fdw
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

# we put all the tests in a test subdir, but pgxs expects us not to, darn it
override pg_regress_clean_files = test/results/ test/regression.diffs test/regression.out tmp_check/ log/
