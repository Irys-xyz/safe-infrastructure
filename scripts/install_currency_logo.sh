#!/usr/bin/env bash
#
# Install the native-currency icon the wallet shows next to IRYS balances.
#
# The Config Service stores chain and currency images in MEDIA_ROOT and serves them under
# ${MEDIA_URL}. docker-compose.yml mounts MEDIA_ROOT from ./data/cfg-media, so what this
# installs survives a container recreate -- it did not before, which is why the icon
# disappeared and the wallet rendered IRYS as a generic unnamed token.
#
# Usage (from the stack directory, as the stack user):
#   bash scripts/install_currency_logo.sh [path-to-png]
#
# With no argument it installs assets/irys_currency.png from this repo. If that is missing it
# falls back to downloading the icon once. Either way the file is then served from our own
# origin, so the wallet never loads an image from a third party at runtime.
#
# Re-run after changing IRYS_CHAIN_ID; the path is per-chain.

set -o pipefail
cd "$(dirname "$0")/.."

CHAIN_ID="${IRYS_CHAIN_ID:-3282}"
MEDIA_DIR="${CFG_MEDIA_DIR:-./data/cfg-media}"
DEST_REL="chains/${CHAIN_ID}/irys_currency.png"
DEST="${MEDIA_DIR}/${DEST_REL}"
# Source, in order of preference: an explicit argument, the icon bundled in this repo, then
# a download. The bundled copy is the normal path -- it makes the result reproducible and
# means no third party is involved at deploy time, let alone at page-load time.
BUNDLED="assets/irys_currency.png"
SRC="${1:-}"
if [ -z "$SRC" ] && [ -f "$BUNDLED" ]; then
  SRC="$BUNDLED"
  echo "using the icon bundled in this repo: $BUNDLED"
fi
# Only reached if the bundled asset is missing. Pinned CoinGecko image for coin id `irys`.
FALLBACK_URL="${CURRENCY_LOGO_URL:-https://coin-images.coingecko.com/coins/images/70808/large/irys.png}"

if ! mkdir -p "$(dirname "$DEST")" 2>/dev/null; then
  echo "error: cannot create $(dirname "$DEST")" >&2
  echo "  The media directory is created by the container runtime when it mounts the volume," >&2
  echo "  so it is owned by root. Give the stack user ownership once:" >&2
  echo "    sudo chown -R \$(id -u):\$(id -g) $MEDIA_DIR" >&2
  exit 1
fi
if ! : > "$(dirname "$DEST")/.writetest" 2>/dev/null; then
  echo "error: $(dirname "$DEST") is not writable by $(id -un)" >&2
  echo "    sudo chown -R \$(id -u):\$(id -g) $MEDIA_DIR" >&2
  exit 1
fi
rm -f "$(dirname "$DEST")/.writetest"

if [ -n "$SRC" ]; then
  [ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }
  cp "$SRC" "$DEST" 2>/dev/null || { echo "error: could not write $DEST" >&2; exit 1; }
  sz=$(wc -c < "$DEST" 2>/dev/null || echo 0)
  [ "${sz:-0}" -gt 0 ] || { echo "error: $DEST is empty — write failed" >&2; exit 1; }
  echo "installed $SRC -> $DEST ($sz bytes)"
else
  echo "fetching the icon from $FALLBACK_URL"
  tmp=$(mktemp)
  if ! curl -fsSL --max-time 60 -H 'User-Agent: curl/8' "$FALLBACK_URL" -o "$tmp"; then
    echo "error: download failed. Pass a local PNG instead:" >&2
    echo "  bash scripts/install_currency_logo.sh /path/to/irys.png" >&2
    rm -f "$tmp"; exit 1
  fi
  # Reject anything that is not actually a PNG -- an HTML error page written here would be
  # served to the wallet as the currency icon.
  if [ "$(head -c8 "$tmp" | od -An -tx1 | tr -d ' \n')" != "89504e470d0a1a0a" ]; then
    echo "error: downloaded file is not a PNG (got $(file -b "$tmp" 2>/dev/null || echo unknown))" >&2
    rm -f "$tmp"; exit 1
  fi
  if ! mv "$tmp" "$DEST" 2>/dev/null; then
    echo "error: could not write $DEST" >&2; rm -f "$tmp"; exit 1
  fi
  chmod 644 "$DEST" 2>/dev/null || true
  sz=$(wc -c < "$DEST" 2>/dev/null || echo 0)
  [ "${sz:-0}" -gt 1000 ] || { echo "error: $DEST is ${sz} bytes — write failed" >&2; exit 1; }
  echo "installed -> $DEST ($sz bytes)"
fi

echo
echo "Now re-run the chain configuration so the Config Service points at it:"
echo "    bash scripts/configure_irys.sh"
echo "Then flush the gateway cache so the wallet picks up the new chain config:"
echo "    docker compose exec -T cgw-redis redis-cli FLUSHALL"
