import { encodeAbiParameters, keccak256, parseAbiParameters, type Address } from 'viem'
import type { ChainDeployment } from '@/config/chains'

/** Mirrors v4-core's PoolKey struct (all static types). */
export type PoolKeyLike = {
  currency0: Address
  currency1: Address
  fee: number
  tickSpacing: number
  hooks: Address
}

const POOL_KEY_PARAMS = parseAbiParameters('address, address, uint24, int24, address')

/**
 * Build the deployment's PoolKey with v4's currency0 < currency1 ordering.
 */
export function poolKeyFor(d: ChainDeployment): PoolKeyLike {
  const t0 = d.token0
  const t1 = d.token1
  const [currency0, currency1] = t0.toLowerCase() < t1.toLowerCase() ? [t0, t1] : [t1, t0]
  return {
    currency0,
    currency1,
    fee: d.poolFee,
    tickSpacing: d.tickSpacing,
    hooks: d.binBook,
  }
}

/**
 * PoolId = keccak256(abi.encode(PoolKey)) — matches PoolIdLibrary.toId on-chain.
 */
export function computePoolId(k: PoolKeyLike): `0x${string}` {
  return keccak256(
    encodeAbiParameters(POOL_KEY_PARAMS, [
      k.currency0,
      k.currency1,
      k.fee,
      k.tickSpacing,
      k.hooks,
    ]),
  )
}
