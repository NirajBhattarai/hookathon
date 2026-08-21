'use client'

import { useMemo } from 'react'
import { useReadContract, useReadContracts } from 'wagmi'
import { binBookAbi } from '@/lib/abi/binBook'
import { buildDepthSeries } from '@/lib/bins'
import { DEMO_BOOK, demoDepthSeries } from '@/lib/demo'
import { useDeployment } from '@/hooks/useDeployment'
import { usePool } from '@/hooks/usePool'

type BookView = {
  binSize: number
  currentBin: number
  minBin: number
  maxBin: number
  configured: boolean
}

function parseBook(data: unknown): BookView | null {
  if (!data) return null
  if (Array.isArray(data)) {
    return {
      binSize: Number(data[0]),
      currentBin: Number(data[3]),
      minBin: Number(data[4]),
      maxBin: Number(data[5]),
      configured: Boolean(data[7]),
    }
  }
  const o = data as Record<string, unknown>
  return {
    binSize: Number(o.binSize),
    currentBin: Number(o.currentBin),
    minBin: Number(o.minBin),
    maxBin: Number(o.maxBin),
    configured: Boolean(o.configured),
  }
}

export function BinDepthChart() {
  const { deployment, ready } = useDeployment()
  const { poolId } = usePool()
  const address = deployment?.binBook
  const preview = !ready

  const bookQ = useReadContract({
    address,
    abi: binBookAbi,
    functionName: 'books',
    args: poolId ? [poolId] : undefined,
    query: { enabled: ready && !!poolId },
  })

  const liveBook = parseBook(bookQ.data)
  const book = preview ? DEMO_BOOK : liveBook

  const indexes = useMemo(() => {
    if (!book || preview) return []
    const out: number[] = []
    for (let i = book.minBin; i <= book.maxBin; i++) out.push(i)
    return out
  }, [book, preview])

  const liqs = useReadContracts({
    contracts: (indexes.length > 200 ? indexes.slice(0, 200) : indexes).map((i) => ({
      address,
      abi: binBookAbi,
      functionName: 'liquidity' as const,
      args: [poolId ?? ('0x' + '00'.repeat(32) as `0x${string}`), i],
    })),
    query: { enabled: ready && !!poolId && indexes.length > 0 },
  })

  const series = useMemo(() => {
    if (preview) return demoDepthSeries()
    if (!book) return []
    const map = new Map<number, bigint>()
    indexes.forEach((idx, j) => {
      const r = liqs.data?.[j]
      if (r?.status === 'success') map.set(idx, r.result as bigint)
    })
    return buildDepthSeries(book.minBin, book.maxBin, book.binSize, map)
  }, [preview, book, indexes, liqs.data])

  const maxL = useMemo(
    () => series.reduce((m, b) => (b.liquidity > m ? b.liquidity : m), 0n),
    [series],
  )

  if (!preview && !book?.configured) {
    return (
      <div className="panel">
        <div className="panel-head">
          <h2>Bin depth</h2>
          <p>Pool not configured — creator must call setBinSize.</p>
        </div>
      </div>
    )
  }

  if (!book) return null

  return (
    <aside className="side-stack">
      <div className={preview ? 'panel preview' : 'panel'}>
        <div className="panel-head">
          <div className="panel-title-row">
            <h2>Bin depth</h2>
            {preview && <span className="badge">Preview</span>}
          </div>
          <p>Liquidity decays around the active bin — swaps walk adjacent bins.</p>
        </div>
        <div className="depth-chart" role="img" aria-label="Bin liquidity depth">
          {series.map((b) => {
            const pct = maxL === 0n ? 0 : Number((b.liquidity * 10000n) / maxL) / 100
            const active = b.binIndex === book.currentBin
            return (
              <div
                key={b.binIndex}
                className={active ? 'depth-bar active' : 'depth-bar'}
                title={`bin ${b.binIndex}`}
                style={{ height: `${Math.max(pct, b.liquidity > 0n ? 6 : 0)}%` }}
              />
            )
          })}
        </div>
      </div>

      <div className="panel">
        <div className="panel-head">
          <h2>Book state</h2>
        </div>
        <dl className="meta-grid">
          <div className="meta-chip">
            <dt>Active bin</dt>
            <dd>{book.currentBin}</dd>
          </div>
          <div className="meta-chip">
            <dt>Bin size</dt>
            <dd>{book.binSize}</dd>
          </div>
          <div className="meta-chip">
            <dt>Min bin</dt>
            <dd>{book.minBin}</dd>
          </div>
          <div className="meta-chip">
            <dt>Max bin</dt>
            <dd>{book.maxBin}</dd>
          </div>
        </dl>
      </div>
    </aside>
  )
}
