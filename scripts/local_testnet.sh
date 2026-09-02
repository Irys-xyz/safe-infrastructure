#!/usr/bin/env bash
#
# Disposable local Irys chain for testing, as an anvil fork. See RUNBOOK section 13.
#
# Forking rather than starting a bare chain is the whole point: Safe's contracts live at
# deterministic CREATE2 addresses, and a fresh anvil has none of them. A fork of Irys already
# contains all 13 v1.5.0 contracts at exactly the addresses this stack is configured with, and
# keeps chain id 3282 -- so nothing else needs changing to test against it.
#
# This runs anvil ALONE (no Safe stack) on 127.0.0.1:8546, which is the quick way to check what
# a transaction actually does. To run the full stack against it instead, use the compose overlay:
#   docker compose -f docker-compose.yml -f docker-compose.local-chain.yml up -d anvil
#
# Nothing here can affect Irys Mainnet: anvil never broadcasts, and all writes stay local.
#
#   start           fork at (tip - LOCAL_FORK_LAG, default 10) on 127.0.0.1:8546 and print the
#                   block, so the run is concrete and can be reproduced exactly
#   start <block>   fork at that block
#   start tip       fork at the current tip, unpinned (a different block every run)
#   stop            remove the fork and discard all local state
#   status          is it running, at what block
#   accounts        the deterministic funded test accounts and their private keys
#   verify          run scripts/verify_deployments.py against the fork
#   create-safe [threshold] [owner...]
#                   deploy a Safe through the real canonical proxy factory and print its state
#
# Requires docker or podman. No local foundry install needed -- cast runs in the image.

set -o pipefail
cd "$(dirname "$0")/.."

NAME=irys-anvil-local
PORT=8546
RPC="http://localhost:${PORT}"
IMAGE=ghcr.io/foundry-rs/foundry:latest
UPSTREAM="${LOCAL_FORK_RPC:-https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc}"
# Chain id the fork serves. 3282 is Irys Mainnet; set IRYS_CHAIN_ID to something else so the
# fork does not collide with the real network in a browser wallet (and build the UI image with
# the same value -- it is baked in).
CHAIN_ID="${IRYS_CHAIN_ID:-3282}"
# Seconds between blocks. Default 9, matching measured Irys Mainnet (~8.8 s/block).
# Without an interval anvil mines only when a transaction arrives, so the head
# freezes right after inclusion and anything awaiting confirmations hangs forever (the wallet's
# "Activating your account" step does). Real chains mine continuously; match that.
BLOCK_TIME="${LOCAL_BLOCK_TIME:-9}"

# Canonical Safe v1.5.0 on chain 3282 (verified on-chain; see scripts/verify_deployments.py).
SINGLETON=0xEdd160fEBBD92E350D4D398fb636302fccd67C7e
FACTORY=0x14F2982D601c9458F93bd70B218933A6f8165e7b
FALLBACK=0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4
ZERO=0x0000000000000000000000000000000000000000

# anvil's published deterministic accounts. Test-only: these keys are in anvil's source.
KEY0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ACC0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ACC1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
ACC2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

RT=$(command -v docker || command -v podman) || { echo "error: need docker or podman" >&2; exit 1; }

