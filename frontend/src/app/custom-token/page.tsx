import dynamic from "next/dynamic";
import { PageFallback } from "@/components/PageFallback";

const CustomTokenPanel = dynamic(
  () => import("@/components/CustomTokenPanel").then((m) => ({ default: m.CustomTokenPanel })),
  { loading: () => <PageFallback label="Loading custom token…" /> }
);

export default function CustomTokenPage() {
  return (
    <main>
      <CustomTokenPanel />
    </main>
  );
}
