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
  // The caller's own contiguous bin range in this pool (from `userRanges`), converted back to
  // ticks — required by removeLiquidity/collectFees, which now scope to this exact range instead
  // of walking a pool-wide position. `hasRange` is false when userRanges was never seeded (no
  // deposit yet), in which case tickLower/tickUpper are meaningless zeros.
  tickLower: number;
  tickUpper: number;
  hasRange: boolean;
};

/**
 * Every position the connected wallet holds a nonzero share of, across every pool the deployment's
 * BinBook has ever created — resolved with a single multicall per pool (shares, supply, pending
 * fees, live book state), no backend involved.
 */
export function usePositions(scanAllPools = true) {
  const { address } = useAccount();
  const { deployment, ready } = useDeployment();
  const { pools, isLoading: poolsLoading } = usePools(scanAllPools && !!address);

  const contracts = useMemo(() => {
    if (!ready || !deployment || !address) return [];
    return pools.flatMap(
      (p) =>
        [
          {
            address: deployment.binBook,
            abi: binBookAbi,
            functionName: "getShares",
            args: [p.poolId, address],
          },
          {
            address: deployment.binBook,
            abi: binBookAbi,
            functionName: "getTotalShares",
            args: [p.poolId],
          },
          {
            address: deployment.binBook,
            abi: binBookAbi,
            functionName: "pendingFees",
            args: [p.poolId, address],
          },
          { address: deployment.binBook, abi: binBookAbi, functionName: "books", args: [p.poolId] },
          {
            address: deployment.binBook,
            abi: binBookAbi,
            functionName: "userRanges",
            args: [p.poolId, address],
          },
        ] as const
    );
  }, [pools, deployment, ready, address]);

  const q = useReadContracts({
    contracts,
    query: {
      enabled: contracts.length > 0,
      staleTime: 30_000,
      refetchInterval: scanAllPools ? 30_000 : false,
      refetchIntervalInBackground: false,
      refetchOnWindowFocus: false,
    },
  });

  const positions = useMemo((): Position[] => {
    if (!q.data || pools.length === 0) return [];
    const out: Position[] = [];
    for (let i = 0; i < pools.length; i++) {
      const p = pools[i]!;
      const base = i * 5;
      const shares = (q.data[base]?.result as bigint | undefined) ?? 0n;
      if (shares === 0n) continue;
      const totalShares = (q.data[base + 1]?.result as bigint | undefined) ?? 0n;
      const fees = q.data[base + 2]?.result as readonly [bigint, bigint] | undefined;
      const book = q.data[base + 3]?.result as
        readonly [number, number, number, number, number, number, bigint, boolean] | undefined;
      const range = q.data[base + 4]?.result as readonly [number, number, boolean] | undefined;
      const hasRange = range?.[2] ?? false;
      // Inverse of BinLayout.resolveBinRange: tickLower = minB * binSize, tickUpper = (maxB + 1) * binSize.
      const tickLower = hasRange ? range![0] * p.binSize : 0;
      const tickUpper = hasRange ? (range![1] + 1) * p.binSize : 0;
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
        tickLower,
        tickUpper,
        hasRange,
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
