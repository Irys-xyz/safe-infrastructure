#!/usr/bin/env bash
#
# Print the digests of the images this stack actually has, formatted for pasting into
# ansible/vars.yml (or, with --env, the repo-root .env).
#
# Why: a tag like `latest` or `14-alpine` is mutable. Whatever the registry served at first
# pull is what you run -- with no record of which build it was and no way to reproduce it on a
# rebuild or a fresh host. A digest is content-addressed, so pinning one gets you the exact
# image you validated. That matters most for the wallet UI base image, which is the code that
# builds, decodes and displays the transactions Safe owners are asked to sign.
#
# Usage (on the deployment host, after a bring-up you have smoke-tested):
#   bash scripts/pin_image_digests.sh          # ansible/vars.yml lines
#   bash scripts/pin_image_digests.sh --env    # repo-root .env lines
#
# Paste the output into vars.yml, then redeploy. Re-run after any deliberate image upgrade.

set -o pipefail
cd "$(dirname "$0")/.." || { echo "error: cannot cd to the repo root" >&2; exit 1; }

# Load .env: UI_BASE_IMAGE lives there (Ansible renders it from irys_ui_base_image), and
# without it this script fell back to :latest and could report the digest of a *different*
# wallet build from the one the stack is actually running -- the one pin that most needs to
# be right, since that image renders what owners are asked to sign.
set -a
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
set +a

MODE="${1:-vars}"
RUNTIME=$(command -v podman || command -v docker) || {
  echo "error: neither podman nor docker found" >&2
  exit 1
}

# repository | ansible var stem | .env var stem
MAPPING='safeglobal/safe-transaction-service|txs|TXS
safeglobal/safe-config-service|cfg|CFG
safeglobal/safe-client-gateway-nest|cgw|CGW
safeglobal/safe-events-service|events|EVENTS
postgres|postgres|POSTGRES
redis|redis|REDIS
rabbitmq|rabbitmq|RABBITMQ
nginx|nginx|NGINX'

# Local images as "repository:tag", newest first. Both runtimes list newest-first by default,
# so dedupe without sorting -- `sort -u` here made the "newest" selection below lexicographic
# instead, which picks postgres:14-alpine over postgres:17-bookworm.
local_images() {
  "$RUNTIME" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -v '<none>' | awk '!seen[$0]++'
}

# Registry digest an image was pulled by.
digest_of() {
  "$RUNTIME" image inspect "$1" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\).*/\1/p' | head -1
}

# Prefer the image a running container of this stack uses; otherwise the newest local image
# for the repository.
#
# Match on the repository component with the registry prefix ignored, but print the reference
# exactly as the runtime reported it, since that is what `image inspect` is given.
#
# The prefix to ignore includes the implicit `library/` namespace podman spells out: it reports
# official images as `docker.io/library/postgres:14-alpine`, and matching that against
# `^postgres:` fails. Stripping only `docker.io/` left `library/` behind, so postgres, redis,
# rabbitmq and nginx matched nothing on the production runtime and four of the eight digests
# this script exists to emit were silently skipped.
match_repo() {
  awk -v repo="$1" -v anchored="$2" '
    { s = $0
      sub(/^docker\.io\//, "", s)
      sub(/^library\//, "", s)
      if (s ~ "^" repo (anchored ? ":" : "([:@]|$)")) print $0 }'
}

resolve_ref() {
  local repo=$1 ref
  ref=$("$RUNTIME" ps --format '{{.Image}}' 2>/dev/null | match_repo "$repo" "" | head -1)
  [ -n "$ref" ] && { echo "$ref"; return; }
  local_images | match_repo "$repo" 1 | head -1
}

echo "# Image digest pins captured $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname)"
if [ "$MODE" = "--env" ]; then
  echo "# Paste into the repo-root .env (or set the ansible vars and redeploy)"
else
  echo "# Paste into ansible/vars.yml"
fi

missing=0
while IFS='|' read -r repo avar evar; do
  [ -n "$repo" ] || continue
  ref=$(resolve_ref "$repo")
  if [ -z "$ref" ]; then
    echo "# WARN: no local image for $repo — bring the stack up first" >&2
    missing=$((missing + 1))
    continue
  fi
  d=$(digest_of "$ref")
  if [ -z "$d" ]; then
    echo "# WARN: $ref has no registry digest — run '$RUNTIME pull $ref', then re-run" >&2
    missing=$((missing + 1))
    continue
  fi
  if [ "$MODE" = "--env" ]; then
    echo "${evar}_DIGEST=@${d}"
  else
    echo "irys_${avar}_digest: \"@${d}\""
  fi
done <<<"$MAPPING"

# The UI base image is pinned as a full reference, not a bare digest suffix.
base_ref="${UI_BASE_IMAGE:-docker.io/safeglobal/safe-wallet-web:latest}"
base_repo=${base_ref#docker.io/}
base_repo=${base_repo%%@*}
base_repo=${base_repo%%:*}
base_d=$(digest_of "$base_ref")
[ -n "$base_d" ] || base_d=$(digest_of "$(resolve_ref "$base_repo")")
if [ -n "$base_d" ]; then
  if [ "$MODE" = "--env" ]; then
    echo "UI_BASE_IMAGE=${base_repo}@${base_d}"
  else
    echo "irys_ui_base_image: ${base_repo}@${base_d}"
  fi
else
  echo "# WARN: no digest for the UI base image ($base_ref) — pull it, then re-run" >&2
  missing=$((missing + 1))
fi

if [ "$missing" -gt 0 ]; then
  echo "# $missing image(s) had no digest — see warnings above" >&2
fi
