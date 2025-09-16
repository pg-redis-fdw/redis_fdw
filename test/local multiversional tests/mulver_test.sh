#!/bin/bash
[ "$1" == "" ] && exit;
fdwname="$1";
[ "$2" == "" ] && pg_multver_src_dir='PostgreSQL source' || pg_multver_src_dir="$2";
baseadr=$(readlink -f "$0");
baseadr=$(dirname "$baseadr");
pg_multver_src_dir="$baseadr/$pg_multver_src_dir";
[ ! -d "$pg_multver_src_dir" ] && (echo "No PostgreSQL source code directory
Press any key"; read x; exit;);

one_ver=$(echo "$3"| tr '.' '_');
ver=$(ls -1 "$baseadr/$fdwname/test/expected/" | tr '.' '_');
echo "$ver";

cd "$pg_multver_src_dir";
# Run $fdwname regression tests for tested version.
echo "$ver" | while read ver_curs; do
	[ "$one_ver" != "" ] && [ "$one_ver" != "$ver_curs" ] && continue;
	basedir="REL_$ver_curs/postgresql/contrib/$fdwname";
	(
 		cd "$basedir";
		./test.sh;
	)
	# "Copy" diff files from regression tests from different PostgreSQL version source code trees.
	rm "rel_$ver_curs regression.diff" "$fdwname_${ver_curs}_results" 2> /dev/null;
	ln -s -r "$basedir/test/regression.diffs" "$fdwname_${ver_curs}_regr.diff";
	ver0=$(echo "$ver_curs" | tr '_' '.');
	ln -s -r "$basedir/test/results/$ver0" "$fdwname_${ver_curs}_results"  ;
done;

cd ..;
