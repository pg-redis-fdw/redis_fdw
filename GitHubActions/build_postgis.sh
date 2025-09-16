#!/bin/bash

################################################################################
#
# This script downloads PostGIS from the official web site into ./workdir
# then builds it.
#
# Usage: ./build_postgis.sh pg_version postgis_version
#     pg_version is a PostgreSQL version to be installed like 16.0.
#     postgis_version is a PostGIS version to be installed.
#
# Requirements
# - be able to connect to the PostGIS official web site by wget.
#
################################################################################

POSTGRESQL_VERSION=$1
POSTGIS_VERSION=$2

# Install necessary dependencies
sudo apt update
sudo apt install -y build-essential libxml2-dev libgeos-dev libproj-dev libgdal-dev libjson-c-dev libprotobuf-c-dev protobuf-c-compiler

cd ./workdir
# Download and compile PostGIS
cp -vr postgis "postgresql-${POSTGRESQL_VERSION}/contrib"
(
cd "postgresql-${POSTGRESQL_VERSION}/contrib/postgis"
echo " - PostGIS directory"
GEOS_CONFIG_PATH=$(which geos-config)
export LD_LIBRARY_PATH="/usr/local/lib/:$LD_LIBRARY_PATH"
./configure --with-pgconfig=/usr/local/pgsql/bin/pg_config --with-geosconfig=$GEOS_CONFIG_PATH
make
sudo make install
)

(
cd "postgresql-${POSTGRESQL_VERSION}/contrib/hstore"
make
sudo make install
)
