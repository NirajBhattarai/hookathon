'use client'

import { useMemo } from 'react'
import { useDeployment } from '@/hooks/useDeployment'
import { computePoolId, poolKeyFor, type PoolKeyLike } from '@/lib/pool'

export function usePool(): { key: PoolKeyLike | null; poolId: `0x${string}` | null; ready: boolean } {
  const { deployment, ready } = useDeployment()
  return useMemo(() => {
    if (!deployment || !ready) return { key: null, poolId: null, ready: false }
    const key = poolKeyFor(deployment)
    return { key, poolId: computePoolId(key), ready: true }
  }, [deployment, ready])
}
