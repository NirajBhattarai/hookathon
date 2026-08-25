"use client";

import { useReadContract } from "wagmi";
import { binBookAbi } from "@/lib/abi/binBook";
import { DEMO_BOOK } from "@/lib/demo";
import { useDeployment } from "./useDeployment";
import { usePool, type PoolPairOverride } from "./usePool";

export type BookView = {
  binSize: number;
  ramp: number;
  numBinsPerSide: number;
  currentBin: number;
  minBin: number;
  maxBin: number;
  sqrtPriceX96: bigint;
  configured: boolean;
};

function parseBook(data: unknown): BookView | null {
  if (!data) return null;
  if (Array.isArray(data)) {
    return {
      binSize: Number(data[0]),
      ramp: Number(data[1]),
      numBinsPerSide: Number(data[2]),
      currentBin: Number(data[3]),
      minBin: Number(data[4]),
      maxBin: Number(data[5]),
      sqrtPriceX96: BigInt(data[6] as bigint),
      configured: Boolean(data[7]),
    };
  }
  const o = data as Record<string, unknown>;
  return {
    binSize: Number(o.binSize),
    ramp: Number(o.ramp),
    numBinsPerSide: Number(o.numBinsPerSide),
    currentBin: Number(o.currentBin),
    minBin: Number(o.minBin),
    maxBin: Number(o.maxBin),
    sqrtPriceX96: BigInt(o.sqrtPriceX96 as bigint),
    configured: Boolean(o.configured),
  };
}

/**
 * The active pool's Book state — falls back to a synthetic demo book in preview mode.
 * Defaults to the deployment's configured pair; pass `pair` to target any other token pair.
 */
export function useBook(pair?: PoolPairOverride) {
  const { deployment, ready } = useDeployment();
  const { poolId } = usePool(pair);
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
