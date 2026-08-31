"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchSwapLogs, type SwapEvent } from "@/lib/activity";
import { useAppPublicClient } from "./useAppPublicClient";
import { useDeployment } from "./useDeployment";
import { usePool } from "./usePool";

export type Timeframe = "1H" | "1D" | "1W" | "ALL";

/** Seconds of history for each timeframe. ALL is capped, not literally all history, to bound
 *  RPC cost — kept generous since it approximates "everything reasonable". */
const SECONDS_WINDOW: Record<Timeframe, number> = {
  "1H": 60 * 60,
  "1D": 24 * 60 * 60,
  "1W": 7 * 24 * 60 * 60,
  ALL: 30 * 24 * 60 * 60,
};

/** Upper bound on the block range for a timeframe regardless of chain block time. */
const MAX_BLOCKS: Record<Timeframe, bigint> = {
  "1H": 30_000n,
  "1D": 250_000n,
  "1W": 1_500_000n,
  ALL: 2_000_000n,
};

/**
 * Converts a time-based window into a block range using the chain's *measured* block time (from
 * two recent block timestamps), falling back to a 12s default — accurate across L1s and L2s with
 * wildly different block times, instead of assuming a fixed blocks-per-day.
 */
async function blockWindowFor(
  client: NonNullable<ReturnType<typeof useAppPublicClient>>,
  timeframe: Timeframe,
  latest: bigint
): Promise<{ from: bigint; to: bigint }> {
  const to = latest;
  const seconds = SECONDS_WINDOW[timeframe];
  try {
    const [latestBlock, prevBlock] = await Promise.all([
      client.getBlock({ blockNumber: latest }),
      client.getBlock({ blockNumber: latest - 1n }),
    ]);
    const blockTime =
      latestBlock.timestamp === prevBlock.timestamp
        ? 12n
        : latestBlock.timestamp - prevBlock.timestamp;
    const blocks = blockTime > 0n ? (BigInt(seconds) + blockTime - 1n) / blockTime : 0n;
    const capped = blocks > 0n && blocks < MAX_BLOCKS[timeframe] ? blocks : MAX_BLOCKS[timeframe];
    const from = latest > capped ? latest - capped : 0n;
    return { from, to };
  } catch {
    // Fall back to a fixed ~12s/block estimate if block metadata is unavailable.
    const blocks = BigInt(seconds) / 12n;
    const from = latest > blocks ? latest - blocks : 0n;
    return { from, to };
  }
}

export function useSwapActivity(timeframe: Timeframe, options?: { enabled?: boolean }) {
  const { deployment, ready } = useDeployment();
  const { poolId } = usePool();
  const client = useAppPublicClient(deployment);

  const enabled =
    ready && !!deployment && !!poolId && !!client && (options?.enabled ?? true);

  const query = useQuery({
    queryKey: ["swap-activity", deployment?.chainId, deployment?.poolManager, poolId, timeframe],
    enabled,
    staleTime: 60_000,
    gcTime: 5 * 60_000,
    refetchInterval: enabled ? 60_000 : false,
    refetchIntervalInBackground: false,
    refetchOnWindowFocus: false,
    queryFn: async (): Promise<SwapEvent[]> => {
      const c = client!;
      const latest = await c.getBlockNumber();
      const { from, to } = await blockWindowFor(c, timeframe, latest);
      return fetchSwapLogs(c, {
        poolManager: deployment!.poolManager,
        poolId: poolId!,
        fromBlock: from,
        toBlock: to,
      });
    },
  });

  return {
    events: query.data ?? [],
    isLoading: enabled && query.isLoading && query.data === undefined,
    isFetching: query.isFetching,
    error: query.error,
    refetch: query.refetch,
    enabled,
  };
}
