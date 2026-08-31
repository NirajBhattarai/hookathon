"use client";

import dynamic from "next/dynamic";
import { TradePairProvider } from "@/context/TradePairContext";
import { WalletGate } from "@/components/WalletGate";

const StatsBar = dynamic(
  () => import("@/components/StatsBar").then((m) => ({ default: m.StatsBar })),
  { ssr: false }
);
const LiquidityLadder = dynamic(
  () => import("@/components/LiquidityLadder").then((m) => ({ default: m.LiquidityLadder })),
  { ssr: false }
);
const SwapForm = dynamic(
  () => import("@/components/SwapForm").then((m) => ({ default: m.SwapForm })),
  { ssr: false }
);

export function TradePage() {
  return (
    <TradePairProvider>
      <WalletGate>
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
      </WalletGate>
    </TradePairProvider>
  );
}
