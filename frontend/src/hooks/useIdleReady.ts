"use client";

import { useEffect, useState } from "react";

/** Flips true after the browser is idle — use to defer heavy RPC until after first paint. */
export function useIdleReady(timeoutMs = 400) {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const run = () => setReady(true);
    if (typeof requestIdleCallback !== "undefined") {
      const id = requestIdleCallback(run, { timeout: timeoutMs });
      return () => cancelIdleCallback(id);
    }
    const t = setTimeout(run, Math.min(timeoutMs, 150));
    return () => clearTimeout(t);
  }, [timeoutMs]);

  return ready;
}
