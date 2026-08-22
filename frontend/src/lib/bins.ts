import { type Address } from 'viem'

/** Tick of the lower edge of a bin index. */
export function tickAtBin(binIndex: number, binSize: number): number {
  return binIndex * binSize
}

/** Floor-divide tick into bin index (matches Solidity `_floorDiv`). */
export function binAtTick(tick: number, binSize: number): number {
  let q = Math.trunc(tick / binSize)
  if (tick % binSize !== 0 && tick < 0) q -= 1
  return q
}

export type BinDepth = {
  binIndex: number
  tickLower: number
  tickUpper: number
  liquidity: bigint
}

export function buildDepthSeries(
  minBin: number,
  maxBin: number,
  binSize: number,
  liquidityByIndex: Map<number, bigint>,
): BinDepth[] {
  const out: BinDepth[] = []
  for (let i = minBin; i <= maxBin; i++) {
    out.push({
      binIndex: i,
      tickLower: tickAtBin(i, binSize),
      tickUpper: tickAtBin(i, binSize) + binSize,
      liquidity: liquidityByIndex.get(i) ?? 0n,
    })
  }
  return out
}

export function shortenAddress(addr: Address | string, size = 4): string {
  const a = String(addr)
  return `${a.slice(0, 2 + size)}…${a.slice(-size)}`
}
