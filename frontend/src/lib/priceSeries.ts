import { formatUnits } from 'viem'
import type { SwapEvent } from './activity'

export type Candle = {
  time: number // unix seconds, bucket open
  open: number
  high: number
  low: number
  close: number
}

export type VolumeBar = {
  time: number
  value: number
  buy: boolean // true = pool sold token0 (price pressure up)
}

/** Bucket swap events into OHLC candles. Buckets with no swaps repeat the prior close (flat candle). */
export function toCandles(events: SwapEvent[], bucketSeconds: number): Candle[] {
  if (events.length === 0) return []
  const byBucket = new Map<number, number[]>()
  for (const e of events) {
    const bucket = Math.floor(e.timestamp / bucketSeconds) * bucketSeconds
    const arr = byBucket.get(bucket)
    if (arr) arr.push(e.price)
    else byBucket.set(bucket, [e.price])
  }
  const buckets = [...byBucket.keys()].sort((a, b) => a - b)
  const out: Candle[] = []
  let prevClose = buckets.length ? byBucket.get(buckets[0]!)![0]! : 0
  for (const t of buckets) {
    const prices = byBucket.get(t)!
    const open = prevClose
    const high = Math.max(open, ...prices)
    const low = Math.min(open, ...prices)
    const close = prices[prices.length - 1]!
    out.push({ time: t, open, high, low, close })
    prevClose = close
  }
  return out
}

/** Bucket swap volume (in quote-token units) into histogram bars. */
export function toVolumeBars(
  events: SwapEvent[],
  bucketSeconds: number,
  quoteDecimals: number,
): VolumeBar[] {
  if (events.length === 0) return []
  const byBucket = new Map<number, { value: number; buys: number; sells: number }>()
  for (const e of events) {
    const bucket = Math.floor(e.timestamp / bucketSeconds) * bucketSeconds
    // quote leg of the swap: whichever side is token1 (amount1), pool's perspective
    const quoteRaw = e.amount1 > 0n ? e.amount1 : -e.amount1
    const quote = Number(formatUnits(quoteRaw, quoteDecimals))
    const cur = byBucket.get(bucket) ?? { value: 0, buys: 0, sells: 0 }
    cur.value += quote
    if (e.zeroForOne) cur.sells += 1
    else cur.buys += 1
    byBucket.set(bucket, cur)
  }
  return [...byBucket.entries()]
    .sort(([a], [b]) => a - b)
    .map(([time, v]) => ({ time, value: v.value, buy: v.buys >= v.sells }))
}

export type ActivityStats = {
  lastPrice: number | null
  changePct: number | null
  volumeQuote: number
  swapCount: number
}

/** Summary stats over a window of events (caller controls the window, e.g. last 24h). */
export function computeStats(events: SwapEvent[], quoteDecimals: number): ActivityStats {
  if (events.length === 0) return { lastPrice: null, changePct: null, volumeQuote: 0, swapCount: 0 }
  const first = events[0]!.price
  const last = events[events.length - 1]!.price
  const volumeQuote = events.reduce((sum, e) => {
    const raw = e.amount1 > 0n ? e.amount1 : -e.amount1
    return sum + Number(formatUnits(raw, quoteDecimals))
  }, 0)
  return {
    lastPrice: last,
    changePct: first > 0 ? ((last - first) / first) * 100 : null,
    volumeQuote,
    swapCount: events.length,
  }
}
