"use client";

import Link from "next/link";
import { useEffect, useMemo, useState, type CSSProperties } from "react";
import { formatUnits, type Address } from "viem";
import { useAccount, useWaitForTransactionReceipt } from "wagmi";
import { useContractWrite } from "@/hooks/useContractWrite";
import { binBookAbi } from "@/lib/abi/binBook";
import { TokenAvatar, TokenSelect } from "@/components/TokenSelect";
import { TxModal, type TxStatus } from "@/components/TxModal";
import { useDeployment } from "@/hooks/useDeployment";
import { useIdleReady } from "@/hooks/useIdleReady";
import { usePairPosition } from "@/hooks/usePairPosition";
import { usePool } from "@/hooks/usePool";
import { usePositions, type Position } from "@/hooks/usePositions";
import { useAppPublicClient } from "@/hooks/useAppPublicClient";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import { unpackBalanceDelta } from "@/lib/balanceDelta";
import { formatBigIntCompact, formatPriceHuman, sqrtPriceX96ToPrice } from "@/lib/priceMath";
import type { FaucetToken } from "@/lib/tokens";

const WITHDRAW_PRESETS = [25, 50, 75, 100] as const;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;

function fmtAmount(raw: bigint, decimals?: number): string {
  if (decimals === undefined) return "—";
  const v = Number(formatUnits(raw, decimals));
  if (v === 0) return "0";
  return v < 0.0001
    ? v.toExponential(2)
    : v.toLocaleString(undefined, { maximumFractionDigits: 6 });
}

