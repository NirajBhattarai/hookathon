'use client'

import { useEffect, useMemo, useRef, useState } from 'react'
import {
  CandlestickSeries,
  ColorType,
  HistogramSeries,
  createChart,
  type IChartApi,
  type ISeriesApi,
  type UTCTimestamp,
} from 'lightweight-charts'
import { useDeployment } from '@/hooks/useDeployment'
import { usePool } from '@/hooks/usePool'
import { useSwapActivity, type Timeframe } from '@/hooks/useSwapActivity'
import { useTokenMeta } from '@/hooks/useTokenMeta'
import { toCandles, toVolumeBars } from '@/lib/priceSeries'
import { demoCandles, demoVolumeBars } from '@/lib/demo'

const TIMEFRAMES: { id: Timeframe; label: string; bucketSeconds: number }[] = [
  { id: '1H', label: '1H', bucketSeconds: 60 },
  { id: '1D', label: '1D', bucketSeconds: 15 * 60 },
  { id: '1W', label: '1W', bucketSeconds: 2 * 60 * 60 },
  { id: 'ALL', label: 'ALL', bucketSeconds: 6 * 60 * 60 },
]

const FONT = '"IBM Plex Sans", "Helvetica Neue", sans-serif'

export function PriceChart() {
  const { ready } = useDeployment()
  const { key } = usePool()
  const preview = !ready
  const [tf, setTf] = useState<Timeframe>('1H')
  const tfMeta = TIMEFRAMES.find((t) => t.id === tf)!

  const { events, isFetching, refetch } = useSwapActivity(tf)
  const quoteDecimals = useTokenMeta(key?.currency1).decimals ?? 18

  const candles = useMemo(
    () => (preview ? demoCandles() : toCandles(events, tfMeta.bucketSeconds)),
    [preview, events, tfMeta.bucketSeconds],
  )
  const volume = useMemo(
    () => (preview ? demoVolumeBars() : toVolumeBars(events, tfMeta.bucketSeconds, quoteDecimals)),
    [preview, events, tfMeta.bucketSeconds, quoteDecimals],
  )

  const containerRef = useRef<HTMLDivElement>(null)
  const chartRef = useRef<IChartApi | null>(null)
  const candleSeriesRef = useRef<ISeriesApi<'Candlestick'> | null>(null)
  const volumeSeriesRef = useRef<ISeriesApi<'Histogram'> | null>(null)

  useEffect(() => {
    if (!containerRef.current) return
    const chart = createChart(containerRef.current, {
      layout: {
        background: { type: ColorType.Solid, color: 'transparent' },
        textColor: '#8b949e',
        fontFamily: FONT,
      },
      grid: {
        vertLines: { color: 'rgba(255,255,255,0.04)' },
        horzLines: { color: 'rgba(255,255,255,0.04)' },
      },
      rightPriceScale: { borderColor: 'rgba(255,255,255,0.08)' },
      timeScale: { borderColor: 'rgba(255,255,255,0.08)', timeVisible: true },
      autoSize: true,
    })

    const candleSeries = chart.addSeries(CandlestickSeries, {
      upColor: '#3ecf8e',
      downColor: '#f07167',
      borderVisible: false,
      wickUpColor: '#3ecf8e',
      wickDownColor: '#f07167',
      priceScaleId: 'right',
    })
    candleSeries.priceScale().applyOptions({ scaleMargins: { top: 0.08, bottom: 0.28 } })

    const volumeSeries = chart.addSeries(HistogramSeries, {
      priceFormat: { type: 'volume' },
      priceScaleId: '',
    })
    volumeSeries.priceScale().applyOptions({ scaleMargins: { top: 0.78, bottom: 0 } })

    chartRef.current = chart
    candleSeriesRef.current = candleSeries
    volumeSeriesRef.current = volumeSeries

    return () => {
      chart.remove()
      chartRef.current = null
      candleSeriesRef.current = null
      volumeSeriesRef.current = null
    }
  }, [])

  useEffect(() => {
    if (!candleSeriesRef.current || !volumeSeriesRef.current) return
    candleSeriesRef.current.setData(
      candles.map((c) => ({ ...c, time: c.time as UTCTimestamp })),
    )
    volumeSeriesRef.current.setData(
      volume.map((v) => ({
        time: v.time as UTCTimestamp,
        value: v.value,
        color: v.buy ? 'rgba(62,207,142,0.5)' : 'rgba(240,113,103,0.5)',
      })),
    )
    chartRef.current?.timeScale().fitContent()
  }, [candles, volume])

  const showEmpty = !preview && !isFetching && events.length === 0

  return (
    <div className={preview ? 'chart-panel preview' : 'chart-panel'}>
      <div className="chart-panel-head">
        <div className="chart-tf-group">
          {TIMEFRAMES.map((t) => (
            <button
              key={t.id}
              type="button"
              className={tf === t.id ? 'chart-tf active' : 'chart-tf'}
              onClick={() => setTf(t.id)}
            >
              {t.label}
            </button>
          ))}
        </div>
        {preview ? (
          <span className="badge">Preview</span>
        ) : (
          <button
            type="button"
            className="chart-refresh"
            onClick={() => refetch()}
            disabled={isFetching}
            aria-label="Refresh chart"
            title="Refresh"
          >
            {isFetching ? '…' : '↻'}
          </button>
        )}
      </div>
      <div className="chart-canvas-wrap">
        <div className="chart-canvas" ref={containerRef} />
        {showEmpty && (
          <div className="chart-empty">No swaps yet in this window — trade to populate the chart.</div>
        )}
      </div>
    </div>
  )
}
