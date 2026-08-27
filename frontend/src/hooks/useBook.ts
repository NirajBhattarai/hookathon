"use client";

import { useReadContracts } from "wagmi";
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
  /** Has `createPool` been called for this exact poolId — i.e. is it safe to addLiquidity
   *  directly, or does the deposit flow need to create the pool first. Note this is distinct
   *  from the Book struct's own `seeded` field, which only flips once the pool's first deposit
   *  has landed — a freshly created, still-empty pool is `configured` but not yet `seeded`. */
  configured: boolean;
};

function parseBookTuple(data: unknown): Omit<BookView, "configured"> | null {
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

  const q = useReadContracts({
    contracts:
      deployment && poolId
        ? [
            { address: deployment.binBook, abi: binBookAbi, functionName: "books", args: [poolId] },
            {
              address: deployment.binBook,
              abi: binBookAbi,
              functionName: "initializedPools",
              args: [poolId],
            },
          ]
        : [],
    query: { enabled: ready && !!poolId },
  });

  const bookTuple = parseBookTuple(q.data?.[0]?.result);
  const liveBook: BookView | null = bookTuple
    ? { ...bookTuple, configured: Boolean(q.data?.[1]?.result) }
    : null;
  const book = preview ? DEMO_BOOK : liveBook;

  return { book, preview, isLoading: q.isLoading };
}
