import { ActivityTable } from '@/components/ActivityTable'
import { BinDepthChart } from '@/components/BinDepthChart'
import { PriceChart } from '@/components/PriceChart'
import { StatsBar } from '@/components/StatsBar'
import { SwapForm } from '@/components/SwapForm'

export default function HomePage() {
  return (
    <main>
      <StatsBar />
      <div className="trade-grid">
        <div className="trade-main">
          <PriceChart />
          <ActivityTable />
        </div>
        <div className="trade-side">
          <SwapForm />
          <BinDepthChart />
        </div>
      </div>
    </main>
  )
}
