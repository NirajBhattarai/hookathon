import { StatsBar } from "@/components/StatsBar";
import { SwapForm } from "@/components/SwapForm";
import { TradeMain } from "@/components/TradeMain";

export default function HomePage() {
  return (
    <main>
      <StatsBar />
      <div className="trade-grid">
        <TradeMain />
        <div className="trade-side">
          <SwapForm />
        </div>
      </div>
    </main>
  );
}
