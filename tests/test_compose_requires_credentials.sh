# expect-fail-against-base: yes
#
# The compose file defaulted POSTGRES_PASSWORD to `postgres` and RABBITMQ_PASSWORD to `guest`,
# so a missing .env entry brought the whole stack up on credentials published in the upstream
# repository, with nothing printed. The Ansible path gates this properly, but a hand-run
# `docker compose up` or run_locally_podman.sh went straight past that gate.
#
# Also asserted here: the credentials are now defined once behind YAML anchors, and production
# runs podman-compose, whose parser is PyYAML. Both parsers must resolve the merge keys to the
# same thing, or the dedup silently drops credentials on the runtime that matters.

need_docker
need_cmd python3

d=$TMP/stack
mkdir -p "$d/container_env_files"
cp "$SUT"/docker-compose*.yml "$d/"
cp -r "$SUT/docker" "$d/"
for f in cfg cgw txs events ui; do
  cp "$SUT/container_env_files/$f.env.example" "$d/container_env_files/$f.env"
done

# `env -C` would need a recent GNU coreutils; a subshell keeps this portable.
in_stack() { (cd "$d" && "$@"); }

versions='TXS_VERSION=v6.10.1
CFG_VERSION=v2.96.1
CGW_VERSION=v1.115.0
EVENTS_VERSION=v1.5.0
RPC_NODE_URL=http://anvil:8545
REVERSE_PROXY_PORT=8000'

# Each credential is checked with the other one present, so the error has to name the one
# actually missing rather than whichever compose happens to reach first.
printf '%s\nRABBITMQ_PASSWORD=br-16-chars-long\n' "$versions" > "$d/.env"
assert_status "no POSTGRES_PASSWORD -> compose refuses to render" 1 \
  in_stack docker compose config
assert_contains "and names POSTGRES_PASSWORD" "POSTGRES_PASSWORD" "$OUT"

printf '%s\nPOSTGRES_PASSWORD=pw-16-chars-long\n' "$versions" > "$d/.env"
assert_status "no RABBITMQ_PASSWORD -> compose refuses to render" 1 \
  in_stack docker compose config
assert_contains "and names RABBITMQ_PASSWORD" "RABBITMQ_PASSWORD" "$OUT"

# With both set it must render, and nothing may be left on an upstream default.
printf '%s\nPOSTGRES_PASSWORD=pw-16-chars-long\nRABBITMQ_PASSWORD=br-16-chars-long\n' "$versions" > "$d/.env"
assert_status "with both set it renders" 0 in_stack docker compose config
assert_not_contains "no :postgres@ left in any connection URL" ":postgres@" "$OUT"
assert_not_contains "no :guest@ left in any connection URL"    ":guest@"    "$OUT"
assert_contains "the configured password reaches the databases" "pw-16-chars-long" "$OUT"

# The overlays used for the rehearsal must render too.
assert_status "the local-chain and ui-stub overlays still render" 0 \
  in_stack docker compose -f docker-compose.yml -f docker-compose.local-chain.yml \
      -f docker-compose.ui-stub.yml config

# PyYAML is podman-compose's parser. Every service that needs a credential must actually get
# one out of the anchors, under that parser and not only under docker compose.
OUT=$(python3 - "$d/docker-compose.yml" <<'PY'
import sys, yaml
s = yaml.safe_load(open(sys.argv[1]))['services']
missing = []
for name in ('txs-db', 'cfg-db', 'cgw-db', 'events-db', 'cfg-web', 'cgw-web'):
    if 'POSTGRES_PASSWORD' not in (s[name].get('environment') or {}):
        missing.append(f'{name}:POSTGRES_PASSWORD')
for name in ('txs-web', 'txs-scheduler', 'txs-worker-indexer',
             'txs-worker-contracts-tokens', 'txs-worker-notifications-webhooks'):
    env = s[name].get('environment') or {}
    for key in ('DATABASE_URL', 'CELERY_BROKER_URL', 'EVENTS_QUEUE_URL'):
        if key not in env:
            missing.append(f'{name}:{key}')
for name in ('txs-rabbitmq', 'general-rabbitmq'):
    if 'RABBITMQ_DEFAULT_PASS' not in (s[name].get('environment') or {}):
        missing.append(f'{name}:RABBITMQ_DEFAULT_PASS')
print(' '.join(missing) if missing else 'all resolved')
PY
)
assert_eq "PyYAML resolves every credential the anchors carry" "all resolved" "$OUT"