rpc() { timeout 10 curl -sS -X POST "$RPC" -H 'Content-Type: application/json' \
          -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" 2>/dev/null; }
# Same, but against the chain being forked (used to resolve a concrete fork block).
up_rpc() { timeout 15 curl -sS -X POST "$UPSTREAM" -H 'Content-Type: application/json' \
             -H 'User-Agent: curl/8' \
             -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" 2>/dev/null; }
hexnum() { sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p'; }
# cast in a throwaway container; --network host so it can reach the fork on loopback.
cast() { "$RT" run --rm --network host --entrypoint cast "$IMAGE" "$@"; }
running() { "$RT" inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true; }

case "${1:-}" in
  start)
    if running; then echo "already running at $RPC (use '$0 stop' first to reset)"; exit 0; fi
    "$RT" rm -f "$NAME" >/dev/null 2>&1
    args="--fork-url=$UPSTREAM --chain-id=$CHAIN_ID --host=0.0.0.0 --accounts=10 --balance=10000 --block-time $BLOCK_TIME"
    want="${2:-}"
    if [ "$want" = tip ]; then
      # Explicitly unpinned: anvil resolves the tip itself. Different block every run.
      echo "forking $UPSTREAM at current tip (unpinned — not reproducible)"
    elif [ -n "$want" ]; then
      args="$args --fork-block-number=$want"
      echo "forking $UPSTREAM at block $want"
    else
      # No block given: resolve one now so the run is concrete and repeatable.
      lag="${LOCAL_FORK_LAG:-10}"
      tip=$(up_rpc eth_blockNumber | hexnum)
      if [ -n "$tip" ]; then
        want=$(( tip - lag ))
        [ "$want" -lt 1 ] && want=1
        args="$args --fork-block-number=$want"
        echo "forking $UPSTREAM at block $want (tip $((tip)) minus LOCAL_FORK_LAG=$lag)"
        echo "  re-run '$0 start $want' to reproduce this exact state"
      else
        echo "WARN: could not read the tip from $UPSTREAM — forking unpinned" >&2
      fi
    fi
    # shellcheck disable=SC2086
    "$RT" run -d --name "$NAME" -p "127.0.0.1:${PORT}:8545" --entrypoint anvil "$IMAGE" $args >/dev/null
    printf 'waiting for the fork'
    for _ in $(seq 1 40); do
      [ -n "$(rpc eth_chainId)" ] && { echo; break; }
      printf '.'; sleep 1
    done
    if [ -z "$(rpc eth_chainId)" ]; then
      echo; echo "FAILED to start. Logs:"; "$RT" logs "$NAME" 2>&1 | tail -20; exit 1
    fi
    bn=$(rpc eth_blockNumber | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
    echo "ready: chain $CHAIN_ID at $RPC (block $((bn)) )"
    echo "Point the stack at it with, in .env:"
    echo "    RPC_NODE_URL=http://anvil:8545          # services, via the compose overlay"
    echo "    PUBLIC_RPC_NODE_URL=$RPC   # the browser / MetaMask"
    echo "Then: $0 accounts   |   $0 verify   |   $0 create-safe"
    ;;

  stop)
    if "$RT" inspect "$NAME" >/dev/null 2>&1; then
      "$RT" rm -f "$NAME" >/dev/null 2>&1
      echo "stopped; all local chain state discarded"
    else
      echo "not running"
    fi
    ;;

  status)
    if running; then
      bn=$(rpc eth_blockNumber | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
      cid=$(rpc eth_chainId | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
      echo "running at $RPC  chainId=$((cid))  block=$((bn))"
    else
      echo "not running"
    fi
    ;;

  accounts)
    echo "Deterministic anvil accounts (TEST ONLY -- these private keys are public):"
    printf '  %-44s %s\n' "$ACC0" "$KEY0"
    echo "  ...plus 9 more; see '$RT logs $NAME' for the full list."
    echo
    echo "In MetaMask: add a network with RPC $RPC, chain id $CHAIN_ID, symbol IRYS,"
    echo "then import the key above. Those accounts are funded with 10000 IRYS on the fork."
    ;;

  verify)
    running || { echo "not running; '$0 start' first" >&2; exit 1; }
    exec python3 scripts/verify_deployments.py --rpc "$RPC" --chain-id "$CHAIN_ID"
    ;;

  create-safe)
    running || { echo "not running; '$0 start' first" >&2; exit 1; }
    threshold="${2:-2}"
    if [ -n "${3:-}" ]; then shift 2; owners=$(printf '%s,' "$@"); owners="[${owners%,}]"
    else owners="[$ACC0,$ACC1,$ACC2]"; fi
    echo "owners=$owners threshold=$threshold"
    init=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
             "$owners" "$threshold" $ZERO 0x $FALLBACK $ZERO 0 $ZERO) || exit 1
    salt=$(date +%s)
    proxy=$(cast call "$FACTORY" "createProxyWithNonce(address,bytes,uint256)(address)" \
              "$SINGLETON" "$init" "$salt" --rpc-url "$RPC" | tr -d '[:space:]') || exit 1
    echo "predicted address: $proxy"
    cast send "$FACTORY" "createProxyWithNonce(address,bytes,uint256)" \
      "$SINGLETON" "$init" "$salt" --private-key "$KEY0" --rpc-url "$RPC" >/dev/null || exit 1
    echo "deployed. state:"
    printf '  VERSION   : %s\n' "$(cast call "$proxy" 'VERSION()(string)' --rpc-url "$RPC")"
    printf '  threshold : %s\n' "$(cast call "$proxy" 'getThreshold()(uint256)' --rpc-url "$RPC")"
    printf '  owners    : %s\n' "$(cast call "$proxy" 'getOwners()(address[])' --rpc-url "$RPC")"
    printf '  nonce     : %s\n' "$(cast call "$proxy" 'nonce()(uint256)' --rpc-url "$RPC")"
    echo
    echo "Open it in a local UI as: irys-mainnet-beta:$proxy"
    ;;

  *)
    sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
