"use client";

import { useMemo } from "react";
import type { Address } from "viem";
import { useReadContracts } from "wagmi";
import { tokenByAddress } from "@/lib/tokens";

const erc20MetaAbi = [
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
] as const;

/**
 * Token symbol/decimals — resolved instantly from the known faucet token list, falling back to
 * a live ERC20 read for tokens outside that list (e.g. a meme-launched pool token).
 */
export function useTokenMeta(address?: Address) {
  const known = address ? tokenByAddress(address) : undefined;

  const q = useReadContracts({
    query: { enabled: !!address && !known },
    contracts: address
      ? [
          { address, abi: erc20MetaAbi, functionName: "symbol" },
          { address, abi: erc20MetaAbi, functionName: "decimals" },
        ]
      : [],
  });

  return useMemo(() => {
    if (known)
      return {
        symbol: known.symbol as string | undefined,
        decimals: known.decimals as number | undefined,
        color: known.color,
      };
    return {
      symbol: q.data?.[0]?.result as string | undefined,
      decimals: q.data?.[1]?.result as number | undefined,
      color: undefined as string | undefined,
    };
  }, [known, q.data]);
}
