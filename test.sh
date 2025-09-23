#!/bin/bash

# Usage:
# ./test.sh                -- test without GIS support
# ./test.sh ENABLE_GIS=1     -- test with GIS support

# full test sequence,
# you can put your own test sequence here by following example
# undefined REGRESS environment variable will cause full test sequence from Makefile
#export REGRESS="redis_fdw extra/test2 test3 types/test4 .... ";

make clean $@;
make $@;
make check $@ | tee make_check.out;