function PositionCard({ position, onChanged }: { position: Position; onChanged: () => void }) {
  const { deployment } = useDeployment();
  const { address } = useAccount();
  const publicClient = useAppPublicClient(deployment);
  const base = useTokenMeta(position.key.currency0);
  const quote = useTokenMeta(position.key.currency1);

  const [pct, setPct] = useState(100);
  const [slippage, setSlippage] = useState("0.50");
  const [expanded, setExpanded] = useState(false);

  const [modalOpen, setModalOpen] = useState(false);
  const [modalStatus, setModalStatus] = useState<TxStatus>("pending");
  const [modalAction, setModalAction] = useState<string>("");
  const [modalSummary, setModalSummary] = useState<string | undefined>(undefined);
  const [modalError, setModalError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);

  const { writeContractAsync, isPending } = useContractWrite();
  const { isLoading: confirming } = useWaitForTransactionReceipt({ hash: txHash ?? undefined });

  const price = position.sqrtPriceX96 > 0n ? sqrtPriceX96ToPrice(position.sqrtPriceX96) : null;
  const hasFees = position.fee0 > 0n || position.fee1 > 0n;
  const busy = isPending || confirming;

  async function run(label: string, summary: string | undefined, fn: () => Promise<`0x${string}`>) {
    setModalAction(label);
    setModalSummary(summary);
    setModalError(null);
    setModalStatus("pending");
    setModalOpen(true);
    setTxHash(null);
    try {
      const hash = await fn();
      setTxHash(hash);
      setModalStatus("confirming");
      onChanged();
    } catch (err) {
      setModalStatus("error");
      setModalError(err instanceof Error ? err.message.slice(0, 200) : "Transaction failed");
    }
  }

  async function claim() {
    if (!deployment || !address || !publicClient) return;
    await run("Claim Fees", undefined, async () => {
      const args = [position.key] as const;
      const sim = await publicClient.simulateContract({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "collectFees",
        args,
        account: address,
      } as Parameters<typeof publicClient.simulateContract>[0]);
      const gas = sim.request.gas ? (sim.request.gas * 12n) / 10n : 1_500_000n;
      return writeContractAsync({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "collectFees",
        args,
        gas,
      });
    });
  }

  async function remove() {
    if (!deployment || !position.hasRange || !address || !publicClient) return;
    const amount = (position.shares * BigInt(pct)) / 100n;
    if (amount === 0n) return;

    const tickLower = position.tickLower;
    const tickUpper = position.tickUpper;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
    const userInputSalt = ("0x" + "00".repeat(32)) as `0x${string}`;
    // Slippage scaled down from the simulated exact-out amounts, so a small adverse price move
    // between quote and execution doesn't revert, but a material shortfall does.
    const pctSlippage = Math.min(Math.max(Number(slippage) || 0.5, 0), 99);
    const minScale = (v: bigint) =>
      v > 0n ? (v * BigInt(Math.round((100 - pctSlippage) * 100))) / 10_000n : 0n;

    const key = position.key;
    const argsFor = (mins: readonly [bigint, bigint]) =>
      [
        key,
        {
          liquidity: amount,
          amount0Min: mins[0],
          amount1Min: mins[1],
          deadline,
          tickLower,
          tickUpper,
          userInputSalt,
        },
      ] as const;

    await run("Remove Liquidity", `${pct}% of your position`, async () => {
      // Simulate with zero mins to get the exact redeemable token0/token1, then set real
      // slippage-bounded mins on the live call.
      const sim = await publicClient.simulateContract({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "removeLiquidity",
        args: argsFor([0n, 0n]),
        account: address,
        gas: 2_000_000n,
      });
      const [out0, out1] = unpackBalanceDelta(sim.result as bigint);
      const gas = sim.request.gas ? (sim.request.gas * 12n) / 10n : 2_000_000n;
      return writeContractAsync({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "removeLiquidity",
        args: argsFor([minScale(out0), minScale(out1)]),
        gas,
      });
    });
  }

  const accentA = base.color ?? "#3ecf8e";
  const accentB = quote.color ?? "#6ea8ff";

  return (
    <div
      className="position-card"
      style={{ "--accent-a": accentA, "--accent-b": accentB } as CSSProperties}
    >
      <div className="position-card-glow" />

      <div className="position-card-head">
        <div className="position-pair">
          <span className="avatar-stack">
            <TokenAvatar color={accentA} symbol={base.symbol ?? "?"} />
            <TokenAvatar color={accentB} symbol={quote.symbol ?? "?"} />
          </span>
          <div className="position-pair-id">
            <strong>
              {base.symbol ?? "…"} / {quote.symbol ?? "…"}
            </strong>
            <span className="muted tiny">
              Bin size {position.binSize}
              {price !== null
                ? ` · 1 ${base.symbol ?? "tok0"} = ${formatPriceHuman(price)} ${quote.symbol ?? "tok1"}`
                : ""}
            </span>
          </div>
        </div>
        {hasFees && <span className="position-fees-dot" title="Fees available to claim" />}
      </div>

      <div className="position-metrics">
        <div className="meta-chip">
          <dt>Your shares</dt>
          <dd className="tabular" title={position.shares.toLocaleString()}>
            {formatBigIntCompact(position.shares)}
          </dd>
        </div>
        <div className="meta-chip">
          <dt>Pool share</dt>
          <dd className="tabular">{position.sharePct.toFixed(2)}%</dd>
        </div>
        <div className="meta-chip">
          <dt>Pending {base.symbol ?? "tok0"}</dt>
          <dd className="tabular up">{fmtAmount(position.fee0, base.decimals)}</dd>
        </div>
        <div className="meta-chip">
          <dt>Pending {quote.symbol ?? "tok1"}</dt>
          <dd className="tabular up">{fmtAmount(position.fee1, quote.decimals)}</dd>
        </div>
      </div>

      <div className="position-actions">
        <button type="button" className="cta secondary" onClick={claim} disabled={busy || !hasFees}>
          {busy && modalAction === "Claim Fees" ? "Confirm…" : "Claim fees"}
        </button>
        <button type="button" className="cta secondary" onClick={() => setExpanded((v) => !v)}>
          {expanded ? "Cancel" : "Remove liquidity"}
        </button>
      </div>

      {expanded && (
        <div className="withdraw-panel">
          <div className="withdraw-presets">
            {WITHDRAW_PRESETS.map((p) => (
              <button
                key={p}
                type="button"
                className={pct === p ? "shape-pill active" : "shape-pill"}
                onClick={() => setPct(p)}
              >
                {p}%
              </button>
            ))}
          </div>
          <input
            type="range"
            min={1}
            max={100}
            value={pct}
            onChange={(e) => setPct(Number(e.target.value))}
            className="withdraw-slider"
            aria-label="Percent to remove"
          />
          <div className="withdraw-slippage">
            <span>Max slippage</span>
            <span>
              <input
                value={slippage}
                onChange={(e) => setSlippage(e.target.value)}
                aria-label="Slippage percent"
              />
              %
            </span>
          </div>
          <button type="button" className="cta" onClick={remove} disabled={busy}>
            {busy && modalAction === "Remove Liquidity" ? "Confirm…" : `Remove ${pct}%`}
          </button>
        </div>
      )}

      <TxModal
        open={modalOpen}
        onClose={() => setModalOpen(false)}
        status={modalStatus}
        hash={txHash}
        chainId={deployment?.chainId}
        error={modalError}
        action={modalAction}
        summary={modalSummary}
      />
    </div>
  );
}

