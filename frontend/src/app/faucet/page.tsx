import dynamic from "next/dynamic";
import { PageFallback } from "@/components/PageFallback";

const TokenFaucetPanel = dynamic(
  () => import("@/components/TokenFaucetPanel").then((m) => ({ default: m.TokenFaucetPanel })),
  { loading: () => <PageFallback label="Loading faucet…" /> }
);

export default function FaucetPage() {
  return (
    <main>
      <TokenFaucetPanel />
    </main>
  );
}
