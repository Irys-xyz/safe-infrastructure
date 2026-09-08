#!/usr/bin/env bash
#
# Upgrade tooling for the self-hosted Safe stack. See RUNBOOK section 14.
#
# The stack pins five images (transaction service, config service, client gateway, events
# service, and the wallet UI base). Upgrading them is not a pure image swap: three of them own
# Postgres databases and run migrations on start, so an upgrade has to be shown to preserve
# data, not just to boot. This drives that rehearsal end to end, against a disposable fork of
# Irys (section 13) so nothing touches production.
#
#   probe [url]            Versions a LIVE deployment reports over HTTP (default:
#                          https://safe.irys.xyz). Authoritative for txs/cfg/cgw, which report
#                          their own version; the UI and events service cannot be determined
#                          this way and are emitted commented out.
#   probe-host <ssh>       The image tags the containers are ACTUALLY running, read over SSH.
#                          Authoritative for all four services. Connect as the stack user --
#                          the stack is a rootless podman user service.
#   latest                 Newest published tag for each of the five images (Docker Hub).
#   plan [url]             probe + latest side by side: how far behind each component is.
#   up <versions.env>      Bring the test stack up at that version set, against a fork.
#   snapshot <out.json>    Capture the running test stack: versions, applied migrations,
#                          table row counts, chain config, indexed Safes.
#   upgrade <versions.env> Swap the test stack to that version set in place (databases kept)
#                          and wait for it to come back healthy.
#   diff <before> <after>  Compare two snapshots and flag anything lost.
#   down                   Tear the test stack down, including its databases.
#
# `upgrade` takes a pg_dump of all four databases first (scripts/db_backup.sh) and aborts if
# that fails -- migrations are not reversible, so the dump is the only rollback path. It then
# asserts the services actually report the requested versions before returning success.
#
# Typical rehearsal:
#   scripts/upgrade_test.sh plan
#   scripts/upgrade_test.sh up  versions/deployed.env
#   scripts/upgrade_test.sh snapshot before.json
#   scripts/upgrade_test.sh upgrade versions/latest.env
#   scripts/upgrade_test.sh snapshot after.json
#   scripts/upgrade_test.sh diff before.json after.json
#
# Env: TEST_DIR (default ./.upgrade-test) is an isolated copy of the repo, so the test stack's
# ./data never collides with a real deployment's. The copy excludes .env,
# container_env_files/*.env, ./data and ./backups, so the rehearsal runs on freshly generated
# throwaway credentials rather than the operator's real ones.

set -o pipefail
# ${BASH_SOURCE[0]} rather than $0, so the path is this file's even when it is sourced (tests/
# does that to exercise the functions below directly), where $0 is the sourcing shell.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "error: cannot cd to the repo root" >&2; exit 1; }
REPO=$PWD

# shellcheck source=lib/stack.sh
. "$REPO/scripts/lib/stack.sh"

TEST_DIR="${TEST_DIR:-$REPO/.upgrade-test}"
PROJECT="${UPGRADE_TEST_PROJECT:-irysupg}"
PORT="${UPGRADE_TEST_PORT:-8100}"
LIVE_URL_DEFAULT="${LIVE_URL:-https://safe.irys.xyz}"
HUB=https://hub.docker.com/v2/repositories/safeglobal

UI_OVERLAY="-f docker-compose.ui-stub.yml"
[ "${UI_REAL:-0}" = 1 ] && UI_OVERLAY=""
# shellcheck disable=SC2086
C() { (cd "$TEST_DIR" && docker compose -f docker-compose.yml -f docker-compose.local-chain.yml $UI_OVERLAY "$@"); }
have_py() { command -v python3 >/dev/null || { echo "need python3" >&2; exit 1; }; }

# The version a Safe service reports at its /about endpoint, empty if it cannot be read.
# One definition for what was ten copies of this pipeline across probe, plan, snapshot and
# the post-upgrade assertion.
svc_version() {
  curl -sS --max-time "${2:-20}" "$1" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null
}

# The tag of an image reference, with any digest suffix removed. Named rather than inlined
# because the naive form is wrong in a way that looks right: a digest-pinned reference is
# repo:v6.10.1@sha256:..., so ${ref##*:} yields the digest hex, not the tag -- which reported a
# correctly upgraded digest-pinned stack as FAIL.
image_tag() { local r=${1%@*}; echo "${r##*:}"; }

# The three services that report their own version, relative to a base URL.
about_url() {
  case $1 in
    txs) echo "$2/txs/api/v1/about/" ;;
    cfg) echo "$2/cfg/api/v1/about/" ;;
    cgw) echo "$2/cgw/about" ;;
  esac
}

