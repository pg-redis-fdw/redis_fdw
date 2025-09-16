### Multiversional local tests in PostgreSQL source code file tree

1. Move this files to parent directory of redis_fdw
2. `mkdir "PostgreSQL source"`
3. copy `redis_fdw` main directory as `redis_fdw_base` to `PostgreSQL source` directory
4. cd to redis_fdw directory
5. Run the following command to get all PostgreSQL source codes for testing versions:
`../getmvpgenv.sh redis_fdw PostgreSQL\ source/`

	Multiversional testing environment will be
	- downloaded from official PostgreSQL git URLs,
	- compiled,
	- tested against internal regress tests

	This need
	- 1.2+ Gb of disk space,
	- not less than 30 minutes and
	- 1+ Gb of network traffic.

	* Please ensure your OS have needed packages for PostgreSQL source code compilation
		See https://wiki.postgresql.org/wiki/Compile_and_Install_from_source_code

6. Full code change tests can be called by following command
`reset; ../new_mulver_cycle.sh redis_fdw 'PostgreSQL\ source';`
   Change tests for a PostgreSQL version be called by following command with some version number
`reset; ../new_mulver_cycle.sh redis_fdw 'PostgreSQL source' 17.0;`

Have a good tests!
