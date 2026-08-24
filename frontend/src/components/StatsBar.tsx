'use client'

import { useMemo } from 'react'
import { useDeployment } from '@/hooks/useDeployment'
import { usePool } from '@/hooks/usePool'
import { useSwapActivity } from '@/hooks/useSwapActivity'
import { useTokenMeta } from '@/hooks/useTokenMeta'
import { useTvl } from '@/hooks/useTvl'
import { computeStats } from '@/lib/priceSeries'
import { demoStats } from '@/lib/demo'

function fmtUsd(n: number): string {
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`
  if (n >= 1_000) return `$${(n / 1_000).toFixed(1)}K`
  return `$${n.toFixed(2)}`
}

function fmtPrice(p: number): string {
  if (p >= 1) return p.toFixed(4)
  if (p >= 0.0001) return p.toFixed(6)
  return p.toExponential(2)
}

export function StatsBar() {
  const { deployment, ready } = useDeployment()
  const { key } = usePool()
  const preview = !ready

  const base = useTokenMeta(key?.currency0)
  const quote = useTokenMeta(key?.currency1)
  const quoteDecimals = quote.decimals ?? 18

  const { events } = useSwapActivity('1D')
  const liveStats = useMemo(() => computeStats(events, quoteDecimals), [events, quoteDecimals])
  const stats = preview ? demoStats() : liveStats

  const tvl = useTvl(stats.lastPrice)

  const baseSymbol = preview ? 'DEMO' : (base.symbol ?? '…')
  const quoteSymbol = preview ? 'USDC' : (quote.symbol ?? '…')
  const up = (stats.changePct ?? 0) >= 0
  const feePct = ((deployment?.poolFee ?? 3000) / 10000).toFixed(2)

  return (
    <div className={preview ? 'stats-bar preview' : 'stats-bar'}>
      <div className="stats-bar-pair">
        <span className="pair-symbol">
          {baseSymbol}/{quoteSymbol}
        </span>
        {preview && <span className="badge">Preview</span>}
      </div>

      <div className="stats-bar-metrics">
        <div className="stat-pill">
          <span className="stat-pill-label">Price</span>
          <span className="stat-pill-value">{stats.lastPrice != null ? fmtPrice(stats.lastPrice) : '—'}</span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">24h change</span>
          <span className={`stat-pill-value ${up ? 'up' : 'down'}`}>
            {stats.changePct != null ? `${up ? '+' : ''}${stats.changePct.toFixed(2)}%` : '—'}
          </span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">24h volume</span>
          <span className="stat-pill-value">{fmtUsd(stats.volumeQuote)}</span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">TVL</span>
          <span className="stat-pill-value">
            {preview ? fmtUsd(842_000) : tvl.tvlInQuote != null ? fmtUsd(tvl.tvlInQuote) : '—'}
          </span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">Fee tier</span>
          <span className="stat-pill-value">{feePct}%</span>
        </div>
      </div>
    </div>
  )
}