# --- probe a live deployment -------------------------------------------------------------
cmd_probe() {
  local url="${1:-$LIVE_URL_DEFAULT}"
  have_py
  echo "# Version set read over HTTP from $url on $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  local cgw txs cfg ui
  # These three are authoritative: each service reports its own version.
  cgw=$(svc_version "$(about_url cgw "$url")")
  txs=$(svc_version "$(about_url txs "$url")")
  cfg=$(svc_version "$(about_url cfg "$url")")
  ui=$(cmd_probe_ui "$url")
  norm() { case "$1" in v*) echo "$1";; "") echo "";; *) echo "v$1";; esac; }
  cat <<EOF
TXS_VERSION=$(norm "$txs")
CFG_VERSION=$(norm "$cfg")
CGW_VERSION=$(norm "$cgw")
EOF
  # The UI has no version endpoint. What is in the bundle is the app's package version, which
  # LAGS the image tag by about a release (the image tagged v1.88.0 contains app version
  # 1.87.5), so it must not be emitted as if it were a tag -- pinning from it would pin the
  # wrong image. Same for events-service, which reports no version at all. Emit both commented
  # out, and point at `probe-host` for the authoritative answer.
  echo "# UI_BASE_IMAGE: cannot be determined over HTTP."
  if [ -n "$ui" ]; then
    echo "#   the served bundle reports app version $ui, which is NOT the image tag"
    echo "#   (it lags by ~1 release), so do not pin from it."
  else
    echo "#   could not read an app version from the served bundle."
  fi
  echo "# EVENTS_VERSION: the events service exposes no version endpoint."
  echo "# For both, read the real image tags off the host:"
  echo "#   scripts/upgrade_test.sh probe-host <stack-user>@<host>"
}

# Authoritative version set: the image tags the containers are actually running. Requires shell
# access. Connect as the user that owns the stack -- it runs as a rootless podman *user*
# service, so root's container list is empty.
cmd_probe_host() {
  local target=${1:?usage: probe-host <stack-user>@<host>}
  echo "# Image tags read from the running containers on $target on $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  local out
  # shellcheck disable=SC2029
  # Collect the RepoDigest as well as the tag. On this deployment every tag is `latest`, so the
  # tag alone identifies nothing -- the digest is the only pinnable value.
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$target" '
rt=$(command -v podman || command -v docker)
"$rt" ps --format "{{.Names}} {{.Image}}" | while read -r n i; do
  d=$("$rt" image inspect "$i" --format "{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}-{{end}}" 2>/dev/null)
  printf "%s %s %s\n" "$n" "$i" "${d:--}"
done' 2>&1) || {
    echo "error: could not list containers on $target" >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    return 1
  }
  printf '%s\n' "$out" | python3 -c '
import re,sys
# Container names differ by compose front-end (podman-compose: project_service_1,
# docker compose v2: project-service-1), so match the service name as a delimited substring.
want=[("txs-web","TXS"),("cfg-web","CFG"),("cgw-web","CGW"),("events-web","EVENTS")]
rows=[l.split() for l in sys.stdin.read().splitlines() if l.strip()]
found={}
for parts in rows:
    if len(parts) < 2: continue
    name, image = parts[0], parts[1]
    digest = parts[2] if len(parts) > 2 else "-"
    for svc,stem in want:
        if re.search(r"[_-]"+re.escape(svc)+r"[_-]", name):
            found[stem]=(image,digest)
for svc,stem in want:
    got=found.get(stem)
    if not got:
        print("# %s_VERSION: no running container matched %s" % (stem,svc))
        continue
    image,digest=got
    last=image.rsplit("/",1)[-1]
    # A reference can be repo:tag, repo@sha256:..., or repo:tag@sha256:... .
    if "@" in last:
        before=image.split("@",1)[0].rsplit("/",1)[-1]
        tag=before.rsplit(chr(58),1)[-1] if chr(58) in before else ""
        print("%s_VERSION=%s" % (stem,tag) if tag else "# %s_VERSION: pinned by digest only" % stem)
        print("%s_DIGEST=@%s" % (stem, image.split("@",1)[1]))
        continue
    tag=last.rsplit(chr(58),1)[-1] if chr(58) in last else ""
    if not tag:
        print("# %s_VERSION: %s has no tag and no digest" % (stem,image))
        continue
    print("%s_VERSION=%s" % (stem,tag))
    if digest and digest != "-" and "@" in digest:
        print("%s_DIGEST=@%s" % (stem, digest.split("@",1)[1]))
        if tag in ("latest","staging","dev"):
            print("#   ^ tag is %s, so the digest above is the only thing identifying this build" % tag)
    else:
        print("#   %s_DIGEST unknown (image has no RepoDigest -- built locally?)" % stem)
