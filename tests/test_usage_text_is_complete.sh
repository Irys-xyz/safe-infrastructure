# expect-fail-against-base: yes
#
# Each script prints its header comment as usage text. That was a hand-maintained line range
# (`sed -n '3,30p'`), which silently truncates or over-prints whenever the header's length
# changes -- and all four had drifted: db_backup printed `set -o pipefail` as if it were usage,
# local_testnet cut its last two lines off. Nobody notices, because nobody reads usage text
# until they are stuck.

check_script() {
  local script=$1 last_line=$2
  OUT=$(cd "$SUT" && bash "scripts/$script" 2>&1)
  assert_contains "$script: prints the whole header" "$last_line" "$OUT"
  assert_not_contains "$script: leaks no code into the usage text" 'set -o pipefail' "$OUT"
  assert_not_contains "$script: strips the comment markers" '#!/usr/bin/env' "$OUT"
}

check_script db_backup.sh    "store them off the host"
check_script local_testnet.sh "cast runs in the image"
check_script upgrade_test.sh  "never collides with a real deployment"
