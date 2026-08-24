'use client'

import { useMemo } from 'react'
import { formatUnits, type Address } from 'viem'
import { useReadContracts } from 'wagmi'
import { poolManagerAbi } from '@/lib/abi/poolManager'
import { useDeployment } from './useDeployment'
import { usePool } from './usePool'
import { useTokenMeta } from './useTokenMeta'

/** v4 Currency.toId() for an ERC20 currency is just its address as uint256. */
function toId(token: Address): bigint {
  return BigInt(token)
}

/**
 * TVL for the active pool. BinBook custodies reserves as ERC-6909 claim balances inside
 * PoolManager (not raw ERC20 balances on itself), so this reads poolManager.balanceOf(binBook, id)
 * for both currencies of the pool and prices them at the latest trade price.
 */
export function useTvl(lastPrice: number | null) {
  const { deployment, ready } = useDeployment()
  const { key } = usePool()
  const dec0 = useTokenMeta(key?.currency0).decimals
  const dec1 = useTokenMeta(key?.currency1).decimals

  const q = useReadContracts({
    query: { enabled: ready && !!deployment && !!key },
    contracts:
      deployment && key
        ? ([
            {
              address: deployment.poolManager,
              abi: poolManagerAbi,
              functionName: 'balanceOf',
              args: [deployment.binBook, toId(key.currency0)],
            },
            {
              address: deployment.poolManager,
              abi: poolManagerAbi,
              functionName: 'balanceOf',
              args: [deployment.binBook, toId(key.currency1)],
            },
          ] as const)
        : [],
  })

  return useMemo(() => {
    const r0 = q.data?.[0]?.result as bigint | undefined
    const r1 = q.data?.[1]?.result as bigint | undefined

    if (r0 === undefined || r1 === undefined || dec0 === undefined || dec1 === undefined) {
      return { reserve0: r0, reserve1: r1, tvlInQuote: null as number | null }
    }
    const amt0 = Number(formatUnits(r0, dec0))
    const amt1 = Number(formatUnits(r1, dec1))
    const tvlInQuote = lastPrice != null ? amt0 * lastPrice + amt1 : null
    return { reserve0: r0, reserve1: r1, tvlInQuote }
  }, [q.data, dec0, dec1, lastPrice])
}
