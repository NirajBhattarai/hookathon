"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import type { Address } from "viem";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import { shortenAddress } from "@/lib/bins";
import { FAUCET_TOKENS, type FaucetToken } from "@/lib/tokens";

export function TokenAvatar({ color, symbol }: { color?: string; symbol: string }) {
  return (
    <span
      className="token-avatar token-avatar-sm"
      style={color ? { background: color } : undefined}
    >
      {symbol.slice(0, 1)}
    </span>
  );
}

export function TokenSelect({
  value,
  onSelect,
  disabled,
  extraTokens,
}: {
  value: Address;
  onSelect: (a: Address) => void;
  disabled?: boolean;
  /** Extra rows to offer beyond the faucet list — e.g. a configured pair's tokens that aren't in it. */
  extraTokens?: FaucetToken[];
}) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const ref = useRef<HTMLDivElement>(null);
  // useTokenMeta already falls back to a live read for a token outside the static faucet list,
  // so the button shows the right symbol even for one not passed via extraTokens either.
  const current = useTokenMeta(value);

  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (!ref.current?.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onDoc);
    return () => document.removeEventListener("mousedown", onDoc);
  }, []);

  const allTokens = useMemo(() => {
    if (!extraTokens?.length) return FAUCET_TOKENS;
    const seen = new Set(FAUCET_TOKENS.map((t) => t.address.toLowerCase()));
    const extras = extraTokens.filter((t) => !seen.has(t.address.toLowerCase()));
    return [...extras, ...FAUCET_TOKENS];
  }, [extraTokens]);

  const list = useMemo(() => {
    const s = q.trim().toLowerCase();
    return allTokens.filter(
      (t) => !s || t.symbol.toLowerCase().includes(s) || t.name.toLowerCase().includes(s)
    );
  }, [allTokens, q]);

  // Two different real tokens can share a symbol (e.g. two "WETH" contracts) — disambiguate
  // those rows with the address so picking the right one isn't a guess.
  const dupSymbols = useMemo(() => {
    const counts = new Map<string, number>();
    for (const t of allTokens) {
      const k = t.symbol.toLowerCase();
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
    return new Set([...counts.entries()].filter(([, n]) => n > 1).map(([k]) => k));
  }, [allTokens]);

  return (
    <div className="tok-select" ref={ref}>
      <button
        type="button"
        className="tok-select-btn"
        disabled={disabled}
        onClick={() => setOpen((v) => !v)}
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        <TokenAvatar color={current.color} symbol={current.symbol ?? "?"} />
        <strong>{current.symbol ?? "Select"}</strong>
        <span className="tok-caret">▾</span>
      </button>

      {open && (
        <div className="tok-menu" role="listbox">
          <input
            className="faucet-search tok-search"
            placeholder="Search token…"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            autoFocus
          />
          <ul>
            {list.map((t) => (
              <li key={t.address}>
                <button
                  type="button"
                  role="option"
                  aria-selected={t.address === value}
                  className={`tok-row ${t.address === value ? "tok-row-active" : ""}`}
                  onClick={() => {
                    onSelect(t.address);
                    setOpen(false);
                    setQ("");
                  }}
                >
                  <TokenAvatar color={t.color} symbol={t.symbol} />
                  <span className="tok-id">
                    <strong>{t.symbol}</strong>
                    <span>
                      {t.name}
                      {dupSymbols.has(t.symbol.toLowerCase()) ? ` · ${shortenAddress(t.address)}` : ""}
                    </span>
                  </span>
                  <span className="muted tiny">{t.category}</span>
                </button>
              </li>
            ))}
            {!list.length && <li className="muted tiny tok-empty">No match</li>}
          </ul>
        </div>
      )}
    </div>
  );
}
