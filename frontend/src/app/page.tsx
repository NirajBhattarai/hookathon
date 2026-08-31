import dynamic from "next/dynamic";
import { PageFallback } from "@/components/PageFallback";

const TradePage = dynamic(
  () => import("@/components/TradePage").then((m) => ({ default: m.TradePage })),
  { loading: () => <PageFallback label="Loading swap…" /> }
);

export default function HomePage() {
  return <TradePage />;
}
