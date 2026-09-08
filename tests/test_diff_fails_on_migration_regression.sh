# expect-fail-against-base: yes
#
# `upgrade_test.sh diff` exists to catch an upgrade that lost state. It printed
# "<== REGRESSION" next to a migration count that went backwards and then "RESULT: PASS",
# exiting 0, because `fails` was initialised AFTER the migration loop -- so only the row-count
# loop below it could ever contribute. Flagging and failing have to be the same decision.

snapshot() {
  cat > "$1" <<JSON
{"captured":"2026-01-01T00:00:00Z",
 "versions":{"txs":"v6.10.1","cfg":"v2.96.1","cgw":"v1.115.0"},
 "migrations":{"txs":$2,"cfg":88},
 "rows":{"safes":$3,"chains":1},
 "chain_config":[{"chainId":"3282"}],
 "safe_addresses":["0xaaa"]}
JSON
}

d=$TMP
diff_cmd() { bash "$SUT/scripts/upgrade_test.sh" diff "$1" "$2"; }

snapshot "$d/before.json" 412 3

# The case the command exists for: migrations went backwards, everything else identical.
snapshot "$d/after-lost-migrations.json" 400 3
assert_status "migrations went backwards -> exit 1" 1 diff_cmd "$d/before.json" "$d/after-lost-migrations.json"
assert_contains "and says so" "REGRESSION" "$OUT"
assert_contains "and reports FAIL" "RESULT: FAIL" "$OUT"

# Row loss was already caught; assert it still is, so the fix did not trade one for the other.
snapshot "$d/after-lost-rows.json" 412 1
assert_status "rows lost -> exit 1" 1 diff_cmd "$d/before.json" "$d/after-lost-rows.json"

# A real upgrade advances migrations and keeps everything else. That must still pass, or the
# command becomes noise and gets ignored.
snapshot "$d/after-good.json" 420 3
assert_status "migrations advanced, nothing lost -> exit 0" 0 diff_cmd "$d/before.json" "$d/after-good.json"
assert_contains "and reports PASS" "RESULT: PASS" "$OUT"
