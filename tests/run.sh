#!/usr/bin/env bash
#
# Test runner for the ops scripts. See tests/README.md.
#
#   tests/run.sh                 run everything
#   tests/run.sh diff image      run tests whose name matches any of these substrings
#   tests/run.sh --prove         run the suite against BASE_REF (default HEAD) as well, and
#                                assert that every regression test fails there
#
# --prove is the point of the suite. A regression test written after its fix passes on the very
# first run, which proves nothing at all: it may be asserting the wrong thing, or nothing.
# Each test declares whether it targets a defect that is fixed in the working tree but present
# at BASE_REF:
#
#   # expect-fail-against-base: yes         must fail there, with a real assertion failure
#   # expect-fail-against-base: no           must pass there too (behaviour already correct)
#   # expect-fail-against-base: unprovable   cannot run there; requires a `unprovable-because`
#
# and --prove extracts BASE_REF into a temporary tree, runs the suite against it, and fails if
# any such test PASSES there -- i.e. if it cannot catch the bug it exists for. It also reports
# WHY each one failed, so you can confirm it failed for the expected reason and not on a typo.
# `unprovable` is reported and counted separately: it is a test whose value rests on review
# rather than on demonstration, and saying so is better than pretending otherwise.
#
# The default BASE_REF of HEAD means: run this before committing a fix. The uncommitted working
# tree has the fix, HEAD does not, so the comparison isolates exactly that change. To prove the
# suite against some other point, set BASE_REF (e.g. BASE_REF=origin/main).

set -o pipefail
cd "$(dirname "$0")/.." || { echo "error: cannot cd to the repo root" >&2; exit 1; }
REPO=$PWD
TESTS_DIR=$REPO/tests

# The tree under test. Overridden by --prove; tests must reach the scripts through it and never
# through $PWD, or they silently test the working copy instead.
SUT="${SUT:-$REPO}"

BASE_REF="${BASE_REF:-HEAD}"

declare -a MATCH=()
PROVE=0
for arg in "$@"; do
  case "$arg" in
    --prove) PROVE=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) MATCH+=("$arg") ;;
  esac
done

selected() {
  [ "${#MATCH[@]}" -eq 0 ] && return 0
  local name=$1 m
  for m in "${MATCH[@]}"; do case "$name" in *"$m"*) return 0 ;; esac; done
  return 1
}

# A test's declared metadata, read from its header comments.
meta() { sed -n "s/^# $2: *//p" "$1" | head -1; }

run_one() {
  local f=$1 name; name=$(basename "$f" .sh); name=${name#test_}
  printf '  %s\n' "$name"
  local out rc
  # The test is sourced so it inherits the assertions, and the wrapper turns its accumulated
  # FAILURES count into the exit status. need_docker's `exit 77` escapes as 77.
  # $TMP is a scratch directory per test, created and removed here rather than by the test:
  # a trap registered inside $(...) fires when that subshell exits, not when the test ends.
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/irystest.XXXXXX")
  out=$(SUT="$SUT" REPO="$REPO" TMP="$tmp" bash -c \
        '. "$0"/lib/assert.sh; . "$1"; [ "$FAILURES" -eq 0 ]' "$TESTS_DIR" "$f" 2>&1); rc=$?
  rm -rf "$tmp"
  printf '%s\n' "$out" | sed '/^$/d'
  return $rc
}

main() {
  local pass=0 failed=0 skipped=0 rc name
  declare -a failed_names=()
  echo "running against: $SUT"
  echo
  for f in "$TESTS_DIR"/test_*.sh; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .sh); name=${name#test_}
    selected "$name" || continue
    run_one "$f"; rc=$?
    case $rc in
      0)  pass=$((pass + 1)) ;;
      77) skipped=$((skipped + 1)) ;;
      *)  failed=$((failed + 1)); failed_names+=("$name") ;;
    esac
  done
  echo
  printf '%d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
  [ "$failed" = 0 ] || { printf 'failed: %s\n' "${failed_names[*]}"; return 1; }
  return 0
}

if [ "$PROVE" = 1 ]; then
  command -v git >/dev/null || { echo "--prove needs git" >&2; exit 2; }
  base=$(git rev-parse --verify "$BASE_REF" 2>/dev/null) || {
    echo "error: cannot resolve BASE_REF=$BASE_REF" >&2; exit 2; }
  tree=$(mktemp -d)
  trap 'rm -rf "$tree"' EXIT
  git archive "$base" | tar -x -C "$tree"
  echo "=== proving the suite: running it against $BASE_REF ($(git rev-parse --short "$base")) ==="
  echo "Every test declaring expect-fail-against-base MUST fail here."
  echo
  wrong=0
  unproven=0
  for f in "$TESTS_DIR"/test_*.sh; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .sh); name=${name#test_}
    selected "$name" || continue
    expect=$(meta "$f" 'expect-fail-against-base')
    if [ "$expect" = unprovable ]; then
      why=$(meta "$f" 'unprovable-because')
      printf '  unproven %-38s %s\n' "$name" "${why:-NO REASON GIVEN}"
      [ -n "$why" ] || wrong=$((wrong + 1))
      unproven=$((unproven + 1))
      continue
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/irystest.XXXXXX")
    out=$(SUT="$tree" REPO="$REPO" TMP="$tmp" bash -c \
          '. "$0"/lib/assert.sh; . "$1"; [ "$FAILURES" -eq 0 ]' "$TESTS_DIR" "$f" 2>&1); rc=$?
    rm -rf "$tmp"
    if [ "$rc" = 77 ]; then
      printf '  SKIP     %-38s (%s)\n' "$name" "$(printf '%s' "$out" | sed -n 's/.*SKIP  //p' | head -1)"
      continue
    fi
    if [ "$expect" = yes ]; then
      # Failing is not enough: a test that blows up before it asserts anything has proved
      # nothing about the bug. Require an actual assertion failure in the output.
      if [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q 'FAIL  '; then
        printf '  caught   %-38s fails against the base, as it must:\n' "$name"
        # Show the reason, so "it failed" can be checked against "it failed for the right
        # reason" -- the whole value of watching a test fail.
        printf '%s\n' "$out" | grep 'FAIL  ' | head -6 | sed 's/^ */             /'
      elif [ "$rc" != 0 ]; then
        printf '  ERRORED  %-38s failed against the base WITHOUT asserting anything --\n' "$name"
        printf '           it proves nothing about the bug. Make it reach its assertions.\n'
        printf '%s\n' "$out" | head -6 | sed 's/^ */             /'
        wrong=$((wrong + 1))
      else
        printf '  USELESS  %-38s PASSES against the base -- it cannot catch its own bug\n' "$name"
        wrong=$((wrong + 1))
      fi
    else
      if [ "$rc" = 0 ]; then
        printf '  stable   %-38s passes against the base too (not a regression test)\n' "$name"
      else
        printf '  UNEXPECTED %-36s fails against the base but is not marked as a regression test\n' "$name"
        printf '%s\n' "$out" | sed 's/^/             /' | head -6
        wrong=$((wrong + 1))
      fi
    fi
  done
  echo
  if [ "$wrong" -gt 0 ]; then
    echo "$wrong test(s) do not behave as declared against the base."
    exit 1
  fi
  [ "$unproven" = 0 ] && echo "All regression tests fail against the base and pass against the working tree." \
    || echo "All provable regression tests fail against the base; $unproven marked unprovable (see above)." 
  echo "Now running them against the working tree:"
  echo
  main
  exit $?
fi

main
