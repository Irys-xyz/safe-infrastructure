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
cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
set +a

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
RPC="${RPC_NODE_URL:-https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc}"
cfg="${PROJECT}_cfg-web_1"
txs="${PROJECT}_txs-web_1"
cgw="${PROJECT}_cgw-web_1"
eventsdb="${PROJECT}_events-db_1"

filter='rusty-rlp|objects imported|Triggering CGW|new HTTP connection|hooks/events HTTP|FeatureChains'

echo "==> Config Service: chain 3282, contracts, features, WALLET_WEB service"
podman exec -e CHAIN_RPC="$RPC" -i "$cfg" python src/manage.py shell 2>&1 <<'PY' | grep -vaE "$filter"
import os
from chains.models import Chain, Feature, Service

RPC = os.environ.get("CHAIN_RPC", "https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc")
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
    name="Irys", short_name="irys-mainnet-beta", l2=True, is_testnet=False,
    rpc_authentication="NO_AUTHENTICATION", rpc_uri=RPC,
    safe_apps_rpc_authentication="NO_AUTHENTICATION", safe_apps_rpc_uri=RPC,
    public_rpc_authentication="NO_AUTHENTICATION", public_rpc_uri=RPC,
    block_explorer_uri_address_template="https://evm-explorer.irys.xyz/address/{{address}}",
    block_explorer_uri_tx_hash_template="https://evm-explorer.irys.xyz/tx/{{txHash}}",
    block_explorer_uri_api_template="https://evm-explorer.irys.xyz/api?module={{module}}&action={{action}}&address={{address}}&apiKey={{apiKey}}",
    currency_name="Irys", currency_symbol="IRYS", currency_decimals=18,
    currency_logo_uri="chains/3282/irys_currency.png",
    transaction_service_uri="http://nginx:8000/txs", vpc_transaction_service_uri="http://nginx:8000/txs",
    recommended_master_copy_version="1.5.0", **ADDRS,
)
chain, _ = Chain.objects.update_or_create(id=3282, defaults=defaults)
svc, _ = Service.objects.get_or_create(
    key="WALLET_WEB", defaults={"name": "Safe Wallet Web", "description": "Safe{Wallet} web client"})
# REQUIRE_LOGIN_DISABLED turns off the forced Spaces sign-in (RUNBOOK §7c).
FEATURES = ["MY_ACCOUNTS", "SPENDING_LIMIT", "SAFE_APPS", "ERC1155", "ERC721",
            "DOMAIN_LOOKUP", "CONTRACT_INTERACTION", "REQUIRE_LOGIN_DISABLED"]
for key in FEATURES:
    f, _ = Feature.objects.get_or_create(key=key)
    f.chains.add(chain)     # add from the Feature side; the Chain-side M2M trips a buggy signal
    f.services.add(svc)
print("    chain 3282 + WALLET_WEB service + %d features ensured" % len(FEATURES))
PY

echo "==> Transaction Service: align contract start blocks to current tip (best effort)"
podman exec -i "$txs" python manage.py shell 2>/dev/null <<'PY'
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
  auth=$(podman exec "$cgw" printenv AUTH_TOKEN 2>/dev/null)
  [ -n "$auth" ] && break
  sleep 2
done
if [ -n "$auth" ]; then
  podman exec -i "$eventsdb" psql -U postgres -d postgres -q >/dev/null <<SQL && echo "    webhook ensured"
INSERT INTO webhook (url, description, "authorization")
VALUES ('http://nginx:8000/cgw/v1/hooks/events', 'Safe CGW cache invalidation', 'Basic ${auth}')
ON CONFLICT (url) DO UPDATE SET "authorization" = EXCLUDED."authorization", "isActive" = true;
SQL
else
  echo "    WARN: could not read AUTH_TOKEN from $cgw after retries; skipping webhook"
fi

echo "==> Irys Safe configuration applied."
