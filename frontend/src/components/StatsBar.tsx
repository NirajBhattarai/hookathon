"use client";

import { useMemo } from "react";
import { useBook } from "@/hooks/useBook";
import { useDeployment } from "@/hooks/useDeployment";
import { useIdleReady } from "@/hooks/useIdleReady";
import { usePool } from "@/hooks/usePool";
import { useSwapActivity } from "@/hooks/useSwapActivity";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import { useTvl } from "@/hooks/useTvl";
import { useTradePair } from "@/context/TradePairContext";
import { computeStats, toCandles, type Candle } from "@/lib/priceSeries";
import { demoCandles, demoStats } from "@/lib/demo";
import { formatPriceHuman, sqrtPriceX96ToPrice } from "@/lib/priceMath";

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

// volume/TVL are denominated in the pool's *quote* token (currency1), not necessarily USD — only
// prefix with "$" when the quote is a known USD stablecoin so we never overstate a fiat value.
const USD_STABLECOINS = new Set(["USDC", "USDT", "DAI", "BUSD", "FDUSD", "TUSD"]);
function fmtQuote(n: number, symbol: string): string {
  const prefix = USD_STABLECOINS.has(symbol) ? "$" : `${symbol} `;
  if (n >= 1_000_000) return `${prefix}${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `${prefix}${(n / 1_000).toFixed(1)}K`;
  return `${prefix}${n.toFixed(2)}`;
}

export function StatsBar() {
  const { deployment, ready } = useDeployment();
  const { pair: tradePair, pairResolved } = useTradePair();
  const { key } = usePool();
  const { book } = useBook();
  const preview = !ready;

  const base = useTokenMeta(tradePair?.token0 ?? key?.currency0);
  const quote = useTokenMeta(tradePair?.token1 ?? key?.currency1);
  const quoteDecimals = quote.decimals ?? 18;

  const deferLogs = useIdleReady(500);
  const { events, isLoading: activityLoading } = useSwapActivity("1D", { enabled: deferLogs });
  const liveStats = useMemo(() => computeStats(events, quoteDecimals), [events, quoteDecimals]);
  const statsPending = !preview && (!pairResolved || activityLoading);
  const stats = preview ? demoStats() : liveStats;

  // The pool's live AMM price is always available once it's seeded — unlike lastPrice, which
  // needs an actual trade to have happened. Fall back to lastPrice only if that's ever unset.
  const bookPrice = book && book.sqrtPriceX96 > 0n ? sqrtPriceX96ToPrice(book.sqrtPriceX96) : null;
  const spotPrice = preview ? stats.lastPrice : (bookPrice ?? stats.lastPrice);

  const candles = useMemo(
    () => (preview ? demoCandles() : toCandles(events, 30 * 60)),
    [preview, events]
  );
  const spark = useMemo(() => sparkPoints(candles), [candles]);

  const tvl = useTvl(spotPrice);

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
            {spotPrice != null ? formatPriceHuman(spotPrice) : "—"}
          </span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">24h change</span>
          <span className={`stat-pill-value ${up ? "up" : "down"}`}>
            {statsPending
              ? "…"
              : stats.changePct != null
                ? `${up ? "+" : ""}${stats.changePct.toFixed(2)}%`
                : "—"}
          </span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">24h volume ({quoteSymbol})</span>
          <span className="stat-pill-value">
            {statsPending ? "…" : fmtQuote(stats.volumeQuote, quoteSymbol)}
          </span>
        </div>
        <div className="stat-pill">
          <span className="stat-pill-label">TVL ({quoteSymbol})</span>
          <span className="stat-pill-value">
            {preview
              ? fmtQuote(842_000, quoteSymbol)
              : statsPending || tvl.tvlInQuote == null
                ? "…"
                : fmtQuote(tvl.tvlInQuote, quoteSymbol)}
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
