"use client";

import { useMemo } from "react";
import { useReadContracts } from "wagmi";
import { binBookAbi } from "@/lib/abi/binBook";
import { buildDepthSeries, type BinDepth } from "@/lib/bins";
import { demoDepthSeries } from "@/lib/demo";
import { useBook } from "./useBook";
import { useDeployment } from "./useDeployment";
import { usePool, type PoolPairOverride } from "./usePool";

const LIQ_QUERY_OPTS = {
  staleTime: 30_000,
  refetchOnWindowFocus: false,
} as const;

/**
 * Per-bin liquidity for the active pool's book — real reads live, synthetic series in preview.
 * Defaults to the swap-page trade pair (or deployment pair); pass `pair` to target another pair.
 */
export function useBinLiquidity(pair?: PoolPairOverride) {
  const { deployment, ready } = useDeployment();
  const { poolId } = usePool(pair);
  const { book, preview, isLoading: bookLoading } = useBook(pair);
  const address = deployment?.binBook;

  const MAX_LIQ_BINS = 200;
  const indexes = useMemo(() => {
    if (!book || preview) return [];
    const out: number[] = [];
    const half = Math.floor(MAX_LIQ_BINS / 2);
    const lo = Math.max(book.minBin, book.currentBin - half);
    const hi = Math.min(book.maxBin, book.currentBin + half - 1);
    const from = hi - lo + 1 <= MAX_LIQ_BINS ? lo : book.minBin;
    const to = Math.min(book.maxBin, from + MAX_LIQ_BINS - 1);
    for (let i = from; i <= to; i++) out.push(i);
    return out;
  }, [book, preview]);

  const liqs = useReadContracts({
    contracts: indexes.map((i) => ({
      address,
      abi: binBookAbi,
      functionName: "liquidity" as const,
      args: [poolId ?? (("0x" + "00".repeat(32)) as `0x${string}`), i],
    })),
    query: {
      enabled: ready && !!poolId && indexes.length > 0 && !!book?.configured,
      ...LIQ_QUERY_OPTS,
    },
  });

  const series = useMemo((): BinDepth[] => {
    if (preview) return demoDepthSeries();
    if (!book || indexes.length === 0) return [];
    const map = new Map<number, bigint>();
    indexes.forEach((idx, j) => {
      const r = liqs.data?.[j];
      if (r?.status === "success") map.set(idx, r.result as bigint);
    });
    return buildDepthSeries(indexes[0]!, indexes[indexes.length - 1]!, book.binSize, map);
  }, [preview, book, indexes, liqs.data]);

  const maxL = useMemo(
    () => series.reduce((m, b) => (b.liquidity > m ? b.liquidity : m), 0n),
    [series]
  );

  const binsLoading = liqs.isPending && series.length === 0;

  return {
    book,
    preview,
    series,
    maxL,
    isLoading: bookLoading || binsLoading,
    isRefreshing: liqs.isFetching && series.length > 0,
  };
}
