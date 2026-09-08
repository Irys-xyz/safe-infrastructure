# expect-fail-against-base: unprovable
# unprovable-because: scripts/anvil-fork.sh does not exist at the base, where this logic was
#                     duplicated between docker-compose.local-chain.yml and local_testnet.sh.
#                     Unifying them is what this pins; the drift it removes was real (the
#                     RUNBOOK documented 2s while both copies used 9s).
#
# Two things here are non-obvious enough to pin. First, --block-time must ALWAYS be passed:
# without it anvil mines only when a transaction arrives, so the head freezes the instant one is
# included and anything awaiting confirmations after inclusion hangs forever -- which is what
# the wallet's "Activating your account" step does. Second, the unpinned default must resolve a
# concrete block (tip minus a lag) rather than leave it to anvil, or no run is reproducible.

d=$TMP
mkdir -p "$d/bin"
printf '#!/bin/sh\necho 5000\n'                  > "$d/bin/cast"   # `cast block-number`
printf '#!/bin/sh\necho "ANVIL: $*"\n'           > "$d/bin/anvil"
chmod +x "$d/bin/cast" "$d/bin/anvil"

fork() { env -i PATH="$d/bin:/usr/bin:/bin" "$@" sh "$SUT/scripts/anvil-fork.sh" 2>&1; }

OUT=$(fork LOCAL_FORK_BLOCK=)
assert_contains "unpinned: resolves tip minus the default lag of 10" "--fork-block-number=4990" "$OUT"
assert_contains "unpinned: says how to reproduce the run"           "LOCAL_FORK_BLOCK=4990"    "$OUT"
assert_contains "always mines on an interval"                       "--block-time 9"           "$OUT"
assert_contains "serves the production chain id by default"         "--chain-id=3282"          "$OUT"

OUT=$(fork LOCAL_FORK_BLOCK=1234)
assert_contains "a pinned block is used as given" "--fork-block-number=1234" "$OUT"

# `tip` is the explicit opt-out: let anvil resolve the tip, accepting that the run is not
# reproducible. The flag must then be OMITTED -- passing --fork-block-number=0 would fork at
# genesis, where none of the Safe contracts exist, which is the opposite of the point.
OUT=$(fork LOCAL_FORK_BLOCK=tip)
assert_not_contains "tip: no --fork-block-number at all" "--fork-block-number" "$OUT"
assert_contains "tip: still mines on an interval" "--block-time 9" "$OUT"

OUT=$(fork LOCAL_FORK_BLOCK= LOCAL_FORK_LAG=50 LOCAL_BLOCK_TIME=2 IRYS_CHAIN_ID=31337)
assert_contains "the lag is overridable"       "--fork-block-number=4950" "$OUT"
assert_contains "the block time is overridable" "--block-time 2"          "$OUT"
assert_contains "the chain id is overridable"   "--chain-id=31337"        "$OUT"

# An unreachable upstream must not silently fork at genesis.
printf '#!/bin/sh\nexit 1\n' > "$d/bin/cast"; chmod +x "$d/bin/cast"
OUT=$(fork LOCAL_FORK_BLOCK=)
assert_contains "an unreadable tip warns"                    "could not read the tip" "$OUT"
assert_not_contains "and does not pass a bogus block number" "--fork-block-number"    "$OUT"
