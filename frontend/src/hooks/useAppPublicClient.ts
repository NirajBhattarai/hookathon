"use client";

import { useMemo } from "react";
import { createPublicClient, http, type PublicClient } from "viem";
import { mainnet, sepolia } from "viem/chains";
import type { ChainDeployment } from "@/config/chains";

const VIEM_CHAIN = { 1: mainnet, 11155111: sepolia } as const;

/**
 * A public client pinned to the deployment's own RPC URL, independent of the connected wallet's
 * transport. When a wallet is connected via WalletConnect, `wagmi`'s `usePublicClient` routes
 * reads through WalletConnect's own RPC relay (`rpc.walletconnect.org`) — observed returning
 * unreliable 429/400s on chunked `eth_getLogs` calls during historical-log scans. Anything doing
 * bulk/historical reads (event log scans in particular) should use this instead.
 */
export function useAppPublicClient(deployment: ChainDeployment | null): PublicClient | null {
  return useMemo((): PublicClient | null => {
    if (!deployment?.rpcUrl) return null;
    const chain = VIEM_CHAIN[deployment.chainId];
    // Tighter than viem's http-transport default (4s) so `waitForTransactionReceipt` notices a
    // mined tx sooner — Sepolia's ~12s block time means a 4s poll can add several extra seconds
    // of visible "still confirming" beyond when the tx actually landed.
    return createPublicClient({ chain, transport: http(deployment.rpcUrl), pollingInterval: 1_500 });
  }, [deployment?.rpcUrl, deployment?.chainId]);
}