# The UI image is built locally, so its tag says nothing about the upstream base it came from.
ui=[(p[0],p[1]) for p in rows if len(p)>=2 and re.search(r"[_-]ui[_-]", p[0])]
if ui:
    print("# UI image running: %s" % ui[0][1])
    print("#   locally built, so its upstream base is the UI_BASE_IMAGE it was built with,")
    print("#   recorded in its irys.base-image label. Read it with:")
    print("#     podman image inspect %s --format={{.Config.Labels}}" % ui[0][1])
    print("#   If the label is absent (image predates it), match its build date against the")
    print("#   safe-wallet-web tag push dates on Docker Hub.")
else:
    print("# UI: no running container matched ui")
'
}

cmd_probe_ui() {
  local url="$1" idx app
  idx=$(curl -sS --max-time 25 "$url/" 2>/dev/null) || return 0
  app=$(printf '%s' "$idx" | grep -oE '/_next/static/chunks/pages/_app-[^"]+\.js' | head -1)
  [ -n "$app" ] || return 0
  curl -sS --max-time 120 "$url$app" 2>/dev/null \
    | grep -oE '"[0-9]+\.[0-9]+\.[0-9]+",[a-zA-Z]+="https://github.com/safe-global/safe-wallet' \
    | head -1 | sed 's/^"//; s/".*//'
}

# --- newest published tags ---------------------------------------------------------------
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) uname -m ;;
  esac
}

newest_tag() {
  local arch="${TARGET_ARCH:-$(host_arch)}"
  curl -sS --max-time 45 "$HUB/$1/tags?page_size=100&ordering=last_updated" 2>/dev/null \
    | ARCH="$arch" python3 -c '
import json,os,sys,re
arch=os.environ["ARCH"]
try: rs=json.load(sys.stdin).get("results",[])
except Exception: sys.exit(0)
best=None
for t in rs:
    m=re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", t["name"])
    if not m: continue
    imgs=t.get("images") or []
    # Keep only tags published for this architecture. Entries with no arch info are skipped
    # rather than assumed compatible.
    if not any((i.get("architecture")==arch and i.get("os")=="linux") for i in imgs):
        continue
    k=tuple(int(x) for x in m.groups())
    if best is None or k>best[0]: best=(k,t["name"],(t.get("tag_last_pushed") or "")[:10])
if best: print(best[1], best[2])
'
}

cmd_latest() {
  have_py
  local t arch; arch="${TARGET_ARCH:-$(host_arch)}"
  echo "# newest tag published for linux/$arch (set TARGET_ARCH to override)" >&2
  for r in safe-transaction-service safe-config-service safe-client-gateway-nest safe-events-service safe-wallet-web; do
    t=$(newest_tag "$r"); printf '%-28s %s\n' "$r" "${t:-<none for this arch>}" >&2
  done
  cat <<EOF
TXS_VERSION=$(newest_tag safe-transaction-service | awk '{print $1}')
CFG_VERSION=$(newest_tag safe-config-service | awk '{print $1}')
CGW_VERSION=$(newest_tag safe-client-gateway-nest | awk '{print $1}')
EVENTS_VERSION=$(newest_tag safe-events-service | awk '{print $1}')
UI_BASE_IMAGE=docker.io/safeglobal/safe-wallet-web:$(newest_tag safe-wallet-web | awk '{print $1}')
EOF
}

cmd_plan() {
  have_py
  local url="${1:-$LIVE_URL_DEFAULT}"
  echo "component                    deployed        latest          pushed"
  echo "---------------------------- --------------- --------------- ----------"
  local dep_cgw dep_txs dep_cfg dep_ui
  dep_cgw=$(svc_version "$(about_url cgw "$url")")
  dep_txs=$(svc_version "$(about_url txs "$url")")
  dep_cfg=$(svc_version "$(about_url cfg "$url")")
  dep_ui=$(cmd_probe_ui "$url")
  row() { printf '%-28s %-15s %-15s %s\n' "$1" "${2:-?}" "$(echo "$3"|awk '{print $1}')" "$(echo "$3"|awk '{print $2}')"; }
  row safe-transaction-service   "$dep_txs" "$(newest_tag safe-transaction-service)"
  row safe-config-service        "$dep_cfg" "$(newest_tag safe-config-service)"
  row safe-client-gateway-nest   "$dep_cgw" "$(newest_tag safe-client-gateway-nest)"
  row safe-events-service        "n/a"      "$(newest_tag safe-events-service)"
  row safe-wallet-web            "$dep_ui"  "$(newest_tag safe-wallet-web)"
  echo
  echo "safe-events-service exposes no version endpoint; check the running image tag instead."
}

