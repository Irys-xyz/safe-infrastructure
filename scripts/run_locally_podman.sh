#!/usr/bin/env bash
#
# Bring up the self-hosted Safe stack under podman-compose.
#
# podman-compose (1.5.x) does not honour `depends_on: condition: service_healthy`:
# a plain `docker compose up -d` only creates the services that have no
# dependencies and silently skips the rest. This script works around that by
# starting services one at a time with `--no-deps`, in dependency order, waiting
# for each tier to become ready before starting the next.
#
# Unlike scripts/run_locally.sh it does NOT run `docker compose down -v`, so it
# is safe to re-run against a live stack: it only starts what is missing and
# leaves database volumes intact.
#   Stop the stack:            docker compose down
#   Stop and wipe databases:   docker compose down -v
#
# Admin users are created non-interactively when credentials are set in .env
# (gitignored); otherwise the step is skipped:
#   CFG_SUPERUSER_USERNAME / CFG_SUPERUSER_EMAIL / CFG_SUPERUSER_PASSWORD
#   TXS_SUPERUSER_USERNAME / TXS_SUPERUSER_EMAIL / TXS_SUPERUSER_PASSWORD

set -o pipefail

cd "$(dirname "$0")/.."

# Load .env so COMPOSE_PROJECT_NAME, REVERSE_PROXY_PORT and the optional
# *_SUPERUSER_* variables are visible to this script (compose reads it too).
set -a
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
set +a

COMPOSE="docker compose"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
PORT="${REVERSE_PROXY_PORT:-8000}"

cname() { echo "${PROJECT}_$1_1"; }

# Pull only images that are missing, untimed. The UI image (safe-wallet-web) is
# ~1.6 GB; a pull truncated by a timeout leaves the ui service unable to start.
ensure_images() {
  echo "==> Ensuring images are present (first run pulls several GB)..."
  # The custom Irys UI image (chain 3282 in safe-deployments) has no remote to pull from; build it.
  # The wallet's Client Gateway path is baked into the static export at build time (UI_GATEWAY_URL,
  # default the relative /cgw so the UI is same-origin on whatever host the stack is reached on; set
  # it in .env / Ansible vars.yml to an absolute URL only for a gateway on a different origin).
  # Rebuild when the image is missing OR when its baked gateway differs from the requested one, so a
  # change actually takes effect.
  UI_REBUILT=0
  local ui_img=localhost/safe-wallet-web-irys:3282
  local ui_gw="${UI_GATEWAY_URL:-/cgw}"
  local ui_baked
  ui_baked=$(podman image inspect "$ui_img" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
               | sed -n 's/^NEXT_PUBLIC_GATEWAY_URL_PRODUCTION=//p')
  if [ "$ui_baked" != "$ui_gw" ]; then
    echo "    building  $ui_img (gateway $ui_gw)"
    if podman build -t "$ui_img" --build-arg "NEXT_PUBLIC_GATEWAY_URL_PRODUCTION=$ui_gw" \
         -f docker/ui-irys.Dockerfile .; then
      UI_REBUILT=1
    else
      echo "    WARN: failed to build the custom UI image"
    fi
  else
    echo "    present  $ui_img (gateway $ui_gw)"
  fi
  $COMPOSE config 2>/dev/null | awk '$1=="image:"{print $2}' | sort -u | while read -r img; do
    [ -n "$img" ] || continue
    if podman image exists "$img" 2>/dev/null; then
      echo "    present  $img"
    else
      echo "    pulling  $img"
      podman pull "$img" || echo "    WARN: failed to pull $img"
    fi
  done
}

