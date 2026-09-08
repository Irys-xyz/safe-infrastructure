#!/usr/bin/env python3
"""Verify the Safe contracts this stack trusts against what is actually on Irys Mainnet.

Run before a deploy, and on a schedule. It answers the question that matters for a signing
UI: are the addresses the wallet builds transactions against really the audited Safe
contracts, on this chain, right now?

Three checks, against EVERY configured RPC independently (a single endpoint that lies is
exactly the threat this guards against):

  1. chainId is 3282.
  2. Each v1.5.0 canonical contract has code whose keccak256 equals the codeHash published
     in @safe-global/safe-deployments. This is the whole trust anchor: it proves the address
     holds the audited bytecode rather than merely holding *something*.
  3. The v1.4.1 / v1.3.0 singletons and proxy factories are still ABSENT. Nothing older than
     v1.5.0 is deployed on Irys, and docker/patch-irys-deployments.mjs deliberately registers
     only v1.5.0 for that reason. If a proxy factory ever appears here WITHOUT its matching
     singleton, the create-Safe flow could deploy a proxy pointing at codeless code -- a Safe
     that is bricked, with anything sent to it unrecoverable. Treat a hit as a blocker.

Addresses and codeHashes below are the canonical (deterministic CREATE2) v1.5.0 deployments,
taken from safe-deployments. Keeping them inline makes this an INDEPENDENT oracle rather than
a restatement of the file it is meant to check.

No third-party dependencies (keccak256 is implemented below), so it runs anywhere python3 does.

Usage:
  python3 scripts/verify_deployments.py
  python3 scripts/verify_deployments.py --rpc https://my-node/... --rpc https://other/...
Exit code 0 = all checks passed on all endpoints; 1 = at least one failed.
"""

import argparse
import json
import sys
import urllib.request

DEFAULT_RPCS = [
    "https://mainnet-beta-rpc.irys.xyz/v1/execution-rpc",
    "https://mainnet-beta-rpc-2.irys.xyz/v1/execution-rpc",
]
# Irys Mainnet. A local fork may run under a different id (RUNBOOK section 13); the contracts
# are CREATE2-deterministic and therefore at the same addresses regardless, so only this
# assertion needs to change -- pass --chain-id.
CHAIN_ID = 3282

# v1.5.0 canonical: contract -> (address, keccak256(runtime bytecode))
MUST_BE_PRESENT = {
    "compatibility_fallback_handler": ("0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4", "0x3c6a85bcf7b563daa624b884b4e9a1b9fa5371edde7be945d998071a48f28bbc"),
    "create_call": ("0x2Ef5ECfbea521449E4De05EDB1ce63B75eDA90B4", "0x6b7d8d29bdf7004c4617d95041923774f3f7e74b056bff55c1861c9ec92ce54f"),
    "extensible_fallback_handler": ("0x85a8ca358D388530ad0fB95D0cb89Dd44Fc242c3", "0xba5bafdfba82e226b6dc8ae29bedf5026bd854ab4bee00128ca322717a5f2acf"),
    "multi_send": ("0x218543288004CD07832472D464648173c77D7eB7", "0xca1147a12963172a93910c5cb2bfa5ad0e941c7f03fc7eb017dd06a8ea4e5604"),
    "multi_send_call_only": ("0xA83c336B20401Af773B6219BA5027174338D1836", "0xcdbdcec38d2f1c7d961b0029ff8416b7e86e9974d6f0e9c9580c7d17fcfb6663"),
    "safe": ("0xFf51A5898e281Db6DfC7855790607438dF2ca44b", "0xdda019cbd7c867a533a2a86e5c53434fdc50b13122b5a5ddb4a8df61b31c20f2"),
    "safe_l2": ("0xEdd160fEBBD92E350D4D398fb636302fccd67C7e", "0x180193227186ccb85316c94db1f0d156ed932b14712cfaac78901899178572dc"),
    "safe_migration": ("0x6439e7ABD8Bb915A5263094784C5CF561c4172AC", "0x52d7472fa02c3a574544f9b5a4ed4c7777e4e3315217e368926b51e1cc6014ea"),
    "safe_proxy_factory": ("0x14F2982D601c9458F93bd70B218933A6f8165e7b", "0x967dae4cda22b0c9ef7f31b010bdc1ceb0af9904b0c3dc060b5302e4c18a4529"),
    "safe_to_l2_setup": ("0x900C7589200010D6C6eCaaE5B06EBe653bc2D82a", "0xf6034d841bcbff8912aa55526b0f1609212536aaf60bb16f5e8a269a4ab38f18"),
    "sign_message_lib": ("0x4FfeF8222648872B3dE295Ba1e49110E61f5b5aa", "0xd61840855da008da59a00fc03fb71455b4f70bdca1f56f9504f072ed8d90c50e"),
    "simulate_tx_accessor": ("0x07EfA797c55B5DdE3698d876b277aBb6B893654C", "0x706db4bb6151f75a5b3845724174e201c59046dfbe65b4e5909ad4b88f8f752d"),
    "token_callback_handler": ("0x54e86d004d71a8D2112ec75FaCE57D730b0433F3", "0xcbc723172700efa52cc33ee26c7fc7e284edc8097f9dc307857fe525fec98cd8"),
}

