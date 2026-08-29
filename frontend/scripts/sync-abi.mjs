import { writeFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const artifact = resolve(root, 'smartcontract/out/BinBook.sol/BinBook.json')
const out = resolve(root, 'frontend/src/lib/abi/binBook.ts')

const keepFns = new Set([
  'addLiquidity',
  'removeLiquidity',
  'collectFees',
  'createPool',
  'setBinSize',
  'pendingFees',
  'liquidity',
  'liquidityOf',
  'books',
  'currentSqrtPriceX96',
  'currentBin',
  'minBin',
  'maxBin',
  'getBinSize',
  'initializedPools',
  'sharesOf',
  'getShares',
  'getTotalShares',
  'totalShares',
  'poolCreator',
  'positions',
  'userRanges',
  'DEFAULT_BINS_PER_SIDE',
  'DEFAULT_RAMP',
  'MAX_BOOK_BINS',
])
const keepEv = new Set(['BinSizeSet', 'BookExpanded', 'FeesCollected', 'PoolCreated'])

const abi = JSON.parse(await import('node:fs').then((fs) => fs.readFileSync(artifact, 'utf8'))).abi
const trimmed = abi.filter(
  (x) =>
    (x.type === 'function' && keepFns.has(x.name)) ||
    (x.type === 'event' && keepEv.has(x.name)) ||
    x.type === 'error',
)

writeFileSync(
  out,
  `// Auto-trimmed from smartcontract/out/BinBook.sol/BinBook.json\nexport const binBookAbi = ${JSON.stringify(trimmed, null, 2)} as const\n`,
)
console.log(`Wrote ${trimmed.length} ABI items → ${out}`)
