"use client";

import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import type { Address } from "viem";
import { poolPairsEqual, type PoolPairOverride } from "@/lib/pool";

type TradePairContextValue = {
  pair: PoolPairOverride | null;
  /** False while tick-spacing discovery is in flight for the current pair. */
  pairResolved: boolean;
  setTradePair: (pair: PoolPairOverride | null, resolved?: boolean) => void;
};

const TradePairContext = createContext<TradePairContextValue>({
  pair: null,
  pairResolved: true,
  setTradePair: () => {},
});

/** Holds the swap-page token pair so the ladder, stats bar, and TVL follow token changes. */
export function TradePairProvider({ children }: { children: ReactNode }) {
  const [pair, setPair] = useState<PoolPairOverride | null>(null);
  const [pairResolved, setPairResolved] = useState(true);

  const setTradePair = useCallback((next: PoolPairOverride | null, resolved = true) => {
    setPair((prev) => (poolPairsEqual(prev, next) ? prev : next));
    setPairResolved(resolved);
  }, []);

  const value = useMemo(
    () => ({ pair, pairResolved, setTradePair }),
    [pair, pairResolved, setTradePair]
  );
  return <TradePairContext.Provider value={value}>{children}</TradePairContext.Provider>;
}

export function useTradePair(): TradePairContextValue {
  return useContext(TradePairContext);
}

export function sameAddress(a?: Address | string, b?: Address | string): boolean {
  if (!a || !b) return false;
  return a.toLowerCase() === b.toLowerCase();
}
