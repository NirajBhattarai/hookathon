"use client";

import type { Address } from "viem";

export type TxStatus = "pending" | "confirming" | "success" | "error";

export interface TxStep {
  label: string;
  done: boolean;
}

function explorerTxUrl(chainId: number, hash: string): string {
  if (chainId === 1) return `https://etherscan.io/tx/${hash}`;
  if (chainId === 11155111) return `https://sepolia.etherscan.io/tx/${hash}`;
  return `https://etherscan.io/tx/${hash}`;
}

export function TxModal({
  open,
  onClose,
  status,
  hash,
  chainId,
  error,
  action,
  summary,
  steps,
}: {
  open: boolean;
  onClose: () => void;
  status: TxStatus;
  hash?: Address | null;
  chainId?: number;
  error?: string | null;
  /** e.g. "Swap", "Add Liquidity" */
  action?: string;
  /** e.g. "100 USDC → 0.05 WETH" */
  summary?: string;
  /** Optional step list for multi-tx flows */
  steps?: TxStep[];
}) {
  if (!open) return null;

  const activeStep = steps?.findIndex((s) => !s.done) ?? -1;

  return (
    <div className="tx-overlay" onClick={onClose}>
      <div className="tx-modal" onClick={(e) => e.stopPropagation()}>
        <button className="tx-modal-close" onClick={onClose} aria-label="Close">
          ×
        </button>

        {action && <div className="tx-action-badge">{action}</div>}

        {status === "pending" && (
          <div className="tx-modal-body">
            <div className="tx-spinner" />
            {summary && <p className="tx-summary">{summary}</p>}

            {steps && steps.length > 0 && (
              <div className="tx-steps">
                {steps.map((s, i) => (
                  <div
                    key={i}
                    className={
                      s.done
                        ? "tx-step done"
                        : i === activeStep
                          ? "tx-step active"
                          : "tx-step"
                    }
                  >
                    <span className="tx-step-dot">
                      {s.done ? "✓" : i === activeStep ? <div className="tx-step-spinner" /> : (i + 1)}
                    </span>
                    <span className="tx-step-label">{s.label}</span>
                  </div>
                ))}
              </div>
            )}

            {!steps && <p className="tx-hint">Confirm in your wallet…</p>}
          </div>
        )}

        {status === "confirming" && (
          <div className="tx-modal-body">
            <div className="tx-spinner" />
            <h3>Transaction submitted</h3>
            {summary && <p className="tx-summary">{summary}</p>}
            {hash && (
              <a
                className="tx-hash-link"
                href={explorerTxUrl(chainId ?? 11155111, hash)}
                target="_blank"
                rel="noopener noreferrer"
              >
                {hash.slice(0, 6)}…{hash.slice(-4)}
              </a>
            )}
            <p className="tx-hint">Waiting for confirmation…</p>
          </div>
        )}

        {status === "success" && (
          <div className="tx-modal-body">
            <div className="tx-success-icon">✓</div>
            <h3>{action ? `${action} confirmed` : "Transaction confirmed"}</h3>
            {summary && <p className="tx-summary">{summary}</p>}
            {hash && (
              <a
                className="tx-hash-link"
                href={explorerTxUrl(chainId ?? 11155111, hash)}
                target="_blank"
                rel="noopener noreferrer"
              >
                View on explorer ↗
              </a>
            )}
            <button className="cta tx-done-btn" onClick={onClose}>
              Done
            </button>
          </div>
        )}

        {status === "error" && (
          <div className="tx-modal-body">
            <div className="tx-error-icon">✕</div>
            <h3>{action ? `${action} failed` : "Transaction failed"}</h3>
            {summary && <p className="tx-summary">{summary}</p>}
            {error && <p className="tx-error-msg">{error}</p>}
            <button className="cta tx-done-btn" onClick={onClose}>
              Close
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
