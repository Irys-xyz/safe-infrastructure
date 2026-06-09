// Add Safe 1.5.0 to the wallet's accepted Safe-version allowlist.
//
// @safe-global/utils hardcodes the supported versions in isValidSafeVersion:
//   const SAFE_VERSIONS: SafeVersion[] = ['1.4.1', '1.3.0', '1.2.0', '1.1.1', '1.0.0']
// and assertValidSafeVersion throws "<version> is not a valid Safe Account version" for anything
// else. Irys Mainnet's Safe singleton is the canonical SafeL2 1.5.0 (0xEdd160fEBBD92E350D4D398fb636302fccd67C7e),
// so every Safe reports version 1.5.0+L2 and trips this assertion on the transaction-execution path.
//
// The rest of the stack already supports 1.5.0: the on-chain contracts, the transaction service
// (singleton registered as "SafeL2 1.5.0"), @safe-global/types-kit (its SafeVersion union already
// lists '1.5.0') and @safe-global/safe-deployments (ships v1.5.0 assets, which docker/patch-irys-deployments.mjs
// maps onto chain 3282). Only this allowlist was never updated, so adding '1.5.0' is type-valid and
// sufficient. This runs at image-build time, before `next build`, so the static export bundles the fix.

import { readFileSync, writeFileSync, existsSync } from 'node:fs'

const file = '/app/packages/utils/src/services/contracts/utils.ts'

if (!existsSync(file)) {
  console.error(`irys-patch(safe-versions): ${file} not found — upstream layout changed`)
  process.exit(1)
}

let src = readFileSync(file, 'utf8')

// Capture the allowlist array body so the 1.5.0 check is scoped to it (the file may mention
// other versions elsewhere). Abort loudly if upstream renames or reshapes the declaration.
const re = /(const SAFE_VERSIONS: SafeVersion\[\] = \[)([^\]]*)(\])/
const m = src.match(re)
if (!m) {
  console.error('irys-patch(safe-versions): SAFE_VERSIONS allowlist not found — upstream layout changed')
  process.exit(1)
}

if (m[2].includes("'1.5.0'")) {
  console.log('irys-patch(safe-versions): 1.5.0 already in allowlist, nothing to do')
  process.exit(0)
}

src = src.replace(re, `$1'1.5.0', $2$3`)
writeFileSync(file, src)
console.log('irys-patch(safe-versions): added 1.5.0 to isValidSafeVersion allowlist')
