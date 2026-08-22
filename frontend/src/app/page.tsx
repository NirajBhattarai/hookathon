import { BinDepthChart } from '@/components/BinDepthChart'
import { SwapForm } from '@/components/SwapForm'

export default function HomePage() {
  return (
    <main className="trade-layout">
      <div className="swap-stage">
        <SwapForm />
      </div>
      <BinDepthChart />
    </main>
  )
}
