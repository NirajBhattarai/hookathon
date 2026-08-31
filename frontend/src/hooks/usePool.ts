"use client";

import { useMemo } from "react";
import { useTradePair } from "@/context/TradePairContext";
import { useDeployment } from "@/hooks/useDeployment";
import { computePoolId, poolKeyFor, type PoolKeyLike, type PoolPairOverride } from "@/lib/pool";

export type { PoolPairOverride };

/**
 * Defaults to the swap-page trade pair when one is set, otherwise the deployment pair.
 * Pass `pair` to target a specific token pair (liquidity / portfolio).
 */
export function usePool(pair?: PoolPairOverride): {
  key: PoolKeyLike | null;
  poolId: `0x${string}` | null;
  ready: boolean;
} {
  const { deployment, ready } = useDeployment();
  const { pair: tradePair, pairResolved } = useTradePair();
  const effective = pair ?? tradePair ?? undefined;
  const t0 = effective?.token0;
  const t1 = effective?.token1;
  const ts = effective?.tickSpacing;

  return useMemo(() => {
    if (!deployment || !ready) return { key: null, poolId: null, ready: false };
    // Swap page: wait for tick-spacing discovery so poolId doesn't flip twice per token change.
    if (!pair && tradePair && !pairResolved) {
      return { key: null, poolId: null, ready: false };
    }
    const override = t0 && t1 ? { token0: t0, token1: t1, tickSpacing: ts } : undefined;
    const key = poolKeyFor(deployment, override);
    return { key, poolId: computePoolId(key), ready: true };
  }, [deployment, ready, pair, tradePair, pairResolved, t0, t1, ts]);
}
