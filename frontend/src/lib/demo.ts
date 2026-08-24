import { buildDepthSeries, type BinDepth } from '@/lib/bins'
import type { Candle, VolumeBar, ActivityStats } from '@/lib/priceSeries'

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

export type DemoTrade = {
  time: number
  side: 'buy' | 'sell'
  price: number
  amountQuote: number
  txHash: `0x${string}`
}

/** Deterministic-ish random walk so the trading UI has something to render with zero RPC config. */
function seededRandom(seed: number) {
  let s = seed
  return () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff
    return s / 0x7fffffff
  }
}

const DEMO_BASE_PRICE = 1.0
const DEMO_POINTS = 180
const DEMO_BUCKET_SECONDS = 60

function demoSeries(): { time: number; price: number; side: 'buy' | 'sell' }[] {
  const rand = seededRandom(42)
  const now = Math.floor(Date.now() / 1000 / DEMO_BUCKET_SECONDS) * DEMO_BUCKET_SECONDS
  let price = DEMO_BASE_PRICE
  const out: { time: number; price: number; side: 'buy' | 'sell' }[] = []
  for (let i = DEMO_POINTS - 1; i >= 0; i--) {
    const drift = (rand() - 0.5) * 0.012
    price = Math.max(0.01, price * (1 + drift))
    out.push({ time: now - i * DEMO_BUCKET_SECONDS, price, side: drift >= 0 ? 'buy' : 'sell' })
  }
  return out
}

export function demoCandles(): Candle[] {
  const series = demoSeries()
  let prevClose = series[0]?.price ?? DEMO_BASE_PRICE
  return series.map((p) => {
    const open = prevClose
    const high = Math.max(open, p.price)
    const low = Math.min(open, p.price)
    prevClose = p.price
    return { time: p.time, open, high, low, close: p.price }
  })
}

export function demoVolumeBars(): VolumeBar[] {
  const rand = seededRandom(7)
  return demoSeries().map((p) => ({
    time: p.time,
    value: 500 + rand() * 4500,
    buy: p.side === 'buy',
  }))
}

export function demoStats(): ActivityStats {
  const series = demoSeries()
  const first = series[0]!.price
  const last = series[series.length - 1]!.price
  return {
    lastPrice: last,
    changePct: ((last - first) / first) * 100,
    volumeQuote: 182_400,
    swapCount: 96,
  }
}

export function demoTrades(count = 16): DemoTrade[] {
  const series = demoSeries().slice(-count).reverse()
  const rand = seededRandom(99)
  return series.map((p, i) => ({
    time: p.time,
    side: p.side,
    price: p.price,
    amountQuote: 50 + rand() * 2000,
    txHash: `0x${(i + 1).toString(16).padStart(4, '0')}${'demo'.repeat(14)}` as `0x${string}`,
  }))
}
