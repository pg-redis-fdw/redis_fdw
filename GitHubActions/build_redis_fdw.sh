#!/bin/bash

################################################################################
#
# This script builds redis_fdw in PostgreSQL source tree.
#
# Usage: ./build_redis_fdw.sh pg_version mode hiredis_for_testing_dir
#     pg_version is a PostgreSQL version like 17.0 to be built in.
#     mode is flag for redis_fdw compiler.
#     hiredis_for_testing_dir: path to install directory of hiredis version for testing
#
# Requirements
# - the source code of redis_fdw is available by git clone.
# - the source code of PostgreSQL is located in ~/workdir/postgresql-{pg_version}.
# - Hiredis development package is installed in a system.
################################################################################

VERSION="$1"
MODE="$2"
HIREDIS_FOR_TESTING_DIR="$3"

mkdir -p ./workdir/postgresql-${VERSION}/contrib/redis_fdw
tar zxf ./redis_fdw.tar.gz -C ./workdir/postgresql-${VERSION}/contrib/redis_fdw/
cd ./workdir/postgresql-${VERSION}/contrib/redis_fdw

# show locally compiled hiredis library
ls -la /usr/local/lib

if [ "$MODE" == "postgis" ]; then
  make ENABLE_GIS=1 HIREDIS_FOR_TESTING_DIR="$3"
else
  make HIREDIS_FOR_TESTING_DIR="$3"
fi

sudo make install
