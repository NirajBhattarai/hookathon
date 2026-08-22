const Q96 = 2n ** 96n

/** Human price (token1 per token0) → sqrtPriceX96 */
export function priceToSqrtPriceX96(price: number): bigint {
  if (price <= 0) return 0n
  const sqrtP = Math.sqrt(price)
  return BigInt(Math.round(sqrtP * Number(Q96)))
}

/** sqrtPriceX96 → human price */
export function sqrtPriceX96ToPrice(sqrtP: bigint): number {
  if (sqrtP === 0n) return 0
  return (Number(sqrtP) / Number(Q96)) ** 2
}
