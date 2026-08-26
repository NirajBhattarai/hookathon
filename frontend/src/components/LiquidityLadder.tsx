"use client";

import { useMemo } from "react";
import { useBinLiquidity } from "@/hooks/useBinLiquidity";
import { formatPriceHuman, tickToPrice } from "@/lib/priceMath";

const WINDOW_HALF = 8;

export function LiquidityLadder() {
  const { book, preview, series, maxL } = useBinLiquidity();

  const rows = useMemo(() => {
    if (!book || series.length === 0) return [];
    const activeIdx = series.findIndex((b) => b.binIndex === book.currentBin);
    if (activeIdx === -1) return series;
    const start = Math.max(0, activeIdx - WINDOW_HALF);
    const end = Math.min(series.length, activeIdx + WINDOW_HALF + 1);
    return series.slice(start, end);
  }, [series, book]);

  if (!preview && !book?.configured) {
    return (
      <div className="panel">
        <div className="panel-head">
          <h2>Liquidity ladder</h2>
          <p>Pool not configured — creator must call setBinSize.</p>
        </div>
      </div>
    );
  }

  if (!book || rows.length === 0) return null;

  // top of the ladder = highest price = highest bin index
  const ordered = [...rows].sort((a, b) => b.binIndex - a.binIndex);

  return (
    <div className={preview ? "panel ladder-panel preview" : "panel ladder-panel"}>
      <div className="panel-head">
        <div className="panel-title-row">
          <h2>Liquidity ladder</h2>
          {preview && <span className="badge">Preview</span>}
        </div>
        <p className="mono ladder-caption">bin · depth · price</p>
      </div>
      <div className="ladder">
        {ordered.map((b) => {
          const active = b.binIndex === book.currentBin;
          const pct = maxL === 0n ? 0 : Number((b.liquidity * 10000n) / maxL) / 100;
          const price = formatPriceHuman(tickToPrice(b.tickLower));

          if (active) {
            return (
              <div key={b.binIndex} className="ladder-row ladder-spot">
                <span className="mono ladder-idx">{b.binIndex}</span>
                <span className="ladder-spot-label">● active bin — spot</span>
                <span className="mono ladder-price">{price}</span>
              </div>
            );
          }

          const side = b.binIndex < book.currentBin ? "sell" : "buy";
          return (
            <div key={b.binIndex} className={`ladder-row ${side}`}>
              <span className="mono ladder-idx">{b.binIndex}</span>
              <span className="ladder-bar-track">
                <span
                  className={`ladder-bar ${side}`}
                  style={{ width: `${Math.max(pct, b.liquidity > 0n ? 4 : 0)}%` }}
                />
              </span>
              <span className="mono ladder-price">{price}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
