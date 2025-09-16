#!/bin/bash
[ "$1" == "" ] && exit;
fdwname="$1";
[ "$2" == "" ] && pg_multver_src_dir='PostgreSQL source' || pg_multver_src_dir="$2";
baseadr=$(readlink -f "$0");
baseadr=$(dirname "$baseadr");
pg_multver_src_dir0="$pg_multver_src_dir"
pg_multver_src_dir="$baseadr/$pg_multver_src_dir";
[ ! -d "$pg_multver_src_dir" ] && (mkdir "$pg_multver_src_dir");

d0=$(date);
echo "$d0";

cd "$pg_multver_src_dir";
# Clone original $fdwname.
#[ ! -d "${fdwname}_base" ] && git clone "https://github.com/pgspider/$fdwname" "${fdwname}_base" || (cd "${fdwname}_base"; git pull; cd ..;);

# Get and read list of PostgreSQL versions.
ver=$(ls -1 "../$fdwname/test/expected/" | tr '.' '_');
echo "$ver";

# Get or pull (update) individual PostgreSQL source trees for different versions.
echo "$ver" | while read ver_curs; do
	[ ! -d "REL_$ver_curs" ] && mkdir "REL_$ver_curs";
	(
 		cd "REL_$ver_curs";
		git clone https://git.postgresql.org/git/postgresql.git -b "REL_$ver_curs" || ( cd postgresql; git pull https://git.postgresql.org/git/postgresql.git "REL_$ver_curs"; cd ..;);
	)
done;

# Configure PostgreSQL sources
echo "$ver" | while read ver_curs; do
	(
		cd "REL_$ver_curs/postgresql";
		./configure;
	)
done;

# Make PostgreSQL sources
echo "$ver" | while read ver_curs; do
	(
		cd "REL_$ver_curs/postgresql";
		make;
	)
done;

# Run internal checks for PostgreSQL. 
echo "$ver" | while read ver_curs; do
	(
		cd "REL_$ver_curs/postgresql";
		make check;
	)
done;

echo "Beginned at $d0";
echo -n "PostgreSQL compiled and tested at";
date;

# Copy generic $fdwname to contrib directory of all PostgreSQL versions.
echo "$ver" | while read ver_curs; do
	basedir="REL_$ver_curs/postgresql/contrib/$fdwname";
	[ -d "$basedir" ] && rm -r -f "$basedir";
	cp -r "${fdwname}_base" "$basedir";
done;

cd ..;

"$baseadr/mulver_test.sh" "$fdwname" "$pg_multver_src_dir0";

echo "Beginned at $d0";
echo -n "Multiversional testing environment for $fdwname and mainstream $fdwname compiled and tested at ";
date;
