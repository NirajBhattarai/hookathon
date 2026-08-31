"use client";

import { LiquidityLadder } from "@/components/LiquidityLadder";

/** Kept for imports; the swap page composes the ladder inside TradePage. */
export function TradeMain() {
  return (
    <div className="trade-main">
      <LiquidityLadder />
    </div>
  );
}
