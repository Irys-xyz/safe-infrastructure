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
cd "$(dirname "$0")/.."

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

# All local images as "repository:tag <digest>", digest empty when the image was not pulled
# from a registry (e.g. the locally built UI image, which is pinned via its base instead).
local_images() {
  "$RUNTIME" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | sort -u
}

# Registry digest an image was pulled by.
digest_of() {
  "$RUNTIME" image inspect "$1" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\).*/\1/p' | head -1
}

# Prefer the image a running container of this stack uses; otherwise the newest local image
# for the repository. Strips any registry prefix so docker.io/foo and foo both match.
resolve_ref() {
  local repo=$1 ref
  ref=$("$RUNTIME" ps --format '{{.Image}}' 2>/dev/null \
          | sed 's#^docker\.io/##' | grep -E "^${repo}(:|@|$)" | head -1)
  [ -n "$ref" ] && { echo "$ref"; return; }
  local_images | sed 's#^docker\.io/##' | grep -E "^${repo}:" | head -1
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
