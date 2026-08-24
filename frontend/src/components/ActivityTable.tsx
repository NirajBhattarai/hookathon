"use client";

import { useMemo } from "react";
import { formatUnits } from "viem";
import { useDeployment } from "@/hooks/useDeployment";
import { usePool } from "@/hooks/usePool";
import { useSwapActivity } from "@/hooks/useSwapActivity";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import { demoTrades } from "@/lib/demo";

function timeAgo(sec: number): string {
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - sec);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

export function ActivityTable() {
  const { deployment, ready } = useDeployment();
  const { key } = usePool();
  const preview = !ready;
  const { events } = useSwapActivity("1D");

  const base = useTokenMeta(key?.currency0);
  const quote = useTokenMeta(key?.currency1);
  const quoteDecimals = quote.decimals ?? 18;
  const quoteSymbol = preview ? "USDC" : (quote.symbol ?? "…");
  const baseSymbol = preview ? "DEMO" : (base.symbol ?? "…");

  const rows = useMemo(() => {
    if (preview) return demoTrades();
    return [...events]
      .reverse()
      .slice(0, 25)
      .map((e) => ({
        time: e.timestamp,
        side: e.zeroForOne ? ("sell" as const) : ("buy" as const),
        price: e.price,
        amountQuote: Number(formatUnits(e.amount1 > 0n ? e.amount1 : -e.amount1, quoteDecimals)),
        txHash: e.txHash,
      }));
  }, [preview, events, quoteDecimals]);

  const explorerBase = deployment?.chainId === 11155111 ? "https://sepolia.etherscan.io/tx/" : null;

  return (
    <div className="panel activity-panel">
      <div className="panel-head">
        <div className="panel-title-row">
          <h2>Recent trades</h2>
          {preview && <span className="badge">Preview</span>}
        </div>
        <p>
          {baseSymbol}/{quoteSymbol} · live from on-chain swap events
        </p>
      </div>

      {rows.length === 0 ? (
        <p className="muted tiny">No trades yet — swap to see activity here.</p>
      ) : (
        <div className="activity-table-wrap">
          <table className="activity-table">
            <thead>
              <tr>
                <th>Side</th>
                <th>Price</th>
                <th>{quoteSymbol} amount</th>
                <th>Time</th>
                <th aria-hidden />
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i}>
                  <td className={r.side === "buy" ? "up" : "down"}>
                    {r.side === "buy" ? "Buy" : "Sell"}
                  </td>
                  <td className="tabular">
                    {r.price >= 1 ? r.price.toFixed(4) : r.price.toFixed(6)}
                  </td>
                  <td className="tabular">
                    {r.amountQuote.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                  </td>
                  <td className="muted">{timeAgo(r.time)}</td>
                  <td>
                    {!preview && explorerBase ? (
                      <a
                        href={`${explorerBase}${r.txHash}`}
                        target="_blank"
                        rel="noreferrer"
                        className="muted tiny"
                        aria-label="View on Etherscan"
                      >
                        ↗
                      </a>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
