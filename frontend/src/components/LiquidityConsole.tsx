"use client";

import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import { formatUnits, maxUint256, parseUnits, type Address } from "viem";
import { useAccount, useReadContracts, useWriteContract } from "wagmi";
import { binBookAbi } from "@/lib/abi/binBook";
import { StatsBar } from "@/components/StatsBar";
import { TokenSelect } from "@/components/TokenSelect";
import { TxModal, type TxStatus, type TxStep } from "@/components/TxModal";
import { useAppPublicClient } from "@/hooks/useAppPublicClient";
import { useBinLiquidity } from "@/hooks/useBinLiquidity";
import { useBook } from "@/hooks/useBook";
import { useDeployment } from "@/hooks/useDeployment";
import { usePool } from "@/hooks/usePool";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import {
  binAtTick,
  binPriceInfo,
  buildRampPreview,
  composeRangeAmounts,
  DEFAULT_BINS_PER_SIDE,
  DEFAULT_RAMP,
  tickAtBin,
} from "@/lib/bins";
import { formatPriceHuman, priceToSqrtPriceX96, sqrtPriceX96ToPrice } from "@/lib/priceMath";
import type { FaucetToken } from "@/lib/tokens";

const erc20Abi = [
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
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
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
] as const;

type Shape = "auto" | "tight" | "wide" | "full" | "custom";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;

/** Formats a linked-input amount, trimming float noise without forcing trailing zeros. */
function trimDecimal(n: number): string {
  if (!Number.isFinite(n) || n < 0) return "0";
  return n.toFixed(8).replace(/\.?0+$/, "");
}

function TokenAmountField({
  tokenAddress,
  onSelectToken,
  extraTokens,
  amount,
  onAmount,
  balance,
  decimals,
  disabled,
}: {
  tokenAddress: Address;
  onSelectToken: (a: Address) => void;
  extraTokens?: FaucetToken[];
  amount: string;
  onAmount: (v: string) => void;
  balance?: bigint;
  decimals?: number;
  disabled?: boolean;
}) {
  return (
    <div className={disabled ? "token-field disabled" : "token-field"}>
      <div className="token-field-top">
        <TokenSelect value={tokenAddress} onSelect={onSelectToken} extraTokens={extraTokens} />
        <div className="balance-row">
          <span>
            Balance{" "}
            {balance !== undefined && decimals !== undefined
              ? Number(formatUnits(balance, decimals)).toLocaleString(undefined, {
                  maximumFractionDigits: 4,
                })
              : "—"}
          </span>
          <button
            type="button"
            className="chip"
            disabled={disabled}
            onClick={() =>
              balance !== undefined &&
              decimals !== undefined &&
              onAmount(formatUnits(balance, decimals))
            }
          >
            Max
          </button>
        </div>
      </div>
      <div className="token-field-row">
        <input
          value={amount}
          onChange={(e) => onAmount(e.target.value)}
          disabled={disabled}
          inputMode="decimal"
          placeholder="0"
        />
      </div>
    </div>
  );
}

