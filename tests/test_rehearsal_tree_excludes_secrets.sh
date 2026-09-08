# expect-fail-against-base: yes
#
# The upgrade rehearsal copies the repo into TEST_DIR with tar. It excluded .git, data and
# .upgrade-test -- but not .env or container_env_files/*.env, under a comment asserting that
# "real secrets are gitignored and not in the repo copy". Gitignoring keeps a file out of the
# *repository*; it does nothing to keep it out of a tar of the working tree. The rehearsal
# therefore ran on the operator's real DJANGO_SECRET_KEY, CGW AUTH_TOKEN and JWT_SECRET, and
# a `[ -f ] && continue` guard meant the throwaway credentials were never even generated.

d=$TMP
# A working tree that looks like a live deployment: real secrets and real dumps present.
mkdir -p "$d/repo/container_env_files" "$d/repo/data/txs-db" "$d/repo/backups" "$d/repo/scripts"
echo "POSTGRES_PASSWORD=REAL_PRODUCTION_PASSWORD" > "$d/repo/.env"
echo "REVERSE_PROXY_PORT=8000"                    > "$d/repo/.env.sample"
for f in cfg cgw txs events ui; do
  echo "SECRET_KEY=REAL_PRODUCTION_SECRET"  > "$d/repo/container_env_files/$f.env"
  echo "SECRET_KEY=__CHANGE_ME__"           > "$d/repo/container_env_files/$f.env.example"
done
echo "indexed history"       > "$d/repo/data/txs-db/PG_VERSION"
echo "pg_dump of production" > "$d/repo/backups/txs-db.sql"
touch "$d/repo/docker-compose.yml"

load_upgrade_test || return
TEST_DIR="$d/rehearsal"
REPO="$d/repo"        # pretend the working tree above is the repo being rehearsed
sync_test_dir >/dev/null 2>&1

assert_file_absent   "the operator's .env is not copied"          "$TEST_DIR/.env"
assert_file_absent   "./data is not copied"                       "$TEST_DIR/data"
assert_file_absent   "./backups (production dumps) is not copied" "$TEST_DIR/backups"

# Over-excluding would be its own bug: the templates and the sample must still arrive.
assert_file_present  ".env.sample still arrives"                  "$TEST_DIR/.env.sample"
assert_file_present  "the .env.example templates still arrive"    "$TEST_DIR/container_env_files/cfg.env.example"

for f in cfg cgw txs events ui; do
  assert_file_present "$f.env is generated"  "$TEST_DIR/container_env_files/$f.env"
  assert_not_contains "$f.env holds no real secret" \
    "REAL_PRODUCTION_SECRET" "$(cat "$TEST_DIR/container_env_files/$f.env" 2>/dev/null)"
done

# And the placeholder really was substituted, not merely left alone.
assert_not_contains "the placeholder was replaced" \
  "__CHANGE_ME__" "$(cat "$TEST_DIR/container_env_files/cfg.env" 2>/dev/null)"
