# expect-fail-against-base: yes
#
# Podman -- the production runtime -- reports official images as docker.io/library/postgres,
# spelling out the `library/` namespace docker leaves implicit. The matcher stripped only
# `docker.io/`, so postgres, redis, rabbitmq and nginx matched nothing and four of the eight
# digests this script exists to emit were silently skipped, on the host that matters, under a
# heading claiming the images were pinned.

d=$TMP
mkdir -p "$d/bin"

# A stand-in podman that answers exactly as the real one does on the deployment host: fully
# qualified names, `library/` included, newest image first.
cat > "$d/bin/podman" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  images)
    cat <<'IMAGES'
docker.io/safeglobal/safe-transaction-service:v6.10.1
docker.io/safeglobal/safe-config-service:v2.96.1
docker.io/safeglobal/safe-client-gateway-nest:v1.115.0
docker.io/safeglobal/safe-events-service:v1.5.0
docker.io/library/postgres:14-alpine
docker.io/library/redis:alpine
docker.io/library/rabbitmq:3.13-alpine
docker.io/library/nginx:alpine
localhost/safe-wallet-web-irys:3282
IMAGES
    ;;
  ps) ;;                       # nothing running: force the local-image path
  image)
    # $3 is the reference being inspected; give each one a distinct, recognisable digest.
    printf '%s@sha256:%064d\n' "$3" "$(printf '%s' "$3" | cksum | cut -d' ' -f1)"
    ;;
esac
STUB
chmod +x "$d/bin/podman"

OUT=$(cd "$SUT" && PATH="$d/bin:$PATH" bash scripts/pin_image_digests.sh 2>&1)

for v in txs cfg cgw events postgres redis rabbitmq nginx; do
  assert_contains "irys_${v}_digest is emitted" "irys_${v}_digest: \"@sha256:" "$OUT"
done
assert_not_contains "and nothing is reported as missing" "no local image" "$OUT"

# --env is the other documented output format; the same eight must appear there.
OUT=$(cd "$SUT" && PATH="$d/bin:$PATH" bash scripts/pin_image_digests.sh --env 2>&1)
for v in TXS CFG CGW EVENTS POSTGRES REDIS RABBITMQ NGINX; do
  assert_contains "${v}_DIGEST is emitted" "${v}_DIGEST=@sha256:" "$OUT"
done