function PositionSkeleton() {
  return (
    <div className="position-card skeleton">
      <div className="position-card-head">
        <div className="position-pair">
          <span className="avatar-stack">
            <span className="token-avatar token-avatar-sm skeleton-block" />
            <span className="token-avatar token-avatar-sm skeleton-block" />
          </span>
          <div className="position-pair-id">
            <span className="skeleton-line" style={{ width: "6rem" }} />
            <span className="skeleton-line" style={{ width: "8rem" }} />
          </div>
        </div>
      </div>
      <div className="position-metrics">
        {[0, 1, 2, 3].map((i) => (
          <div className="meta-chip" key={i}>
            <span className="skeleton-line" style={{ width: "4rem" }} />
            <span className="skeleton-line" style={{ width: "3rem", marginTop: "0.4rem" }} />
          </div>
        ))}
      </div>
    </div>
  );
}

export function PortfolioPanel() {
  const { isConnected } = useAccount();
  const { deployment } = useDeployment();
  const deferPoolScan = useIdleReady(600);
  const { positions, isLoading, refetch } = usePositions(isConnected && deferPoolScan);

  // Pair picker — defaults to the deployment's configured pair, but any two tokens can be
  // targeted directly instead of waiting on the full-history pool scan to surface them.
  const [baseAddr, setBaseAddr] = useState<Address | undefined>(undefined);
  const [quoteAddr, setQuoteAddr] = useState<Address | undefined>(undefined);
  useEffect(() => {
    if (deployment && !baseAddr && !quoteAddr) {
      setBaseAddr(deployment.token0);
      setQuoteAddr(deployment.token1);
    }
  }, [deployment, baseAddr, quoteAddr]);

  const pair = baseAddr && quoteAddr ? { token0: baseAddr, token1: quoteAddr } : undefined;
  const pairInvalid =
    !!baseAddr && !!quoteAddr && baseAddr.toLowerCase() === quoteAddr.toLowerCase();

  function selectAt(slot: "base" | "quote", a: Address) {
    if (slot === "base") {
      if (quoteAddr && a.toLowerCase() === quoteAddr.toLowerCase()) setQuoteAddr(baseAddr);
      setBaseAddr(a);
    } else {
      if (baseAddr && a.toLowerCase() === baseAddr.toLowerCase()) setBaseAddr(quoteAddr);
      setQuoteAddr(a);
    }
  }

  const defBase = useTokenMeta(deployment?.token0);
  const defQuote = useTokenMeta(deployment?.token1);
  const extraTokens = useMemo((): FaucetToken[] => {
    const out: FaucetToken[] = [];
    if (deployment?.token0 && defBase.symbol) {
      out.push({
        symbol: defBase.symbol,
        name: defBase.symbol,
        decimals: defBase.decimals ?? 18,
        amountLabel: "",
        color: defBase.color ?? "#3ecf8e",
        category: "DeFi",
        address: deployment.token0,
      });
    }
    if (deployment?.token1 && defQuote.symbol) {
      out.push({
        symbol: defQuote.symbol,
        name: defQuote.symbol,
        decimals: defQuote.decimals ?? 18,
        amountLabel: "",
        color: defQuote.color ?? "#6ea8ff",
        category: "DeFi",
        address: deployment.token1,
      });
    }
    return out;
  }, [
    deployment?.token0,
    deployment?.token1,
    defBase.symbol,
    defBase.decimals,
    defBase.color,
    defQuote.symbol,
    defQuote.decimals,
    defQuote.color,
  ]);

  const { poolId: selectedPoolId } = usePool(pair);
  const {
    position: selected,
    isLoading: selectedLoading,
    refetch: refetchSelected,
  } = usePairPosition(pair);
  const others = positions.filter((p) => p.poolId !== selectedPoolId);

  function refetchAll() {
    refetch();
    refetchSelected();
  }

  return (
    <div className="page-wrap portfolio-wrap">
      <h1 className="page-title">Portfolio</h1>
      <p className="page-sub">
        Read straight from the chain — no backend, no indexer. Pick a pair to manage it directly, or
        claim fees and pull liquidity from any position below.
      </p>

      <div className="console-topbar">
        <TokenSelect
          value={baseAddr ?? deployment?.token0 ?? ZERO_ADDRESS}
          onSelect={(a) => selectAt("base", a)}
          extraTokens={extraTokens}
          align="left"
        />
        <span className="muted">/</span>
        <TokenSelect
          value={quoteAddr ?? deployment?.token1 ?? ZERO_ADDRESS}
          onSelect={(a) => selectAt("quote", a)}
          extraTokens={extraTokens}
        />
        <span className="console-topbar-spacer" />
        {isConnected && !pairInvalid && !selectedLoading && (
          <span className={selected ? "pool-status ok" : "pool-status warn"}>
            <span className="pool-status-dot" />
            {selected ? "Position open" : "No position"}
          </span>
        )}
      </div>

      {!isConnected ? (
        <div className="form-card portfolio-empty">
          <p className="muted">Connect a wallet to view your positions.</p>
        </div>
      ) : pairInvalid ? (
        <div className="form-card portfolio-empty">
          <p className="muted">Pick two different tokens to continue.</p>
        </div>
      ) : (
        <>
          {selectedLoading ? (
            <div className="positions-grid positions-grid-single">
              <PositionSkeleton />
            </div>
          ) : selected ? (
            <div className="positions-grid positions-grid-single">
              <PositionCard key={selected.poolId} position={selected} onChanged={refetchAll} />
            </div>
          ) : (
            <div className="form-card portfolio-empty">
              <p className="muted">No position in this pair yet.</p>
              <Link
                href="/liquidity"
                className="cta"
                style={{ display: "inline-block", width: "auto", padding: "0.75rem 1.5rem" }}
              >
                Add liquidity
              </Link>
            </div>
          )}

          {isLoading
            ? others.length === 0 && (
                <>
                  <h2 className="portfolio-subhead">Other positions</h2>
                  <div className="positions-grid">
                    <PositionSkeleton />
                  </div>
                </>
              )
            : others.length > 0 && (
                <>
                  <h2 className="portfolio-subhead">Other positions</h2>
                  <div className="positions-grid">
                    {others.map((p) => (
                      <PositionCard key={p.poolId} position={p} onChanged={refetchAll} />
                    ))}
                  </div>
                </>
              )}
        </>
      )}
    </div>
  );
}
