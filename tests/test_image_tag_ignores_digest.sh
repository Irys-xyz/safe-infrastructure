# expect-fail-against-base: unprovable
# unprovable-because: image_tag did not exist at the base; the behaviour it fixes is proved by
#                     test_version_check_accepts_digest_pinned_images. This pins the edge cases.
#
# The post-upgrade check compares the running image's tag against the requested version. A
# digest-pinned reference is repo:v6.10.1@sha256:..., and versions/deployed.env.example
# documents exactly that form -- so the naive ${ref##*:} returned the digest hex and reported a
# correctly upgraded, correctly pinned stack as FAIL. Which is the reading that gets the check
# switched off.

load_upgrade_test || return

assert_eq "plain tag"                    "v6.10.1" "$(image_tag 'safeglobal/safe-transaction-service:v6.10.1')"
assert_eq "digest-pinned tag"            "v6.10.1" "$(image_tag 'safeglobal/safe-transaction-service:v6.10.1@sha256:aaaa')"
assert_eq "registry host in the ref"     "v2.96.1" "$(image_tag 'docker.io/safeglobal/safe-config-service:v2.96.1@sha256:bbbb')"
assert_eq "a port in the registry host"  "v1.5.0"  "$(image_tag 'registry.example.com:5000/safe/events:v1.5.0')"
# A bare digest reference has no tag to report; it must not report the digest as one.
assert_not_contains "digest-only ref reports no sha256" "sha256" "$(image_tag 'safeglobal/safe-events-service@sha256:cccc')"
