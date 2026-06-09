// Add Irys Mainnet (chain 3282) to the bundled @safe-global/safe-deployments data.
//
// safe-deployments keys each contract's deployment by chain id under
// `networkAddresses`. Chain 3282 is absent (pending safe-deployments PR #1555), so the
// UI's create-Safe flow cannot resolve Safe contract addresses for Irys. Irys uses the
// canonical (deterministic CREATE2) deployments, so for every contract that is deployed
// on Ethereum mainnet (chain 1) we register 3282 with the same deployment type. The Irys
// image (docker/ui-irys.Dockerfile) runs `next build` at image-build time, which bundles
// these patched addresses into the static export.

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire('/app/apps/web/')
const entry = require.resolve('@safe-global/safe-deployments') // .../safe-deployments/dist/index.js
const pkgRoot = dirname(dirname(entry))
console.log('safe-deployments at', pkgRoot)

let patched = 0
const walk = (d) => {
  if (!existsSync(d)) return
  for (const name of readdirSync(d)) {
    const p = join(d, name)
    if (statSync(p).isDirectory()) {
      walk(p)
      continue
    }
    if (!name.endsWith('.json')) continue
    let j
    try {
      j = JSON.parse(readFileSync(p, 'utf8'))
    } catch {
      continue
    }
    const na = j.networkAddresses
    if (na && na['1'] && !na['3282']) {
      na['3282'] = na['1']
      writeFileSync(p, JSON.stringify(j))
      patched++
    }
  }
}

walk(join(pkgRoot, 'dist', 'assets'))
walk(join(pkgRoot, 'src', 'assets'))

console.log(`irys-patch: added chain 3282 to ${patched} deployment files`)
if (patched < 10) {
  console.error('irys-patch: too few files patched — aborting')
  process.exit(1)
}
