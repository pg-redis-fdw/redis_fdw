#!/bin/bash

################################################################################
#
# This script downloads PostGIS from the official web site into ./workdir
# then builds it.
#
# Usage: ./download_postgis.sh postgis_version
#     postgis_version is a PostGIS version to be installed.
#
# Requirements
# - be able to connect to the PostGIS official web site by wget.
#
################################################################################

POSTGIS_VERSION=$1

mkdir -p ./workdir
cd ./workdir
pgisfile="postgis-${POSTGIS_VERSION}.tar.gz"
if [ ! -f "$pgisfile" ]; then
  wget -nv "http://download.osgeo.org/postgis/source/$pgisfile"
  tar -xzf "$pgisfile"
  mv postgis-${POSTGIS_VERSION} postgis -v
  echo "PostGIS source code directory " $(dirname $(readlink -f postgis))
else
  echo "PostGIS downloaded"
fi
