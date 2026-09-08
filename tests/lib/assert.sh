# Assertions for the shell test suite. Sourced by tests/run.sh into each test's subshell.
#
# Deliberately dependency-free: the repo's whole argument is that an ops toolchain should not
# need anything the target host lacks, and a test suite that cannot run on the deployment host
# is a test suite that does not get run. bash, awk, sed and (for some tests) docker, nothing else.

FAILURES=0

_loc() { echo "${BASH_SOURCE[3]##*/}:${BASH_LINENO[2]}"; }

fail() {
  FAILURES=$((FAILURES + 1))
  printf '    FAIL  %s\n' "$1"
  shift
  for line in "$@"; do printf '          %s\n' "$line"; done
}

pass() { printf '    ok    %s\n' "$1"; }

assert_eq() {
  local what=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then pass "$what"
  else fail "$what" "expected: $want" "got:      $got"; fi
}

assert_contains() {
  local what=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) pass "$what" ;;
    *) fail "$what" "expected to contain: $needle" "got: $(printf '%s' "$haystack" | head -5)" ;;
  esac
}

assert_not_contains() {
  local what=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) fail "$what" "expected NOT to contain: $needle" ;;
    *) pass "$what" ;;
  esac
}

# Run a command, capturing output, and assert its exit status. Sets $OUT for follow-up asserts.
assert_status() {
  local what=$1 want=$2; shift 2
  OUT=$("$@" 2>&1); local got=$?
  if [ "$got" = "$want" ]; then pass "$what"
  else
    fail "$what" "expected exit $want, got $got" "output:"
    printf '%s\n' "$OUT" | head -8 | sed 's/^/            /'
  fi
}

assert_file_absent() {
  local what=$1 path=$2
  if [ -e "$path" ]; then fail "$what" "$path exists and should not"; else pass "$what"; fi
}

assert_file_present() {
  local what=$1 path=$2
  if [ -e "$path" ]; then pass "$what"; else fail "$what" "$path is missing"; fi
}

# Tests that need a container runtime declare it. The runner reports these as SKIP rather than
# passing them vacuously -- a suite that silently skips is the same failure mode as a check
# that silently passes.
need_docker() {
  command -v docker >/dev/null 2>&1 || { echo "    SKIP  needs docker"; exit 77; }
  docker info >/dev/null 2>&1 || { echo "    SKIP  docker present but not usable"; exit 77; }
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "    SKIP  needs $1"; exit 77; }
}

# Load scripts/upgrade_test.sh for its functions, without running a command.
#
# `down` is passed as the argument because the revisions this suite is proved against have no
# library mode: sourcing runs their command dispatcher, and `down` against an empty directory
# is the one command that does nothing and returns immediately. The current version returns at
# its sourcing guard before the dispatcher is reached, so the argument is ignored there.
load_upgrade_test() {
  TEST_DIR="$TMP/loader"; mkdir -p "$TEST_DIR"
  # shellcheck disable=SC1090
  . "$SUT/scripts/upgrade_test.sh" down >/dev/null 2>&1
  command -v wait_healthy >/dev/null || {
    fail "could not load scripts/upgrade_test.sh"; return 1; }
}
