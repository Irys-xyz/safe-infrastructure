// Register Irys Mainnet (chain 3282) in the bundled @safe-global/safe-deployments data.
//
// safe-deployments keys each contract's deployment by chain id under `networkAddresses`.
// Chain 3282 is absent from the bundled copy (pending safe-deployments PR #1555), so the
// UI's create-Safe flow cannot resolve the Safe contract addresses for Irys.
//
// SCOPE: v1.5.0 `canonical` deployments ONLY -- matching what is actually on the chain.
// Verified against chain 3282 on both mainnet-beta-rpc and mainnet-beta-rpc-2: each of the
// 13 v1.5.0 canonical addresses holds bytecode whose keccak256 equals the `codeHash` that
// safe-deployments ships, and NOTHING from v1.0.0-v1.4.1 is deployed (39 addresses, zero
// code -- including every v1.3.0 `eip155` variant). Registering those older versions would
// tell the wallet that contracts exist which do not: the create-Safe flow would build
// transactions against codeless addresses. So this patch deliberately registers only
// v1.5.0/canonical. Re-check with `scripts/verify_deployments.py` before widening it.
//
// The Irys image (docker/ui-irys.Dockerfile) runs `next build` at image-build time, which
// bundles these addresses into the static export.

import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'node:fs'
import { dirname, join, basename } from 'node:path'
import { createRequire } from 'node:module'

// Chain id to register. Defaults to Irys Mainnet; overridden for a local fork running under a
// different id so the wallet does not collide with the real network in a browser wallet
// (RUNBOOK section 13). Production always builds with the default.
const CHAIN_ID = process.env.IRYS_CHAIN_ID || '3282'
const VERSION = 'v1.5.0'
const TYPE = 'canonical'

// safe-deployments keys networkAddresses by the decimal chain id as a string. A value that is
// not one -- "0x0cd2", " 3282", "mainnet" -- would be registered under a key no consumer ever
// looks up, and the REQUIRED check below would still pass, since the contracts *are* present:
// just under a useless key. Fail the build instead.
if (!/^[1-9][0-9]*$/.test(CHAIN_ID)) {
  console.error(`irys-patch: FAILED — IRYS_CHAIN_ID must be a positive decimal chain id, got ${JSON.stringify(CHAIN_ID)}`)
  process.exit(1)
}

// The contracts this stack actually depends on: the eight the Config Service records for the
// chain (scripts/configure_irys.sh). If any is missing from the bundled package, fail the
// build rather than ship a UI that silently cannot create or execute a Safe.
const REQUIRED = [
  'safe_l2',
  'safe_proxy_factory',
  'multi_send',
  'multi_send_call_only',
  'compatibility_fallback_handler',
  'sign_message_lib',
  'create_call',
  'simulate_tx_accessor',
]

const require = createRequire('/app/apps/web/')
const entry = require.resolve('@safe-global/safe-deployments') // .../safe-deployments/dist/index.js
const pkgRoot = dirname(dirname(entry))
console.log('safe-deployments at', pkgRoot)

const registered = new Set()
const skipped = []
let written = 0
let dirsSeen = 0

const patchDir = (dir) => {
  if (!existsSync(dir)) return
  dirsSeen++
  for (const name of readdirSync(dir)) {
    if (!name.endsWith('.json')) continue
    const p = join(dir, name)
    if (!statSync(p).isFile()) continue

    let j
    try {
      j = JSON.parse(readFileSync(p, 'utf8'))
    } catch {
      continue
    }

    const na = j.networkAddresses
    if (!na || typeof na !== 'object') continue
    const contract = basename(name, '.json')

    // Only register a deployment type this file actually ships.
    if (!j.deployments || !j.deployments[TYPE]) {
      skipped.push(`${contract} (no ${TYPE} deployment)`)
      continue
    }

    const existing = na[CHAIN_ID]
    if (existing !== undefined) {
      // Already present -- e.g. the upstream PR landed and the bundled package has 3282.
      const ok = existing === TYPE || (Array.isArray(existing) && existing.includes(TYPE))
      if (ok) registered.add(contract)
      else skipped.push(`${contract} (chain ${CHAIN_ID} already set to ${JSON.stringify(existing)})`)
      continue
    }

    na[CHAIN_ID] = TYPE
    writeFileSync(p, JSON.stringify(j))
    registered.add(contract)
    written++
  }
}

// `dist` is what `next build` actually consumes, so patching only `src` is not a success:
// track it separately rather than counting both directories together.
let distPatched = false
for (const root of ['dist', 'src']) {
  const before = dirsSeen
  patchDir(join(pkgRoot, root, 'assets', VERSION))
  if (root === 'dist' && dirsSeen > before) distPatched = true
}

if (dirsSeen === 0) {
  console.error(`irys-patch: FAILED — no ${VERSION} asset directory under ${pkgRoot}/{dist,src}/assets`)
  console.error('The bundled @safe-global/safe-deployments predates the v1.5.0 assets, or its layout changed.')
  process.exit(1)
}
if (!distPatched) {
  console.error(`irys-patch: FAILED — ${pkgRoot}/dist/assets/${VERSION} is missing; only src was patched.`)
  console.error('`next build` resolves the package through dist, so the built bundle would not have chain ' + CHAIN_ID + '.')
  process.exit(1)
}

console.log(
  `irys-patch: chain ${CHAIN_ID} -> ${TYPE} for ${registered.size} ${VERSION} contracts ` +
    `(${written} file writes across ${dirsSeen} asset dir(s))`,
)
if (skipped.length) console.log(`irys-patch: skipped ${skipped.length}: ${skipped.join(', ')}`)

const missing = REQUIRED.filter((c) => !registered.has(c))
if (missing.length) {
  console.error(`irys-patch: FAILED — required ${VERSION} contracts not registered: ${missing.join(', ')}`)
  process.exit(1)
}
console.log(`irys-patch: all ${REQUIRED.length} required contracts registered`)
