const I128_MAX = (1n << 127n) - 1n;
const I128_MASK = (1n << 128n) - 1n;

/** Interpret a (possibly sign-extended) 256-bit word holding an int128 as a signed bigint. */
export function asInt128(v: bigint): bigint {
  const w = v & I128_MASK;
  return w > I128_MAX ? w - I128_MASK - 1n : w;
}

/**
 * Unpack a v4 BalanceDelta (int256): upper 128 bits = amount0, lower 128 bits = amount1.
 * Returns non-negative uint amounts suitable for slippage mins.
 */
export function unpackBalanceDelta(delta: bigint): readonly [bigint, bigint] {
  const amount0 = asInt128(delta >> 128n);
  const amount1 = asInt128(delta);
  const abs = (v: bigint) => (v < 0n ? -v : v);
  return [abs(amount0), abs(amount1)];
}
