# expect-fail-against-base: yes
#
# This is the branch's designated rollback path: migrations are not reversible, so a dump taken
# before an upgrade is the only way back. It restored with ON_ERROR_STOP=0, which makes psql run
# past every SQL error and still exit 0 -- so a restore that half-applied, or did not apply at
# all, printed "ok" and returned success. On the one day anyone runs it.
#
# Real Postgres containers, because what is under test is psql's behaviour, and a mock of psql
# would just encode the same wrong assumption that caused the bug.

need_docker

d=$TMP
project="irystest$$"
compose() { docker compose -p "$project" -f "$d/docker-compose.yml" "$@"; }
psql_txs() { compose exec -T txs-db psql -U postgres -d postgres -tAc "$1" 2>/dev/null; }
cleanup() { compose down -v >/dev/null 2>&1; }
trap cleanup EXIT

# The four databases the stack has, since db_backup.sh backs up and restores all of them.
{
  echo "services:"
  for svc in txs-db cfg-db cgw-db events-db; do
    printf '  %s:\n    image: postgres:14-alpine\n    environment:\n      POSTGRES_PASSWORD: testpw\n' "$svc"
  done
} > "$d/docker-compose.yml"
touch "$d/stack-marker"

compose up -d >/dev/null 2>&1 || { echo "    SKIP  could not start postgres"; exit 77; }

# Wait for a query to actually succeed, on every database. `pg_isready` is not enough: the
# postgres image runs a temporary server while initdb and the entrypoint scripts run, so
# pg_isready reports ready before the real server is accepting connections -- which made this
# test seed an empty database roughly one run in three.
for svc in txs-db cfg-db cgw-db events-db; do
  ready=0
  for _ in $(seq 1 60); do
    [ "$(compose exec -T "$svc" psql -U postgres -d postgres -tAc 'select 1' 2>/dev/null)" = 1 ] \
      && { ready=1; break; }
    sleep 1
  done
  [ "$ready" = 1 ] || { echo "    SKIP  $svc never accepted a query"; exit 77; }
done

seed() {
  compose exec -T txs-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "CREATE TABLE history(id int primary key, v text);
     INSERT INTO history SELECT g, 'block'||g FROM generate_series(1,50) g;"
}
assert_status "seeding the database succeeds" 0 seed
assert_eq "and the rows are there" "50" "$(psql_txs 'select count(*) from history')"

backup() { env STACK_DIR="$d" COMPOSE_PROJECT_NAME="$project" CONTAINER_RUNTIME=docker \
    COMPOSE_CMD="docker compose -p $project -f $d/docker-compose.yml" \
    bash "$SUT/scripts/db_backup.sh" backup "$1"; }
restore() { env STACK_DIR="$d" COMPOSE_PROJECT_NAME="$project" CONTAINER_RUNTIME=docker FORCE=1 \
    COMPOSE_CMD="docker compose -p $project -f $d/docker-compose.yml" \
    bash "$SUT/scripts/db_backup.sh" restore "$1"; }

assert_status "backup succeeds" 0 backup "$d/good"
assert_file_present "and wrote a dump" "$d/good/txs-db.sql"

# Dumps hold the chain configuration and the indexed history; the script calls them sensitive.
assert_eq "the dump is not world-readable" "600" "$(stat -c '%a' "$d/good/txs-db.sql")"
assert_eq "nor is the directory"           "700" "$(stat -c '%a' "$d/good")"

# A good dump must restore, or the fail-closed change has simply broken the rollback path.
psql_txs "DELETE FROM history WHERE id > 10" >/dev/null
assert_eq "rows deleted, ready to roll back" "10" "$(psql_txs 'select count(*) from history')"
assert_status "restoring a good dump succeeds" 0 restore "$d/good"
assert_eq "and the data is back" "50" "$(psql_txs 'select count(*) from history')"

# The case the tool exists for and could not report: a dump that does not apply cleanly.
cp -r "$d/good" "$d/broken"; chmod 700 "$d/broken"
python3 - "$d/broken/txs-db.sql" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
marker = "COPY public.history"
assert marker in t, "the dump does not look like pg_dump output"
p.write_text(t.replace(marker, "SELECT * FROM a_table_that_does_not_exist;\n" + marker, 1))
PY

assert_status "restoring a dump that fails mid-way reports failure" 1 restore "$d/broken"
assert_contains "and says it rolled back" "rolled back" "$OUT"
assert_contains "and shows the error" "does not exist" "$OUT"
# Rolled back means rolled back: the pre-restore state has to survive intact, because a
# half-restored database is worse than a failed restore.
assert_eq "and the database is untouched" "50" "$(psql_txs 'select count(*) from history')"
