#!/usr/bin/env bash
#
# Idempotently apply the Irys Mainnet (chain 3282) Safe configuration to a
# running stack. Safe to re-run. Covers everything that is NOT captured by
# docker-compose / the database image defaults:
#
#   - Config Service: chain 3282 (RUNBOOK §4), the v1.5.0 contract addresses
#     (§5), the seven UI features, the REQUIRE_LOGIN_DISABLED gate flag (§7c),
#     and the WALLET_WEB service the v2 chains API requires (§7b).
#   - Transaction Service: align the contract indexing start blocks to the
#     current chain tip (best effort; skipped if contracts not yet registered).
#   - Events Service: the cache-invalidation webhook to the Client Gateway (§7).
#
# run_locally_podman.sh calls this after the stack is up; it can also be run
# standalone once the stack is healthy.

set -o pipefail
cd "$(dirname "$0")/.." || { echo "error: cannot cd to the repo root" >&2; exit 1; }

# shellcheck source=lib/stack.sh
. "$(dirname "$0")/lib/stack.sh"

set -a
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
set +a

# Container runtime and compose front-end. The stack runs under rootless podman in production,
# but the same script has to work under docker compose for local testing (RUNBOOK section 13) --
# the two differ in both the exec command and the container naming scheme
# (podman-compose: project_service_1, docker compose v2: project-service-1).
RUNTIME=$(resolve_runtime)
COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"

# RPC the *services* use (resolved inside the container network).
RPC="${RPC_NODE_URL:-https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc}"
# RPC written into the chain config. The config service's Chain model has three RPC fields
# (rpc_uri, safe_apps_rpc_uri, public_rpc_uri) and they are ALL served to clients in the
# chains API -- there is no vpc_ variant the way there is for the transaction service, so the
# in-network address cannot be advertised separately. All three therefore get the
# browser-reachable URL, which is the only one the wallet can use to read state, build and
# sign. Normally it is identical to $RPC.
#
# Consequence on the local-fork path (§13), where the two differ (services: http://anvil:8545,
# browser: http://localhost:8546): the Client Gateway also builds its own RPC client from
# rpc_uri, and that URL does not resolve inside its container. Its RPC-backed endpoints
# (relay, counterfactual checks) therefore do not work against a local fork. The wallet does,
# which is the trade the single field forces. Nothing changes in production, where both vars
# hold the same public URL.
PUBLIC_RPC="${PUBLIC_RPC_NODE_URL:-$RPC}"

# `exit` inside a command substitution only leaves the subshell, so the callers below have to
# propagate the status themselves -- without the `|| exit 1` this printed one error per service
# and then carried on with empty container names.
svc_container() {
  local c
  c=$(cname "$1") || { echo "error: no container for service $1 -- is the stack up?" >&2; return 1; }
  echo "$c"
}
cfg=$(svc_container cfg-web)      || exit 1
txs=$(svc_container txs-web)      || exit 1
cgw=$(svc_container cgw-web)      || exit 1
eventsdb=$(svc_container events-db) || exit 1

filter='rusty-rlp|objects imported|Triggering CGW|new HTTP connection|hooks/events HTTP|FeatureChains'

# Public base URL of this deployment, used for the browser-facing transaction-service URI.
# Set IRYS_PUBLIC_ORIGIN=https://safe.irys.xyz (Ansible does) to advertise the real origin.
PUBLIC_TXS_URI="${IRYS_PUBLIC_ORIGIN:+${IRYS_PUBLIC_ORIGIN}/txs}"

# Chain id to configure -- see chain_id() in lib/stack.sh. Build the UI image with the same
# IRYS_CHAIN_ID, since it is baked in (RUNBOOK section 13).
CHAIN_ID=$(chain_id)

echo "==> Config Service: chain $CHAIN_ID, contracts, features, WALLET_WEB service"
$RUNTIME exec -e CHAIN_RPC="$PUBLIC_RPC" -e PUBLIC_TXS_URI="$PUBLIC_TXS_URI" \
  -e GAS_MAX_FEE_WEI="${GAS_MAX_FEE_WEI:-}" -e GAS_MAX_PRIORITY_FEE_WEI="${GAS_MAX_PRIORITY_FEE_WEI:-}" \
  -e CHAIN_ID="$CHAIN_ID" -i "$cfg" python src/manage.py shell 2>&1 <<'PY' | grep -vaE "$filter"
import os
from chains.models import Chain, Feature, Service

