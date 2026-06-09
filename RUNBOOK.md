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

`container_env_files/*.env` are **tracked by git** in this repo. This scaffold writes real secrets into
them (see table below). For local use this is fine. **Do not push this clone anywhere with those secrets
committed.** Before any remote/production deployment, rotate every secret and move them out of version
control (e.g. an untracked `.env` / secrets manager).

---

## 2. What was pre-configured

| File | Key | Value |
| --- | --- | --- |
| `.env` | `RPC_NODE_URL` | placeholder `REPLACE_WITH_IRYS_MAINNET_RPC` — **you must set this** to the public RPC in §1 |
| `container_env_files/ui.env` | `NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID` | `3282` |
| `container_env_files/cgw.env` | `AUTH_TOKEN` | `<AUTH_TOKEN>` |
| `container_env_files/cfg.env` | `CGW_AUTH_TOKEN` | `<AUTH_TOKEN>` (must match `AUTH_TOKEN`) |
| `container_env_files/cfg.env` | `SECRET_KEY` | generated random key |
| `container_env_files/txs.env` | `DJANGO_SECRET_KEY` | generated random key |

Image versions are left at `latest` in `.env`. After the first successful run, pin them to the exact tags
reported by `docker images` for reproducibility.

Postgres passwords, the Config Service admin (`root` / `admin`), and the Events admin
(`admin@safe` / `password`) are left at their repo defaults — fine for local, **rotate for production**.

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
idempotent. The wallet UI is then at <http://localhost:8080/>; admin and APIs are on `:8000`.

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

Endpoints once up:

- Web UI: <http://localhost:8000/>
- Config admin: <http://localhost:8000/cfg/admin/> (`root` / `admin`)
- Tx-service admin: <http://localhost:8000/txs/admin/>
- Events admin: <http://localhost:8000/events/admin/> (`admin@safe` / `password`)
- Chains API (verify your config): <http://localhost:8000/cfg/api/v1/chains>

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
data: Irys uses the canonical (deterministic) deployments, so 3282 is registered with the same address as
Ethereum mainnet for every contract (`docker/patch-irys-deployments.mjs`). The image runs `next build`
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
lagged. To verify after a rebuild, the version array adjacent to `is not a valid Safe Account version` in
`out/_next/static/chunks/pages/_app-*.js` should start with `["1.5.0", …]`.

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

- **Rotate every secret**: `DJANGO_SECRET_KEY` (txs), `SECRET_KEY` (cfg), all four `POSTGRES_PASSWORD`,
  `AUTH_TOKEN` / `CGW_AUTH_TOKEN`, Events `ADMIN_PASSWORD`, `DJANGO_SUPERUSER_PASSWORD`, `JWT_SECRET`,
  `FINGERPRINT_ENCRYPTION_KEY`. Move them out of tracked files.
- **TLS and domain**: the bundled nginx serves plain HTTP on `:8000`. Put a TLS-terminating proxy
  (Caddy, Traefik, nginx) in front. Update `DJANGO_ALLOWED_HOSTS`, `CSRF_TRUSTED_ORIGINS`, `MEDIA_URL`
  (cfg), `CGW_URL` (cfg), and `SAFE_CONFIG_BASE_URI` (cgw) to the real host — e.g. `https://safe.irys.xyz`
  with paths `/cfg`, `/cgw`, `/txs`, `/events`. The UI's `NEXT_PUBLIC_GATEWAY_URL_PRODUCTION` stays the
  relative `/cgw` (same-origin behind the proxy — no rebuild); give it an absolute URL only if the Client
  Gateway is served from a different origin than the UI.
- **Pin image versions** in `.env` instead of `latest`.
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

## References

- safe-infrastructure: <https://github.com/safe-global/safe-infrastructure>
- Local setup: `docs/running_locally.md` · ChainInfo fields: `docs/chain_info.md`
- RPC requirements (why L2 avoids tracing): <https://docs.safe.global/core-api/api-safe-transaction-service/rpc-requirements>
- Add/edit chain: <https://docs.safe.global/config-service-configuration/add-or-edit-chain>
