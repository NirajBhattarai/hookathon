"use client";

import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import {
  encodeAbiParameters,
  formatUnits,
  keccak256,
  maxUint256,
  parseUnits,
  type Address,
} from "viem";
import {
  useAccount,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import { useDeployment } from "@/hooks/useDeployment";
import { TokenSelect } from "@/components/TokenSelect";
import { formatPriceHuman } from "@/lib/priceMath";
import { findToken, tokenByAddress } from "@/lib/tokens";

/**
 * BinQuoter performs the real pool swap inside PoolManager.unlock() and reverts
 * with Quote(amount0, amount1). eth_call discards the state changes, so the
 * revert payload is the quote. Works without any token approvals.
 */
const binQuoterAbi = [
  {
    type: "error",
    name: "Quote",
    inputs: [
      { name: "amount0", type: "int128" },
      { name: "amount1", type: "int128" },
    ],
  },
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          {
            name: "key",
            type: "tuple",
            components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ],
          },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint256" },
          { name: "receiver", type: "address" },
        ],
      },
    ],
    outputs: [],
  },
] as const;

/** Decode Quote(int128,int128) out of a reverted eth_call. viem puts parsed args on a nested
 *  cause's `.data`; fall back to scanning raw revert hex anywhere on the error chain. */
function parseQuoteDelta(err: unknown): readonly [bigint, bigint] | null {
  let c: unknown = err;
  for (let depth = 0; c && depth < 8; depth++) {
    const e = c as {
      data?: unknown;
      message?: string;
      raw?: unknown;
      cause?: unknown;
    };
    const d = e.data;
    if (d) {
      const args = (d as { args?: readonly [bigint, bigint] }).args;
      if (args && args.length === 2) return [BigInt(args[0]), BigInt(args[1])];
      const hex =
        typeof d === "string"
          ? d
          : typeof (d as { data?: string }).data === "string"
            ? (d as { data: string }).data
            : "";
      const m = /0xd391f9d4([0-9a-fA-F]{128})/.exec(hex);
      if (m) return [BigInt(`0x${m[1].slice(0, 32)}`), BigInt(`0x${m[1].slice(32)}`)];
    }
    const m = /0xd391f9d4([0-9a-fA-F]{128})/.exec(`${e.raw ?? ""} ${e.message ?? ""}`);
    if (m) return [BigInt(`0x${m[1].slice(0, 32)}`), BigInt(`0x${m[1].slice(32)}`)];
    c = e.cause;
  }
  return null;
}

const I128_MAX = (1n << 127n) - 1n;
/** Interpret an ABI-encoded int128 as a signed bigint. */
function asInt(v: bigint): bigint {
  return v > I128_MAX ? v - (1n << 256n) : v;
}

