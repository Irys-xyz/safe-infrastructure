# expect-fail-against-base: yes
#
# An upgrade is only real if the services now run the requested versions, so the harness checks
# the running image's tag. Pinning by digest -- which this branch introduces and
# versions/deployed.env.example documents -- makes the reference repo:v6.10.1@sha256:..., and
# the check read the digest hex as the tag. So the more correctly the stack was pinned, the more
# certainly the check failed: a false alarm on every run, which is how a check stops being read.

load_upgrade_test || return

d=$TMP
# One version for all three services, so a single pair of stubs answers for every check. What
# is under test is the digest suffix, not telling the services apart.
printf 'TXS_VERSION=v6.10.1\nCFG_VERSION=v6.10.1\nCGW_VERSION=v6.10.1\n' > "$d/versions.env"

# Stubs, so nothing here needs a running stack.
C() { echo fake-container-id; }
curl() { echo '{"version":"6.10.1"}'; }
docker() { echo 'safeglobal/safe-transaction-service:v6.10.1@sha256:aaaabbbb'; }

assert_status "a digest-pinned stack at the requested version passes" 0 \
  assert_versions "$d/versions.env"
assert_contains "and names the pinned reference it accepted" "sha256:aaaabbbb" "$OUT"
assert_not_contains "with no spurious failure" "FAIL" "$OUT"

# The check must still catch a real failure: an image left on the previous version.
docker() { echo 'safeglobal/safe-transaction-service:v6.9.0@sha256:aaaabbbb'; }
assert_status "a stack still on the old image fails" 1 assert_versions "$d/versions.env"
assert_contains "and says the upgrade did not take effect" "DID NOT TAKE EFFECT" "$OUT"

# An untagged, digest-only reference cannot be shown to match a requested tag, so it must not
# be accepted just because the digest happens to contain the digits.
docker() { echo 'safeglobal/safe-transaction-service@sha256:6106101aaaa'; }
assert_status "a digest-only reference is not accepted as a tag match" 1 \
  assert_versions "$d/versions.env"
