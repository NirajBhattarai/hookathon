"use client";

import { useMemo } from "react";
import { useReadContracts } from "wagmi";
import { binBookAbi } from "@/lib/abi/binBook";
import { buildDepthSeries, type BinDepth } from "@/lib/bins";
import { demoDepthSeries } from "@/lib/demo";
import { useBook } from "./useBook";
import { useDeployment } from "./useDeployment";
import { usePool } from "./usePool";

/** Per-bin liquidity for the active pool's book — real reads live, synthetic series in preview. */
export function useBinLiquidity() {
  const { deployment, ready } = useDeployment();
  const { poolId } = usePool();
  const { book, preview } = useBook();
  const address = deployment?.binBook;

  const indexes = useMemo(() => {
    if (!book || preview) return [];
    const out: number[] = [];
    for (let i = book.minBin; i <= book.maxBin; i++) out.push(i);
    return out;
  }, [book, preview]);

  const liqs = useReadContracts({
    contracts: (indexes.length > 200 ? indexes.slice(0, 200) : indexes).map((i) => ({
      address,
      abi: binBookAbi,
      functionName: "liquidity" as const,
      args: [poolId ?? (("0x" + "00".repeat(32)) as `0x${string}`), i],
    })),
    query: { enabled: ready && !!poolId && indexes.length > 0 },
  });

  const series = useMemo((): BinDepth[] => {
    if (preview) return demoDepthSeries();
    if (!book) return [];
    const map = new Map<number, bigint>();
    indexes.forEach((idx, j) => {
      const r = liqs.data?.[j];
      if (r?.status === "success") map.set(idx, r.result as bigint);
    });
    return buildDepthSeries(book.minBin, book.maxBin, book.binSize, map);
  }, [preview, book, indexes, liqs.data]);

  const maxL = useMemo(
    () => series.reduce((m, b) => (b.liquidity > m ? b.liquidity : m), 0n),
    [series]
  );

  return { book, preview, series, maxL };
}