export function LiquidityConsole() {
  const { address, isConnected } = useAccount();
  const { deployment, ready, needsNetworkSwitch } = useDeployment();

  // Pair picker — defaults to the deployment's configured pair (BINU/WETH), but any two tokens
  // can be picked: existing pools get an "Add liquidity" flow, new ones a "Create pool" one.
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

  // Picking a token already on the other side swaps instead of duplicating it.
  function selectAt(slot: "base" | "quote", a: Address) {
    if (slot === "base") {
      if (quoteAddr && a.toLowerCase() === quoteAddr.toLowerCase()) setQuoteAddr(baseAddr);
      setBaseAddr(a);
    } else {
      if (baseAddr && a.toLowerCase() === baseAddr.toLowerCase()) setBaseAddr(quoteAddr);
      setQuoteAddr(a);
    }
    resetRange();
  }

  // Inject the deployment's default pair as pickable rows — they're the actual pool tokens but
  // aren't necessarily in the faucet's generic token list.
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

  const { key } = usePool(pair);
  const { book, preview } = useBook(pair);
  const { series: liveSeries, maxL: liveMaxL } = useBinLiquidity(pair);

  const base = useTokenMeta(key?.currency0);
  const quote = useTokenMeta(key?.currency1);
  const pickBase = useTokenMeta(baseAddr ?? key?.currency0);
  const pickQuote = useTokenMeta(quoteAddr ?? key?.currency1);

  const baseIsCurrency0 = useMemo(() => {
    if (!key || !baseAddr) return true;
    return baseAddr.toLowerCase() === key.currency0.toLowerCase();
  }, [key, baseAddr]);

  const [baseAmount, setBaseAmount] = useState("1");
  const [quoteAmount, setQuoteAmount] = useState("1");
  const depositLeaderRef = useRef<"base" | "quote">("base");

  const amount0 = baseIsCurrency0 ? baseAmount : quoteAmount;
  const amount1 = baseIsCurrency0 ? quoteAmount : baseAmount;
  const [shape, setShape] = useState<Shape>("auto");
  const [lowerBin, setLowerBin] = useState<number | null>(null);
  const [upperBin, setUpperBin] = useState<number | null>(null);
  const [hoveredBin, setHoveredBin] = useState<number | null>(null);
  const [rangeStart, setRangeStart] = useState<number | null>(null);
  const [startingPrice, setStartingPrice] = useState("1");
  const [binSize, setBinSize] = useState("60");
  const [slippage, setSlippage] = useState("0.50");
  const [status, setStatus] = useState<string | null>(null);

  function resetDepositAmounts() {
    setBaseAmount("1");
    setQuoteAmount("1");
    depositLeaderRef.current = "base";
  }

  function resetRange() {
    setShape("auto");
    setLowerBin(null);
    setUpperBin(null);
    setRangeStart(null);
    resetDepositAmounts();
  }

  const needsCreate = !!book && !preview && !book.configured;
  const showDemo = preview || needsCreate;

  const previewBinSize = Number(binSize) || 60;
  const rampPreview = useMemo(() => buildRampPreview(previewBinSize), [previewBinSize]);
  const rampPreviewMaxL = useMemo(
    () => rampPreview.reduce((m, b) => (b.liquidity > m ? b.liquidity : m), 0n),
    [rampPreview]
  );
  const previewPrice = Number(startingPrice) > 0 ? Number(startingPrice) : 1;
  const previewAxisBook = useMemo(
    () => ({
      binSize: previewBinSize,
      currentBin: 0,
      minBin: -DEFAULT_BINS_PER_SIDE,
      maxBin: DEFAULT_BINS_PER_SIDE - 1,
      sqrtPriceX96: priceToSqrtPriceX96(previewPrice),
      configured: false,
    }),
    [previewBinSize, previewPrice]
  );

  const series = showDemo ? rampPreview : liveSeries;
  const maxL = showDemo ? rampPreviewMaxL : liveMaxL;
  const axisBook = showDemo ? previewAxisBook : book;

  const bookPrice = book && book.sqrtPriceX96 > 0n ? sqrtPriceX96ToPrice(book.sqrtPriceX96) : null;

  // Range composition (which side(s) of the deposit this range actually needs) — mirrors the
  // contract's per-bin token0/token1 split so typing one amount can correctly derive the other,
  // and so a range entirely above/below spot locks out the token it doesn't need.
  const baseRamp = showDemo ? DEFAULT_RAMP : (book?.ramp ?? DEFAULT_RAMP);
  const numBinsPerSide = showDemo
    ? DEFAULT_BINS_PER_SIDE
    : (book?.numBinsPerSide ?? DEFAULT_BINS_PER_SIDE);
  // The demo ramp's own axisBook always centers on bin 0 (a fixed, price-independent visual), but
  // the actual deposit composition must be centered on whichever bin the entered starting price
  // falls into — otherwise a price far from 1 makes the checked range miss the real price entirely,
  // and every bin looks single-sided (composeRangeAmounts sees `sqrtCur` outside every bin it's
  // given), locking one of the two deposit fields even though the pool would genuinely take both.
  const previewCurBin = useMemo(
    () => binAtTick(Math.round(Math.log(previewPrice) / Math.log(1.0001)), previewBinSize),
    [previewPrice, previewBinSize]
  );
  const curBin = needsCreate ? previewCurBin : (axisBook?.currentBin ?? 0);
  const effLower = lowerBin ?? curBin - numBinsPerSide;
  const effUpper = upperBin ?? curBin + numBinsPerSide - 1;
  const effBinSize = axisBook?.binSize ?? previewBinSize;
  const compositionPrice = showDemo ? previewPrice : (bookPrice ?? 1);

  const composition = useMemo(
    () => composeRangeAmounts(effLower, effUpper, curBin, effBinSize, baseRamp, compositionPrice),
    [effLower, effUpper, curBin, effBinSize, baseRamp, compositionPrice]
  );

  const depositRatioQuotePerBase = useMemo(() => {
    if (composition.mode !== "straddle" || composition.need0 <= 0) return null;
    const baseNeed = baseIsCurrency0 ? composition.need0 : composition.need1;
    const quoteNeed = baseIsCurrency0 ? composition.need1 : composition.need0;
    if (baseNeed <= 0) return null;
    return quoteNeed / baseNeed;
  }, [composition, baseIsCurrency0]);

  function linkDepositFromLeader(
    leader: "base" | "quote",
    leaderValue: string,
    ratio: number | null
  ) {
    if (composition.mode === "above") {
      if (baseIsCurrency0) {
        setQuoteAmount("0");
        if (leader === "base") setBaseAmount(leaderValue);
      } else {
        setBaseAmount("0");
        if (leader === "quote") setQuoteAmount(leaderValue);
      }
      return;
    }
    if (composition.mode === "below") {
      if (baseIsCurrency0) {
        setBaseAmount("0");
        if (leader === "quote") setQuoteAmount(leaderValue);
      } else {
        setQuoteAmount("0");
        if (leader === "base") setBaseAmount(leaderValue);
      }
      return;
    }
    if (composition.mode !== "straddle" || ratio == null || ratio <= 0) return;
    const n = Number(leaderValue);
    if (!Number.isFinite(n) || n < 0) return;
    if (leader === "base") {
      setBaseAmount(leaderValue);
      setQuoteAmount(trimDecimal(n * ratio));
    } else {
      setQuoteAmount(leaderValue);
      setBaseAmount(trimDecimal(n / ratio));
    }
  }

  function handleBaseAmountChange(v: string) {
    depositLeaderRef.current = "base";
    linkDepositFromLeader("base", v, depositRatioQuotePerBase);
  }

  function handleQuoteAmountChange(v: string) {
    depositLeaderRef.current = "quote";
    linkDepositFromLeader("quote", v, depositRatioQuotePerBase);
  }

  const needsOnlyToken0 = composition.mode === "above";
  const needsOnlyToken1 = composition.mode === "below";
  const disableBase =
    (needsOnlyToken0 && !baseIsCurrency0) || (needsOnlyToken1 && baseIsCurrency0);
  const disableQuote =
    (needsOnlyToken0 && baseIsCurrency0) || (needsOnlyToken1 && !baseIsCurrency0);

  // Re-link the follower whenever price, range, or side-mode changes — respect last-edited field.
  useEffect(() => {
    if (composition.mode === "above") {
      depositLeaderRef.current = baseIsCurrency0 ? "base" : "quote";
    } else if (composition.mode === "below") {
      depositLeaderRef.current = baseIsCurrency0 ? "quote" : "base";
    }
    const leader = depositLeaderRef.current;
    const leaderVal = leader === "base" ? baseAmount : quoteAmount;
    linkDepositFromLeader(leader, leaderVal, depositRatioQuotePerBase);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- follower only; leader value read at change time
  }, [composition.mode, depositRatioQuotePerBase, lowerBin, upperBin, shape, compositionPrice, baseIsCurrency0]);

  const balQ = useReadContracts({
    query: { enabled: !!key && !!address },
    contracts:
      key && address
        ? [
            { address: key.currency0, abi: erc20Abi, functionName: "balanceOf", args: [address] },
            { address: key.currency1, abi: erc20Abi, functionName: "balanceOf", args: [address] },
          ]
        : [],
  });
  const bal0 = balQ.data?.[0]?.result as bigint | undefined;
  const bal1 = balQ.data?.[1]?.result as bigint | undefined;

  const allowQ = useReadContracts({
    query: { enabled: !!key && !!address && !!deployment },
    contracts:
      key && address && deployment
        ? [
            {
              address: key.currency0,
              abi: erc20Abi,
              functionName: "allowance",
              args: [address, deployment.binBook],
            },
            {
              address: key.currency1,
              abi: erc20Abi,
              functionName: "allowance",
              args: [address, deployment.binBook],
            },
          ]
        : [],
  });
  const allowance0 = (allowQ.data?.[0]?.result as bigint | undefined) ?? 0n;
  const allowance1 = (allowQ.data?.[1]?.result as bigint | undefined) ?? 0n;

  function applyShape(next: Shape) {
    setShape(next);
    setRangeStart(null);
    if (!book) return;
    if (next === "auto") {
      setLowerBin(null);
      setUpperBin(null);
    } else if (next === "full") {
      setLowerBin(book.minBin);
      setUpperBin(book.maxBin);
    } else if (next === "tight" || next === "wide") {
      const half = next === "tight" ? 5 : 20;
      setLowerBin(Math.max(book.minBin, book.currentBin - half));
      setUpperBin(Math.min(book.maxBin, book.currentBin + half));
    }
  }

  function handleSelectBin(bin: number) {
    setShape("custom");
    if (rangeStart === null) {
      setRangeStart(bin);
      setLowerBin(bin);
      setUpperBin(bin);
    } else {
      setLowerBin(Math.min(rangeStart, bin));
      setUpperBin(Math.max(rangeStart, bin));
      setRangeStart(null);
    }
  }

  const { writeContractAsync } = useWriteContract();
  const publicClient = useAppPublicClient(deployment);
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);

  const [txModalOpen, setTxModalOpen] = useState(false);
  const [txModalStatus, setTxModalStatus] = useState<TxStatus>("pending");
  const [txError, setTxError] = useState<string | null>(null);
  const [txSteps, setTxSteps] = useState<TxStep[]>([]);
  // Locks the whole multi-step flow (create pool → approvals → add liquidity) from the moment the
  // first transaction is sent until the last one is confirmed — `isPending`/`confirming` alone
  // briefly go false between steps (once one tx is sent but before the next is requested), which
  // would let a second click race a new submission in on top of one still in flight.
  const [isSubmitting, setIsSubmitting] = useState(false);

  const balBase = baseIsCurrency0 ? bal0 : bal1;
  const balQuote = baseIsCurrency0 ? bal1 : bal0;
  const decBase = baseIsCurrency0 ? base.decimals : quote.decimals;
  const decQuote = baseIsCurrency0 ? quote.decimals : base.decimals;

  const txSummary =
    (baseAmount !== "0" || quoteAmount !== "0") && pickBase.symbol && pickQuote.symbol
      ? `${baseAmount !== "0" ? `${baseAmount} ${pickBase.symbol}` : ""}${baseAmount !== "0" && quoteAmount !== "0" ? " + " : ""}${quoteAmount !== "0" ? `${quoteAmount} ${pickQuote.symbol}` : ""}`
      : undefined;

  const dec0 = base.decimals;
  const dec1 = quote.decimals;

  const binsCovered = lowerBin !== null && upperBin !== null ? upperBin - lowerBin + 1 : null;

  const binPriceLabel = (info: ReturnType<typeof binPriceInfo>) =>
    `1 ${base.symbol ?? "token0"} = ${formatPriceHuman(info.arithmeticMean)} ${quote.symbol ?? "token1"}`;

  const hoveredBinPrice = useMemo(() => {
    if (hoveredBin === null) return null;
    return binPriceInfo(hoveredBin, effBinSize);
  }, [hoveredBin, effBinSize]);

  const selectedRangePrice = useMemo(() => {
    if (lowerBin === null || upperBin === null) return null;
    const lo = binPriceInfo(lowerBin, effBinSize);
    const hi = binPriceInfo(upperBin, effBinSize);
    return {
      priceMin: lo.priceLower,
      priceMax: hi.priceUpper,
      meanLower: lo.arithmeticMean,
      meanUpper: hi.arithmeticMean,
    };
  }, [lowerBin, upperBin, effBinSize]);

  const defaultRangePrice = useMemo(() => {
    const lo = binPriceInfo(effLower, effBinSize);
    const hi = binPriceInfo(effUpper, effBinSize);
    return { priceMin: lo.priceLower, priceMax: hi.priceUpper };
  }, [effLower, effUpper, effBinSize]);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (isSubmitting) return;
    if (
      !deployment ||
      !address ||
      !key ||
      dec0 === undefined ||
      dec1 === undefined ||
      !publicClient
    )
      return;
    setIsSubmitting(true);
    setStatus(null);
    setTxError(null);
    setTxModalOpen(true);
    setTxModalStatus("pending");
    setTxHash(null);

    const a0 = parseUnits(amount0 || "0", dec0);
    const a1 = parseUnits(amount1 || "0", dec1);
    const needsApproval0 = a0 > 0n && allowance0 < a0;
    const needsApproval1 = a1 > 0n && allowance1 < a1;

    const allSteps: TxStep[] = [];
    if (needsCreate) {
      allSteps.push({ label: "Create pool", done: false });
    }
    if (needsApproval0) allSteps.push({ label: `Approve ${base.symbol}`, done: false });
    if (needsApproval1) allSteps.push({ label: `Approve ${quote.symbol}`, done: false });
    allSteps.push({ label: "Add liquidity", done: false });
    setTxSteps(allSteps);

    let stepIdx = 0;
    const markDone = () => {
      setTxSteps((prev) => prev.map((s, i) => (i === stepIdx ? { ...s, done: true } : s)));
      stepIdx++;
    };

    // Waits for each step to actually land on-chain before moving to the next — addLiquidity
    // depends on createPool having landed, and its transferFrom depends on the approvals having
    // landed, so firing steps back-to-back the moment each is merely *sent* (not yet mined) risks
    // the next step reverting against stale pre-tx state.
    const sendAndConfirm = async (params: Parameters<typeof writeContractAsync>[0]) => {
      // Dry-runs the call against current chain state first — surfaces the real revert reason
      // immediately, before the wallet even opens or any gas is spent, instead of only finding
      // out after paying for a failed transaction. It also returns an accurate gas estimate,
      // replacing the hardcoded caps so wide books don't run out of gas.
      const sim = await publicClient.simulateContract({ ...params, account: address } as Parameters<
        typeof publicClient.simulateContract
      >[0]);
      const estimatedGas = sim.request.gas;
      const gas = estimatedGas ? (estimatedGas * 12n) / 10n : params.gas;
      const hash = await writeContractAsync(gas ? { ...params, gas } : params);
      setTxHash(hash);
      // A bounded timeout so a flaky/rate-limited RPC surfaces as an error instead of spinning
      // forever — the transaction itself may still be fine on-chain even if this call times out.
      await publicClient.waitForTransactionReceipt({ hash, timeout: 120_000 });
      markDone();
    };

    try {
      if (needsCreate) {
        const price = Number(startingPrice);
        if (!Number.isFinite(price) || price <= 0) {
          setTxModalStatus("error");
          setTxError("Enter a valid starting price");
          setStatus("Enter a valid starting price");
          return;
        }
        const bs = Number(binSize);
        if (!Number.isFinite(bs) || bs <= 0) {
          setTxModalStatus("error");
          setTxError("Enter a valid bin size");
          setStatus("Enter a valid bin size");
          return;
        }
        await sendAndConfirm({
          address: deployment.binBook,
          abi: binBookAbi,
          functionName: "createPool",
          args: [key, priceToSqrtPriceX96(price), bs],
          gas: 500_000n,
        });
      }

      if (needsApproval0) {
        await sendAndConfirm({
          address: key.currency0,
          abi: erc20Abi,
          functionName: "approve",
          args: [deployment.binBook, maxUint256],
          gas: 100_000n,
        });
      }
      if (needsApproval1) {
        await sendAndConfirm({
          address: key.currency1,
          abi: erc20Abi,
          functionName: "approve",
          args: [deployment.binBook, maxUint256],
          gas: 100_000n,
        });
      }

      // effLower/effUpper already fall back to the default ramp window (curBin ± numBinsPerSide)
      // whenever no explicit range is picked — reuse that instead of a 0/0 sentinel, which
      // `resolveWindow` rejects outright (`tickLower >= tickUpper`) since the contract has no
      // "auto" concept of its own; it only ever validates a real, non-degenerate tick range.
      const tickLower = tickAtBin(effLower, effBinSize);
      const tickUpper = tickAtBin(effUpper + 1, effBinSize);

      // Slippage guard on the deposit: allow the pool to take slightly less of each token than
      // desired (normal for a small price move) but revert if it would take materially less than
      // the user asked for — otherwise a reorder could settle the deposit at any near-zero ratio.
      const pct = Math.min(Math.max(Number(slippage) || 0.5, 0), 99);
      const minScale = (amount: bigint) =>
        amount > 0n ? (amount * BigInt(Math.round((100 - pct) * 100))) / 10_000n : 0n;

      const addLiquidityParams = {
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "addLiquidity",
        args: [
          key,
          {
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: minScale(a0),
            amount1Min: minScale(a1),
            deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
            tickLower,
            tickUpper,
            userInputSalt: ("0x" + "00".repeat(32)) as `0x${string}`,
          },
        ],
        gas: 3_000_000n,
      } as const;

      const addLiqSim = await publicClient.simulateContract({
        ...addLiquidityParams,
        account: address,
      } as Parameters<typeof publicClient.simulateContract>[0]);
      // Use the simulated gas estimate (+10% headroom) instead of the hardcoded cap, so wide
      // books / many-bin deposits don't hit OutOfGas.
      const addLiqGas = addLiqSim.request.gas
        ? (addLiqSim.request.gas * 12n) / 10n
        : addLiquidityParams.gas;
      const addLiqHash = await writeContractAsync({ ...addLiquidityParams, gas: addLiqGas });
      setTxSteps((prev) => prev.map((s) => ({ ...s, done: true })));
      setTxHash(addLiqHash);
      setTxModalStatus("confirming");
      await publicClient.waitForTransactionReceipt({ hash: addLiqHash, timeout: 120_000 });
      setTxModalStatus("success");
      setStatus(needsCreate ? "Pool created and liquidity added" : "Liquidity added");
      balQ.refetch();
    } catch (err) {
      setTxModalStatus("error");
      const msg = err instanceof Error ? err.message.slice(0, 200) : "Failed";
      setTxError(msg);
      setStatus(msg);
    } finally {
      setIsSubmitting(false);
    }
  }

  const cta = !isConnected
    ? "Connect wallet"
    : needsNetworkSwitch
      ? "Switch network"
      : pairInvalid
        ? "Pick two tokens"
        : isSubmitting
          ? "Confirm in wallet…"
          : needsCreate
            ? "Create pool & add liquidity"
            : "Add liquidity";

  const canSubmit = isConnected && !needsNetworkSwitch && !pairInvalid && !isSubmitting;

  const currentPricePct = axisBook
    ? ((axisBook.currentBin - axisBook.minBin + 0.5) / (axisBook.maxBin - axisBook.minBin + 1)) *
      100
    : 50;

  return (
    <div>
      <StatsBar />

      <div className="console-topbar">
        <span className="mono">
          {base.symbol ?? "…"} / {quote.symbol ?? "…"}
        </span>
        <span className="fee-badge mono">
          {((deployment?.poolFee ?? 3000) / 10000).toFixed(2)}% fee
        </span>
        {ready && !pairInvalid && (
          <span className={needsCreate ? "pool-status warn" : "pool-status ok"}>
            <span className="pool-status-dot" />
            {needsCreate ? "Not deployed" : "Pool live"}
          </span>
        )}
        {preview && <span className="badge">Preview</span>}
      </div>

      {pairInvalid && (
        <p className="status" style={{ marginBottom: "1rem" }}>
          Pick two different tokens to continue.
        </p>
      )}

      {!pairInvalid && needsCreate && (
        <div className="new-pool-panel">
          <div className="field">
            <label>Starting price</label>
            <input
              value={startingPrice}
              onChange={(e) => setStartingPrice(e.target.value)}
              inputMode="decimal"
              placeholder="1"
            />
          </div>
          <div className="field">
            <label>Bin size</label>
            <select value={binSize} onChange={(e) => setBinSize(e.target.value)}>
              <option value="10">10</option>
              <option value="60">60 · matches 0.30% tier</option>
              <option value="100">100</option>
              <option value="200">200</option>
            </select>
          </div>
          <p className="new-pool-hint">
            Initializes the {base.symbol ?? "token0"} / {quote.symbol ?? "token1"} pool at this
            price, locks the bin size, then deposits the amounts below as the first bins of the ramp
            — one confirmation flow instead of a separate create-pool page.
          </p>
        </div>
      )}

      <div className="console-grid">
        <div className={showDemo ? "panel preview" : "panel"}>
          <div className="ramp-card-head">
            <div>
              <h2>Liquidity ramp</h2>
              <p>
                {showDemo
                  ? "Computed from the default ramp decay for this bin size — per-bin liquidity turns real once the pool is live."
                  : "Click a bin to start a range, click another to finish it — or pick a shape below."}
              </p>
            </div>
            {!preview && (
              <span className="ramp-price-chip mono">
                1 {base.symbol ?? "token0"} ={" "}
                {formatPriceHuman(needsCreate ? previewPrice : (bookPrice ?? 1))}{" "}
                {quote.symbol ?? "token1"}
              </span>
            )}
          </div>

          <div className="ramp-visual">
            <div className="ramp-current-tag" style={{ left: `${currentPricePct}%` }}>
              spot
            </div>
            <div className="ramp-current-line" style={{ left: `${currentPricePct}%` }} />
            <div className="ramp-bars" role="img" aria-label="Bin liquidity ramp">
              {series.map((b) => {
                const pct = maxL === 0n ? 0 : Number((b.liquidity * 10000n) / maxL) / 100;
                const isCurrent = !!axisBook && b.binIndex === axisBook.currentBin;
                const inRange =
                  lowerBin !== null &&
                  upperBin !== null &&
                  b.binIndex >= lowerBin &&
                  b.binIndex <= upperBin;
                const clickable = !showDemo;
                const info = binPriceInfo(b.binIndex, effBinSize);
                const cls = [
                  "ramp-bar",
                  isCurrent ? "current" : "",
                  inRange ? "in-range" : "",
                  clickable ? "clickable" : "",
                  hoveredBin === b.binIndex ? "hovered" : "",
                ]
                  .filter(Boolean)
                  .join(" ");
                return (
                  <div
                    key={b.binIndex}
                    className={cls}
                    style={{ height: `${Math.max(pct, b.liquidity > 0n ? 6 : 0)}%` }}
                    title={
                      clickable
                        ? `bin ${b.binIndex}\n${binPriceLabel(info)}\nedges ${formatPriceHuman(info.priceLower)} – ${formatPriceHuman(info.priceUpper)}`
                        : `bin ${b.binIndex} · ${binPriceLabel(info)}`
                    }
                    onClick={clickable ? () => handleSelectBin(b.binIndex) : undefined}
                    onMouseEnter={clickable ? () => setHoveredBin(b.binIndex) : undefined}
                    onMouseLeave={clickable ? () => setHoveredBin(null) : undefined}
                    role={clickable ? "button" : undefined}
                    tabIndex={clickable ? 0 : undefined}
                  />
                );
              })}
            </div>
          </div>
          {hoveredBinPrice && !showDemo && (
            <p className="ramp-bin-price mono">
              Bin <b>{hoveredBin}</b> · mean {formatPriceHuman(hoveredBinPrice.arithmeticMean)}{" "}
              {quote.symbol ?? "token1"} / {base.symbol ?? "token0"} · edges{" "}
              {formatPriceHuman(hoveredBinPrice.priceLower)} –{" "}
              {formatPriceHuman(hoveredBinPrice.priceUpper)}
            </p>
          )}
          <div className="ramp-axis">
            <span>
              lower · {formatPriceHuman((selectedRangePrice ?? defaultRangePrice).priceMin)}{" "}
              {quote.symbol ?? "token1"}/{base.symbol ?? "token0"}
            </span>
            <span>
              upper · {formatPriceHuman((selectedRangePrice ?? defaultRangePrice).priceMax)}{" "}
              {quote.symbol ?? "token1"}/{base.symbol ?? "token0"}
            </span>
          </div>

          <p className="ramp-caption">
            {binsCovered !== null ? (
              <>
                Bins <b>{lowerBin}</b> to <b>{upperBin}</b> selected ({binsCovered} bins)
                {selectedRangePrice && (
                  <>
                    {" "}
                    · price {formatPriceHuman(selectedRangePrice.priceMin)} –{" "}
                    {formatPriceHuman(selectedRangePrice.priceMax)} {quote.symbol ?? "token1"} per{" "}
                    {base.symbol ?? "token0"}
                  </>
                )}
              </>
            ) : (
              <>
                Default ramp window around the active bin
                {" · price "}
                {formatPriceHuman(defaultRangePrice.priceMin)} –{" "}
                {formatPriceHuman(defaultRangePrice.priceMax)} {quote.symbol ?? "token1"} per{" "}
                {base.symbol ?? "token0"}
              </>
            )}
            {" · per-bin mean = average of that bin's lower and upper edge prices (1.0001^tick)."}
          </p>

          <div className="shape-row">
            <span className="shape-label">Shape</span>
            <button
              type="button"
              className={shape === "auto" ? "shape-pill active" : "shape-pill"}
              onClick={() => applyShape("auto")}
              disabled={showDemo}
            >
              Auto
            </button>
            <button
              type="button"
              className={shape === "tight" ? "shape-pill active" : "shape-pill"}
              onClick={() => applyShape("tight")}
              disabled={showDemo}
            >
              Tight · ±5
            </button>
            <button
              type="button"
              className={shape === "wide" ? "shape-pill active" : "shape-pill"}
              onClick={() => applyShape("wide")}
              disabled={showDemo}
            >
              Wide · ±20
            </button>
            <button
              type="button"
              className={shape === "full" ? "shape-pill active" : "shape-pill"}
              onClick={() => applyShape("full")}
              disabled={showDemo}
            >
              Full book
            </button>
            <button
              type="button"
              className={shape === "custom" ? "shape-pill active" : "shape-pill"}
              disabled
            >
              Custom
            </button>
          </div>
          {showDemo && (
            <p className="ramp-caption">
              Range picker unlocks once the pool is live — the first deposit uses the default ramp
              window.
            </p>
          )}

          <div className="stat-strip">
            <div className="meta-chip">
              <dt>Bins covered</dt>
              <dd>{binsCovered ?? "Auto"}</dd>
            </div>
            <div className="meta-chip">
              <dt>Bin size</dt>
              <dd>{showDemo ? binSize : (book?.binSize ?? "—")}</dd>
            </div>
            <div className="meta-chip">
              <dt>Active bin</dt>
              <dd>{showDemo ? "—" : (book?.currentBin ?? "—")}</dd>
            </div>
          </div>
        </div>

        <form className={preview ? "deposit-dock preview" : "deposit-dock"} onSubmit={onSubmit}>
          <div className="deposit-dock-head">
            <h2>Deposit</h2>
          </div>

          {composition.mode === "above" && (
            <p className="new-pool-hint" style={{ marginBottom: "0.6rem" }}>
              This range sits entirely above the spot price — it only takes{" "}
              {baseIsCurrency0 ? (pickBase.symbol ?? "base") : (pickQuote.symbol ?? "quote")}.
            </p>
          )}
          {composition.mode === "below" && (
            <p className="new-pool-hint" style={{ marginBottom: "0.6rem" }}>
              This range sits entirely below the spot price — it only takes{" "}
              {baseIsCurrency0 ? (pickQuote.symbol ?? "quote") : (pickBase.symbol ?? "base")}.
            </p>
          )}

          <TokenAmountField
            tokenAddress={baseAddr ?? key?.currency0 ?? ZERO_ADDRESS}
            onSelectToken={(a) => selectAt("base", a)}
            extraTokens={extraTokens}
            amount={baseAmount}
            onAmount={handleBaseAmountChange}
            balance={balBase}
            decimals={decBase}
            disabled={disableBase}
          />

          <div className="plus-divider">
            <span>+</span>
          </div>

          <TokenAmountField
            tokenAddress={quoteAddr ?? key?.currency1 ?? ZERO_ADDRESS}
            onSelectToken={(a) => selectAt("quote", a)}
            extraTokens={extraTokens}
            amount={quoteAmount}
            onAmount={handleQuoteAmountChange}
            balance={balQuote}
            decimals={decQuote}
            disabled={disableQuote}
          />

          <details className="details" open>
            <summary>
              <span>Details</span>
            </summary>
            <div className="details-body">
              <div className="detail-row">
                <span>Fee tier</span>
                <span>{((deployment?.poolFee ?? 3000) / 10000).toFixed(2)}%</span>
              </div>
              <div className="detail-row">
                <span>Deposit ratio</span>
                <span>
                  {composition.mode === "above"
                    ? `${baseIsCurrency0 ? pickBase.symbol : pickQuote.symbol} only`
                    : composition.mode === "below"
                      ? `${baseIsCurrency0 ? pickQuote.symbol : pickBase.symbol} only`
                      : composition.mode === "straddle" && depositRatioQuotePerBase != null
                        ? `1 ${pickBase.symbol ?? "base"} : ${formatPriceHuman(depositRatioQuotePerBase)} ${pickQuote.symbol ?? "quote"}`
                        : "—"}
                </span>
              </div>
              <div className="detail-row">
                <span>Range</span>
                <span>{binsCovered !== null ? `${binsCovered} bins` : "Auto"}</span>
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
            </div>
          </details>

          <button type="submit" className="cta" disabled={!canSubmit}>
            {cta}
          </button>
          {status && <p className="status">{status}</p>}
          {preview && <p className="dock-note">Preview data — connect a wallet to go live.</p>}

          <TxModal
            open={txModalOpen}
            onClose={() => setTxModalOpen(false)}
            status={txModalStatus}
            hash={txHash}
            chainId={deployment?.chainId}
            error={txError}
            action={needsCreate ? "Create Pool" : "Add Liquidity"}
            summary={txSummary}
            steps={txSteps}
          />
        </form>
      </div>
    </div>
  );
}
