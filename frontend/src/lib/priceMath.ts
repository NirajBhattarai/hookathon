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

/**
 * On-chain pool price is always currency1 / currency0. The liquidity UI lets users pick an
 * arbitrary base/quote pair, so convert their "quote per base" input into pool price space.
 */
export function poolPriceFromQuotePerBase(quotePerBase: number, baseIsCurrency0: boolean): number {
  if (!Number.isFinite(quotePerBase) || quotePerBase <= 0) return 1;
  return baseIsCurrency0 ? quotePerBase : 1 / quotePerBase;
}

/** Inverse of `poolPriceFromQuotePerBase` — show an on-chain c1/c0 price in pick-quote terms. */
export function displayQuotePerBase(poolPrice: number, baseIsCurrency0: boolean): number {
  if (!Number.isFinite(poolPrice) || poolPrice <= 0) return 1;
  return baseIsCurrency0 ? poolPrice : 1 / poolPrice;
}

/**
 * Uniswap pool price is token1_wei / token0_wei. Convert human currency1 per currency0
 * (e.g. 100 PEPE per 1 USDC) to that raw on-chain ratio.
 */
export function humanPoolPriceToRaw(humanC1PerC0: number, dec0: number, dec1: number): number {
  if (!Number.isFinite(humanC1PerC0) || humanC1PerC0 <= 0) return 1;
  return humanC1PerC0 * 10 ** (dec1 - dec0);
}

/** Raw on-chain currency1/currency0 → human currency1 per currency0. */
export function rawPoolPriceToHuman(rawC1PerC0: number, dec0: number, dec1: number): number {
  if (!Number.isFinite(rawC1PerC0) || rawC1PerC0 <= 0) return 1;
  return rawC1PerC0 / 10 ** (dec1 - dec0);
}

/** User pick quote-per-base → raw on-chain currency1/currency0 (wei ratio). */
export function quotePerBaseToRawPoolPrice(
  quotePerBase: number,
  baseIsCurrency0: boolean,
  dec0: number,
  dec1: number
): number {
  const humanC1PerC0 = poolPriceFromQuotePerBase(quotePerBase, baseIsCurrency0);
  return humanPoolPriceToRaw(humanC1PerC0, dec0, dec1);
}

/** Raw on-chain price → user-facing quote per pick-base. */
export function rawPoolPriceToQuotePerBase(
  rawC1PerC0: number,
  baseIsCurrency0: boolean,
  dec0: number,
  dec1: number
): number {
  const humanC1PerC0 = rawPoolPriceToHuman(rawC1PerC0, dec0, dec1);
  return displayQuotePerBase(humanC1PerC0, baseIsCurrency0);
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
  let zeroCount = -exp - 1;
  const mantissa = p / 10 ** exp;
  // toPrecision rounds; a value just below a power of ten (e.g. 0.00009999999) rounds up to
  // "10.00". That bumps the magnitude by a factor of 10, so carry the exponent/zero-count up by
  // one to keep the printed price on the correct order of magnitude.
  const prec = mantissa.toPrecision(sigFigs);
  const carry = Number(prec) >= 10 ? 1 : 0;
  zeroCount += carry;
  const scaled = Number(prec) / 10 ** carry;
  const sig = scaled.toPrecision(sigFigs).replace(".", "").slice(0, sigFigs);
  return `0.0${toSubscript(zeroCount)}${sig}`;
}

const SUPERSCRIPT_DIGITS = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"];

function toSuperscript(n: number): string {
  return String(n)
    .split("")
    .map((d) => SUPERSCRIPT_DIGITS[Number(d)])
    .join("");
}

/**
 * Human-readable integer, for raw on-chain counters too large to read at a glance (e.g. LP
 * "shares", which are an opaque internal accounting unit — not a token amount — so there's no
 * decimals count to divide by). Comma-formats below a million; above that, scientific notation
 * with a superscript exponent ("5.00 × 10²⁷") reads at a glance instead of a 28-digit number.
 */
export function formatBigIntCompact(n: bigint, sigFigs = 3): string {
  if (n === 0n) return "0";
  const neg = n < 0n;
  const digits = (neg ? -n : n).toString();
  if (digits.length <= 6) return n.toLocaleString();
  const exp = digits.length - 1;
  const mantissaDigits = digits.slice(0, sigFigs).padEnd(sigFigs, "0");
  const mantissa = `${mantissaDigits[0]}.${mantissaDigits.slice(1)}`;
  return `${neg ? "-" : ""}${mantissa} × 10${toSuperscript(exp)}`;
}