# --- test stack lifecycle ----------------------------------------------------------------
# TEST_DIR is documented as settable, and reset_data / `down` delete everything under its
# ./data recursively. So refuse to touch a directory this script did not create -- a marker
# file it writes itself. `TEST_DIR=$PWD upgrade_test.sh up ...` run from a live stack
# directory would otherwise destroy all four production Postgres data directories.
MARKER=.upgrade-test-dir

assert_test_dir() {
  [ "$TEST_DIR" != "$REPO" ] || {
    echo "error: TEST_DIR must not be the repo root" >&2; exit 1; }
  [ -f "$TEST_DIR/$MARKER" ] || {
    echo "error: $TEST_DIR holds no $MARKER, so this script did not create it." >&2
    echo "       Refusing to delete data under it. Use the default (.upgrade-test) or an" >&2
    echo "       empty directory; 'up' creates the marker." >&2
    exit 1; }
}

sync_test_dir() {
  [ "$TEST_DIR" != "$REPO" ] || {
    echo "error: TEST_DIR must not be the repo root" >&2; exit 1; }
  if [ -e "$TEST_DIR" ] && [ ! -f "$TEST_DIR/$MARKER" ] && [ -n "$(ls -A "$TEST_DIR" 2>/dev/null)" ]; then
    echo "error: $TEST_DIR is not empty and holds no $MARKER." >&2
    echo "       This script overwrites the tree and wipes ./data under it; pick another TEST_DIR." >&2
    exit 1
  fi
  mkdir -p "$TEST_DIR"
  : > "$TEST_DIR/$MARKER"
  # Copy the repo, NOT the operator's secrets. Being gitignored keeps .env and
  # container_env_files/*.env out of the *repository*; it does nothing to keep them out of a
  # tar of the working tree, which is what this is. Excluding them is what makes the rehearsal
  # stack run on throwaway credentials -- without it it ran on the real DJANGO_SECRET_KEY, CGW
  # AUTH_TOKEN, JWT_SECRET and FINGERPRINT_ENCRYPTION_KEY, and copied production dumps too.
  tar -C "$REPO" -cf - \
      --exclude=./.git --exclude=./data --exclude=./.upgrade-test \
      --exclude=./.env --exclude='./container_env_files/*.env' --exclude=./backups \
      . | tar -C "$TEST_DIR" -xf -
  local s p
  s=$(openssl rand -hex 32)
  # One password for every test database: docker-compose.yml passes $POSTGRES_PASSWORD to the
  # DB containers, and the service env files below must use the same value or nothing connects.
  p="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
  export POSTGRES_PASSWORD="$p"
  mkdir -p "$TEST_DIR/container_env_files"
  for f in cfg cgw txs events ui; do
    # Written unconditionally: a `[ -f ] && continue` guard here is what let a copied real
    # secrets file survive and be used instead of the throwaway one.
    sed -e "s/__CHANGE_ME__/$s/g" -e "s/__USER__/postgres/g" -e "s/__PASSWORD__/$p/g" \
        -e "s/__SAFE_DOMAIN__/localhost/g" \
        -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$p/" \
        "$REPO/container_env_files/$f.env.example" > "$TEST_DIR/container_env_files/$f.env"
  done
}

write_env() {
  local vf=$1
  # Preserve credentials already in the test .env: `upgrade` must not rewrite them, or the
  # recreated services get a different password than the databases were initialised with.
  if [ -f "$TEST_DIR/.env" ]; then
    local prev
    for k in POSTGRES_PASSWORD RABBITMQ_USER RABBITMQ_PASSWORD; do
      prev=$(sed -n "s/^${k}=//p" "$TEST_DIR/.env" | head -1)
      [ -n "$prev" ] && export "$k=$prev"
    done
  fi
  { echo "COMPOSE_PROJECT_NAME=$PROJECT"
    echo "REVERSE_PROXY_PORT=$PORT"
    echo "RPC_NODE_URL=http://anvil:8545"
    echo "LOCAL_CHAIN_PORT=${LOCAL_CHAIN_PORT:-8546}"
    echo "PUBLIC_RPC_NODE_URL=http://localhost:${LOCAL_CHAIN_PORT:-8546}"
    echo "UI_GATEWAY_URL=/cgw"
    [ -n "${LOCAL_FORK_BLOCK:-}" ] && echo "LOCAL_FORK_BLOCK=$LOCAL_FORK_BLOCK"
    echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?no test credentials yet -- run 'up' before 'upgrade'}"
    echo "RABBITMQ_USER=${RABBITMQ_USER:-safe}"
    echo "RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD:-$POSTGRES_PASSWORD}"
    grep -vE '^\s*(#|$)' "$vf"
  } > "$TEST_DIR/.env"
}

