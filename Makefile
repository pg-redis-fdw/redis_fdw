##########################################################################
#
#                foreign-data wrapper for Redis
#
# Copyright (c) 2011,2013 PostgreSQL Global Development Group
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
DATA = redis_fdw--1.0.sql # here can be additional future file # redis_fdw--1.0--1.1.sql

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

UNAME = uname
OS := $(shell $(UNAME))
ifeq ($(OS), Darwin)
DLSUFFIX = .dylib
else
DLSUFFIX = .so
endif

SHLIB_LINK := -lhiredis

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
ifndef MAJORVERSION
MAJORVERSION := $(basename $(VERSION))
endif
ifeq (,$(findstring $(MAJORVERSION), 10 11 12 13 14 15 16 17 18))
$(error PostgreSQL 10 11 12 13, 14, 15, 16, 17 or 18 is required to compile this extension)
endif
else
subdir = contrib/redis_fdw
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

ifdef REGRESS_PREFIX
REGRESS_PREFIX_SUB = $(REGRESS_PREFIX)
else
REGRESS_PREFIX_SUB = $(VERSION)
endif

REGRESS := $(addprefix $(REGRESS_PREFIX_SUB)/,$(REGRESS))
$(shell mkdir -p test)
$(shell mkdir -p test/results)
$(shell mkdir -p test/results/$(REGRESS_PREFIX_SUB))

EXTRA_INSTALL+=contrib/hstore

ifdef ENABLE_GIS
check: temp-install
temp-install: EXTRA_INSTALL+=contrib/postgis
checkprep: EXTRA_INSTALL+=contrib/postgis
endif

# we put all the tests in a test subdir, but pgxs expects us not to, darn it
override pg_regress_clean_files = test/results/ test/regression.diffs test/regression.out tmp_check/ log/
