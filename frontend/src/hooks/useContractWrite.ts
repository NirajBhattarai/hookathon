"use client";

import { useCallback } from "react";
import { useWriteContract } from "wagmi";
import { useDeployment } from "@/hooks/useDeployment";
import { useResolvedConnector } from "@/hooks/useResolvedConnector";

type WriteContractParams = Parameters<
  ReturnType<typeof useWriteContract>["writeContractAsync"]
>[0];

/**
 * writeContract wrapper that passes the resolved wagmi connector + target chain id.
 * Avoids `connection.connector.getChainId is not a function` after AppKit reconnect.
 */
export function useContractWrite() {
  const { targetChainId } = useDeployment();
  const connector = useResolvedConnector();
  const { writeContractAsync, ...rest } = useWriteContract();

  const writeContractAsyncSafe = useCallback(
    async (params: WriteContractParams) => {
      if (!connector) {
        throw new Error("Wallet connector not ready — wait a moment or reconnect your wallet.");
      }
      return writeContractAsync({
        ...params,
        connector,
        chainId: params.chainId ?? targetChainId,
      });
    },
    [connector, targetChainId, writeContractAsync]
  );

  return {
    ...rest,
    connector,
    writeContractAsync: writeContractAsyncSafe,
  };
}
