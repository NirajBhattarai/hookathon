"use client";

import { LiquidityLadder } from "@/components/LiquidityLadder";
import { SwapForm } from "@/components/SwapForm";
import { StatsBar } from "@/components/StatsBar";
import { TradePairProvider } from "@/context/TradePairContext";

export function TradePage() {
  return (
    <TradePairProvider>
      <main>
        <StatsBar />
        <div className="trade-grid">
          <div className="trade-main">
            <LiquidityLadder />
          </div>
          <div className="trade-side">
            <SwapForm />
          </div>
        </div>
      </main>
    </TradePairProvider>
  );
}
