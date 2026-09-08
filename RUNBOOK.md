# Self-hosted Safe{Wallet} for Irys Mainnet (chain 3282)

This is a clone of [`safe-global/safe-infrastructure`](https://github.com/safe-global/safe-infrastructure)
pre-configured to run the full Safe stack against Irys Mainnet. It runs the Config Service,
Transaction Service, Client Gateway, Events Service, and the Safe{Wallet} web UI behind a single
nginx reverse proxy.

Irys uses the **L2 Safe singleton**, and this stack runs in L2 (event-indexing) mode by default
(`ETH_L2_NETWORK=1` in `container_env_files/txs.env`). The Transaction Service therefore indexes from
`eth_getLogs` and **does not need a tracing or archive node** — a standard Irys RPC endpoint is enough.

---

## 1. Before you start — one required edit

Set the Irys Mainnet RPC endpoint in `.env`. Irys publishes a public mainnet endpoint:

```ini
RPC_NODE_URL=https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc
```

A second public endpoint, `https://mainnet-beta-rpc-2.irys.xyz/v1/execution-rpc`, is available as a
fallback. The public RPC is sufficient to boot and smoke-test the stack; for production indexing, use a
dedicated endpoint, since the indexer's `eth_getLogs` load will hit public rate limits (see §10).
Nothing else is required to boot locally.

### Security note (read once)

`container_env_files/*.env` hold real secrets and are **gitignored**. Only the `*.env.example`
templates are committed, and they carry `__CHANGE_ME__` / `__USER__` / `__PASSWORD__` placeholders
rather than values. Provision the real files out-of-band on the host:

```bash
cd container_env_files
for f in cfg cgw txs events ui; do cp $f.env.example $f.env; done
# then fill every placeholder — generate secrets with: openssl rand -hex 32
```

The Ansible deploy does **not** sync these files, and refuses to start the stack if any is
missing, still contains a placeholder, or still contains one of the upstream repo's public dev
defaults (`insecure_key_for_dev`, `postgres`, `admin`, `guest:guest`, …). Those defaults are
published in this repo's git history, so treat them as compromised, not merely weak.

Why this is strict: the Config Service's `SECRET_KEY` signs its admin sessions, and the Config
Service admin is what defines chain 3282's contract addresses, RPC URL and transaction-service
URL — i.e. what the wallet asks owners to sign. A guessable key there is a malicious-payload
path, not just an information leak.

---

## 2. What was pre-configured

Chain-specific settings are committed; every secret is a placeholder you must fill (§1).

| File | Key | Value |
| --- | --- | --- |
| `.env` (rendered by Ansible) | `RPC_NODE_URL` | the Irys RPC from §1 |
| `container_env_files/ui.env` | `NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID` | `3282` |
| `container_env_files/ui.env` | `NEXT_PUBLIC_GATEWAY_URL_PRODUCTION` | `/cgw` (relative — same-origin, see §8) |
| `container_env_files/cgw.env` | `AUTH_TOKEN` | `__CHANGE_ME__` — must match `cfg.env`'s `CGW_AUTH_TOKEN` |
| `container_env_files/cfg.env` | `SECRET_KEY`, `POSTGRES_PASSWORD`, `DJANGO_SUPERUSER_PASSWORD` | `__CHANGE_ME__` |
| `container_env_files/txs.env` | `DJANGO_SECRET_KEY`, `DATABASE_URL`, `CELERY_BROKER_URL` | `__CHANGE_ME__` / `__USER__` / `__PASSWORD__` |
| `container_env_files/events.env` | `ADMIN_PASSWORD`, `DATABASE_URL` | `__CHANGE_ME__` / `__USER__` / `__PASSWORD__` |

There are **no default credentials**: the Config Service and Transaction Service admins are created
only if you set `*_SUPERUSER_*` in `vars.yml` / `.env`, and the Events admin password is a placeholder.

Image tags default to `latest`, which is fine for a first bring-up but is **not** what you should run
against real assets — a tag is mutable, so you get whatever the registry served at first pull with no
record of which build that was. Pin digests before anything real depends on the stack (§10).

---

## 3. Quickstart (local)

```bash
# after setting RPC_NODE_URL in .env — the script now cd's to the repo root itself
bash scripts/run_locally.sh
```

**podman — one command, end-to-end (recommended for this fork).** Under rootless podman, podman-compose
ignores `depends_on: condition: service_healthy`, so use the dedicated script. It builds the custom Irys
UI image, brings the stack up tier by tier, applies the full chain-3282 configuration (§4–§7c) via
`scripts/configure_irys.sh`, and verifies the endpoints — a reproducible deployment in one command:

```bash
# after setting RPC_NODE_URL in .env
bash scripts/run_locally_podman.sh
```

Re-running is safe: already-running services are skipped (no recreation) and the configuration step is
idempotent. The wallet UI, admin and APIs are all served on `:8000` (the earlier extra `8080` publish was
removed: it duplicated the whole proxy, admin panels included, on a world-reachable port).

The compose file (`docker-compose.yml`) and `.env` live at the repo root, where `docker compose`
resolves them; `run_locally.sh` changes to that directory before invoking compose, so it runs correctly
from any directory. This pulls images, starts containers, and creates the Config Service and Transaction
Service superusers. The `ui` service runs the custom Irys image (`localhost/safe-wallet-web-irys:3282`),
which bakes `next build` at image-build time (see §8), so the heavy step is the one-time image build;
thereafter the container starts in seconds.

> **podman users:** if `docker` delegates to `podman-compose` (you'll see "Executing external compose
> provider podman-compose"), the stack still runs, but use a recent `podman-compose` for
> `depends_on: condition: service_healthy` support, and note that rootless podman may need
> user-namespace mapping for the `./data/*-db` Postgres bind mounts to be writable.

Endpoints once up (all on the reverse-proxy port, default `8000`):

- Web UI: <http://localhost:8000/>
- Config admin: <http://localhost:8000/cfg/admin/> (credentials from `CFG_SUPERUSER_*`; none by default)
- Tx-service admin: <http://localhost:8000/txs/admin/> (credentials from `TXS_SUPERUSER_*`)
- Events admin: <http://localhost:8000/events/admin/> (credentials from `events.env`)
- Chains API (verify your config): <http://localhost:8000/cfg/api/v1/chains>

On an Ansible-deployed host, nginx is bound to **loopback only** and the three `/*/admin*` paths are
`403`'d at the Caddy edge. Reach an admin panel over an SSH local-forward instead:

```bash
ssh -L 8000:127.0.0.1:8000 <host>   # then browse http://localhost:8000/cfg/admin/
```

---

## 4. Add the Irys chain (Config admin → Chains → Add)

`http://localhost:8000/cfg/admin/chains/chain/add/`

| Field | Value |
| --- | --- |
| Chain ID | `3282` |
| Name | `Irys` |
| EIP-3770 short name | `irys-mainnet-beta` (registered for chain 3282 in `ethereum-lists/chains`) |
| `l2` | **true** (required — Irys uses the L2 singleton) |
| Testnet | false |
| Native currency name / symbol / decimals | `Irys` / `IRYS` / `18` |
| RPC URI (and Safe-Apps RPC / public RPC) | `https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc` |
| Transaction service URI | `http://nginx:8000/txs` |
| VPC transaction service URI | `http://nginx:8000/txs` |
| Block explorer — address | `https://evm-explorer.irys.xyz/address/{{address}}` |
| Block explorer — txHash | `https://evm-explorer.irys.xyz/tx/{{txHash}}` |
| Block explorer — api | `https://evm-explorer.irys.xyz/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}` (Blockscout-style; verify once the explorer cert is renewed) |

> Use `evm-explorer.irys.xyz` — the EVM explorer, which uses EIP-3091 paths. `explorer.irys.xyz` is the
> Irys datachain/gateway explorer, not the EVM one. The EVM explorer's TLS certificate was observed
> expired on 2026-06-03; this affects only the UI's outbound explorer links, not stack operation.

Enable these features on the chain: `MY_ACCOUNTS`, `SPENDING_LIMIT`, `SAFE_APPS`, `ERC1155`, `ERC721`,
`DOMAIN_LOOKUP`, `CONTRACT_INTERACTION`.

Enter the contract addresses below in the chain's contract-address fields (use the **SafeL2** singleton).

---

## 5. Irys Safe v1.5.0 contract addresses

Canonical (deterministic) deployments — verified against `safe-deployments` v1.5.0 assets.

| Contract | Address |
| --- | --- |
| **SafeL2** (singleton to use) | `0xEdd160fEBBD92E350D4D398fb636302fccd67C7e` |
| Safe (L1, optional) | `0xFf51A5898e281Db6DfC7855790607438dF2ca44b` |
| SafeProxyFactory | `0x14F2982D601c9458F93bd70B218933A6f8165e7b` |
| MultiSend | `0x218543288004CD07832472D464648173c77D7eB7` |
| MultiSendCallOnly | `0xA83c336B20401Af773B6219BA5027174338D1836` |
| CompatibilityFallbackHandler | `0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4` |
| SignMessageLib | `0x4FfeF8222648872B3dE295Ba1e49110E61f5b5aa` |
| CreateCall | `0x2Ef5ECfbea521449E4De05EDB1ce63B75eDA90B4` |
| SimulateTxAccessor | `0x07EfA797c55B5DdE3698d876b277aBb6B893654C` |
| SafeMigration | `0x6439e7ABD8Bb915A5263094784C5CF561c4172AC` |
| SafeToL2Setup | `0x900C7589200010D6C6eCaaE5B06EBe653bc2D82a` |
| ExtensibleFallbackHandler | `0x85a8ca358D388530ad0fB95D0cb89Dd44Fc242c3` |
| TokenCallbackHandler | `0x54e86d004d71a8D2112ec75FaCE57D730b0433F3` |

---

## 6. Register contracts in the Transaction Service (`txs/admin/`)

Chain 3282 is not in `safe-eth-py`, so the service will not auto-configure it. Add manually:

- **Master Copy** — `0xEdd160fEBBD92E350D4D398fb636302fccd67C7e`, version `1.5.0`, L2 = true.
  (Optionally also add the L1 Safe singleton `0xFf51A5898e281Db6DfC7855790607438dF2ca44b`.)
- **Proxy Factory** — `0x14F2982D601c9458F93bd70B218933A6f8165e7b`, version `1.5.0`.
- Set the **initial block number** to the block at which the Safe contracts were deployed on Irys.
  Without this the indexer scans from genesis, which is slow.

> The indexing mode is permanent once the service has initialised against a chain. This stack is L2 by
> default; do not switch it after first run.

---

## 7. Configure the cache-invalidation webhook (`events/admin/`)

`AUTH_TOKEN` (cgw) and `CGW_AUTH_TOKEN` (cfg) are already set to the same value. In the Events admin:

- Create a new Webhook.
- URL: `http://nginx:8000/cgw/v1/hooks/events`
- Authorization: `Basic <AUTH_TOKEN>`
- Is Active: on. Leave the chains field blank. Enable every webhook option. Save.

---

## 7b. Required: the `WALLET_WEB` config service (v2 chains API)

The web UI loads its chain list from the Client Gateway **v2** endpoint
`GET /cgw/v2/chains?serviceKey=WALLET_WEB`, which proxies to the Config Service
`GET /api/v2/chains/WALLET_WEB/`. That view does `get_object_or_404(Service, key="WALLET_WEB")`, so
without a matching `Service` row it returns **404 and the UI renders blank** — even though the v1
endpoints (`/cgw/v1/chains`) work, which masks the problem. Create the service once:

```bash
podman exec -i irys-safe-infrastructure_cfg-web_1 python src/manage.py shell <<'PY'
from chains.models import Service, Feature
svc, _ = Service.objects.get_or_create(
    key="WALLET_WEB", defaults={"name": "Safe Wallet Web", "description": "Safe{Wallet} web client"})
for f in Feature.objects.all():
    f.services.add(svc)   # add from the Feature side; the Service-side M2M trips a buggy signal
PY
```

Verify: `curl -s -o /dev/null -w '%{http_code}' 'http://localhost:8000/cgw/v2/chains?serviceKey=WALLET_WEB'`
returns `200`. The v2 queryset returns all non-hidden chains (the service does not filter which chains
appear); assigning features to the service controls which features each chain exposes.

## 7c. Disable the forced Spaces sign-in (`REQUIRE_LOGIN_DISABLED`)

The current `safe-wallet-web` image gates the whole wallet behind a Spaces sign-in: every protected
route redirects to `/welcome/spaces?next=…`, which renders blank on a self-hosted instance (no console
error — the page simply doesn't paint). The gate is controlled by a chain feature flag read from the
**default** chain (`useIsRequireLoginEnabled`: `!hasFeature(chain, REQUIRE_LOGIN_DISABLED)`). Add the
flag to chain 3282 to turn the gate off and restore the classic `/welcome/accounts` flow:

```bash
podman exec -i irys-safe-infrastructure_cfg-web_1 python src/manage.py shell <<'PY'
from chains.models import Chain, Feature, Service
chain = Chain.objects.get(id=3282)
svc = Service.objects.get(key="WALLET_WEB")
f, _ = Feature.objects.get_or_create(key="REQUIRE_LOGIN_DISABLED")
f.chains.add(chain); f.services.add(svc)   # add from the Feature side (Service-side M2M trips a buggy signal)
PY
```

Verify `/cgw/v2/chains?serviceKey=WALLET_WEB` lists `REQUIRE_LOGIN_DISABLED` in the chain `features`.
Reload the UI in a **fresh** browser profile (the chain config is cached client-side via RTK Query /
redux-persist, so a stale profile may still gate). The wallet then loads at `/welcome/accounts`.

## 8. The UI and the `safe-deployments` PR

The `ui` service uses the prebuilt `safeglobal/safe-wallet-web` image, which bundles
`@safe-global/safe-deployments` as of its build date. Until Irys (3282) is merged into that package,
the UI's **create-Safe** flow may not resolve deployment addresses for the chain. Two reliable fixes:

1. **Land the upstream PR** ([safe-deployments #1555](https://github.com/safe-global/safe-deployments/pull/1555)).
   It is the ungated track (reviewed on a ~2-week cadence). Once merged, a freshly pulled UI image
   includes 3282.
2. **Build your own UI image** from
   [`safe-wallet-monorepo`](https://github.com/safe-global/safe-wallet-monorepo) with the package
   patched or a `contractNetworks` override. This also lets you rebrand.

Indexing, signing, and viewing existing Safes work regardless; the gap is only the in-UI creation flow.

**Implemented in this repo (option 2, lightweight).** `docker/ui-irys.Dockerfile` builds a derived image
(`localhost/safe-wallet-web-irys:3282`) that adds chain 3282 to the bundled `@safe-global/safe-deployments`
data (`docker/patch-irys-deployments.mjs`).

The patch registers **v1.5.0 `canonical` deployments only** — the 13 contracts that are actually on the
chain. That scope is deliberate: v1.5.0 is the only Safe version deployed on Irys, and
`scripts/verify_deployments.py` confirms the other 39 addresses across v1.0.0–v1.4.1 (including every
v1.3.0 `eip155` variant) hold no code. Registering them would tell the wallet that contracts exist which
do not, and the create-Safe flow would build transactions against codeless addresses. If a required
v1.5.0 contract is missing from the bundled package, the patch **fails the image build** rather than
shipping a UI that cannot create or execute a Safe.

Note that canonical deployment is permissionless — the Safe Singleton Factory
(`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`) *is* present on Irys, so anyone can deploy an older Safe
version there at any time. Re-run `scripts/verify_deployments.py` before widening the patch's scope; it
warns when a previously-absent address gains code. The image runs `next build`
**at image-build time** — not at container start — with the `NEXT_PUBLIC_*` config baked in, so the served
static export already contains the patched addresses and the deployment config. The `ui` service in
`docker-compose.yml` uses this image. Build it before bringing the stack up:

```bash
podman build -t localhost/safe-wallet-web-irys:3282 -f docker/ui-irys.Dockerfile .
```

This closes the create-Safe gap without waiting for PR #1555. When 3282 lands upstream, you can drop the
custom image and revert the `ui` service to `safeglobal/safe-wallet-web:${UI_VERSION}`.

### Safe 1.5.0 version allowlist

Irys Mainnet's Safe singleton is the canonical **SafeL2 1.5.0** (`0xEdd160fEBBD92E350D4D398fb636302fccd67C7e`,
the only Safe contracts deployed on the chain), so every Safe here reports version `1.5.0+L2`. The wallet's
`@safe-global/utils` hardcodes the versions it accepts in `isValidSafeVersion`
(`['1.4.1', '1.3.0', '1.2.0', '1.1.1', '1.0.0']`), and `assertValidSafeVersion` throws
`"<version> is not a valid Safe Account version"` for anything else. Left unpatched, that assertion fires on
the transaction-execution path: the review screen reports that the transaction will fail and execution is
blocked.

`docker/patch-safe-versions.mjs` adds `1.5.0` to that allowlist at image-build time (run from the Dockerfile
before `next build`). The patch is type-valid — `@safe-global/types-kit` already lists `1.5.0` in its
`SafeVersion` union — and the rest of the stack already supports 1.5.0: the on-chain contracts, the
transaction service (the singleton is registered as `SafeL2 1.5.0`) and `@safe-global/safe-deployments`
(it ships `v1.5.0` assets, which `patch-irys-deployments.mjs` maps onto chain 3282). Only the allowlist
lagged. To verify after a rebuild, the version array adjacent to the "not a valid Safe account version"
assertion in `out/_next/static/chunks/pages/_app-*.js` should start with `["1.5.0", …]`. Grep
case-insensitively: upstream changed the wording from "Safe Account" to "Safe account" after
v1.88.0.

**On newer base images this patch is a no-op, by design.** Upstream added `'1.5.0'` to
`SAFE_VERSIONS` itself — it is present at `web-v1.99.1` and absent at `web-v1.88.0`. The script
detects that and exits 0 with "already in allowlist, nothing to do", so it is safe to keep across
an upgrade; keeping it also means the build still fails loudly if the declaration ever disappears
or is renamed. `docker/patch-irys-deployments.mjs`, by contrast, is **still required**: chain 3282
is not in `@safe-global/safe-deployments` as of 1.37.62 (2026-08-06), so PR #1555 has not landed.

A second hardcoded version list lives in `determineMasterCopyVersion` (`packages/utils/src/utils/safe.ts`),
used only by the multichain "add this Safe to another network" flow and by Safe version-upgrade parameter
decoding. Neither applies to a single-chain Irys deployment on the latest contracts, so it is left
unpatched; extend the patch to that list as well if multichain support is ever required.

> **Rebuilding the UI image is not a pure image swap.** Recreating the `ui` container assigns it a new IP on
> the rootless network, but nginx resolves its upstreams once at config load — so it keeps connecting to the
> old `ui` IP and returns **502** until it re-resolves. After recreating `ui`, reload nginx:
> `podman exec irys-safe-infrastructure_nginx_1 nginx -s reload`. Returning browsers also cache the previous
> bundle via the PWA service worker; hard-reload, clear site data, or use a fresh profile to load a new build.

### Build-time vs. start-time build (memory and config)

Upstream's image runs `next build` on **every container start** (its command is `yarn static-serve` =
`yarn build && yarn serve`), because a Next.js static export (`output: 'export'`) inlines the
`NEXT_PUBLIC_*` values into the bundle and the generic published image must stay config-agnostic. That
build needs **~4–8 GiB RAM** and, on an 8 GiB host with no swap, can OOM-kill the UI mid-start (symptom: a
blank page or a restart loop). This fork's UI config is fixed (`container_env_files/ui.env`), so the
Dockerfile bakes the `NEXT_PUBLIC_*` values and runs the build once, at image-build time; container start
then only serves the prebuilt `out/`.

Consequences:

- The memory spike happens **once, during `podman build`**, not on every start. Build the image on CI or a
  larger machine and the runtime host stays small — serve-only needs well under 1 GiB for the UI.
- The baked `NEXT_PUBLIC_*` values are **frozen into the image**. Editing them in `ui.env` no longer changes
  the UI; pass new values as `--build-arg` and rebuild. The Dockerfile bakes the gateway URL, chain id and
  WalletConnect project id (the rest are empty in `ui.env` and omitted — to bake another, add it to the
  Dockerfile's `ARG`/`ENV` block). Defaults match `ui.env`; for a real domain:

  ```bash
  podman build -t localhost/safe-wallet-web-irys:3282 \
    --build-arg NEXT_PUBLIC_GATEWAY_URL_PRODUCTION=https://safe.irys.xyz/cgw \
    -f docker/ui-irys.Dockerfile .
  ```

- Only `REVERSE_PROXY_UI_PORT` (consumed by `serve`) still takes effect at runtime.

The UI points at the Client Gateway via the `NEXT_PUBLIC_GATEWAY_URL_PRODUCTION` build arg (default
`/cgw`, matching `container_env_files/ui.env`). It is **relative on purpose**: the browser resolves
`/cgw` against whatever origin served the page, so the gateway calls are same-origin — and stay
same-origin whether the stack is reached by IP, hostname, or domain — with no rebuild and no CORS.
Use an absolute URL only for a Client Gateway on a different origin than the UI (§10). Set
`NEXT_PUBLIC_WC_PROJECT_ID` the same way for WalletConnect-based wallets. Both are baked at build
time per the note above.

---

## 9. Smoke test

1. `http://localhost:8000/cfg/api/v1/chains` lists chain 3282.
2. `http://localhost:8000/txs/api/v1/about/` responds.
3. Open `http://localhost:8000/`, select Irys, connect a wallet.
4. Create a Safe, send a transaction, and confirm it appears (indexed) in the UI and via the txs API.

---

## 10. Production hardening (before public exposure)

- **Fill every secret** (§1). Ansible refuses to start the stack while a placeholder or a known
  upstream dev default remains in `container_env_files/*.env`. The set: `DJANGO_SECRET_KEY` (txs),
  `SECRET_KEY` (cfg), the database passwords, `AUTH_TOKEN` / `CGW_AUTH_TOKEN` (must match),
  Events `ADMIN_PASSWORD`, `DJANGO_SUPERUSER_PASSWORD`, `JWT_SECRET`, `FINGERPRINT_ENCRYPTION_KEY`.

- **Deferring the rotation.** If you need to ship other changes before rotating, set
  `irys_postgres_password` / `irys_rabbitmq_password` to the values the host **already**
  uses and add `irys_accept_default_credentials: true`. The play then skips the strength
  check and prints a warning on every run. Do this knowingly: the upstream defaults are
  published, so the databases and broker accept publicly-known credentials. They are only
  survivable because they sit on a private container network with no published ports — any
  code execution inside that network reaches all four databases.

- **Rotating the Postgres passwords takes three steps, not one.** This is the one that bites:
  the database password lives in *two* places that must agree, and editing either alone breaks
  the stack.

  1. `POSTGRES_PASSWORD` in the repo-root `.env` — what `docker-compose.yml` gives the four
     `*-db` containers. (It used to be hardcoded to `postgres`, which meant filling in the
     `__CHANGE_ME__` placeholders in the service env files could only ever break the stack.)
  2. The connecting service's own config: `POSTGRES_PASSWORD` in `cfg.env`, and the password
     embedded in `DATABASE_URL` for `txs.env` / `events.env`.
  3. **On an existing deployment, the database itself.** Postgres only reads
     `POSTGRES_PASSWORD` at `initdb`. On a `./data` volume that already exists the stored
     password does not change, so steps 1 and 2 alone leave every service unable to
     authenticate. Change it inside the database as well:

     ```bash
     docker compose exec cfg-db psql -U postgres -c "ALTER USER postgres PASSWORD 'new';"
     ```

     Do that for each of `txs-db`, `cfg-db`, `events-db`, `cgw-db`, then update 1 and 2 to match
     and restart. Rehearse it with `scripts/upgrade_test.sh` (§14) before doing it in place.

- **RabbitMQ has the identical trap.** `RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS` are only
  read the first time the broker boots; afterwards the credentials live in its own store, and
  changing `RABBITMQ_USER` / `RABBITMQ_PASSWORD` in `.env` just makes every client fail with
  `ACCESS_REFUSED (403)`. The brokers in this stack have **no volume**, so their state is
  ephemeral and recreating them adopts the new credentials:

  ```bash
  docker compose up -d --force-recreate --no-deps txs-rabbitmq general-rabbitmq
  ```

  In-flight queued messages are lost, which is acceptable for these queues (indexing work is
  re-derived from the chain, and the CGW cache-invalidation hook is best-effort).
- **TLS and domain** — done by the Ansible deploy (`ansible/README.md`): Caddy terminates TLS with a
  Cloudflare Origin Certificate, nginx binds loopback only, the host firewall admits `80`/`443`
  from Cloudflare's ranges alone, and the `/*/admin*` paths are `403`'d publicly. The playbook also
  rewrites `DJANGO_ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`, `MEDIA_URL` (cfg) and
  `AUTH_POST_LOGIN_REDIRECT_URI` (cgw) from `irys_safe_domain`. Doing it by hand instead? Set those
  four plus `CGW_URL` (cfg) and `SAFE_CONFIG_BASE_URI` (cgw) to the real host. The UI's
  `NEXT_PUBLIC_GATEWAY_URL_PRODUCTION` stays the relative `/cgw` (same-origin, no rebuild); make it
  absolute only if the Client Gateway is served from a different origin than the UI.
- **Pin image digests, not just tags.** A tag is mutable; a digest is content-addressed. This matters
  most for the wallet UI base image, which is the code that builds, decodes and renders what owners
  sign. After a bring-up you have smoke-tested:

  ```bash
  bash scripts/pin_image_digests.sh          # emits ansible/vars.yml lines
  bash scripts/pin_image_digests.sh --env    # emits .env lines
  ```

  Paste into `vars.yml` and redeploy. Each `*_DIGEST` is appended to its image reference in
  `docker-compose.yml`, so the digest becomes authoritative and the tag stays advisory — keep the tag
  accurate for humans, since it is no longer what resolves. Repinning `irys_ui_base_image` triggers a
  UI rebuild and container recreate automatically.
- **Verify the on-chain contracts** before and after any deploy, and on a schedule:

  ```bash
  python3 scripts/verify_deployments.py
  ```

  It checks, against each RPC independently, that chainId is 3282, that all 13 v1.5.0 canonical
  addresses hold bytecode whose keccak256 matches the `codeHash` published in `safe-deployments`, and
  that the v1.4.1/v1.3.0 singletons and proxy factories are still absent. Exit code 1 blocks a deploy.
  Querying more than one endpoint is the point: a single RPC that lies about contract code is exactly
  the threat. No dependencies — run it from cron or CI.
- **Add a Content-Security-Policy** at the Caddy edge. The stack sets HSTS, `X-Frame-Options`,
  `nosniff` and `Referrer-Policy` but no CSP, which is the main in-browser limit on injected script
  in a signing UI. Start with `script-src 'self'` (Next.js needs nonces or `'unsafe-inline'`),
  `connect-src 'self'` plus the RPC origin, and `frame-ancestors 'none'`; test the wallet fully
  before enforcing, and roll out with `Content-Security-Policy-Report-Only` first.
- **Deploy from a reviewed commit.** `ansible/README.md` rsyncs your local working copy as-is,
  uncommitted changes included, and excludes `.git` — so the host keeps no record of what it is
  running. Deploy from a tagged commit or a CI artifact, and record `git rev-parse HEAD` on the host.
- **Persist and back up** the `./data` Postgres volumes.
- **Dedicated Irys RPC**: the indexer makes heavy `eth_getLogs` calls; do not rely on the rate-limited
  public endpoints (`mainnet-beta-rpc*.irys.xyz`). Set the indexer start block to the Safe deployment block.
- **Resource sizing**: for low volume, start the Transaction Service around 2–4 vCPU / 8–16 GiB and scale
  with usage (upstream quotes 8 vCPU / 32 GiB for Ethereum-mainnet scale).
- **UI build memory**: building the wallet image runs `next build` (~4–8 GiB RAM, a few minutes). This repo
  runs that build at image-build time (§8), so the **runtime** host does not need that headroom — but the
  **build** host does. Build on CI or a ≥8 GiB machine, then deploy the built image; serve-only uses well
  under 1 GiB for the UI.

---

## 11. Troubleshooting first boot (podman)

These were hit and fixed on a `podman-compose` first boot (podman 5.7, podman-compose 1.5). The fixes
are baked into `docker-compose.yml` and `container_env_files/cgw.env` in this clone.

- **`Queue.declare: (541) INTERNAL_ERROR - Feature transient_nonexcl_queues is deprecated`** — the
  unpinned `rabbitmq:alpine` resolves to RabbitMQ 4.x, which no longer permits the transient
  non-exclusive queues that the Transaction Service (Celery) and Events Service declare. Both RabbitMQ
  services are pinned to `rabbitmq:3.13-alpine`. Symptom without the pin: `txs-worker-indexer` stays
  `unhealthy` and `txs-scheduler` / `events-web` never start.
- **`Configuration is invalid: AUTH_POST_LOGIN_REDIRECT_URI ... received undefined`** — recent Client
  Gateway builds require `AUTH_POST_LOGIN_REDIRECT_URI`. It is set in `cgw.env` to `http://localhost:8000`
  (change to the real host for production).
- **`relation "django_celery_beat_clockedschedule" does not exist`** — `txs-scheduler` started before
  the indexer (which runs migrations via `RUN_MIGRATIONS=1`) had finished. Its `depends_on` is now gated
  on `txs-worker-indexer: condition: service_healthy`, so migrations complete first.
- **`"…_ui_1" is not a valid container, cannot be used as a dependency`** — `podman-compose` skipped the
  `safeglobal/safe-wallet-web` image, so the `ui` container was never created and `nginx` (which depends
  on it) failed. Pull it explicitly before bringing the stack up:
  `podman pull docker.io/safeglobal/safe-wallet-web:latest`.
- **`Error reading /var/lib/rabbitmq/.erlang.cookie: eacces`** on one RabbitMQ container — a transient
  first-start race under rootless podman (the sibling container starts cleanly). If it persists after a
  restart, pin the cookie by adding `RABBITMQ_ERLANG_COOKIE=<value>` to that service's `environment`.

- **UI hangs on "We are activating your account", or Safe pages return 502/503** — the public Irys
  RPC is slow (~2 s/call) and intermittently fails. The Client Gateway's Safe-overview calls the
  Transaction Service, which makes a live RPC call that intermittently returns 503; that trips the CGW
  `txs-service-3282` circuit breaker, which then hard-fails every request and the UI poll never
  completes. The Safe itself is created and indexed regardless (check `/txs/api/v1/safes/<addr>/`).
  Reset the breaker and cache:
  `podman restart irys-safe-infrastructure_cgw-web_1 && podman restart irys-safe-infrastructure_nginx_1`
  — restart nginx too, because `podman restart` reassigns the container's IP and nginx caches the
  upstream (otherwise every `/cgw` request 502s). For reliable operation, use a dedicated RPC (§10).

- **Blank page + console shows `/cgw/v2/chains` blocked by CORS** ("No 'Access-Control-Allow-Origin'
  header", `from origin 'http://<host>:8080'`) — the UI bundle was built with an **absolute**
  `NEXT_PUBLIC_GATEWAY_URL_PRODUCTION` (e.g. `http://1.2.3.4:8080/cgw`) but the page was opened on a
  *different* origin (e.g. the host's name instead of that IP). The browser compares origins as strings, so
  `name:8080` ≠ `1.2.3.4:8080` even when they resolve to the same host; the cross-origin `/cgw` preflight is
  rejected → the UI gets no chains → blank. Fix: bake the **relative** `/cgw` (the default), which is
  same-origin on every host, then rebuild + recreate the `ui` — set `UI_GATEWAY_URL=/cgw` in `.env` (or
  `irys_ui_gateway_url: /cgw` in Ansible) and `systemctl --user restart irys-safe`, which rebuilds when the
  baked gateway differs. Quick check with no rebuild: open the UI on the **exact** host:port baked into the
  bundle. Browser-wallet-extension console noise (`contentscript.js`, "Invalid domain", "Failed to get
  initial state") is unrelated.

Re-run after any of these fixes, from the repo root:

```bash
podman pull docker.io/safeglobal/safe-wallet-web:latest
bash scripts/run_locally.sh
```

---

## 12. Run as a service (systemd)

`systemd/irys-safe.service` runs the whole stack as a rootless podman **user** service —
the same rootless context the stack is built and tested in. `ExecStart` calls
`scripts/run_locally_podman.sh` (idempotent: build-if-absent, tier-by-tier start,
chain-3282 configuration, endpoint check); `ExecStop` runs `docker compose down`, which
removes the containers but **keeps** the `./data` Postgres volumes (`down -v` is never run).

Install it as the unprivileged user that owns the clone, not root. `enable-linger` lets it
start at boot with no interactive login:

```bash
loginctl enable-linger "$USER"
install -Dm644 systemd/irys-safe.service ~/.config/systemd/user/irys-safe.service
# Edit WorkingDirectory in the unit if the clone is not at ~/irys-safe-infrastructure.
systemctl --user daemon-reload
systemctl --user enable --now irys-safe.service
```

Manage and inspect:

```bash
systemctl --user status irys-safe
journalctl --user -u irys-safe -f
systemctl --user restart irys-safe
systemctl --user stop irys-safe          # databases preserved
```

> Requires `podman`, `podman-compose` and `podman-docker` (the `docker` shim that both the
> bring-up script and `ExecStop` invoke). The first start pulls several GB and builds the
> custom UI image — `next build` needs 4–8 GiB RAM and runs for minutes, so the unit sets
> `TimeoutStartSec=1800`; raise it on a slow host. The service reports success once the
> bring-up script returns, even if a container is still warming up — check the endpoint
> lines in `journalctl` and re-run the §9 smoke test to confirm the stack is healthy.

To run it as a **system** service instead (rootful podman, root-owned containers), place the
file in `/etc/systemd/system/`, replace the `%h`-based paths with an absolute clone path
(e.g. `/opt/irys-safe-infrastructure`), and manage it with `systemctl` (no `--user`). Rootful
podman changes the networking and bind-mount behaviour described in §11, so prefer the user
service unless you have a specific reason not to.

---

## 13. Local test chain (anvil fork of Irys)

Test the wallet, the create-Safe flow and individual transaction payloads against a **disposable
local copy of Irys**, with no risk to mainnet. Nothing here can reach the real chain: anvil never
broadcasts, and stopping it discards all state.

**Why a fork, not a fresh chain.** Safe's contracts live at deterministic CREATE2 addresses, and a
bare anvil has none of them — you would have to redeploy all 13 and then override every address in
the config service, the deployments patch and the UI. Forking Irys means the contracts are *already
there, at exactly the addresses this stack is configured with*, and the fork keeps chain id 3282, so
nothing else changes. Verified: `scripts/verify_deployments.py` passes byte-for-byte against a fork.

### Quick path — chain only (best for checking payloads)

```bash
bash scripts/local_testnet.sh start          # resolves a concrete block and prints it
bash scripts/local_testnet.sh verify         # all 13 contracts, byte-for-byte
bash scripts/local_testnet.sh accounts       # funded test keys for MetaMask
bash scripts/local_testnet.sh create-safe 2  # a real 2-of-3 Safe via the canonical factory
bash scripts/local_testnet.sh stop           # discards everything
```

**Which block you fork.** `start` with no argument does not leave the block floating: it reads the
tip, backs off `LOCAL_FORK_LAG` blocks (default 10) and passes that number explicitly, then prints
it —

```
forking ... at block 2317502 (tip 2317512 minus LOCAL_FORK_LAG=10)
  re-run 'scripts/local_testnet.sh start 2317502' to reproduce this exact state
```

so every run is concrete and repeatable, and you are never forking the newest block, which is the
least reliable one (its state may not have settled upstream, and it can still be reorged away).
`start <block>` pins explicitly; `start tip` restores the genuinely unpinned behaviour, which lands
on a different block every run. The compose overlay does the same thing via `LOCAL_FORK_BLOCK`
(unset = auto-resolve and log the block, `tip` = unpinned, a number = pin).

Needs only docker or podman — `cast` runs in a container, no local foundry install. The chain
listens on `127.0.0.1:8546`. This is the fastest way to answer "what does this transaction actually
do": create a Safe, submit the payload, and inspect the resulting state directly with `cast`,
independently of anything the UI claims.

### Full path — the whole stack against the fork

Use a **separate compose project and data directory** so you cannot touch production databases.
In `.env`:

```ini
COMPOSE_PROJECT_NAME=irys-safe-local
RPC_NODE_URL=http://anvil:8545              # what the services use (in the compose network)
PUBLIC_RPC_NODE_URL=http://localhost:8546   # what the BROWSER uses (the published port)
# LOCAL_FORK_BLOCK=2317034                  # pin a block; unset = auto (tip - LOCAL_FORK_LAG)
```

Those two RPC values must differ here, and that is the one non-obvious part: the transaction
service resolves `anvil` inside the container network, while MetaMask and the wallet page run in
your browser and can only reach the published port. `scripts/configure_irys.sh` writes
`PUBLIC_RPC_NODE_URL` into the chain config the wallet reads, and leaves `RPC_NODE_URL` for the
services. Then:

```bash
docker compose -f docker-compose.yml -f docker-compose.local-chain.yml up -d anvil
bash scripts/run_locally_podman.sh
```

Wallet on <http://localhost:8000/>. Add the network to MetaMask (RPC `http://localhost:8546`, chain
id 3282, symbol IRYS) and import a key from `local_testnet.sh accounts` — those accounts hold
10000 test IRYS on the fork.

Tear down with `docker compose -f docker-compose.yml -f docker-compose.local-chain.yml down -v`
(`-v` also wipes the local Postgres volumes — safe here, never on production).

### What this is good for

- **The create-Safe flow** — the thing the deployments patch and `NEXT_PUBLIC_SAFE_VERSION` affect.
  Rebuild the UI image, create a Safe, and confirm the proxy points at the 1.5.0 singleton.
- **Signing and execution end to end**, with throwaway keys, against real contract bytecode.
- **Independent payload verification.** Build the transaction in the UI, then check the decoded
  calldata and the resulting state with `cast` against the fork. If those disagree, the UI is
  lying — which is exactly the failure mode a self-hosted signing front-end has to rule out.

### Caveats

- Fork state is ephemeral and starts at the forked block; the indexer only sees activity from
  there forward (`configure_irys.sh` aligns the start blocks automatically).
- Pin the block (or note the one that was auto-resolved) when a test result matters — an
  unpinned fork is a different chain state each run, which makes failures hard to reproduce.
- **The fork must mine on an interval.** By default anvil mines only when a transaction
  arrives, so the chain head freezes the moment a transaction is included, and anything waiting
  for confirmations *after* inclusion never completes — the wallet's "Activating your account"
  step hangs indefinitely while the Safe is, in fact, already deployed. Both the compose overlay
  and `local_testnet.sh` run the same entrypoint (`scripts/anvil-fork.sh`), which passes
  `--block-time` (`LOCAL_BLOCK_TIME`, default 9s — measured Irys Mainnet is ~8.8 s/block). To
  fix an already-running fork without losing state:
  `curl -X POST $RPC -d '{"jsonrpc":"2.0","id":1,"method":"evm_setIntervalMining","params":[9]}'`
- The Client Gateway builds its own RPC client from the chain config's `rpcUri`, which has to
  hold the *browser-reachable* URL (the config service has no internal-only RPC field the way
  it has `vpc_transaction_service_uri` for the transaction service). Against a local fork those
  two differ, so CGW's RPC-backed endpoints — relay, counterfactual checks — do not work here.
  The wallet itself does. Nothing changes in production, where both URLs are the same.
- Historical calls hit the upstream RPC on demand, so keep it reachable; pin a block for
  reproducibility.
- These test keys are published in anvil's source. Never fund them, never reuse them anywhere.

## 14. Upgrading the stack (and rehearsing it first)

Five images are pinned: transaction service, config service, client gateway, events service, and
the wallet UI base. Three of them own a Postgres database and run migrations on start, so an
upgrade is **not** a pure image swap — it has to be shown to preserve data, not merely to boot.

`scripts/upgrade_test.sh` rehearses the whole thing against a disposable fork of Irys (§13), in an
isolated copy of the repo (`TEST_DIR`, default `.upgrade-test/`) so the test stack's `./data` can
never collide with a real deployment's.

### Find out where you are

```bash
scripts/upgrade_test.sh plan            # deployed vs. latest, side by side
scripts/upgrade_test.sh probe           # deployed set, as a pinnable env fragment
scripts/upgrade_test.sh latest          # newest published tags
```

`probe` reads a **live** deployment: versions come from `/cgw/about`, `/txs/api/v1/about/` and
`/cfg/api/v1/about/`, and the UI version is extracted from the served bundle (it has no version
endpoint — the app version is a constant next to the safe-wallet-web repo URL). The events service
exposes no version endpoint at all; set `EVENTS_VERSION` by hand from the running image tag.

Save the two ends as version sets. `versions/latest.env` is checked in (newest published upstream
tags — not what any host runs); `versions/deployed.env` is **gitignored**, because naming the exact
versions a live deployment runs is an inventory an attacker can match against advisories. Generate
it on the host from `versions/deployed.env.example`.

### Rehearse the upgrade

```bash
scripts/upgrade_test.sh up       versions/deployed.env   # baseline: what production runs today
scripts/upgrade_test.sh snapshot before.json
scripts/upgrade_test.sh upgrade  versions/latest.env     # swap in place, migrations run
scripts/upgrade_test.sh snapshot after.json
scripts/upgrade_test.sh diff     before.json after.json
scripts/upgrade_test.sh down                             # removes containers AND ./data
```

`snapshot` captures service versions, applied migration counts, row counts across the four
databases, the served chain config, and the set of indexed Safe addresses. `diff` prints them
side by side and **exits 1** if a migration count went backwards, any row count shrank, a Safe
disappeared, or the chain config changed — so it is usable as a CI gate, not just a report.

Start the baseline from the *deployed* set rather than from empty: an upgrade that works on a
fresh database proves nothing about one that has to migrate months of accumulated state.

### Then pin what you tested

```bash
scripts/upgrade_test.sh down
bash scripts/pin_image_digests.sh          # digests of the set you just validated
python3 scripts/verify_deployments.py      # contracts still verify
```

Paste the digests into `ansible/vars.yml` and deploy that exact set (§10). Upgrading the UI alone
is not safe: it is built against a contemporary Client Gateway, so move all five together and
validate them as one set.

### Three steps that make a good upgrade look broken

All three were found by running the rehearsal; `upgrade_test.sh upgrade` now does them for you.

1. **Reload nginx.** It resolves upstream IPs once, at config load. Recreated containers get new
   IPs, so nginx keeps dialling the old ones and returns **502** — `/cgw/about` and the UI, but
   not `/txs` or `/cfg`, which are reached over shared unix sockets.
   `docker compose exec nginx nginx -s reload`
2. **Flush the transaction service's Redis.** It caches its own `/about` response, so after an
   upgrade it keeps reporting the **previous** version. A version check that reads it without
   flushing will tell you the upgrade did not happen when it did.
   `docker compose exec txs-redis redis-cli FLUSHALL`
3. **Use `up -d`, not `restart`.** `docker compose restart` reuses the existing container and
   therefore the **old image**. Only `up -d` recreates it against the new tag. Mixing them leaves
   a split stack — during this rehearsal the indexer ran the new code and applied migrations while
   `txs-web` still served the old one.

Verify against the **running image** (`docker compose ps` / `docker inspect`), not only the HTTP
`about` endpoints, for exactly these reasons.

### Verified compatibility: UI v1.99.1 with Client Gateway v1.115.0

Because the gateway is capped at v1.115.0 on x86 (below), the newest UI has to run against a
gateway about two months older. That pairing was rehearsed end to end against a fork and works:

- The UI image built cleanly on the `safe-wallet-web:v1.99.1` base.
- `docker/patch-irys-deployments.mjs` registered **13** v1.5.0 contracts, all `canonical`, **zero**
  `eip155` — confirmed by counting `"3282":` entries in the served `_app-*.js` bundle.
- `docker/patch-safe-versions.mjs` reported *"1.5.0 already in allowlist, nothing to do"*: upstream
  ships `['1.5.0', '1.4.1', …]` from v1.99.1, so the patch is now a no-op guard (§8).
- A Safe created through the canonical factory on the fork was indexed and served by CGW v1.115.0
  as `version: 1.5.0+L2`, threshold 2, correct owners, `implementation` = the canonical v1.5.0
  SafeL2 singleton — i.e. the `1.5.0+L2` string that needed the allowlist patch is accepted.
- Wallet-critical gateway endpoints all returned 200: `/v1/chains/3282`, `/v1/chains`,
  `.../balances/usd`, `.../transactions/queued`, `.../transactions/history`,
  `/v1/chains/3282/about/master-copies`, and `/v2/chains?serviceKey=WALLET_WEB`.

Two endpoints return non-200 and are **expected**, identically on the current production
deployment:

- `/cgw/v2/chains` → **422** `"serviceKey query parameter is required"`. It needs
  `?serviceKey=WALLET_WEB`, which is why §7b registers that service in the Config Service.
- `/cgw/v1/chains/3282/safes/<addr>/collectibles` → **404**; collectibles moved to `/v2/...`,
  which returns 200. Newer UI builds call the v2 path.

### Watch the image architecture

`safeglobal/safe-client-gateway-nest` is published **arm64-only from v1.116.0**. On an x86 host the
newest usable Client Gateway is **v1.115.0**, and `docker pull` of anything later fails with
"no matching manifest for linux/amd64" — which, if the pull error is swallowed, silently leaves the
old image running and the upgrade looking successful. `scripts/upgrade_test.sh latest` only offers
tags built for the host architecture (override with `TARGET_ARCH`), so check your host first:

```bash
ssh <host> uname -m       # x86_64 -> CGW ceiling is v1.115.0
```

### Notes

- `./data` is a **bind** mount, so `docker compose down -v` does not remove it, and its
  directories are owned by the container's postgres uid — the host user cannot delete them.
  `upgrade_test.sh down` wipes them from inside a throwaway container. A leftover `./data` is the
  usual cause of "password authentication failed" on the next bring-up: the volume was
  initialised with a different password.
- The harness drives `docker compose`; production runs rootless podman. `configure_irys.sh`
  detects the runtime and resolves container names through compose, so it works under both
  (podman-compose names containers `project_service_1`, docker compose v2 `project-service-1`).

## 15. Database backup and restore

`scripts/db_backup.sh` dumps and restores the four Postgres databases. It is production-safe: no
test overlays, works under docker or podman, and never touches the chain. Run it from the stack
directory, or set `STACK_DIR`.

```bash
bash scripts/db_backup.sh backup  ./backups/pre-upgrade-$(date +%F)
bash scripts/db_backup.sh verify  ./backups/pre-upgrade-2026-09-02
bash scripts/db_backup.sh list    ./backups/pre-upgrade-2026-09-02
bash scripts/db_backup.sh restore ./backups/pre-upgrade-2026-09-02   # asks first; FORCE=1 skips
```

**Why this is not optional before an upgrade.** Service upgrades run schema migrations on start,
and migrations are **not reversible** — putting the old image tag back does not put the old schema
back. A dump taken beforehand is the only route back. `upgrade_test.sh upgrade` takes one
automatically and **aborts if it fails**, rather than proceeding with no rollback path.

`verify` checks each dump is non-empty and ends with pg_dump's completion marker, so a truncated
dump is caught before you need it rather than after.

### Rolling back

Restore alone is not a rollback. The dumps carry the **old schema**, so the images have to go back
too or the new code will run against an old database. The manifest in each backup records the
images that were actually running when it was taken, which is what you revert to:

```bash
grep running_ ./backups/pre-upgrade-2026-09-02/manifest.txt
```

Then, in order:

1. Put those image tags back in `.env`.
2. `bash scripts/db_backup.sh restore ./backups/...`
3. `docker compose up -d` (**not** `restart` — see §14).
4. Reload nginx and flush the txs Redis (§14).

Verified end to end in the rehearsal: after rolling back from
a newer version set to the previous one, the migration counts returned to their pre-upgrade
values and the indexed Safe was still present.

### Consistency

For a strictly consistent set, stop the writers first:

```bash
docker compose stop txs-worker-indexer txs-scheduler txs-web cfg-web cgw-web events-web
bash scripts/db_backup.sh backup ./backups/cold-$(date +%F)
docker compose start txs-worker-indexer txs-scheduler txs-web cfg-web cgw-web events-web
```

A hot backup is fine for a rehearsal but can catch the indexer mid-write. Dumps contain your chain
configuration and indexed history — treat them as sensitive and store them off the host.

For a restore, stopping the writers is close to mandatory rather than merely advisable: the dump
drops and recreates every object, which needs locks a live writer holds. A restore now runs in one
transaction, so a failure leaves the database exactly as it was, and it times out on a held lock
rather than hanging.

## 16. Tests

`tests/run.sh` covers the operational scripts. No dependencies beyond bash, python3 and — for
three of the tests — docker; anything missing is reported as a skip rather than a pass.

```bash
tests/run.sh                # everything (~20s)
tests/run.sh restore digest # only tests matching these substrings
tests/run.sh --prove        # also run against BASE_REF (default HEAD) and require that every
                            # regression test FAILS there, with a real assertion failure
```

It deliberately does not chase coverage. These scripts are mostly orchestration, and a test
asserting that `compose up` was called says nothing. What is covered is the behaviour that is
*surprising* — `psql` exiting 0 after every SQL error, `compose ps` having no row for a service
it failed to create, gitignoring not excluding a file from `tar`, `${ref##*:}` yielding a digest
rather than a tag — because that is where a future edit reintroduces the bug. `tests/README.md`
lists each case and the surprise it pins.

Run `--prove` before committing a fix: the working tree has it and `HEAD` does not, so it shows
you the test failing on the real bug. A regression test that has never been seen to fail is not
evidence of anything.

## References

- safe-infrastructure: <https://github.com/safe-global/safe-infrastructure>
- Local setup: `docs/running_locally.md` · ChainInfo fields: `docs/chain_info.md`
- RPC requirements (why L2 avoids tracing): <https://docs.safe.global/core-api/api-safe-transaction-service/rpc-requirements>
- Add/edit chain: <https://docs.safe.global/config-service-configuration/add-or-edit-chain>
