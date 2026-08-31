import dynamic from "next/dynamic";
import { Suspense } from "react";
import { PageFallback } from "@/components/PageFallback";

const LiquidityConsole = dynamic(
  () => import("@/components/LiquidityConsole").then((m) => ({ default: m.LiquidityConsole })),
  { loading: () => <PageFallback label="Loading liquidity console…" /> }
);

export default function LiquidityPage() {
  return (
    <main>
      <Suspense fallback={<PageFallback label="Loading liquidity console…" />}>
        <LiquidityConsole />
      </Suspense>
    </main>
  );
}
