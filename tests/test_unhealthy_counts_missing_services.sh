# expect-fail-against-base: yes
#
# `compose ps` has no row for a service compose failed to create. The health check only looked
# at the rows it found, so a service that never came up contributed nothing and the rehearsal
# reported "all services healthy" for a stack that was not there. Absence has to count as
# unhealthy, which means checking against the list of services that were asked for.

load_upgrade_test || return

# Stand in for `docker compose`, so the test needs no containers. Only `ps` is consulted.
PS_ROWS=""
C() { case "$2$1" in *ps*) printf '%s\n' "$PS_ROWS" ;; esac; }

STARTED=(txs-db cfg-db txs-worker-indexer)

PS_ROWS='txs-db running healthy
cfg-db running healthy
txs-worker-indexer running healthy'
assert_eq "all present and healthy -> nothing reported" "" "$(unhealthy | tr '\n' ' ' | sed 's/ *$//')"

# The case that mattered: compose never created the indexer, so it has no row at all.
PS_ROWS='txs-db running healthy
cfg-db running healthy'
assert_eq "a service with no ps row is unhealthy" "txs-worker-indexer" "$(unhealthy | tr -d '\n')"

# The case that already worked; assert it still does.
PS_ROWS='txs-db running healthy
cfg-db running starting
txs-worker-indexer running healthy'
assert_eq "a row that is running but not healthy is unhealthy" "cfg-db" "$(unhealthy | tr -d '\n')"

PS_ROWS='txs-db exited
cfg-db running healthy
txs-worker-indexer running healthy'
assert_eq "an exited service is unhealthy" "txs-db" "$(unhealthy | tr -d '\n')"

# A healthcheck-less service reports an empty Health column and must not be called unhealthy.
PS_ROWS='txs-db running healthy
cfg-db running healthy
txs-worker-indexer running '
assert_eq "no healthcheck, just running -> healthy" "" "$(unhealthy | tr '\n' ' ' | sed 's/ *$//')"

# And wait_healthy must not declare success when nothing was ever started successfully.
PS_ROWS=""
assert_status "wait_healthy fails when no service has a row" 1 wait_healthy 1
