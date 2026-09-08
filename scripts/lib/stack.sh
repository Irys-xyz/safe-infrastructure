# Shared helpers for the stack scripts. Source it, do not execute it:
#
#   . "$(dirname "$0")/lib/stack.sh"
#
# Kept in one place because the two callers (configure_irys.sh, db_backup.sh) previously each
# carried their own copy of `cname`, with *different* failure semantics -- one returned 1, the
# other echoed a guessed name and returned 0. Two conventions under one name is how a caller
# ends up running `$RUNTIME exec ""`.

# The container runtime to use. Production is rootless podman; the local test path (RUNBOOK
# section 13) is docker compose. Exits rather than returning an empty string: `basename ""` is
# "", and every later `$RUNTIME exec ...` would then word-split into an unrelated command.
resolve_runtime() {
  local rt="${CONTAINER_RUNTIME:-}"
  if [ -z "$rt" ]; then
    rt=$(command -v podman || command -v docker) || {
      echo "error: neither podman nor docker found (set CONTAINER_RUNTIME)" >&2; exit 1; }
  fi
  basename "$rt"
}

# Resolve a compose service to a container id or name, on stdout. Returns 1 (printing nothing)
# when the service has no container, so callers can report which service is missing.
# Asks compose first -- authoritative and naming-scheme agnostic -- then falls back to both
# conventional names (podman-compose: project_service_1, docker compose v2: project-service-1)
# so it still works when compose itself cannot be reached.
cname() {
  local svc=$1 id proj n
  id=$($COMPOSE_CMD ps -q "$svc" 2>/dev/null | head -1)
  [ -n "$id" ] && { echo "$id"; return 0; }
  proj="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
  for n in "${proj}_${svc}_1" "${proj}-${svc}-1"; do
    $RUNTIME inspect "$n" >/dev/null 2>&1 && { echo "$n"; return 0; }
  done
  return 1
}

# The leading comment block of a script, as usage text. Replaces a hand-maintained
# `sed -n '3,NNp'` range, which silently truncates or over-prints whenever the header's length
# changes -- all four callers had drifted.
usage() { awk 'NR<3{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$1"; }

# Chain id this deployment is configured for. 3282 is Irys Mainnet; a local fork can run under
# another id so it does not collide with the real network in a browser wallet (RUNBOOK section
# 13). Defined once because the literal default was repeated in every script that bakes it into
# an image, configures it or names a file after it -- and one of them had already been missed,
# so a UI built for 3282 was served against a fork on another id.
chain_id() { echo "${IRYS_CHAIN_ID:-3282}"; }
