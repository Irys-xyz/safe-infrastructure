# expect-fail-against-base: yes
#
# Two non-obvious things meet here. Resolving a compose service to a container returned a
# GUESSED name and exit 0 when nothing matched, so the script ran on names that do not exist.
# And `exit` inside $(...) leaves only the subshell, so even after that was made to fail, the
# callers had to propagate it themselves -- without which the script printed one error per
# service and carried on regardless.
#
# Run against no stack at all, it must stop, once, and say so.

d=$TMP
mkdir -p "$d/stack"
touch "$d/stack/docker-compose.yml"

assert_status "no containers -> exits non-zero" 1 \
  env CONTAINER_RUNTIME=docker COMPOSE_PROJECT_NAME=nosuchproject \
      bash "$SUT/scripts/configure_irys.sh"
assert_contains "and names the service it could not find" "cfg-web" "$OUT"
assert_contains "and suggests the cause" "is the stack up" "$OUT"
assert_not_contains "and does not claim to have applied the configuration" \
  "configuration applied" "$OUT"
assert_eq "and reports it once, not once per service" 1 \
  "$(printf '%s\n' "$OUT" | grep -c 'no container for service')"
