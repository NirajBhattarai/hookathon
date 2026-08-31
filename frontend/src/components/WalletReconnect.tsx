"use client";

import { useEffect, useRef } from "react";
import { useAccount, useReconnect } from "wagmi";

/** Ensures wagmi finishes reconnect after SSR hydration so connector methods are available. */
export function WalletReconnect() {
  const { status } = useAccount();
  const { reconnectAsync } = useReconnect();
  const tried = useRef(false);

  useEffect(() => {
    if (tried.current || status !== "reconnecting") return;
    tried.current = true;
    void reconnectAsync();
  }, [reconnectAsync, status]);

  return null;
}
