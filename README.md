## psql-retry

This package provides an executable `psql-retry` that invokes psql
with `PSQL_ARGS` and re-tries when it sees a psql error `"canceling statement due to lock timeout"` until it succeeds
or it does 500 attempts. `PSQL_ARGS` can be passed as an environment variable or as an argument to `psql-retry`.

### Usage

```bash
$ PSQL_ARGS="'postgres://dbuser@dbhost:dbport/db' -v 'ON_ERROR_STOP=1' -f ./test/this_will_timeout.sql" psql-retry
psql:./test/this_will_timeout.sql:3: ERROR:  canceling statement due to lock timeout
CONTEXT:  while locking tuple (0,1) in relation "test_lock"
```

Note: The setting `ON_ERROR_STOP=1` **must** be passed in the arguments when `psql-retry` is invoked directly. Some programs like sqitch set this variable themselves.

#### Usage with sqitch

A script like the below can be used with sqitch.

```bash
#! /usr/bin/env bash
# psql-retry.sh

# This is mean to be used as the argument for --client in sqitch

db_name=$1
shift

connection_string="$1"
shift

# while $@ does not start with --quiet, keep appending args to connection_string
# --quiet is the first argumet after the connections string that sqitch passes.
while [[ "$1" != "--quiet" ]]; do
  connection_string="$connection_string $1"
  shift
done

export PSQL_ARGS="$db_name '$connection_string' $@"

# if psql-retry not in the PATH then get it with nix
if ! command -v psql-retry &> /dev/null
then
  echo "psql-retry could not be found in PATH"
  command="nix run github:kronor-io/psql-retry -- "
else
  command="psql-retry"
fi

exec $command
```

This can be used with `sqitch` as `sqitch deploy --client ./psql-retry.sh`
