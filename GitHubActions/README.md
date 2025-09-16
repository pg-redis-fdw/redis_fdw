# CI environment of redis_fdw.

Tests will be executed automatically when commited to main/master branch and when a pull request was opened/updated.
It is realized by using GitHub actions.

The CI process is defined in .github/workflows/CI.yml file.
Scripts in this directory (GitHubActions/*.sh) are referred by CI.yml. 

The regression test will be executed for multi-versions of PostgreSQL.
Target versions are determined automatically based on directory names in "expected" directory.

If the regression test failed, test result files (result directory, regression.diff amd regression.out) are uploaded as artifacts.
7 days later, artifact files will be deleted.
