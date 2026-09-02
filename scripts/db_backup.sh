#!/usr/bin/env bash
#
# Back up and restore the Safe stack's Postgres databases. See RUNBOOK section 15.
#
# The stack has four databases: txs-db (indexed chain history), cfg-db (chain + contract
# configuration -- the addresses the wallet builds transactions against), cgw-db and events-db.
# Service upgrades run schema migrations on start, and migrations are not reversible: rolling an
# image back does NOT roll the schema back. A dump taken before the upgrade is the only way back.
#
# Production-safe: no test overlays, works under docker or podman, and never touches the chain.
# Run it from the stack directory (the one holding docker-compose.yml), or set STACK_DIR.
#
#   backup <dir>     Dump all four databases into <dir>, with a manifest of the running versions.
#   restore <dir>    Restore all four from <dir>. DESTRUCTIVE -- asks first unless FORCE=1.
#   list <dir>       Show what a backup directory holds.
#   verify <dir>     Check the dumps are non-empty and readable.
#
# Examples:
#   bash scripts/db_backup.sh backup ./backups/pre-upgrade-$(date +%F)
#   bash scripts/db_backup.sh restore ./backups/pre-upgrade-2026-09-02
#
# Notes
#   - Stop the writers first for a strictly consistent set: `docker compose stop txs-worker-indexer
#     txs-scheduler txs-web cfg-web cgw-web events-web`, back up, then start them again. A hot
#     backup is fine for a rehearsal but can catch the indexer mid-write.
#   - Dumps contain your chain configuration and indexed history. Treat them as sensitive and
#     store them off the host.

set -o pipefail

STACK_DIR="${STACK_DIR:-$PWD}"
[ -f "$STACK_DIR/docker-compose.yml" ] || {
  echo "error: no docker-compose.yml in $STACK_DIR (set STACK_DIR)" >&2; exit 1; }

RUNTIME="${CONTAINER_RUNTIME:-$(command -v podman || command -v docker)}"
RUNTIME="$(basename "$RUNTIME")"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"

# db service -> the label used in filenames
DBS="txs-db cfg-db cgw-db events-db"

cd "$STACK_DIR"

# Resolve a compose service to a container, tolerating both naming schemes.
cname() {
  local svc=$1 id
  id=$($COMPOSE_CMD ps -q "$svc" 2>/dev/null | head -1)
  [ -n "$id" ] && { echo "$id"; return 0; }
  local proj="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
  for n in "${proj}_${svc}_1" "${proj}-${svc}-1"; do
    $RUNTIME inspect "$n" >/dev/null 2>&1 && { echo "$n"; return 0; }
  done
  return 1
}

cmd_backup() {
  local dir=${1:?usage: backup <dir>}
  mkdir -p "$dir"
  echo "==> backing up to $dir"
  local ok=0 fail=0
  for db in $DBS; do
    local c; c=$(cname "$db") || { echo "  SKIP $db (no container)"; fail=$((fail+1)); continue; }
    printf '  %-12s ' "$db"
    # --clean --if-exists makes the dump self-contained: restoring drops the old objects first.
    if $RUNTIME exec -i "$c" pg_dump -U postgres -d postgres --clean --if-exists > "$dir/$db.sql" 2>"$dir/$db.err"; then
      local sz; sz=$(wc -c < "$dir/$db.sql")
      if [ "$sz" -lt 200 ]; then
        echo "FAILED (dump only ${sz} bytes -- see $dir/$db.err)"; fail=$((fail+1))
      else
        echo "ok ($(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B"))"; ok=$((ok+1)); rm -f "$dir/$db.err"
      fi
    else
      echo "FAILED (see $dir/$db.err)"; fail=$((fail+1))
    fi
  done
  # Record what produced these dumps: a backup you cannot match to a version set is hard to use.
  { echo "captured=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname)"
    echo "stack_dir=$STACK_DIR"
    echo "runtime=$RUNTIME"
    echo "# images actually running when this dump was taken"
    for svc in txs-web cfg-web cgw-web events-web ui; do
      c=$(cname "$svc" 2>/dev/null) || continue
      img=$($RUNTIME inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)
      [ -n "$img" ] && echo "running_${svc}=$img"
    done
    echo "# what .env requested at dump time (may differ after a partial upgrade)"
    grep -hE '^(TXS|CFG|CGW|EVENTS)_VERSION=|^UI_BASE_IMAGE=' .env 2>/dev/null \
      | sed 's/^/requested_/'
  } > "$dir/manifest.txt"
  echo "  manifest:"; sed 's/^/    /' "$dir/manifest.txt"
  if [ "$fail" -gt 0 ]; then
    echo "==> $ok ok, $fail FAILED -- do not rely on this backup" >&2
    return 1
  fi
  echo "==> $ok/$ok databases backed up"
}

