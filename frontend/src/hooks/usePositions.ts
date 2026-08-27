"use client";

import { useMemo } from "react";
import { useAccount, useReadContracts } from "wagmi";
import { binBookAbi } from "@/lib/abi/binBook";
import { useDeployment } from "./useDeployment";
import { usePools } from "./usePools";
import type { PoolKeyLike } from "@/lib/pool";

export type Position = {
  poolId: `0x${string}`;
  key: PoolKeyLike;
  binSize: number;
  shares: bigint;
  totalShares: bigint;
  sharePct: number;
  fee0: bigint;
  fee1: bigint;
  sqrtPriceX96: bigint;
  currentBin: number;
};

/**
 * Every position the connected wallet holds a nonzero share of, across every pool the deployment's
 * BinBook has ever created — resolved with a single multicall per pool (shares, supply, pending
 * fees, live book state), no backend involved.
 */
export function usePositions() {
  const { address } = useAccount();
  const { deployment, ready } = useDeployment();
  const { pools, isLoading: poolsLoading } = usePools();

  const contracts = useMemo(() => {
    if (!ready || !deployment || !address) return [];
    return pools.flatMap((p) => [
      { address: deployment.binBook, abi: binBookAbi, functionName: "getShares", args: [p.poolId, address] },
      { address: deployment.binBook, abi: binBookAbi, functionName: "getTotalShares", args: [p.poolId] },
      { address: deployment.binBook, abi: binBookAbi, functionName: "pendingFees", args: [p.poolId, address] },
      { address: deployment.binBook, abi: binBookAbi, functionName: "books", args: [p.poolId] },
    ] as const);
  }, [pools, deployment, ready, address]);

  const q = useReadContracts({
    contracts,
    query: { enabled: contracts.length > 0, refetchInterval: 20_000 },
  });

  const positions = useMemo((): Position[] => {
    if (!q.data || pools.length === 0) return [];
    const out: Position[] = [];
    for (let i = 0; i < pools.length; i++) {
      const p = pools[i]!;
      const base = i * 4;
      const shares = (q.data[base]?.result as bigint | undefined) ?? 0n;
      if (shares === 0n) continue;
      const totalShares = (q.data[base + 1]?.result as bigint | undefined) ?? 0n;
      const fees = q.data[base + 2]?.result as readonly [bigint, bigint] | undefined;
      const book = q.data[base + 3]?.result as
        | readonly [number, number, number, number, number, number, bigint, boolean]
        | undefined;
      out.push({
        poolId: p.poolId,
        key: p.key,
        binSize: p.binSize,
        shares,
        totalShares,
        sharePct: totalShares > 0n ? Number((shares * 10000n) / totalShares) / 100 : 0,
        fee0: fees?.[0] ?? 0n,
        fee1: fees?.[1] ?? 0n,
        sqrtPriceX96: book?.[6] ?? 0n,
        currentBin: book?.[3] ?? 0,
      });
    }
    return out;
  }, [q.data, pools]);

  return {
    positions,
    isLoading: poolsLoading || q.isLoading,
    refetch: q.refetch,
  };
}
