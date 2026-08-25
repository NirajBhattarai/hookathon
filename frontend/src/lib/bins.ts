import { type Address } from "viem";
import { tickToPrice } from "./priceMath";

/** Tick of the lower edge of a bin index. */
export function tickAtBin(binIndex: number, binSize: number): number {
  return binIndex * binSize;
}

/** Floor-divide tick into bin index (matches Solidity `_floorDiv`). */
export function binAtTick(tick: number, binSize: number): number {
  let q = Math.trunc(tick / binSize);
  if (tick % binSize !== 0 && tick < 0) q -= 1;
  return q;
}

export type BinDepth = {
  binIndex: number;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
};

export function buildDepthSeries(
  minBin: number,
  maxBin: number,
  binSize: number,
  liquidityByIndex: Map<number, bigint>
): BinDepth[] {
  const out: BinDepth[] = [];
  for (let i = minBin; i <= maxBin; i++) {
    out.push({
      binIndex: i,
      tickLower: tickAtBin(i, binSize),
      tickUpper: tickAtBin(i, binSize) + binSize,
      liquidity: liquidityByIndex.get(i) ?? 0n,
    });
  }
  return out;
}

export function shortenAddress(addr: Address | string, size = 4): string {
  const a = String(addr);
  return `${a.slice(0, 2 + size)}…${a.slice(-size)}`;
}

/** Matches BinBook's Book defaults for a freshly created pool (createPool/setBinSize). */
export const DEFAULT_RAMP = 10;
export const DEFAULT_BINS_PER_SIDE = 10;

/** Mirrors BinBook._distance: bins below current are 1-indexed away, current-and-above too. */
export function rampDistance(binIndex: number, cur: number): number {
  return binIndex < cur ? cur - binIndex : binIndex - cur + 1;
}

/** Mirrors SwapMath.lForDistance's linear decay (L * (ramp - distance) / ramp, floored at 0). */
export function lForDistance(base: number, ramp: number, distance: number): number {
  if (distance >= ramp) return 0;
  return (base * (ramp - distance)) / ramp;
}

/** Mirrors BinBook._rampFor: the decay radius widens to cover whichever edge is farthest. */
export function rampForRange(lowerBin: number, upperBin: number, cur: number, baseRamp: number): number {
  const farthest = Math.max(rampDistance(lowerBin, cur), rampDistance(upperBin, cur));
  return Math.max(baseRamp, farthest + 1);
}

/**
 * Client-side preview of the ramp shape a fresh pool would get — same decay formula and
 * defaults (`DEFAULT_RAMP`, `DEFAULT_BINS_PER_SIDE`) the contract uses on createPool/setBinSize.
 * Used before a pool exists on-chain, so the shown ramp isn't an arbitrary illustration.
 */
export function buildRampPreview(
  binSize: number,
  ramp: number = DEFAULT_RAMP,
  binsPerSide: number = DEFAULT_BINS_PER_SIDE
): BinDepth[] {
  const cur = 0;
  const minBin = cur - binsPerSide;
  const maxBin = cur + binsPerSide - 1;
  const map = new Map<number, bigint>();
  for (let i = minBin; i <= maxBin; i++) {
    map.set(i, BigInt(Math.round(lForDistance(1_000_000, ramp, rampDistance(i, cur)))));
  }
  return buildDepthSeries(minBin, maxBin, binSize, map);
}

export type RangeComposition = {
  /** Relative amount0/amount1 needed for this range at L=1 per undecayed bin — a ratio, not a settlement amount. */
  need0: number;
  need1: number;
  /** "above"/"below" spot = single-sided (only token0 / only token1 respectively); "straddle" = both. */
  mode: "above" | "below" | "straddle" | "none";
};

/**
 * Client-side mirror of BinBook._getAmountIn's per-bin split: each bin entirely above the spot
 * price only takes token0, each bin entirely below only takes token1, and a bin straddling spot
 * takes both — mirroring Uniswap's standard liquidity-amount formulas. Weighted by the same ramp
 * decay as the contract (`rampForRange`/`lForDistance`) and summed across the range, so the
 * resulting need0:need1 ratio is what an even (non-wasteful) deposit into this range looks like.
 */
export function composeRangeAmounts(
  lowerBin: number,
  upperBin: number,
  currentBin: number,
  binSize: number,
  baseRamp: number,
  currentPrice: number
): RangeComposition {
  if (upperBin < lowerBin || !(currentPrice > 0)) return { need0: 0, need1: 0, mode: "none" };
  const ramp = rampForRange(lowerBin, upperBin, currentBin, baseRamp);
  const sqrtCur = Math.sqrt(currentPrice);
  let need0 = 0;
  let need1 = 0;
  for (let i = lowerBin; i <= upperBin; i++) {
    const L = lForDistance(1, ramp, rampDistance(i, currentBin));
    if (L <= 0) continue;
    const sqrtLo = Math.sqrt(tickToPrice(tickAtBin(i, binSize)));
    const sqrtHi = Math.sqrt(tickToPrice(tickAtBin(i + 1, binSize)));
    if (sqrtCur <= sqrtLo) {
      need0 += L * (1 / sqrtLo - 1 / sqrtHi);
    } else if (sqrtCur >= sqrtHi) {
      need1 += L * (sqrtHi - sqrtLo);
    } else {
      need0 += L * (1 / sqrtCur - 1 / sqrtHi);
      need1 += L * (sqrtCur - sqrtLo);
    }
  }
  const mode = need0 === 0 && need1 === 0 ? "none" : need1 === 0 ? "above" : need0 === 0 ? "below" : "straddle";
  return { need0, need1, mode };
}