# Services this run has asked compose to start. wait_healthy checks against this list rather
# than against whatever `ps` happens to report, because a service compose FAILED to create has
# no row in `ps` at all -- so it contributed nothing to the old check and a stack that never
# came up was declared "all services healthy".
STARTED=()

# Bring services up and record them. Compose's output is no longer discarded: a failed create
# used to be invisible here, which is the same lesson the `pull` step below already records.
up_svc() {
  local out svc
  if ! out=$(C up -d "$@" 2>&1); then
    printf '%s\n' "$out" | tail -6 | sed 's/^/    /'
    echo "    ABORTING: compose could not start: $*" >&2
    return 1
  fi
  for svc in "$@"; do
    case "$svc" in -*) continue ;; esac   # skip flags like --no-deps
    STARTED+=("$svc")
  done
}

# Of the services started so far, those that are not (running AND healthy-or-healthcheckless),
# one per line. A service with no row in `ps` counts as unhealthy, not as absent.
unhealthy() {
  local state svc
  state=$(C ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null)
  for svc in "${STARTED[@]}"; do
    printf '%s\n' "$state" | awk -v s="$svc" '
      $1==s { seen=1; if ($2!="running" || ($3!="" && $3!="healthy")) bad=1 }
      END   { if (!seen || bad) print s }'
  done
}

wait_healthy() {
  local timeout=${1:-300}
  local end=$((SECONDS + timeout))
  local bad
  [ "${#STARTED[@]}" -gt 0 ] || return 0
  while [ "$SECONDS" -lt "$end" ]; do
    bad=$(unhealthy | tr '\n' ' ')
    if [ -z "${bad// /}" ]; then echo "  all services healthy"; return 0; fi
    sleep 5
  done
  # Re-read rather than trusting the loop variable, so the message always reflects reality.
  bad=$(unhealthy | tr '\n' ' ')
  echo "  WARN: after ${timeout}s still not ready: ${bad:-<none reported>}"
  return 1
}

