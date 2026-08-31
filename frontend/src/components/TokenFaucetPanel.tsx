"use client";

import { useEffect, useMemo, useState } from "react";
import type { Address } from "viem";
import { formatUnits } from "viem";
import {
  useAccount,
  useReadContracts,
  useWaitForTransactionReceipt,
} from "wagmi";
import { useContractWrite } from "@/hooks/useContractWrite";
import { erc20Abi, tokenFaucetAbi } from "@/lib/abi/tokenFaucet";
import { FAUCET_TOKENS, type Category } from "@/lib/tokens";

const FILTERS = ["All", "Stables", "Majors", "L1s", "DeFi", "Memes"] as const;
const FAUCET_ADDRESS =
  (process.env.NEXT_PUBLIC_FAUCET_11155111 as Address | undefined) ??
  "0xF65e569C6a5DD2eB465fe69de653fDecc72eF019";

export function TokenFaucetPanel() {
  const { address, isConnected, status: accountStatus } = useAccount();
  const [filter, setFilter] = useState<(typeof FILTERS)[number]>("All");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const [pendingIndex, setPendingIndex] = useState<number | null>(null);
  const [mintAllPending, setMintAllPending] = useState(false);
  const [doneSymbol, setDoneSymbol] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  const { writeContractAsync, connector, data: hash, isPending: signing } = useContractWrite();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  const enabled = isConnected && !!address && !!connector && accountStatus === "connected";
  const balanceQueries = useReadContracts({
    query: { enabled },
    contracts: FAUCET_TOKENS.map((t) => ({
      address: t.address,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [address!],
    })),
  });

  // celebrate the minted row + refresh balances once confirmed
  useEffect(() => {
    if (!isSuccess) return;
    const idx = pendingIndex ?? (balanceQueries.data ? balanceQueries.data.length - 1 : -1);
    setDoneSymbol(FAUCET_TOKENS[idx]?.symbol ?? null);
    setStatus("Tokens delivered — check your balances below");
    setPendingIndex(null);
    setMintAllPending(false);
    balanceQueries.refetch();
    const t = setTimeout(() => setDoneSymbol(null), 2500);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess]);

  async function drip(index: number) {
    setStatus(null);
    setPendingIndex(index);
    try {
      await writeContractAsync({
        address: FAUCET_ADDRESS,
        abi: tokenFaucetAbi,
        functionName: "mint",
        args: [BigInt(index)],
      });
    } catch (err) {
      setStatus(err instanceof Error ? err.message.slice(0, 120) : "Mint failed");
      setPendingIndex(null);
    }
  }

  async function dripAll() {
    setStatus(null);
    setMintAllPending(true);
    try {
      await writeContractAsync({
        address: FAUCET_ADDRESS,
        abi: tokenFaucetAbi,
        functionName: "mintAll",
      });
    } catch (err) {
      setStatus(err instanceof Error ? err.message.slice(0, 120) : "Mint failed");
      setMintAllPending(false);
    }
  }

  function copyFaucet() {
    void navigator.clipboard?.writeText(FAUCET_ADDRESS);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  const visible = useMemo(() => {
    const q = search.trim().toLowerCase();
    return FAUCET_TOKENS.map((t, i) => ({ t, i })).filter(
      ({ t }) =>
        (filter === "All" || t.category === filter) &&
        (!q || t.symbol.toLowerCase().includes(q) || t.name.toLowerCase().includes(q))
    );
  }, [filter, search]);

  const busy = signing || confirming;

  return (
    <section className="page-wrap">
      {/* hero */}
      <div className="faucet-hero">
        <div className="faucet-hero-glow" aria-hidden />
        <span className="faucet-drip-icon" aria-hidden>
          <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
            <path
              d="M12 2.5c3.5 4.2 6.5 7.6 6.5 11.4A6.5 6.5 0 0 1 12 20.5a6.5 6.5 0 0 1-6.5-6.6C5.5 10.1 8.5 6.7 12 2.5Z"
              fill="currentColor"
            />
          </svg>
        </span>
        <h1 className="faucet-title">
          Test Token <em>Faucet</em>
        </h1>
        <p className="faucet-sub">
          Twenty mock top tokens with realistic decimals. Drip any of them, then pair them into your
          own BinBook pools.
        </p>
        <div className="faucet-chips">
          <span className="chip">{FAUCET_TOKENS.length} tokens</span>
          <span className="chip chip-accent">● Sepolia testnet</span>
          <button type="button" className="chip chip-copy" onClick={copyFaucet}>
            {copied ? "✓ copied" : `${FAUCET_ADDRESS.slice(0, 6)}…${FAUCET_ADDRESS.slice(-4)}`}
          </button>
        </div>
      </div>

      {/* toolbar */}
      <div className="form-card faucet-toolbar">
        <div className="faucet-filters" role="tablist">
          {FILTERS.map((f) => (
            <button
              key={f}
              type="button"
              role="tab"
              aria-selected={filter === f}
              className={`pill ${filter === f ? "pill-active" : ""}`}
              onClick={() => setFilter(f)}
            >
              {f}
            </button>
          ))}
        </div>
        <div className="faucet-actions">
          <input
            className="faucet-search"
            placeholder="Search token…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <button
            type="button"
            className="cta"
            disabled={!enabled || busy || mintAllPending}
            onClick={dripAll}
          >
            {mintAllPending ? (confirming ? "Confirming…" : "Sign in wallet…") : "Mint All"}
          </button>
        </div>
      </div>

      {status && <p className="status ok">{status}</p>}
      {!enabled && (
        <p className="status muted">
          {accountStatus === "reconnecting"
            ? "Restoring wallet connection…"
            : "Connect your wallet to start dripping tokens."}
        </p>
      )}

      {/* grid */}
      <div className="faucet-grid">
        {visible.map(({ t, i }) => {
          const bal = balanceQueries.data?.[i]?.result as bigint | undefined;
          const rowBusy = busy || pendingIndex === i || mintAllPending;
          const isDone = doneSymbol === t.symbol;
          return (
            <article key={t.symbol} className={`token-card ${isDone ? "token-card-done" : ""}`}>
              <header className="token-card-head">
                <span className="token-avatar" style={{ background: t.color }}>
                  {t.symbol.slice(0, 1)}
                </span>
                <div className="token-card-id">
                  <strong>{t.symbol}</strong>
                  <span className="muted">{t.name}</span>
                </div>
                <span className="badge">{t.decimals} dec</span>
              </header>

              <div className="token-card-body">
                <div className="token-stat">
                  <span className="muted">Your balance</span>
                  <strong className="token-balance">
                    {bal !== undefined
                      ? Number(formatUnits(bal, t.decimals)).toLocaleString(undefined, {
                          maximumFractionDigits: 2,
                        })
                      : "—"}
                  </strong>
                </div>
                <div className="token-stat">
                  <span className="muted">Per drip</span>
                  <strong className="token-drip">+{t.amountLabel}</strong>
                </div>
              </div>

              <button
                type="button"
                className={`cta ${isDone ? "cta-success" : ""}`}
                disabled={!enabled || rowBusy}
                onClick={() => drip(i)}
              >
                {isDone
                  ? "✓ Sent"
                  : pendingIndex === i
                    ? confirming
                      ? "Confirming…"
                      : "Sign…"
                    : rowBusy
                      ? "…"
                      : "Mint"}
              </button>
            </article>
          );
        })}
      </div>

      {!visible.length && <p className="status muted">No tokens match “{search}”.</p>}
    </section>
  );
}