cmd_verify() {
  local dir=${1:?usage: verify <dir>}
  local bad=0
  for db in $DBS; do
    printf '  %-12s ' "$db"
    if [ ! -f "$dir/$db.sql" ]; then echo "MISSING"; bad=$((bad+1)); continue; fi
    local sz; sz=$(wc -c < "$dir/$db.sql")
    # A valid pg_dump ends with a completion marker; truncated dumps are the common failure.
    if [ "$sz" -lt 200 ]; then echo "TOO SMALL (${sz}B)"; bad=$((bad+1))
    elif ! grep -q 'PostgreSQL database dump complete' "$dir/$db.sql"; then
      echo "TRUNCATED (no completion marker)"; bad=$((bad+1))
    else echo "ok ($(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B"))"; fi
  done
  [ "$bad" -eq 0 ] && { echo "==> backup looks complete"; return 0; }
  echo "==> $bad problem(s)" >&2; return 1
}

cmd_list() {
  local dir=${1:?usage: list <dir>}
  [ -d "$dir" ] || { echo "no such directory: $dir" >&2; exit 1; }
  [ -f "$dir/manifest.txt" ] && sed 's/^/  /' "$dir/manifest.txt"
  ls -la "$dir"/*.sql 2>/dev/null | awk '{printf "  %10s  %s\n", $5, $NF}'
}

cmd_restore() {
  local dir=${1:?usage: restore <dir>}
  cmd_verify "$dir" || { echo "refusing to restore an incomplete backup" >&2; exit 1; }
  echo
  echo "This REPLACES the contents of: $DBS"
  echo "from $dir"
  [ -f "$dir/manifest.txt" ] && sed 's/^/    /' "$dir/manifest.txt"
  if [ "${FORCE:-0}" != 1 ]; then
    printf 'Type RESTORE to proceed: '
    read -r reply
    [ "$reply" = RESTORE ] || { echo "aborted"; exit 1; }
  fi
  # Migrations already applied by a newer image are NOT undone by restoring data; put the old
  # image tags back (from the manifest) before restoring, or the schema and code will disagree.
  echo "==> restoring"
  local fail=0
  for db in $DBS; do
    local c; c=$(cname "$db") || { echo "  SKIP $db (no container)"; fail=$((fail+1)); continue; }
    printf '  %-12s ' "$db"
    if $RUNTIME exec -i "$c" psql -U postgres -d postgres -q -v ON_ERROR_STOP=0 \
         < "$dir/$db.sql" >/dev/null 2>"$dir/$db.restore.err"; then
      echo "ok"
    else
      echo "FAILED (see $dir/$db.restore.err)"; fail=$((fail+1))
    fi
  done
  echo "==> restart the services so they reconnect: $COMPOSE_CMD restart"
  [ "$fail" -eq 0 ] || return 1
}

case "${1:-}" in
  backup)  shift; cmd_backup "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  verify)  shift; cmd_verify "$@" ;;
  list)    shift; cmd_list "$@" ;;
  *) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
