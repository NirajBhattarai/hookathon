"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchCreatedPools, type CreatedPool } from "@/lib/pools";
import { useAppPublicClient } from "./useAppPublicClient";
import { useDeployment } from "./useDeployment";

/** Bounds the scan so a long-lived chain (Sepolia is already 11M+ blocks) doesn't turn "find my
 *  pools" into thousands of chunked eth_getLogs calls. Converted to a time window from the
 *  chain's measured block time, capped by hard block limits for RPC safety. */
const POOL_SCAN_SECONDS = 7 * 24 * 60 * 60; // ~7 days — enough for portfolio discovery without huge log scans
const POOL_SCAN_MAX_BLOCKS = 400_000n;

/**
 * Every pool created against the connected chain's BinBook in the recent history window —
 * discovered by scanning `PoolCreated` logs directly from the RPC, not a database. Powers the
 * portfolio's "find every position this wallet holds" scan without needing to know pairs up front.
 */
export function usePools(enabledOverride = true) {
  const { deployment, ready, chainId } = useDeployment();
  const client = useAppPublicClient(deployment);
  const enabled = enabledOverride && ready && !!deployment && !!client;

  const query = useQuery({
    queryKey: ["created-pools", chainId, deployment?.binBook],
    enabled,
    staleTime: 60_000,
    gcTime: 10 * 60_000,
    refetchOnWindowFocus: false,
    refetchIntervalInBackground: false,
    queryFn: async (): Promise<CreatedPool[]> => {
      const c = client!;
      const latest = await c.getBlockNumber();

      // Measure the chain's block time from two recent blocks so the window is accurate on any
      // chain, falling back to a ~12s/block estimate when metadata is unavailable.
      let fromBlock: bigint;
      try {
        const [latestBlock, prevBlock] = await Promise.all([
          c.getBlock({ blockNumber: latest }),
          c.getBlock({ blockNumber: latest - 1n }),
        ]);
        const blockTime =
          latestBlock.timestamp === prevBlock.timestamp
            ? 12n
            : latestBlock.timestamp - prevBlock.timestamp;
        const blocks =
          blockTime > 0n ? (BigInt(POOL_SCAN_SECONDS) + blockTime - 1n) / blockTime : 0n;
        const capped = blocks > 0n && blocks < POOL_SCAN_MAX_BLOCKS ? blocks : POOL_SCAN_MAX_BLOCKS;
        fromBlock = latest > capped ? latest - capped : 0n;
      } catch {
        const blocks = BigInt(POOL_SCAN_SECONDS) / 12n;
        fromBlock = latest > blocks ? latest - blocks : 0n;
      }

      return fetchCreatedPools(c, { binBook: deployment!.binBook, fromBlock, toBlock: latest });
    },
  });

  return {
    pools: query.data ?? [],
    isLoading: enabled && query.isLoading,
    error: query.error,
    refetch: query.refetch,
  };
}