cmd_up() {
  local vf=${1:?usage: up <versions.env>}
  vf=$(cd "$(dirname "$vf")" && pwd)/$(basename "$vf")
  sync_test_dir; write_env "$vf"
  # Take any previous run down before reset_data: it deletes the bind-mounted Postgres files,
  # and doing that under running containers corrupts them rather than resetting them.
  C down -v --remove-orphans >/dev/null 2>&1
  reset_data
  echo "==> test dir $TEST_DIR  (project $PROJECT, proxy port $PORT)"
  grep -E 'VERSION|UI_BASE' "$TEST_DIR/.env" | sed 's/^/    /'
  echo "==> starting the fork"
  # The overlay gives anvil a healthcheck, so wait on that rather than on a fixed sleep --
  # forking a remote chain takes as long as it takes.
  up_svc anvil || return 1
  wait_healthy 120 || return 1
  C logs anvil 2>&1 | grep -iE 'forking|reproduce' | sed 's/^/    /' | head -2
  echo "==> starting the backend"
  up_svc txs-db cfg-db events-db cgw-db txs-redis cgw-redis txs-rabbitmq general-rabbitmq || return 1
  wait_healthy 180 || return 1
  up_svc txs-worker-indexer || return 1
  wait_healthy 420 || return 1
  up_svc cfg-web cgw-web events-web txs-web txs-scheduler \
       txs-worker-contracts-tokens txs-worker-notifications-webhooks || return 1
  wait_healthy 300 || return 1
  echo "==> starting the ui ($([ "${UI_REAL:-0}" = 1 ] && echo 'real image' || echo 'stub')) and nginx"
  up_svc --no-deps ui || return 1
  up_svc --no-deps nginx || return 1
  wait_healthy 120 || return 1
  echo "==> applying the chain configuration (chain $(chain_id))"
  (cd "$TEST_DIR" && CONTAINER_RUNTIME=docker \
     COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.local-chain.yml $UI_OVERLAY" \
     bash scripts/configure_irys.sh 2>&1 | tail -6 | sed 's/^/    /')
}

cmd_upgrade() {
  local vf=${1:?usage: upgrade <versions.env>}
  vf=$(cd "$(dirname "$vf")" && pwd)/$(basename "$vf")
  echo "==> upgrading IN PLACE (databases preserved)"
  grep -E 'VERSION|UI_BASE' "$vf" | sed 's/^/    /'
  write_env "$vf"
  echo "==> backing up the databases first (rollback path)"
  local bdir="$TEST_DIR/backups/pre-upgrade-$(date +%Y%m%d-%H%M%S)"
  if (cd "$TEST_DIR" && STACK_DIR="$TEST_DIR" CONTAINER_RUNTIME=docker \
        COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.local-chain.yml $UI_OVERLAY" \
        bash scripts/db_backup.sh backup "$bdir" 2>&1 | sed 's/^/    /'); then
    echo "    restore with: STACK_DIR=$TEST_DIR bash scripts/db_backup.sh restore $bdir"
  else
    echo "    ABORTING: the pre-upgrade backup failed, so there would be no way back." >&2
    return 1
  fi

  echo "==> pulling"
  # Must not be silenced: a failed pull previously left the old images running and the upgrade
  # still reported success.
  C pull txs-web cfg-web cgw-web events-web 2>&1 \
    | grep -iE 'Pulled|Error|error|no matching manifest|denied|not found' \
    | sed 's/^/    /'
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "    ABORTING: pull failed (see above -- an image may not exist for this architecture;" >&2
    echo "              'scripts/upgrade_test.sh latest' only offers tags built for it)" >&2
    return 1
  fi
  # The wallet UI is not one of the pulled images: it is built here from UI_BASE_IMAGE. Without
  # this the rehearsal could "pass" an upgrade in which the bundle under test was still the old
  # one -- the single most important artefact in the set, since it renders what owners sign.
  if [ "${UI_REAL:-0}" = 1 ]; then
    echo "==> rebuilding the wallet UI from the requested base"
    grep -E '^UI_BASE_IMAGE' "$vf" | sed 's/^/    /'
    if ! C build ui 2>&1 | tail -5 | sed 's/^/    /'; then
      echo "    ABORTING: the UI image did not build" >&2; return 1
    fi
  else
    echo "==> skipping the UI (stub overlay; re-run with UI_REAL=1 to include it)"
  fi

  echo "==> recreating (migrations run on start)"
  if ! up_svc --no-deps txs-worker-indexer; then
    echo "    ABORTING: could not recreate txs-worker-indexer" >&2; return 1
  fi
  wait_healthy 420 || return 1
  if ! up_svc --no-deps cfg-web cgw-web events-web txs-web txs-scheduler \
       txs-worker-contracts-tokens txs-worker-notifications-webhooks; then
    echo "    ABORTING: could not recreate the services" >&2; return 1
  fi
  wait_healthy 420 || return 1
  if [ "${UI_REAL:-0}" = 1 ]; then
    up_svc --no-deps --force-recreate ui || return 1
    wait_healthy 180 || return 1
  fi

  # Three steps that are easy to miss and make a good upgrade look broken:
  #  1. nginx resolves upstream IPs once, at config load. Recreated containers get new IPs, so
  #     nginx keeps dialling the old ones and returns 502 until it is reloaded. (Services reached
  #     over the shared unix sockets -- txs, cfg -- are unaffected.)
  #  2. The transaction service caches its /about response in Redis, so it keeps reporting the
  #     PREVIOUS version after an upgrade. Without flushing, a version check reads a stale value.
  #  3. Verify against the running image, not only the HTTP response.
  echo "==> reloading nginx (recreated containers have new IPs)"
  C exec -T nginx nginx -s reload 2>&1 | sed 's/^/    /' || true
  echo "==> flushing the transaction-service cache (its /about response is cached)"
  C exec -T txs-redis redis-cli FLUSHALL 2>&1 | sed 's/^/    /' || true
  sleep 8
  assert_versions "$vf"
}

# The upgrade is only real if the services now REPORT the requested versions. Without this the
# harness happily "passes" an upgrade in which nothing was replaced.
assert_versions() {
  local vf=$1 base="http://localhost:$PORT" bad=0
  local want_txs want_cfg want_cgw got
  want_txs=$(sed -n 's/^TXS_VERSION=//p' "$vf" | head -1)
  want_cfg=$(sed -n 's/^CFG_VERSION=//p' "$vf" | head -1)
  want_cgw=$(sed -n 's/^CGW_VERSION=//p' "$vf" | head -1)
  echo "==> verifying the running versions match the requested set"
  check() {
    local label=$1 url=$2 want=$3
    got=$(svc_version "$url")
    # Services report with and without the leading "v" inconsistently.
    if [ "${got#v}" = "${want#v}" ]; then
      printf '    ok   %-8s %s\n' "$label" "$got"
    else
      printf '    FAIL %-8s running %s, expected %s\n' "$label" "${got:-<none>}" "$want"
      bad=$((bad+1))
    fi
  }
  # The image the container is actually running: authoritative, and not subject to caching or
  # proxy staleness.
  check_image() {
    local svc=$1 want=$2 img tag
    img=$(C ps -q "$svc" 2>/dev/null | head -1)
    img=$(docker inspect "$img" --format '{{.Config.Image}}' 2>/dev/null)
    tag=$(image_tag "$img")
    if [ "$tag" = "$want" ] || [ "$tag" = "${want#v}" ]; then
      printf '    ok   %-14s image %s\n' "$svc" "$img"
    else
      printf '    FAIL %-14s image %s, expected tag %s\n' "$svc" "${img:-<none>}" "$want"
      bad=$((bad+1))
    fi
  }
  check_image txs-web "$want_txs"
  check_image cfg-web "$want_cfg"
  check_image cgw-web "$want_cgw"
  check_image txs-worker-indexer "$want_txs"
  # The UI carries no version endpoint and no meaningful tag, so verify the base image its
  # bundle was built from -- the value the version set actually pins.
  if [ "${UI_REAL:-0}" = 1 ]; then
    local want_base got_base uiid
    want_base=$(sed -n 's/^UI_BASE_IMAGE=//p' "$vf" | head -1)
    uiid=$(C ps -q ui 2>/dev/null | head -1)
    got_base=$(docker inspect "$uiid" --format '{{index .Config.Labels "irys.base-image"}}' 2>/dev/null)
    if [ -n "$want_base" ] && [ "$got_base" = "$want_base" ]; then
      printf '    ok   %-14s base %s\n' ui "$got_base"
    else
      printf '    FAIL %-14s base %s, expected %s\n' ui "${got_base:-<none>}" "${want_base:-<unset>}"
      bad=$((bad+1))
    fi
  fi
  # What the services report over HTTP, which is what clients actually see.
  check txs "$(about_url txs "$base")" "$want_txs"
  check cfg "$(about_url cfg "$base")" "$want_cfg"
  check cgw "$(about_url cgw "$base")" "$want_cgw"
  if [ "$bad" -gt 0 ]; then
    echo "    UPGRADE DID NOT TAKE EFFECT ($bad service(s) still on the old version)" >&2
    return 1
  fi
}

cmd_down() {
  assert_test_dir
  echo "==> tearing down $PROJECT (including databases)"
  C down -v --remove-orphans 2>&1 | tail -3 | sed 's/^/    /'
  if [ -d "$TEST_DIR/data" ]; then
    echo "==> removing bind-mounted ./data (container-owned; needs a container to delete)"
    reset_data
    rmdir "$TEST_DIR/data" 2>/dev/null
  fi
}

# Empty the bind-mounted ./data. The files are container-owned (root inside the containers),
# so deleting them needs a container. Used by `down` and before a fresh `up`, so a stale
# volume cannot poison the run.
reset_data() {
  assert_test_dir
  [ -d "$TEST_DIR/data" ] || return 0
  docker run --rm -v "$TEST_DIR/data:/d" alpine:3 sh -c 'rm -rf /d/* /d/.[!.]* 2>/dev/null; true'
}

# --- snapshot / diff ---------------------------------------------------------------------
psql_q() { C exec -T "$1" psql -U postgres -d postgres -tA -c "$2" 2>/dev/null; }

cmd_snapshot() {
  local out=${1:?usage: snapshot <out.json>}
  have_py
  echo "==> snapshotting the running test stack" >&2
  local base="http://localhost:$PORT"
  {
    echo "{"
    echo "  \"captured\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"versions\": {"
    echo "    \"txs\": \"$(svc_version "$(about_url txs "$base")" 15)\","
    echo "    \"cfg\": \"$(svc_version "$(about_url cfg "$base")" 15)\","
    echo "    \"cgw\": \"$(svc_version "$(about_url cgw "$base")" 15)\""
    echo "  },"
    echo "  \"migrations\": {"
    echo "    \"txs\": $(psql_q txs-db 'select count(*) from django_migrations' | tr -d '[:space:]' || echo 0),"
    echo "    \"cfg\": $(psql_q cfg-db 'select count(*) from django_migrations' | tr -d '[:space:]' || echo 0)"
    echo "  },"
    echo "  \"rows\": {"
    echo "    \"safe_master_copies\": $(psql_q txs-db 'select count(*) from history_safemastercopy' | tr -d '[:space:]' || echo 0),"
    echo "    \"proxy_factories\": $(psql_q txs-db 'select count(*) from history_proxyfactory' | tr -d '[:space:]' || echo 0),"
    echo "    \"safes\": $(psql_q txs-db 'select count(*) from history_safecontract' | tr -d '[:space:]' || echo 0),"
    echo "    \"multisig_txs\": $(psql_q txs-db 'select count(*) from history_multisigtransaction' | tr -d '[:space:]' || echo 0),"
    echo "    \"chains\": $(psql_q cfg-db 'select count(*) from chains_chain' | tr -d '[:space:]' || echo 0),"
    echo "    \"features\": $(psql_q cfg-db 'select count(*) from chains_feature' | tr -d '[:space:]' || echo 0),"
    echo "    \"webhooks\": $(psql_q events-db 'select count(*) from webhook' | tr -d '[:space:]' || echo 0)"
    echo "  },"
    echo "  \"chain_config\": $(curl -sSL --max-time 20 "$base/cfg/api/v1/chains" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("null"); sys.exit()
r=(d.get("results") or [d])
out=[]
for c in r:
    out.append({"chainId":c.get("chainId"),"recommendedMasterCopyVersion":c.get("recommendedMasterCopyVersion"),
                "contractAddresses":c.get("contractAddresses"),"rpcUri":(c.get("rpcUri") or {}).get("value"),
                "transactionService":c.get("transactionService")})
print(json.dumps(out,sort_keys=True))
' 2>/dev/null || echo null),"
    echo "  \"safe_addresses\": $(psql_q txs-db "select coalesce(json_agg(t.a order by t.a)::text,'[]') from (select distinct '0x'||encode(address,'hex') a from history_safecontract) t" 2>/dev/null | tr -d '\n' || echo '[]')"
    echo "}"
  } > "$out"
  python3 -c "import json;d=json.load(open('$out'));print('  wrote $out');print('  versions:',d['versions']);print('  migrations:',d['migrations']);print('  rows:',d['rows'])"
}

cmd_diff() {
  local a=${1:?usage: diff <before.json> <after.json>} b=${2:?}
  have_py
  python3 - "$a" "$b" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
print(f"{'':28} {'before':>18} {'after':>18}")
print("-"*68)
def row(label, x, y, worse=None):
    flag=""
    if worse and worse(x,y): flag="  <== REGRESSION"
    print(f"{label:28} {str(x):>18} {str(y):>18}{flag}")
print("versions")
for k in a['versions']: row("  "+k, a['versions'][k], b['versions'].get(k))
# Counted from here on, so that a regression the loops FLAG is also a regression they FAIL on.
# `fails` used to be initialised after the migration loop, which meant a rehearsal that lost
# migrations printed "<== REGRESSION" and then "RESULT: PASS", exiting 0 -- the precise
# scenario this command exists to catch.
fails=0
print("migrations applied")
for k in a['migrations']:
    x=a['migrations'][k]; y=b['migrations'].get(k)
    fails += (y or 0) < (x or 0)
    row("  "+k, x, y, lambda p,q: (q or 0) < (p or 0))
print("row counts")
for k in a['rows']:
    x=a['rows'][k]; y=b['rows'].get(k)
    lost=(y or 0) < (x or 0)
    fails+=lost
    row("  "+k, x, y, lambda p,q: (q or 0) < (p or 0))
print()
sa=set(a.get('safe_addresses') or []); sb=set(b.get('safe_addresses') or [])
missing=sorted(sa-sb)
print(f"indexed Safes: before={len(sa)} after={len(sb)}")
if missing:
    fails+=1
    print("  LOST:", ", ".join(missing))
ca=json.dumps(a.get('chain_config'),sort_keys=True); cb=json.dumps(b.get('chain_config'),sort_keys=True)
same = ca==cb
print(f"chain config identical: {same}")
if not same:
    print("  before:", ca[:300]); print("  after :", cb[:300])
print()
if fails or missing or not same:
    print("RESULT: FAIL -- the upgrade changed or lost state; investigate before deploying.")
    sys.exit(1)
print("RESULT: PASS -- migrations advanced and no state was lost.")
PY
}

# Sourcing this file defines its functions without running a command, so the tests can exercise
# them directly (tests/test_*.sh do). Executing it dispatches as usual.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
  probe)      shift; cmd_probe "$@" ;;
  probe-host) shift; cmd_probe_host "$@" ;;
  latest)   shift; cmd_latest "$@" ;;
  plan)     shift; cmd_plan "$@" ;;
  up)       shift; cmd_up "$@" ;;
  upgrade)  shift; cmd_upgrade "$@" ;;
  snapshot) shift; cmd_snapshot "$@" ;;
  diff)     shift; cmd_diff "$@" ;;
  down)     shift; cmd_down "$@" ;;
  *) usage "$0"; exit 1 ;;
esac