# Start one service without processing its depends_on. Retries once if the
# container exits immediately (rabbitmq can lose an Erlang-cookie race on first
# boot and comes up on a second attempt).
start() {
  local svc=$1 c st
  c=$(cname "$svc")
  # Skip services that are already running so re-runs against a live stack do not
  # recreate them. podman-compose's `up` recreates on every call, which reassigns
  # container IPs (breaking nginx's cached upstreams) and restarts the RabbitMQ
  # brokers (erlang-cookie race). The ui no longer builds at start (its image bakes
  # `next build` at image-build time), so re-running does not retrigger a UI build.
  st=$(podman inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  if [ "$st" = running ]; then
    echo "--> $svc already running — skipping"
    return 0
  fi
  echo "--> starting $svc"
  $COMPOSE up -d --no-deps "$svc" 2>&1 | grep -vE 'external compose provider|^[[:space:]]*$' || true
  sleep 2
  st=$(podman inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  if [ "$st" = exited ] || [ "$st" = missing ]; then
    echo "    $svc is '$st' — retrying once"
    $COMPOSE up -d --no-deps "$svc" 2>&1 | grep -vE 'external compose provider|^[[:space:]]*$' || true
    sleep 2
  fi
}

# Wait for a service to be ready: "healthy" if it defines a healthcheck,
# otherwise "running". Warns and continues on timeout rather than aborting.
wait_ready() {
  local svc=$1 timeout=${2:-180} c st has end
  c=$(cname "$svc")
  end=$((SECONDS + timeout))
  while [ $SECONDS -lt $end ]; do
    has=$(podman inspect -f '{{if .State.Health}}yes{{end}}' "$c" 2>/dev/null || true)
    if [ "$has" = yes ]; then
      st=$(podman inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || true)
      [ "$st" = healthy ] && { echo "    ready: $svc (healthy)"; return 0; }
    else
      st=$(podman inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)
      [ "$st" = running ] && { echo "    ready: $svc (running)"; return 0; }
    fi
    sleep 3
  done
  echo "    WARN: $svc still '$st' after ${timeout}s — continuing"
}

# Create a Django superuser non-interactively, if credentials are configured.
create_superuser() {
  local svc=$1 manage=$2 pfx=$3 c uvar evar pvar u e p
  c=$(cname "$svc")
  uvar="${pfx}_SUPERUSER_USERNAME"; evar="${pfx}_SUPERUSER_EMAIL"; pvar="${pfx}_SUPERUSER_PASSWORD"
  u="${!uvar:-}"; e="${!evar:-}"; p="${!pvar:-}"
  if [ -z "$u" ] || [ -z "$p" ]; then
    echo "    skip $svc superuser (set ${uvar}/${evar}/${pvar} in .env to auto-create)"
    return 0
  fi
  podman exec \
    -e DJANGO_SUPERUSER_USERNAME="$u" \
    -e DJANGO_SUPERUSER_EMAIL="$e" \
    -e DJANGO_SUPERUSER_PASSWORD="$p" \
    "$c" python "$manage" createsuperuser --noinput 2>&1 \
    | grep -viE 'already (taken|exists)|is already' || true
  echo "    $svc superuser ensured ($u)"
}

ensure_images

echo "==> Tier 1: databases, caches, brokers"
for s in txs-db cfg-db events-db cgw-db txs-redis cgw-redis txs-rabbitmq general-rabbitmq; do start "$s"; done
for s in txs-db cfg-db events-db cgw-db txs-redis cgw-redis txs-rabbitmq general-rabbitmq; do wait_ready "$s" 120; done

echo "==> Tier 2: indexer (runs DB migrations), then config / gateway / events / ui"
start txs-worker-indexer
wait_ready txs-worker-indexer 300
for s in cfg-web cgw-web events-web; do start "$s"; done
# Recreate ui when its image was just (re)built so the new bundle (and any changed gateway
# URL) is served; otherwise start normally (skipped if already running).
if [ "${UI_REBUILT:-0}" = 1 ]; then
  echo "--> starting ui (force-recreate: image changed)"
  $COMPOSE up -d --no-deps --force-recreate ui 2>&1 | grep -vE 'external compose provider|^[[:space:]]*$' || true
else
  start ui
fi

echo "==> Tier 3: transaction web, scheduler, workers"
for s in txs-web txs-scheduler txs-worker-contracts-tokens txs-worker-notifications-webhooks; do start "$s"; done

echo "==> Tier 4: nginx reverse proxy"
start nginx

echo "==> Admin users"
create_superuser cfg-web "src/manage.py" CFG
create_superuser txs-web "manage.py" TXS

echo "==> Applying Irys Safe configuration (chain 3282, contracts, services, webhook)"
bash "$(dirname "$0")/configure_irys.sh" || echo "    WARN: Irys configuration step reported an error"

echo "==> Verifying endpoints on http://localhost:${PORT}"
for u in /cfg/api/v1/about/ /txs/api/v1/about/ /cgw/about /; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:${PORT}${u}" 2>/dev/null)
  printf '    %-4s %s\n' "$code" "$u"
done

echo
echo "Done. Wallet UI at http://localhost:8080  (admin/APIs at http://localhost:${PORT})"
echo "If the UI is blank/502, give the stack a few seconds to settle, then reload (see RUNBOOK §11 if it persists)."
echo "Chain 3282, the v1.5.0 contracts, the WALLET_WEB service, and the Events webhook were configured automatically."
