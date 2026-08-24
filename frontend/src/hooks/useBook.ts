"use client";

import { useReadContract } from "wagmi";
import { binBookAbi } from "@/lib/abi/binBook";
import { DEMO_BOOK } from "@/lib/demo";
import { useDeployment } from "./useDeployment";
import { usePool } from "./usePool";

export type BookView = {
  binSize: number;
  currentBin: number;
  minBin: number;
  maxBin: number;
  configured: boolean;
};

function parseBook(data: unknown): BookView | null {
  if (!data) return null;
  if (Array.isArray(data)) {
    return {
      binSize: Number(data[0]),
      currentBin: Number(data[3]),
      minBin: Number(data[4]),
      maxBin: Number(data[5]),
      configured: Boolean(data[7]),
    };
  }
  const o = data as Record<string, unknown>;
  return {
    binSize: Number(o.binSize),
    currentBin: Number(o.currentBin),
    minBin: Number(o.minBin),
    maxBin: Number(o.maxBin),
    configured: Boolean(o.configured),
  };
}

/** The active pool's Book state — falls back to a synthetic demo book in preview mode. */
export function useBook() {
  const { deployment, ready } = useDeployment();
  const { poolId } = usePool();
  const preview = !ready;

  const bookQ = useReadContract({
    address: deployment?.binBook,
    abi: binBookAbi,
    functionName: "books",
    args: poolId ? [poolId] : undefined,
    query: { enabled: ready && !!poolId },
  });

  const liveBook = parseBook(bookQ.data);
  const book = preview ? DEMO_BOOK : liveBook;

  return { book, preview, isLoading: bookQ.isLoading };
}
