import { buildDepthSeries, type BinDepth } from '@/lib/bins'

/** Synthetic book used when addresses are unset — UI preview only. */
export const DEMO_BOOK = {
  binSize: 60,
  currentBin: 0,
  minBin: -10,
  maxBin: 9,
  configured: true,
} as const

export function demoDepthSeries(): BinDepth[] {
  const map = new Map<number, bigint>()
  for (let i = DEMO_BOOK.minBin; i <= DEMO_BOOK.maxBin; i++) {
    const dist = Math.abs(i - DEMO_BOOK.currentBin) + (i >= DEMO_BOOK.currentBin ? 1 : 0)
    // Linear decay away from spot (matches ramp feel)
    const weight = Math.max(0, DEMO_BOOK.maxBin - DEMO_BOOK.minBin + 1 - dist * 1.4)
    map.set(i, BigInt(Math.round(weight * 1e15)))
  }
  return buildDepthSeries(DEMO_BOOK.minBin, DEMO_BOOK.maxBin, DEMO_BOOK.binSize, map)
}
