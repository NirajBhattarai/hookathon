import dynamic from "next/dynamic";
import { PageFallback } from "@/components/PageFallback";

const PortfolioPanel = dynamic(
  () => import("@/components/PortfolioPanel").then((m) => ({ default: m.PortfolioPanel })),
  { loading: () => <PageFallback label="Loading portfolio…" /> }
);

export default function PortfolioPage() {
  return (
    <main>
      <PortfolioPanel />
    </main>
  );
}