RPC = os.environ.get("CHAIN_RPC", "https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc")
CHAIN_ID = int(os.environ.get("CHAIN_ID") or 3282)
IS_PROD_CHAIN = CHAIN_ID == 3282
# Label a non-production chain distinctly: the wallet shows this name, and "Irys" appearing
# twice (once real, once a fork) is exactly the ambiguity a separate chain id is meant to avoid.
NAME = "Irys" if IS_PROD_CHAIN else "Irys Local Fork"
SHORT_NAME = "irys-mainnet-beta" if IS_PROD_CHAIN else "irys-local-%d" % CHAIN_ID
ADDRS = dict(
    safe_singleton_address="0xEdd160fEBBD92E350D4D398fb636302fccd67C7e",
    safe_proxy_factory_address="0x14F2982D601c9458F93bd70B218933A6f8165e7b",
    multi_send_address="0x218543288004CD07832472D464648173c77D7eB7",
    multi_send_call_only_address="0xA83c336B20401Af773B6219BA5027174338D1836",
    fallback_handler_address="0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4",
    sign_message_lib_address="0x4FfeF8222648872B3dE295Ba1e49110E61f5b5aa",
    create_call_address="0x2Ef5ECfbea521449E4De05EDB1ce63B75eDA90B4",
    simulate_tx_accessor_address="0x07EfA797c55B5DdE3698d876b277aBb6B893654C",
)
defaults = dict(
    name=NAME, short_name=SHORT_NAME, l2=True, is_testnet=not IS_PROD_CHAIN,
    rpc_authentication="NO_AUTHENTICATION", rpc_uri=RPC,
    safe_apps_rpc_authentication="NO_AUTHENTICATION", safe_apps_rpc_uri=RPC,
    public_rpc_authentication="NO_AUTHENTICATION", public_rpc_uri=RPC,
    block_explorer_uri_address_template="https://evm-explorer.irys.xyz/address/{{address}}",
    block_explorer_uri_tx_hash_template="https://evm-explorer.irys.xyz/tx/{{txHash}}",
    block_explorer_uri_api_template="https://evm-explorer.irys.xyz/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}",
    currency_name="Irys", currency_symbol="IRYS", currency_decimals=18,
    # CoinGecko coin id for the native currency. Without it the Client Gateway logs
    # "pricesProvider.nativeCoinId is not defined" on every balance request and the wallet
    # shows no fiat value for IRYS at all.
    #
    # prices_provider_chain_name is deliberately left unset: it is the CoinGecko *asset
    # platform* id, used to price ERC-20s by contract address, and CoinGecko has no platform
    # for chain 3282. Setting it to anything would just produce failed lookups. ERC-20 tokens
    # on Irys therefore have no fiat value until CoinGecko lists the chain.
    prices_provider_native_coin=os.environ.get("PRICES_NATIVE_COIN") or "irys",
    # currency_logo_uri is deliberately absent here and set after the chain is saved, only if
    # the image really exists in MEDIA_ROOT -- pointing at a missing file makes the wallet
    # render the native currency as a generic unknown token.
    #
    # transaction_service_uri is public (served to browsers in the chain config); the vpc_ one is
    # the in-network address the Client Gateway calls. Keeping the internal http://nginx:8000 in
    # the public field leaks the container topology and breaks any client that reads it.
    transaction_service_uri=(os.environ.get("PUBLIC_TXS_URI") or "http://nginx:8000/txs"),
    vpc_transaction_service_uri="http://nginx:8000/txs",
    recommended_master_copy_version="1.5.0", **ADDRS,
)
chain, _ = Chain.objects.update_or_create(id=CHAIN_ID, defaults=defaults)

# Native-currency logo. MEDIA_ROOT is a volume (docker-compose.yml), so this survives a
# recreate. Only claim the logo when the file is present: an ImageField pointing at a missing
# file serves a 404, and the wallet then draws IRYS as an unnamed generic token.
import os.path
from django.conf import settings
_logo_rel = "chains/%d/irys_currency.png" % CHAIN_ID
_logo_abs = os.path.join(str(settings.MEDIA_ROOT), _logo_rel)
if os.path.exists(_logo_abs):
    if str(chain.currency_logo_uri) != _logo_rel:
        chain.currency_logo_uri = _logo_rel
        chain.save(update_fields=["currency_logo_uri"])
    print("    currency logo present (%s)" % _logo_rel)
else:
    if str(chain.currency_logo_uri or ""):
        chain.currency_logo_uri = ""
        chain.save(update_fields=["currency_logo_uri"])
    print("    WARN: %s missing under MEDIA_ROOT -- native currency will have no icon." % _logo_rel)
    print("          Install it with: scripts/install_currency_logo.sh")

