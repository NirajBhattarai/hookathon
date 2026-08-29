"use client";

import { useMemo } from "react";
import { useAccount, useReadContracts } from "wagmi";
import { binBookAbi } from "@/lib/abi/binBook";
import type { Position } from "./usePositions";
import { useDeployment } from "./useDeployment";
import { usePool, type PoolPairOverride } from "./usePool";

/**
 * Reads a single pair's position directly — independent of `usePools`' `PoolCreated`-event scan.
 * That scan can't find a pool that was initialized outside `BinBook.createPool()` (e.g. an older
 * deployment script that called `PoolManager.initialize()` directly, before the createPool gateway
 * existed) — no event was ever emitted for it, so no amount of log scanning finds it. Picking a
 * pair explicitly and reading its state directly sidesteps that gap entirely.
 */
export function usePairPosition(pair?: PoolPairOverride) {
  const { address } = useAccount();
  const { deployment, ready } = useDeployment();
  const { key, poolId } = usePool(pair);

  const contracts = useMemo(() => {
    if (!ready || !deployment || !address || !poolId) return [];
    return [
      {
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "getShares",
        args: [poolId, address],
      },
      {
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "getTotalShares",
        args: [poolId],
      },
      {
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "pendingFees",
        args: [poolId, address],
      },
      { address: deployment.binBook, abi: binBookAbi, functionName: "books", args: [poolId] },
      {
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "userRanges",
        args: [poolId, address],
      },
    ];
  }, [ready, deployment, address, poolId]);

  const q = useReadContracts({
    contracts,
    query: { enabled: contracts.length > 0, refetchInterval: 20_000 },
  });

  const position = useMemo((): Position | null => {
    if (!key || !poolId || !q.data) return null;
    const shares = (q.data[0]?.result as bigint | undefined) ?? 0n;
    if (shares === 0n) return null;
    const totalShares = (q.data[1]?.result as bigint | undefined) ?? 0n;
    const fees = q.data[2]?.result as readonly [bigint, bigint] | undefined;
    const book = q.data[3]?.result as
      readonly [number, number, number, number, number, number, bigint, boolean] | undefined;
    const binSize = book?.[0] ?? 0;
    const range = q.data[4]?.result as readonly [number, number, boolean] | undefined;
    const hasRange = range?.[2] ?? false;
    // Inverse of BinLayout.resolveBinRange: tickLower = minB * binSize, tickUpper = (maxB + 1) * binSize.
    const tickLower = hasRange ? range![0] * binSize : 0;
    const tickUpper = hasRange ? (range![1] + 1) * binSize : 0;
    return {
      poolId,
      key,
      binSize,
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
    };
  }, [key, poolId, q.data]);

  return {
    position,
    isLoading: contracts.length > 0 && q.isLoading,
    refetch: q.refetch,
  };
}
