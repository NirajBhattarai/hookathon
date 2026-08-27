"use client";

import { useQuery } from "@tanstack/react-query";
import { fetchCreatedPools, type CreatedPool } from "@/lib/pools";
import { useAppPublicClient } from "./useAppPublicClient";
import { useDeployment } from "./useDeployment";

/** Bounds the scan so a long-lived chain (Sepolia is already 11M+ blocks) doesn't turn "find my
 *  pools" into thousands of chunked eth_getLogs calls — mirrors useSwapActivity's capped "ALL". */
const POOL_SCAN_BLOCKS = 150_000n;

/**
 * Every pool created against the connected chain's BinBook in the recent history window —
 * discovered by scanning `PoolCreated` logs directly from the RPC, not a database. Powers the
 * portfolio's "find every position this wallet holds" scan without needing to know pairs up front.
 */
export function usePools() {
  const { deployment, ready, chainId } = useDeployment();
  const client = useAppPublicClient(deployment);
  const enabled = ready && !!deployment && !!client;

  const query = useQuery({
    queryKey: ["created-pools", chainId, deployment?.binBook],
    enabled,
    staleTime: 30_000,
    queryFn: async (): Promise<CreatedPool[]> => {
      const c = client!;
      const latest = await c.getBlockNumber();
      const fromBlock = latest > POOL_SCAN_BLOCKS ? latest - POOL_SCAN_BLOCKS : 0n;
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
