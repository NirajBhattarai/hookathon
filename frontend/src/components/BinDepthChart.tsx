"use client";

import { tickToPrice } from "@/lib/priceMath";
import { useBinLiquidity } from "@/hooks/useBinLiquidity";

export type BinRange = { lower: number; upper: number };

export function BinDepthChart({
  selection = null,
  onSelectBin,
}: {
  /** Bin index range (inclusive) to highlight, e.g. a pending add-liquidity range. */
  selection?: BinRange | null;
  /** When provided, bins become clickable and the chart doubles as a range picker. */
  onSelectBin?: (binIndex: number) => void;
} = {}) {
  const { book, preview, series, maxL } = useBinLiquidity();

  if (!preview && !book?.configured) {
    return (
      <div className="panel">
        <div className="panel-head">
          <h2>Bin depth</h2>
          <p>Pool not configured — creator must call setBinSize.</p>
        </div>
      </div>
    );
  }

  if (!book) return null;

  return (
    <aside className="side-stack">
      <div className={preview ? "panel preview" : "panel"}>
        <div className="panel-head">
          <div className="panel-title-row">
            <h2>Bin depth</h2>
            {preview && <span className="badge">Preview</span>}
          </div>
          <p>
            {onSelectBin
              ? "Click a bin to start a range, click again to finish it."
              : "Liquidity decays around the active bin — swaps walk adjacent bins."}
          </p>
        </div>
        <div className="depth-chart" role="img" aria-label="Bin liquidity depth">
          {series.map((b) => {
            const pct = maxL === 0n ? 0 : Number((b.liquidity * 10000n) / maxL) / 100;
            const active = b.binIndex === book.currentBin;
            const inSelection =
              !!selection && b.binIndex >= selection.lower && b.binIndex <= selection.upper;
            const side = active ? "active" : b.binIndex < book.currentBin ? "sell" : "buy";
            const priceLower = tickToPrice(b.tickLower);
            const priceUpper = tickToPrice(b.tickUpper);
            const cls = [
              "depth-bar",
              side,
              inSelection ? "selected" : "",
              onSelectBin ? "clickable" : "",
            ]
              .filter(Boolean)
              .join(" ");
            return (
              <div
                key={b.binIndex}
                className={cls}
                title={`bin ${b.binIndex} · price ${priceLower.toPrecision(6)}–${priceUpper.toPrecision(6)} · liquidity ${b.liquidity.toString()}`}
                style={{ height: `${Math.max(pct, b.liquidity > 0n ? 6 : 0)}%` }}
                onClick={onSelectBin ? () => onSelectBin(b.binIndex) : undefined}
                role={onSelectBin ? "button" : undefined}
                tabIndex={onSelectBin ? 0 : undefined}
              />
            );
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
  );
}