const swapRouterAbi = [
  {
    type: "function",
    name: "swapExactTokensForTokens",
    stateMutability: "payable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "zeroForOne", type: "bool" },
      {
        name: "poolKey",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      { name: "hookData", type: "bytes" },
      { name: "receiver", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [
      {
        name: "delta",
        type: "tuple",
        components: [
          { name: "amount0", type: "int128" },
          { name: "amount1", type: "int128" },
        ],
      },
    ],
  },
] as const;

const erc20MetaAbi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "", type: "address" },
      { name: "", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

export function SwapForm() {
  const { address, isConnected } = useAccount();
  const { deployment } = useDeployment();

  // default: stablecoin in, WETH out (changeable via selectors)
  const [inAddr, setInAddr] = useState<Address>(() => findToken("USDC").address);
  const [outAddr, setOutAddr] = useState<Address>(() => findToken("WETH").address);
  const [amountIn, setAmountIn] = useState("1");
  const [slippage, setSlippage] = useState("0.50");
  const [status, setStatus] = useState<string | null>(null);
  const [swapError, setSwapError] = useState<string | null>(null);

  // sorted pair + candidate keys over common tickSpacings (discovered on-chain, not env-guessed)
  const [c0, c1] = useMemo((): readonly [Address?, Address?] => {
    if (!deployment || inAddr === outAddr) return [undefined, undefined];
    return inAddr.toLowerCase() < outAddr.toLowerCase() ? [inAddr, outAddr] : [outAddr, inAddr];
  }, [deployment, inAddr, outAddr]);

  const tickCandidates = useMemo(() => {
    const set = new Set<number>([deployment?.tickSpacing ?? 10, 10, 60, 1]);
    return [...set];
  }, [deployment]);

  // poolId = keccak256(abi.encode(PoolKey))
  const poolIdOf = useCallback(
    (tickSpacing: number): Address | undefined =>
      deployment && c0 && c1
        ? keccak256(
            encodeAbiParameters(
              [
                { type: "address" },
                { type: "address" },
                { type: "uint24" },
                { type: "int24" },
                { type: "address" },
              ],
              [c0, c1, deployment.poolFee, tickSpacing, deployment.binBook]
            )
          )
        : undefined,
    [deployment, c0, c1]
  );

  // probe BinBook.isConfigured(poolId) for every candidate
  const discoverQ = useReadContracts({
    query: { enabled: !!deployment && !!c0 && !!c1 },
    contracts: tickCandidates.map((ts) => ({
      address: deployment!.binBook,
      abi: [
        {
          type: "function",
          name: "isConfigured",
          stateMutability: "view",
          inputs: [{ name: "", type: "bytes32" }],
          outputs: [{ name: "", type: "bool" }],
        },
      ] as const,
      functionName: "isConfigured",
      args: [poolIdOf(ts)!],
    })),
  });

  const discoveredTickSpacing = useMemo(
    () =>
      tickCandidates[
        discoverQ.data?.findIndex((r) => r.status === "success" && r.result === true) ?? -1
      ],
    [discoverQ.data, tickCandidates]
  );

  // v4 pool key from the selected pair using the DISCOVERED tickSpacing
  const key = useMemo(() => {
    if (!discoveredTickSpacing || !c0 || !c1 || !deployment) return null;
    return {
      currency0: c0,
      currency1: c1,
      fee: deployment.poolFee,
      tickSpacing: discoveredTickSpacing,
      hooks: deployment.binBook,
    };
  }, [deployment, c0, c1, discoveredTickSpacing]);
  const zeroForOne = !!key && inAddr === key.currency0;

  const payToken = inAddr;
  const recvToken = outAddr;

  // metadata + balances for both selected tokens (ordered by sorted c0/c1)
  const metaQ = useReadContracts({
    query: { enabled: !!c0 && !!c1 },
    contracts:
      c0 && c1
        ? [
            { address: c0, abi: erc20MetaAbi, functionName: "symbol" },
            { address: c0, abi: erc20MetaAbi, functionName: "decimals" },
            { address: c0, abi: erc20MetaAbi, functionName: "balanceOf", args: [address!] },
            { address: c1, abi: erc20MetaAbi, functionName: "symbol" },
            { address: c1, abi: erc20MetaAbi, functionName: "decimals" },
            { address: c1, abi: erc20MetaAbi, functionName: "balanceOf", args: [address!] },
          ]
        : [],
  });
  // metaQ slots are ordered by SORTED currency0/currency1 — index directly, no direction swap
  const slotOf = (a: Address) => (a === c0 ? 0 : 3);
  const symOf = (a: Address) => metaQ.data?.[slotOf(a)]?.result as string | undefined;
  const decOf = (a: Address) => metaQ.data?.[slotOf(a) + 1]?.result as number | undefined;
  const balOf = (a: Address) => metaQ.data?.[slotOf(a) + 2]?.result as bigint | undefined;

  const paySymbol = symOf(payToken) ?? tokenByAddress(payToken)?.symbol;
  const recvSymbol = symOf(recvToken) ?? tokenByAddress(recvToken)?.symbol;
  const payDecimals = decOf(payToken) ?? tokenByAddress(payToken)?.decimals;
  const recvDecimals = decOf(recvToken) ?? tokenByAddress(recvToken)?.decimals;
  const payBalance = balOf(payToken);

  const amountInRaw = useMemo(() => {
    try {
      if (!Number.isFinite(Number(amountIn)) || Number(amountIn) <= 0 || payDecimals === undefined)
        return 0n;
      return parseUnits(amountIn, payDecimals);
    } catch {
      return 0n;
    }
  }, [amountIn, payDecimals]);

  // real quote: run the swap through BinQuoter inside eth_call (no approvals needed).
  // The quoter always reverts with Quote(amount0, amount1) — that payload IS the quote.
  const quoteArgs = useMemo(
    () =>
      key && address
        ? ([{ key, zeroForOne, amountIn: amountInRaw, receiver: address }] as const)
        : undefined,
    [key, address, zeroForOne, amountInRaw]
  );
  const quoteQ = useReadContract({
    address: deployment?.quoter,
    abi: binQuoterAbi,
    functionName: "quoteExactInput",
    args: quoteArgs,
    query: {
      enabled: !!deployment?.quoter && !!key && !!address && amountInRaw > 0n,
      refetchInterval: 15_000,
      retry: false,
    },
  });

  const quoteErrorText = useMemo(() => {
    const e = quoteQ.error;
    if (!e) return null;
    const s = `${(e as { name?: string }).name ?? ""} ${e.message}`;
    if (/InsufficientLiquidity|PoolNotConfigured|PoolNotInitialized|CurrencyNotSettled/i.test(s))
      return "NO_LIQUIDITY";
    // WrappedError(address,bytes4,bytes,bytes) 0x90bfb865: hook engine ran out of bins
    if (/0x90bfb865|WrappedError/i.test(s) || !parseQuoteDelta(e)) return "TOO_LARGE";
    return null;
  }, [quoteQ.error]);

  const estimatedOutRaw = useMemo(() => {
    const deltas = parseQuoteDelta(quoteQ.error);
    if (!deltas) return 0n;
    const out = asInt(zeroForOne ? deltas[1] : deltas[0]);
    return out > 0n ? out : 0n;
  }, [quoteQ.error, zeroForOne]);

  const minOutRaw = useMemo(() => {
    if (estimatedOutRaw === 0n) return 0n;
    const pct = Math.min(Math.max(Number(slippage) || 0.5, 0), 99);
    return (estimatedOutRaw * BigInt(Math.round((100 - pct) * 100))) / 10_000n;
  }, [estimatedOutRaw, slippage]);

  // ERC20 allowance of the swap router for tokenIn
  // (router04 poolKey-mode pulls input via plain transferFrom, NOT Permit2)
  const allowQ = useReadContracts({
    query: { enabled: !!payToken && !!deployment },
    contracts: [
      {
        address: payToken!,
        abi: erc20MetaAbi,
        functionName: "allowance",
        args: [address!, deployment!.swapRouter],
      },
    ],
  });
  const erc20ToRouter = (allowQ.data?.[0]?.result as bigint | undefined) ?? 0n;

  const { writeContractAsync, isPending } = useWriteContract();
  const { data: hash, isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({});

  useEffect(() => {
    if (!isSuccess) return;
    setStatus("Swap complete");
    setSwapError(null);
    metaQ.refetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess]);

  async function ensureApproval(): Promise<void> {
    if (!deployment || !payToken) return;
    // router04 pulls input tokens via ERC20 transferFrom: approve router directly
    if (erc20ToRouter < amountInRaw) {
      await writeContractAsync({
        address: payToken,
        abi: erc20MetaAbi,
        functionName: "approve",
        args: [deployment.swapRouter, maxUint256],
      });
      await allowQ.refetch();
    }
  }

  function flip() {
    setInAddr(outAddr);
    setOutAddr(inAddr);
    setAmountIn("");
  }

  function selectIn(a: Address) {
    if (a === outAddr) setOutAddr(inAddr);
    setInAddr(a);
    setAmountIn("");
  }
  function selectOut(a: Address) {
    if (a === inAddr) setInAddr(outAddr);
    setOutAddr(a);
  }

  // pair picked but no on-chain pool found at any candidate tickSpacing
  const noPool = !!c0 && !!c1 && !!deployment && discoverQ.isSuccess && !discoveredTickSpacing;

  const ctaLabel = useMemo(() => {
    if (!isConnected) return "Connect wallet";
    if (isPending || confirming) return "Confirm in wallet…";
    if (inAddr === outAddr) return "Pick two different tokens";
    if (!amountIn || Number(amountIn) <= 0) return "Enter an amount";
    if (noPool) return "No pool for this pair";
    if (quoteErrorText === "NO_LIQUIDITY") return "No liquidity";
    if (quoteErrorText === "TOO_LARGE") return "Amount too large for pool";
    return "Swap";
  }, [isConnected, isPending, confirming, amountIn, inAddr, outAddr, quoteErrorText, noPool]);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (!deployment || !key || !address || amountInRaw === 0n || inAddr === outAddr) return;
    setStatus(null);
    setSwapError(null);
    try {
      await ensureApproval();
      await writeContractAsync({
        address: deployment.swapRouter,
        abi: swapRouterAbi,
        functionName: "swapExactTokensForTokens",
        gas: 1_500_000n, // keep under RPC gas caps; router+hook swaps use ~250-450k
        args: [
          amountInRaw,
          minOutRaw,
          zeroForOne,
          key,
          "0x",
          address,
          BigInt(Math.floor(Date.now() / 1000) + 600),
        ],
      });
    } catch (err) {
      const msg =
        err instanceof Error ? `${err.message} ${(err as { data?: unknown }).data ?? ""}` : "";
      if (/InsufficientLiquidity|PoolNotConfigured|PoolNotInitialized/i.test(msg)) {
        setSwapError(
          `No ${paySymbol}/${recvSymbol} pool with liquidity yet — add liquidity first.`
        );
      } else {
        setSwapError(err instanceof Error ? err.message.slice(0, 160) : "Swap failed");
      }
    }
  }

  const fmtOut = useMemo(() => {
    if (!estimatedOutRaw || recvDecimals === undefined) return "—";
    const v = Number(formatUnits(estimatedOutRaw, recvDecimals));
    if (v === 0) return "0";
    // adaptive precision so dust-scale outputs (parity-priced pools) stay visible
    const dp = v >= 1 ? 4 : v >= 0.0001 ? 8 : 12;
    return v.toFixed(dp).replace(/\.?0+$/, "");
  }, [estimatedOutRaw, recvDecimals]);

  return (
    <form className="swap-card" onSubmit={onSubmit}>
      <div className="swap-card-top">
        <h1>Swap</h1>
      </div>

      <div className="token-field">
        <div className="token-field-top">
          <span>You pay</span>
          <div className="balance-row">
            <span>
              Balance{" "}
              {payBalance !== undefined && payDecimals !== undefined
                ? Number(formatUnits(payBalance, payDecimals)).toLocaleString(undefined, {
                    maximumFractionDigits: 4,
                  })
                : "—"}
            </span>
            <button
              type="button"
              className="chip"
              onClick={() =>
                payBalance !== undefined &&
                payDecimals !== undefined &&
                setAmountIn(formatUnits(payBalance, payDecimals))
              }
            >
              Max
            </button>
          </div>
        </div>
        <div className="token-field-row">
          <input
            value={amountIn}
            onChange={(e) => setAmountIn(e.target.value)}
            inputMode="decimal"
            placeholder="0"
            aria-label="Amount in"
          />
          <TokenSelect value={inAddr} onSelect={selectIn} />
        </div>
        <div className="fiat-hint">≈ $—</div>
      </div>

      <div className="swap-flip-wrap">
        <button type="button" className="flip-btn" onClick={flip} aria-label="Flip tokens">
          ↓
        </button>
      </div>

      <div className="token-field">
        <div className="token-field-top">
          <span>You receive</span>
          <span>Balance —</span>
        </div>
        <div className="token-field-row">
          <input value={fmtOut} readOnly tabIndex={-1} aria-label="Amount out estimate" />
          <TokenSelect value={outAddr} onSelect={selectOut} />
        </div>
        <div className="fiat-hint">live quote · est. after fee</div>
      </div>

      <details className="details" open>
        <summary>
          <span>
            1 {paySymbol ?? "?"} ≈{" "}
            {fmtOut === "—" ? "—" : formatPriceHuman(Number(fmtOut) / (Number(amountIn) || 1))}{" "}
            {recvSymbol ?? "?"}
          </span>
          <span>Details</span>
        </summary>
        <div className="details-body">
          {amountInRaw > 0n && fmtOut === "—" && (
            <div className="detail-row" style={{ color: "#f66", wordBreak: "break-all" }}>
              <span>quote debug</span>
              <span style={{ textAlign: "right" }}>
                {String(
                  quoteErrorText ??
                    quoteQ.error?.message?.slice(0, 220) ??
                    "no error object — quote pending"
                )}
              </span>
            </div>
          )}
          <div className="detail-row">
            <span>Fee tier</span>
            <span>{((deployment?.poolFee ?? 3000) / 10000).toFixed(2)}%</span>
          </div>
          <div className="detail-row">
            <span>Max slippage</span>
            <span>
              <input
                value={slippage}
                onChange={(e) => setSlippage(e.target.value)}
                style={{
                  width: "3.5rem",
                  background: "transparent",
                  border: "0",
                  color: "inherit",
                  textAlign: "right",
                }}
                aria-label="Slippage percent"
              />
              %
            </span>
          </div>
          <div className="detail-row">
            <span>Minimum received</span>
            <span>
              {minOutRaw && recvDecimals !== undefined
                ? Number(formatUnits(minOutRaw, recvDecimals)).toFixed(6)
                : "—"}{" "}
              {recvSymbol ?? ""}
            </span>
          </div>
          <div className="detail-row">
            <span>Route</span>
            <span>BinBook hook</span>
          </div>
        </div>
      </details>

      <button
        type="submit"
        className="cta"
        disabled={
          isPending ||
          confirming ||
          !amountIn ||
          Number(amountIn) <= 0 ||
          inAddr === outAddr ||
          quoteErrorText === "NO_LIQUIDITY" ||
          quoteErrorText === "TOO_LARGE" ||
          noPool
        }
      >
        {ctaLabel}
      </button>

      {noPool && (
        <p className="status warn">
          No {paySymbol}/{recvSymbol} pool exists on-chain yet — create one first.
        </p>
      )}

      {quoteErrorText === "NO_LIQUIDITY" && (
        <p className="status warn">
          No liquidity for {paySymbol}/{recvSymbol} yet — create a pool or add liquidity first.
        </p>
      )}

      {quoteErrorText === "TOO_LARGE" && (
        <p className="status warn">
          Quote failed — amount exceeds available pool liquidity. Try a smaller amount.
        </p>
      )}

      {swapError && <p className="status warn">{swapError}</p>}
      {status && <p className="status ok">{status}</p>}
    </form>
  );
}
