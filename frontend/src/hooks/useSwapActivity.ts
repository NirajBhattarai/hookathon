"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchSwapLogs, type SwapEvent } from "@/lib/activity";
import { useAppPublicClient } from "./useAppPublicClient";
import { useDeployment } from "./useDeployment";
import { usePool } from "./usePool";

export type Timeframe = "1H" | "1D" | "1W" | "ALL";

/** Sepolia is ~12s/block. ALL is capped, not literally all history, to bound RPC cost. */
const BLOCK_WINDOW: Record<Timeframe, bigint> = {
  "1H": 300n,
  "1D": 7_200n,
  "1W": 50_400n,
  ALL: 100_000n,
};

export function useSwapActivity(timeframe: Timeframe) {
  const { deployment, ready } = useDeployment();
  const { poolId } = usePool();
  const client = useAppPublicClient(deployment);

  const enabled = ready && !!deployment && !!poolId && !!client;

  const query = useQuery({
    queryKey: ["swap-activity", deployment?.chainId, deployment?.poolManager, poolId, timeframe],
    enabled,
    staleTime: 15_000,
    refetchInterval: 30_000,
    queryFn: async (): Promise<SwapEvent[]> => {
      const c = client!;
      const latest = await c.getBlockNumber();
      const window = BLOCK_WINDOW[timeframe];
      const fromBlock = latest > window ? latest - window : 0n;
      return fetchSwapLogs(c, {
        poolManager: deployment!.poolManager,
        poolId: poolId!,
        fromBlock,
        toBlock: latest,
      });
    },
  });

  return {
    events: query.data ?? [],
    isLoading: enabled && query.isLoading,
    isFetching: query.isFetching,
    error: query.error,
    refetch: query.refetch,
    enabled,
  };
}
