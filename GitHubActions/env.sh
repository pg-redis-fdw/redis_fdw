#!/bin/bash

################################################################################
#
# This script configures apt.conf to set a proxy if an environment variable
# HTTP_PROXY or HTTPS_PROXY is set.
#
# Usage: ./env.sh
#
# Requirements
# - having superuser privileges
#
################################################################################

if [ -z $HTTP_PROXY ] && [ "$HTTP_PROXY" != "" ]; then
	echo 'Acquire::http::proxy "$HTTP_PROXY";' | sudo tee /etc/apt/apt.conf
fi
if [ -z $HTTPS_PROXY ] && [ "$HTTPS_PROXY" != "" ]; then
	echo 'Acquire::https::proxy "$HTTPS_PROXY";' | sudo tee -a /etc/apt/apt.conf
fi
