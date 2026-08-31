"use client";

import { useMemo } from "react";
import { useAccount, useConfig, type Connector } from "wagmi";

/**
 * AppKit can leave a stale connector object in wagmi connection state (missing getChainId).
 * Resolve the live connector instance from the wagmi config registry.
 */
export function useResolvedConnector(): Connector | undefined {
  const { connector, status } = useAccount();
  const config = useConfig();

  return useMemo(() => {
    if (status !== "connected" || !connector) return undefined;

    const live =
      config.connectors.find((c) => c.uid === connector.uid) ??
      config.connectors.find((c) => c.id === connector.id);

    if (live && typeof live.getChainId === "function") return live;
    return typeof connector.getChainId === "function" ? connector : undefined;
  }, [config.connectors, connector, status]);
}