# Older-version singletons and proxy factories: must have no code on Irys.
MUST_BE_ABSENT = {
    "v1.4.1/safe": "0x41675C099F32341bf84BFc5382aF534df5C7461a",
    "v1.4.1/safe_l2": "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762",
    "v1.4.1/safe_proxy_factory": "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67",
    "v1.3.0/gnosis_safe": "0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552",
    "v1.3.0/gnosis_safe_l2": "0x3E5c63644E683549055b9Be8653de26E0B4CD36E",
    "v1.3.0/proxy_factory": "0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2",
}

# --- keccak256 (FIPS-202 Keccak-f[1600], 0x01 domain suffix -- Ethereum's variant) ---------
_M = (1 << 64) - 1
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
       0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
       0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
       0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
       0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_R = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
      [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _M if n else x


def _permute(A):
    for rnd in range(24):
        C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
        D = [C[(x - 1) % 5] ^ _rol(C[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                A[x][y] ^= D[x]
        B = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                B[y][(2 * x + 3 * y) % 5] = _rol(A[x][y], _R[x][y])
        for x in range(5):
            for y in range(5):
                A[x][y] = B[x][y] ^ ((B[(x + 1) % 5][y] ^ _M) & B[(x + 2) % 5][y])
        A[0][0] ^= _RC[rnd]
    return A


def keccak256(data):
    rate = 136
    buf = bytearray(data)
    buf.append(0x01)
    while len(buf) % rate:
        buf.append(0x00)
    buf[-1] |= 0x80
    A = [[0] * 5 for _ in range(5)]
    for off in range(0, len(buf), rate):
        block = buf[off:off + rate]
        for i in range(rate // 8):
            A[i % 5][i // 5] ^= int.from_bytes(block[8 * i:8 * i + 8], "little")
        _permute(A)
    out = bytearray()
    for i in range(4):
        out += A[i % 5][i // 5].to_bytes(8, "little")
    return bytes(out)


def _self_test():
    """Refuse to report results from an arithmetic we have not just proven correct."""
    vectors = {
        b"": "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        b"abc": "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
        # >136 bytes, so the multi-block absorb path is covered too
        b"a" * 200: "96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d",
    }
    for data, want in vectors.items():
        got = keccak256(data).hex()
        if got != want:
            sys.exit(f"FATAL: keccak256 self-test failed ({len(data)}-byte input)")


# --- RPC -----------------------------------------------------------------------------------
def _post(url, payload):
    # Some providers reject the default python-urllib User-Agent outright.
    req = urllib.request.Request(
        url, json.dumps(payload).encode(),
        {"Content-Type": "application/json", "User-Agent": "curl/8"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def rpc(url, method, params):
    payload = _post(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    if "error" in payload:
        raise RuntimeError(payload["error"])
    return payload["result"]


def get_code_many(url, addresses, chunk=20):
    """eth_getCode for many addresses using JSON-RPC batches.

    One request per chunk instead of one per address: 40+ sequential round-trips is slow
    enough to be skipped in CI, and a check that gets skipped protects nothing. Falls back
    to single calls if the endpoint rejects batching.
    """
    out = {}
    for i in range(0, len(addresses), chunk):
        part = addresses[i:i + chunk]
        calls = [{"jsonrpc": "2.0", "id": j, "method": "eth_getCode",
                  "params": [a, "latest"]} for j, a in enumerate(part)]
        try:
            resp = _post(url, calls)
            if not isinstance(resp, list):
                raise RuntimeError("endpoint did not return a batch response")
            by_id = {r["id"]: r for r in resp}
            for j, a in enumerate(part):
                r = by_id.get(j, {})
                out[a] = RuntimeError(r["error"]) if "error" in r else r.get("result")
        except Exception:
            for a in part:
                try:
                    out[a] = rpc(url, "eth_getCode", [a, "latest"])
                except Exception as e:
                    out[a] = RuntimeError(str(e))
    return out


def check(url):
    """Run all checks against one endpoint. Returns the list of failures."""
    fails = []
    print(f"\n== {url}")

    try:
        cid = int(rpc(url, "eth_chainId", []), 16)
    except Exception as e:
        fails.append(f"{url}: unreachable ({e})")
        print(f"  UNREACHABLE  {e}")
        return fails
    if cid != CHAIN_ID:
        fails.append(f"{url}: chainId {cid}, expected {CHAIN_ID}")
        print(f"  FAIL  chainId {cid} != {CHAIN_ID}")
        return fails
    print(f"  ok    chainId {cid}")

    wanted = [a for a, _ in MUST_BE_PRESENT.values()] + list(MUST_BE_ABSENT.values())
    codes = get_code_many(url, wanted)

    for name, (addr, want) in sorted(MUST_BE_PRESENT.items()):
        code = codes.get(addr)
        if isinstance(code, Exception):
            fails.append(f"{url}: {name}: RPC error {code}")
            print(f"  ERROR {name}: {code}")
            continue
        if code in ("0x", "", None):
            fails.append(f"{url}: {name} ({addr}) HAS NO CODE")
            print(f"  FAIL  {name:32} no code at {addr}")
            continue
        got = "0x" + keccak256(bytes.fromhex(code[2:])).hex()
        if got.lower() != want.lower():
            fails.append(f"{url}: {name} ({addr}) WRONG BYTECODE: {got} != {want}")
            print(f"  FAIL  {name:32} bytecode mismatch at {addr}")
            print(f"        got  {got}\n        want {want}")
        else:
            print(f"  ok    {name:32} {addr}")

    for name, addr in MUST_BE_ABSENT.items():
        code = codes.get(addr)
        # A must-be-absent address whose state we could not read is not a pass. An endpoint
        # that refuses these queries would otherwise satisfy the check by saying nothing.
        if isinstance(code, Exception):
            fails.append(f"{url}: {name}: RPC error on a must-be-absent address: {code}")
            print(f"  ERROR {name:32} {code}")
            continue
        if code not in ("0x", "", None):
            # A blocker, per the contract at the top of this file: a proxy factory reachable
            # without its matching singleton means the create-Safe flow can deploy a proxy
            # pointing at codeless code -- a bricked Safe, with anything sent to it lost.
            fails.append(
                f"{url}: {name} ({addr}) now HAS code — an older Safe version has been "
                f"deployed to Irys. Re-run the full audit before widening "
                f"docker/patch-irys-deployments.mjs, and confirm no proxy factory is "
                f"reachable without its matching singleton.")
            print(f"  FAIL  {name:32} unexpectedly has code at {addr}")
        else:
            print(f"  ok    {name:32} absent (as expected)")
    return fails


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    global CHAIN_ID
    ap.add_argument("--rpc", action="append", metavar="URL",
                    help="RPC endpoint (repeatable). Defaults to both public Irys endpoints.")
    ap.add_argument("--chain-id", type=int, default=CHAIN_ID, metavar="N",
                    help="expected chain id (default %(default)s; use it for a local fork "
                         "running under a different id)")
    args = ap.parse_args()
    CHAIN_ID = args.chain_id

    _self_test()
    rpcs = args.rpc or DEFAULT_RPCS
    print(f"Verifying {len(MUST_BE_PRESENT)} v1.5.0 contracts + "
          f"{len(MUST_BE_ABSENT)} must-be-absent addresses on chain {CHAIN_ID} "
          f"across {len(rpcs)} endpoint(s)")

    all_fails = []
    for url in rpcs:
        all_fails += check(url)

    print("\n" + "=" * 78)
    if all_fails:
        for f in all_fails:
            print(f"FAIL: {f}")
        print(f"\n{len(all_fails)} FAILURE(S) — do not deploy against these contracts.")
        return 1
    print(f"PASS: all {len(MUST_BE_PRESENT)} v1.5.0 contracts verified byte-for-byte, and all "
          f"{len(MUST_BE_ABSENT)} must-be-absent addresses confirmed codeless, on "
          f"{len(rpcs)} endpoint(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
