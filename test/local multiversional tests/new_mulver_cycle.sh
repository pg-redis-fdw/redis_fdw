#!/bin/bash
[ "$1" == "" ] && exit;
fdwname="$1";
[ "$2" == "" ] && pg_multver_src_dir='PostgreSQL source' || pg_multver_src_dir="$2";
baseadr=$(readlink -f "$0");
baseadr=$(dirname "$baseadr");
pg_multver_src_dir0="$pg_multver_src_dir"
pg_multver_src_dir="$baseadr/$pg_multver_src_dir";
[ ! -d "$pg_multver_src_dir" ] && (echo "No PostgreSQL source code directory
Press any key"; read x; exit;);

one_ver="$3";
ver=$(ls -1 "$baseadr/$fdwname/test/expected/" | tr '.' '_');

echo "$ver" | while read ver_curs; do
	[ "$one_ver" != "" ] && [ "$one_ver" != "$ver_curs" ] && continue;
	rm -v "$pg_multver_src_dir/$fdwname_${ver_curs}_regr.diff";
	rm -v "$pg_multver_src_dir/$fdwname_${ver_curs}_results";
done;

# Run $fdwname regression tests for tested version.
echo "$ver" | while read ver_curs; do
	rm -r -f "$pg_multver_src_dir/REL_$ver_curs/postgresql/contrib/$fdwname";
	cp -r "$baseadr/$fdwname" "$pg_multver_src_dir/REL_$ver_curs/postgresql/contrib";
done;

dir=$(readlink -f "$0");
dir=$(dirname "$dir");
"$dir/mulver_test.sh" "$fdwname" "$pg_multver_src_dir0" "$3" "$4";
echo "TESTING CYCLE IS ENDED, PLEASE READ THE RESULTS!";