# Gas price. Without at least one GasPrice row the chains API serves "gasPrice": [], and the
# wallet has no fee data to build or price a transaction with -- which shows up as the UI
# hanging on execution or on activating a counterfactual Safe. Irys has no public gas oracle,
# so configure a fixed EIP-1559 pair (it reports baseFeePerGas ~7 wei and a 1 gwei priority
# fee, so 1 gwei priority / 3 gwei cap is ample headroom). Override via the env if that changes.
from chains.models import GasPrice

def _wei(var, default):
    raw = os.environ.get(var) or ""
    if not raw:
        return default
    if not raw.strip().isdigit():
        raise SystemExit("    ERROR: %s must be a decimal number of wei, got %r" % (var, raw))
    return int(raw)

# rank is part of the lookup, not just the defaults: GasPrice is a per-chain *ranked*
# collection, so several rows per chain are a supported state. Filtering on chain alone raised
# MultipleObjectsReturned as soon as a second row existed (one added through the admin), which
# aborted this script after the chain was written but before the features and the webhook.
GasPrice.objects.update_or_create(
    chain=chain, rank=100,
    defaults=dict(
        max_fee_per_gas=_wei("GAS_MAX_FEE_WEI", 3_000_000_000),
        max_priority_fee_per_gas=_wei("GAS_MAX_PRIORITY_FEE_WEI", 1_000_000_000),
    ),
)
print("    gas price configured (fixed EIP-1559)")
svc, _ = Service.objects.get_or_create(
    key="WALLET_WEB", defaults={"name": "Safe Wallet Web", "description": "Safe{Wallet} web client"})
# Chain features the wallet checks with useHasFeature(). A missing key does not degrade
# gracefully -- the UI hides the whole surface. NESTED_SAFES in particular gates the
# owned-Safes query outright (`skip: !enabled`), so without it the wallet never discovers
# which Safes a Safe owns and the nested-Safe UI is simply absent.
# REQUIRE_LOGIN_DISABLED turns off the forced Spaces sign-in (RUNBOOK section 7c).
FEATURES = ["MY_ACCOUNTS", "SPENDING_LIMIT", "SAFE_APPS", "ERC1155", "ERC721",
            "DOMAIN_LOOKUP", "CONTRACT_INTERACTION", "REQUIRE_LOGIN_DISABLED",
            "NESTED_SAFES"]
for key in FEATURES:
    f, _ = Feature.objects.get_or_create(key=key)
    f.chains.add(chain)     # add from the Feature side; the Chain-side M2M trips a buggy signal
    f.services.add(svc)
print("    chain %d (%s) + WALLET_WEB service + %d features ensured" % (CHAIN_ID, NAME, len(FEATURES)))
PY

echo "==> Transaction Service: align contract start blocks to current tip (best effort)"
$RUNTIME exec -i "$txs" python manage.py shell 2>/dev/null <<'PY'
import os, requests
from safe_transaction_service.history.models import SafeMasterCopy, ProxyFactory
try:
    tip = int(requests.post(os.environ["ETHEREUM_NODE_URL"],
        json={"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []},
        timeout=10).json()["result"], 16)
except Exception:
    tip = None
n = 0
if tip:
    for M in (SafeMasterCopy, ProxyFactory):
        for o in M.objects.all():
            if (o.initial_block_number or 0) < tip:
                o.initial_block_number = tip
            if (o.tx_block_number or 0) < tip:
                o.tx_block_number = tip
            o.save(); n += 1
print("    aligned %d contracts to block %s" % (n, tip) if tip else "    skipped (no tip / no contracts yet)")
PY

echo "==> Events Service: cache-invalidation webhook -> Client Gateway"
# Read CGW's AUTH_TOKEN, retrying for ~30s. This step runs right after bring-up, when cgw-web
# may still be booting (or mid-restart); a single empty read would silently skip the webhook
# and leave CGW caches stale until the next manual run.
auth=""
for _ in $(seq 1 15); do
  auth=$($RUNTIME exec "$cgw" printenv AUTH_TOKEN 2>/dev/null)
  [ -n "$auth" ] && break
  sleep 2
done
if [ -n "$auth" ]; then
  $RUNTIME exec -i "$eventsdb" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 >/dev/null <<SQL && echo "    webhook ensured"
INSERT INTO webhook (url, description, "authorization")
VALUES ('http://nginx:8000/cgw/v1/hooks/events', 'Safe CGW cache invalidation', 'Basic ${auth}')
ON CONFLICT (url) DO UPDATE SET "authorization" = EXCLUDED."authorization", "isActive" = true;
SQL
else
  echo "    WARN: could not read AUTH_TOKEN from $cgw after retries; skipping webhook"
fi

echo "==> Irys Safe configuration applied."
