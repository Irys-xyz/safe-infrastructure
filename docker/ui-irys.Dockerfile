# Custom Safe{Wallet} web image for Irys Mainnet (chain 3282).
#
# The upstream safeglobal/safe-wallet-web image bundles @safe-global/safe-deployments,
# which does not yet list chain 3282 (pending safe-deployments PR #1555). Without that
# entry the in-UI "create Safe" flow cannot resolve the Safe contract addresses for Irys,
# even though the chain itself is served correctly by the Client Gateway.
#
# The upstream start command is `yarn static-serve` (= `yarn build && yarn serve`), which
# runs `next build` on every container start. Because the app is a Next.js static export
# (`output: 'export'`), the build inlines the NEXT_PUBLIC_* values into the served bundle;
# the only reason upstream defers it to runtime is to keep the published image config-agnostic.
# This fork's UI config is fixed and committed (container_env_files/ui.env), so this image
# instead:
#   1. patches chain 3282 into safe-deployments (canonical/deterministic, identical to
#      Ethereum mainnet) so create-Safe resolves the contract addresses,
#   2. bakes the NEXT_PUBLIC_* config and runs `next build` here, at image-build time, and
#   3. overrides the start command to serve the prebuilt out/ only.
#
# Net effect: the ~4-8 GiB `next build` memory spike happens once, during image build,
# instead of on every container start, and startup is near-instant. Trade-off: the
# NEXT_PUBLIC_* values are frozen into the image -- changing the gateway URL, chain id or
# WalletConnect project id requires a rebuild (pass them as --build-arg below), not an edit
# of ui.env plus a restart. Only REVERSE_PROXY_UI_PORT still takes effect at runtime.
#
# Build (defaults match container_env_files/ui.env):
#   podman build -t localhost/safe-wallet-web-irys:3282 -f docker/ui-irys.Dockerfile .
# Override config at build time, e.g. for a real domain:
#   podman build -t localhost/safe-wallet-web-irys:3282 \
#     --build-arg NEXT_PUBLIC_GATEWAY_URL_PRODUCTION=https://safe.irys.xyz/cgw \
#     -f docker/ui-irys.Dockerfile .
FROM docker.io/safeglobal/safe-wallet-web:latest

# Patch chain 3282 into the bundled safe-deployments data. Must precede the build so the
# static export bundles the Irys addresses.
COPY docker/patch-irys-deployments.mjs /tmp/patch-irys-deployments.mjs
RUN node /tmp/patch-irys-deployments.mjs

# Patch the wallet's accepted Safe-version allowlist to include 1.5.0. @safe-global/utils hardcodes
# isValidSafeVersion = ['1.4.1' ... '1.0.0'], and assertValidSafeVersion throws
# "<version> is not a valid Safe Account version" for anything else. Irys Safes are SafeL2 1.5.0
# (canonical 0xEdd160fEBBD92E350D4D398fb636302fccd67C7e), so without this they fail validation on
# the transaction-execution path. types-kit's SafeVersion union already lists '1.5.0', so the patch
# is type-valid. Must precede the build so the static export bundles it.
COPY docker/patch-safe-versions.mjs /tmp/patch-safe-versions.mjs
RUN node /tmp/patch-safe-versions.mjs

# Deployment config baked into the static export. Defaults mirror container_env_files/ui.env;
# override with --build-arg. These NEXT_PUBLIC_* values are inlined by `next build` and cannot
# be changed at runtime afterwards. The other NEXT_PUBLIC_* keys in ui.env (Infura, Tenderly,
# Sentry, Beamer, ...) are empty by default and omitted here; to bake one, add it to this block.
ARG NEXT_PUBLIC_GATEWAY_URL_PRODUCTION=/cgw
ARG NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID=3282
ARG NEXT_PUBLIC_WC_PROJECT_ID=
ENV NEXT_PUBLIC_GATEWAY_URL_PRODUCTION=$NEXT_PUBLIC_GATEWAY_URL_PRODUCTION \
    NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID=$NEXT_PUBLIC_DEFAULT_MAINNET_CHAIN_ID \
    NEXT_PUBLIC_WC_PROJECT_ID=$NEXT_PUBLIC_WC_PROJECT_ID \
    NEXT_PUBLIC_IS_PRODUCTION=true \
    NEXT_PUBLIC_SAFE_VERSION=1.4.1

WORKDIR /app/apps/web

# Build the static export now, at image-build time. `yarn build` also runs `fetch-chains`, which
# tries to pre-fetch ${NEXT_PUBLIC_GATEWAY_URL_PRODUCTION}/v2/chains; that fetch fails during the
# build (no gateway is running, and the default relative /cgw has no origin to resolve against), so
# the script catches it, logs a warning, writes an empty cache and exits 0 (the UI fetches chains
# client-side at runtime regardless) -- exactly as it behaves when the build runs at container start.
#
# NODE_OPTIONS raises V8's heap ceiling for the build only (not persisted into the image): the
# default limit OOMs `next build` ("JavaScript heap out of memory") on RAM-constrained hosts.
# On a small host (<16 GiB) back this with swap so the heap is not cut short by a system OOM.
RUN NODE_OPTIONS="--max-old-space-size=8192" yarn build

# Best-effort: warm the `serve` package into the npx cache so runtime startup needs no network.
RUN npx -y serve --version >/dev/null 2>&1 || true

# Startup serves the prebuilt out/ only -- no build, no memory spike.
CMD ["yarn", "serve"]
