# expect-fail-against-base: yes
#
# The wallet image is built on the host from UI_BASE_IMAGE, and that image is the code that
# decodes and renders the transactions Safe owners are asked to sign -- which is the argument
# this branch makes for pinning it by digest. A failed build printed a WARN and fell through, so
# the stack started on the previously built image and the systemd/Ansible deploy reported
# success: repin the base, deploy, and keep serving the old signing bundle. The pin is only
# worth anything if a build that does not happen stops the deploy.

d=$TMP
mkdir -p "$d/bin"

cat > "$d/bin/podman" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "image inspect") exit 1 ;;            # no image yet, so a build is required
  "build "*|"build") exit 1 ;;          # ...and the build fails
esac
case "$1" in
  build) exit 1 ;;
  inspect) echo running ;;              # keep any later waiting loops from stalling the test
  *) exit 0 ;;
esac
STUB
# Only `compose config` is read, and an empty list of images is a fine answer.
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/docker"
chmod +x "$d/bin/podman" "$d/bin/docker"

assert_status "a failed UI build stops the bring-up" 1 \
  env PATH="$d/bin:$PATH" bash "$SUT/scripts/run_locally_podman.sh"
assert_contains "and says the build failed" "failed to build" "$OUT"
assert_not_contains "and starts no services" "Tier 1" "$OUT"
assert_not_contains "and does not report success" "Done." "$OUT"
