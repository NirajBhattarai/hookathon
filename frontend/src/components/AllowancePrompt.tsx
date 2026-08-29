"use client";

import { useEffect, useState } from "react";
import { maxUint256, parseUnits } from "viem";

export type AllowanceMode = "infinite" | "exact";

export function AllowancePrompt({
  open,
  onClose,
  onConfirm,
  symbol,
  decimals,
  tradeAmount,
  spenderLabel = "BinBook Router",
}: {
  open: boolean;
  onClose: () => void;
  /** Called with the ERC20 amount to approve once the user confirms. */
  onConfirm: (approveAmount: bigint) => void;
  symbol?: string;
  decimals?: number;
  /** Human-readable amount being swapped, e.g. "100" — seeds the exact-amount field. */
  tradeAmount: string;
  spenderLabel?: string;
}) {
  const [mode, setMode] = useState<AllowanceMode>("infinite");
  const [amount, setAmount] = useState(tradeAmount);

  useEffect(() => {
    if (open) {
      setMode("infinite");
      setAmount(tradeAmount);
    }
    // only reseed when the prompt opens for a fresh swap, not on every keystroke elsewhere
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  if (!open) return null;

  const tradeAmountNum = Number(tradeAmount) || 0;
  const amountNum = Number(amount);
  const amountValid = mode === "infinite" || (Number.isFinite(amountNum) && amountNum >= tradeAmountNum);

  function confirm() {
    if (!amountValid || decimals === undefined) return;
    const approveAmount = mode === "infinite" ? maxUint256 : parseUnits(amount || "0", decimals);
    onConfirm(approveAmount);
  }

  return (
    <div className="tx-overlay" onClick={onClose}>
      <div className="tx-modal allowance-modal" onClick={(e) => e.stopPropagation()}>
        <button className="tx-modal-close" onClick={onClose} aria-label="Close">
          ×
        </button>
        <div className="tx-action-badge">Swap</div>

        <h3 className="allowance-title">Allow {spenderLabel} to use your {symbol ?? "token"}</h3>
        <p className="allowance-sub">
          You&apos;re granting <b>{spenderLabel}</b> permission to move {symbol ?? "this token"} from your
          wallet when you sign a swap. Choose how much it can access.
        </p>

        <div className="segmented">
          <button
            type="button"
            className={mode === "infinite" ? "seg-btn active" : "seg-btn"}
            onClick={() => setMode("infinite")}
          >
            Unlimited
            <small>Approve once, swap anytime</small>
          </button>
          <button
            type="button"
            className={mode === "exact" ? "seg-btn active" : "seg-btn"}
            onClick={() => setMode("exact")}
          >
            This swap only
            <small>
              Approve {tradeAmount} {symbol}
            </small>
          </button>
        </div>

        {mode === "exact" && (
          <div className="amount-row">
            <input
              value={amount}
              onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
              inputMode="decimal"
              aria-label="Allowance amount"
            />
            <span className="unit">{symbol} allowance</span>
          </div>
        )}
        {mode === "exact" && !amountValid && (
          <p className="allowance-warn">
            Must be at least {tradeAmount} {symbol} to cover this swap.
          </p>
        )}

        <details className="info-row">
          <summary className="info-head">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none">
              <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.6" />
              <path d="M12 11v5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
              <circle cx="12" cy="8" r="0.9" fill="currentColor" />
            </svg>
            <span>What am I approving?</span>
            <span className="chev">
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                <path
                  d="M6 9l6 6 6-6"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </span>
          </summary>
          <div className="info-body">
            An allowance lets {spenderLabel} move {symbol} out of your wallet only when you sign a swap —
            it can&apos;t pull funds on its own. <b>Unlimited</b> skips this step on future swaps;{" "}
            <b>this swap only</b> caps exposure to this trade and asks again next time. Revoke either one
            anytime from Manage Allowances.
          </div>
        </details>

        <button className="cta" type="button" disabled={!amountValid} onClick={confirm}>
          Approve {symbol}
        </button>
      </div>
    </div>
  );
}
