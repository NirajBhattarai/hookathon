"use client";

import { useMemo } from "react";
import { useDeployment } from "@/hooks/useDeployment";
import { usePool } from "@/hooks/usePool";
import { useSwapActivity } from "@/hooks/useSwapActivity";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import { useTvl } from "@/hooks/useTvl";
import { computeStats, toCandles, type Candle } from "@/lib/priceSeries";
import { demoCandles, demoStats } from "@/lib/demo";

function sparkPoints(candles: Candle[], w = 120, h = 32): string {
  if (candles.length < 2) return "";
  const closes = candles.map((c) => c.close);
  const min = Math.min(...closes);
  const max = Math.max(...closes);
  const range = max - min || 1;
  return closes
    .map((c, i) => {
      const x = (i / (closes.length - 1)) * w;
      const y = h - ((c - min) / range) * h;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");
}

function fmtUsd(n: number): string {
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `$${(n / 1_000).toFixed(1)}K`;
  return `$${n.toFixed(2)}`;
}

function fmtPrice(p: number): string {
  if (p >= 1) return p.toFixed(4);
  if (p >= 0.0001) return p.toFixed(6);
  return p.toExponential(2);
}

export function StatsBar() {
  const { deployment, ready } = useDeployment();
  const { key } = usePool();
  const preview = !ready;

  const base = useTokenMeta(key?.currency0);
  const quote = useTokenMeta(key?.currency1);
  const quoteDecimals = quote.decimals ?? 18;

  const { events } = useSwapActivity("1D");
  const liveStats = useMemo(() => computeStats(events, quoteDecimals), [events, quoteDecimals]);
  const stats = preview ? demoStats() : liveStats;

  const candles = useMemo(
    () => (preview ? demoCandles() : toCandles(events, 30 * 60)),
    [preview, events]
  );
  const spark = useMemo(() => sparkPoints(candles), [candles]);

  const tvl = useTvl(stats.lastPrice);

  const baseSymbol = preview ? "DEMO" : (base.symbol ?? "…");
  const quoteSymbol = preview ? "USDC" : (quote.symbol ?? "…");
  const up = (stats.changePct ?? 0) >= 0;
  const feePct = ((deployment?.poolFee ?? 3000) / 10000).toFixed(2);

  return (
    <div className={preview ? "stats-bar preview" : "stats-bar"}>
      <div className="stats-bar-pair">
        <span className="pair-symbol">
          {baseSymbol}/{quoteSymbol}
        </span>
        {preview && <span className="badge">Preview</span>}
      </div>

      {spark && (
        <svg className="stats-bar-spark" width="120" height="32" viewBox="0 0 120 32">
          <polyline
            points={spark}
            fill="none"
            stroke={up ? "var(--up)" : "var(--down)"}
            strokeWidth="1.75"
          />
        </svg>
      )}

      <div className="stats-bar-metrics">
        <div className="stat-pill">
          <span className="stat-pill-label">Price</span>
          <span className="stat-pill-value">
            {stats.lastPrice != null ? fmtPrice(stats.lastPrice) : "—"}
          </span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">24h change</span>
          <span className={`stat-pill-value ${up ? "up" : "down"}`}>
            {stats.changePct != null ? `${up ? "+" : ""}${stats.changePct.toFixed(2)}%` : "—"}
          </span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">24h volume</span>
          <span className="stat-pill-value">{fmtUsd(stats.volumeQuote)}</span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">TVL</span>
          <span className="stat-pill-value">
            {preview ? fmtUsd(842_000) : tvl.tvlInQuote != null ? fmtUsd(tvl.tvlInQuote) : "—"}
          </span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">Fee tier</span>
          <span className="stat-pill-value">{feePct}%</span>
        </div>
      </div>
    </div>
  );
}
