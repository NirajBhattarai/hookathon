"use client";

import { useState } from "react";
import { ActivityTable } from "@/components/ActivityTable";
import { LiquidityLadder } from "@/components/LiquidityLadder";
import { PriceChart } from "@/components/PriceChart";

type View = "ladder" | "chart";

export function TradeMain() {
  const [view, setView] = useState<View>("ladder");

  return (
    <div className="trade-main">
      <div className="trade-tabs">
        <button
          type="button"
          className={view === "ladder" ? "trade-tab active" : "trade-tab"}
          onClick={() => setView("ladder")}
        >
          Ladder
        </button>
        <button
          type="button"
          className={view === "chart" ? "trade-tab active" : "trade-tab"}
          onClick={() => setView("chart")}
        >
          Chart
        </button>
      </div>

      {view === "ladder" ? <LiquidityLadder /> : <PriceChart />}
      <ActivityTable />
    </div>
  );
}
