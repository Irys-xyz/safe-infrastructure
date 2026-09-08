# expect-fail-against-base: yes
#
# TEST_DIR is documented as settable, and both `down` and the reset before `up` delete
# everything under $TEST_DIR/data recursively, through a container so it can remove
# root-owned files. Run from a real stack directory -- TEST_DIR=$PWD -- that destroys all four
# production Postgres data directories. The default is safe; nothing enforced it.

d=$TMP
# A directory that looks exactly like a live deployment, because that is the accident.
mkdir -p "$d/live/data/txs-db"
touch "$d/live/docker-compose.yml"
echo "the indexed chain history" > "$d/live/data/txs-db/PG_VERSION"

assert_status "down on a directory this script did not create is refused" 1 \
  env TEST_DIR="$d/live" bash "$SUT/scripts/upgrade_test.sh" down
assert_contains "and says why" "did not create it" "$OUT"
assert_file_present "the data is still there" "$d/live/data/txs-db/PG_VERSION"

# The repo root is the other way to lose a real ./data.
assert_status "TEST_DIR set to the repo root is refused" 1 \
  env TEST_DIR="$SUT" bash "$SUT/scripts/upgrade_test.sh" down
assert_contains "and says why" "must not be the repo root" "$OUT"

# The guard must not block the legitimate case: a directory the script itself created.
mkdir -p "$d/mine/data"
touch "$d/mine/.upgrade-test-dir" "$d/mine/docker-compose.yml"
OUT=$(env TEST_DIR="$d/mine" bash "$SUT/scripts/upgrade_test.sh" down 2>&1)
assert_not_contains "a directory it did create is accepted" "did not create it" "$OUT"
