"use client";

import { useMemo } from "react";
import type { Address } from "viem";
import { useDeployment } from "@/hooks/useDeployment";
import { computePoolId, poolKeyFor, type PoolKeyLike } from "@/lib/pool";

export type PoolPairOverride = { token0: Address; token1: Address };

/** Defaults to the deployment's configured pair; pass `pair` to target any other token pair. */
export function usePool(pair?: PoolPairOverride): {
  key: PoolKeyLike | null;
  poolId: `0x${string}` | null;
  ready: boolean;
} {
  const { deployment, ready } = useDeployment();
  return useMemo(() => {
    if (!deployment || !ready) return { key: null, poolId: null, ready: false };
    const key = poolKeyFor(deployment, pair);
    return { key, poolId: computePoolId(key), ready: true };
  }, [deployment, ready, pair]);
}
