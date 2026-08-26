const Q96 = 2n ** 96n;

/** Human price (token1 per token0) → sqrtPriceX96 */
export function priceToSqrtPriceX96(price: number): bigint {
  if (price <= 0) return 0n;
  const sqrtP = Math.sqrt(price);
  return BigInt(Math.round(sqrtP * Number(Q96)));
}

/** sqrtPriceX96 → human price */
export function sqrtPriceX96ToPrice(sqrtP: bigint): number {
  if (sqrtP === 0n) return 0;
  return (Number(sqrtP) / Number(Q96)) ** 2;
}

/** Uniswap tick → human price (token1 per token0): 1.0001^tick */
export function tickToPrice(tick: number): number {
  return 1.0001 ** tick;
}

const SUBSCRIPT_DIGITS = ["₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉"];

function toSubscript(n: number): string {
  return String(n)
    .split("")
    .map((d) => SUBSCRIPT_DIGITS[Number(d)])
    .join("");
}

/**
 * Human-readable price, Uniswap-style: normal decimals down to 0.0001, then compact
 * "0.0₈2018" notation (the subscript is the zero count) instead of "2.018e-9" — reads at a
 * glance instead of requiring the reader to count exponent digits.
 */
export function formatPriceHuman(p: number, sigFigs = 4): string {
  if (!Number.isFinite(p) || p <= 0) return "0";
  if (p >= 1000) return p.toLocaleString(undefined, { maximumFractionDigits: 2 });
  if (p >= 1) return p.toLocaleString(undefined, { maximumFractionDigits: 4 });
  if (p >= 0.0001) return p.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");

  const exp = Math.floor(Math.log10(p));
  const zeroCount = -exp - 1;
  const mantissa = p / 10 ** exp;
  const sig = mantissa.toPrecision(sigFigs).replace(".", "").slice(0, sigFigs);
  return `0.0${toSubscript(zeroCount)}${sig}`;
}
