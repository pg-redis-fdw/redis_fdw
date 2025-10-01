#!/bin/bash

################################################################################
#
# This sript installs Redis environment for Redis FDW testing
#
# Usage: ./install_redis.sh version year testing_mode hiredis_for_testing_dir [configure_options]
#     testing_mode:	'default' or 'postgis' value.
#     hiredis_for_testing_dir: path to install directory of the specified hiredis version
#
#     Ex) ./install_redis.sh postgis /opt/redis_testing
#
# Requirements
# - be able to connect to official repository of Ununtu
# - having superuser privileges
#
################################################################################

TESTING_MODE="$1"
HIREDIS_FOR_TESTING_DIR="$2"

# libhiredis*** is a dependency of hiredis-dev
sudo apt-get install redis libhiredis-dev -y
