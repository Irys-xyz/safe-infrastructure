#!/bin/sh
#
# anvil entrypoint for a disposable Irys fork. Runs INSIDE the foundry image (POSIX sh, uses
# `cast`), and is the single source of the fork's defaults and block-resolution rules.
#
# Both callers run this same file, rather than each carrying its own copy:
#   docker-compose.local-chain.yml   the full Safe stack against a fork (RUNBOOK section 13)
#   scripts/local_testnet.sh         anvil alone, for quick chain-level checks
# The two copies had already drifted from each other and from the RUNBOOK, which is what this
# removes: one defaulting rule, one place to change it.
#
# Inputs (all optional):
#   LOCAL_FORK_RPC    chain to fork (default Irys Mainnet beta)
#   IRYS_CHAIN_ID     id the fork serves (default 3282 = Irys Mainnet)
#   LOCAL_BLOCK_TIME  seconds between blocks (default 9)
#   LOCAL_FORK_BLOCK  block to fork at; empty = tip minus LOCAL_FORK_LAG; `tip` = unpinned
#   LOCAL_FORK_LAG    blocks to stay behind the tip when unpinned (default 10)
set -e

RPC="${LOCAL_FORK_RPC:-https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc}"
CHAIN_ID="${IRYS_CHAIN_ID:-3282}"
# 9 seconds matches measured Irys Mainnet (~8.8 s/block), so confirmation timing behaves like
# the real chain. Mining on an interval AT ALL is the load-bearing part: by default anvil mines
# only when a transaction arrives, so the head freezes the instant one is included, and
# anything waiting for confirmations *after* inclusion then hangs forever -- the wallet's
# "Activating your account" step does exactly that, and never completes.
BLOCK_TIME="${LOCAL_BLOCK_TIME:-9}"
LAG="${LOCAL_FORK_LAG:-10}"
PIN="${LOCAL_FORK_BLOCK:-}"

# Deterministic funded test accounts: same keys every run.
# NEVER use these keys anywhere real -- they are published in anvil's source.
ARGS="--fork-url=$RPC --chain-id=$CHAIN_ID --host=0.0.0.0 --accounts=10 --balance=10000 --block-time $BLOCK_TIME"

if [ "$PIN" = tip ]; then
  # Explicitly unpinned: anvil resolves the tip itself. Different block every run.
  echo "forking $RPC at current tip (unpinned - not reproducible)"
  PIN=""
elif [ -z "$PIN" ]; then
  # Resolve a concrete block so the run is repeatable, and stay a little behind the tip: the
  # newest block is the least reliable to fork (state may not have settled, and it can still
  # be reorged away).
  TIP=$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo "")
  if [ -n "$TIP" ]; then
    PIN=$(( TIP - LAG ))
    [ "$PIN" -lt 1 ] && PIN=1
    echo "forking $RPC at block $PIN (tip $TIP minus LOCAL_FORK_LAG=$LAG)"
    echo "  set LOCAL_FORK_BLOCK=$PIN to reproduce this exact state"
  else
    echo "WARN: could not read the tip from $RPC - forking unpinned" >&2
  fi
else
  echo "forking $RPC at pinned block $PIN"
fi

[ -n "$PIN" ] && ARGS="$ARGS --fork-block-number=$PIN"
# shellcheck disable=SC2086
exec anvil $ARGS
