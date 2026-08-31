"use client";

import { useMemo } from "react";
import { useBinLiquidity } from "@/hooks/useBinLiquidity";
import { usePool } from "@/hooks/usePool";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import { useTradePair } from "@/context/TradePairContext";
import { formatPriceHuman } from "@/lib/priceMath";
import { binPriceInfo } from "@/lib/bins";

const WINDOW_HALF = 8;

export function LiquidityLadder() {
  const { pair: tradePair, pairResolved } = useTradePair();
  const { book, preview, series, maxL, isLoading, isRefreshing } = useBinLiquidity();
  const { key } = usePool();
  const base = useTokenMeta(tradePair?.token0 ?? key?.currency0);
  const quote = useTokenMeta(tradePair?.token1 ?? key?.currency1);
  const pairLabel = `${base.symbol ?? "token0"}/${quote.symbol ?? "token1"}`;

  const rows = useMemo(() => {
    if (!book || series.length === 0) return [];
    const activeIdx = series.findIndex((b) => b.binIndex === book.currentBin);
    if (activeIdx === -1) return series;
    const start = Math.max(0, activeIdx - WINDOW_HALF);
    const end = Math.min(series.length, activeIdx + WINDOW_HALF + 1);
    return series.slice(start, end);
  }, [series, book]);

  const showLadder = Boolean(book && rows.length > 0);
  const waitingForPool = !preview && (!pairResolved || isLoading);
  const unconfigured = !preview && pairResolved && !isLoading && book && !book.configured;
  const emptyDepth = !preview && pairResolved && !isLoading && book?.configured && rows.length === 0;

  let statusLine = `${pairLabel} · bin · depth · mean price`;
  if (waitingForPool) statusLine = `Loading ${pairLabel} book…`;
  else if (unconfigured)
    statusLine = `No BinBook pool for ${pairLabel} yet — create one and add liquidity first.`;
  else if (emptyDepth) statusLine = `${pairLabel} pool has no bin depth to show yet.`;

  const ordered = showLadder ? [...rows].sort((a, b) => b.binIndex - a.binIndex) : [];

  return (
    <div
      className={[
        preview ? "panel ladder-panel preview" : "panel ladder-panel",
        isRefreshing ? "panel-refreshing" : "",
        waitingForPool ? "panel-loading" : "",
      ]
        .filter(Boolean)
        .join(" ")}
    >
      <div className="panel-head">
        <div className="panel-title-row">
          <h2>Liquidity ladder</h2>
          {preview && <span className="badge">Preview</span>}
          {isRefreshing && <span className="badge">Updating</span>}
        </div>
        <p className="mono ladder-caption">{statusLine}</p>
      </div>
      {showLadder && book && (
        <div className="ladder">
          {ordered.map((b) => {
            const active = b.binIndex === book.currentBin;
            const pct = maxL === 0n ? 0 : Number((b.liquidity * 10000n) / maxL) / 100;
            const { arithmeticMean, priceLower, priceUpper } = binPriceInfo(b.binIndex, book.binSize);
            const price = formatPriceHuman(arithmeticMean);
            const edgeHint = `${formatPriceHuman(priceLower)} – ${formatPriceHuman(priceUpper)}`;

            if (active) {
              return (
                <div key={b.binIndex} className="ladder-row ladder-spot">
                  <span className="mono ladder-idx">{b.binIndex}</span>
                  <span className="ladder-spot-label">● active bin — spot</span>
                  <span className="mono ladder-price" title={`edges ${edgeHint}`}>
                    {price}
                  </span>
                </div>
              );
            }

            const side = b.binIndex < book.currentBin ? "buy" : "sell";
            return (
              <div key={b.binIndex} className={`ladder-row ${side}`}>
                <span className="mono ladder-idx">{b.binIndex}</span>
                <span className="ladder-bar-track">
                  <span
                    className={`ladder-bar ${side}`}
                    style={{ width: `${Math.max(pct, b.liquidity > 0n ? 4 : 0)}%` }}
                  />
                </span>
                <span className="mono ladder-price" title={`edges ${edgeHint}`}>
                  {price}
                </span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
