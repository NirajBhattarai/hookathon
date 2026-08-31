"use client";

import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import { formatUnits, maxUint256, parseUnits, type Address } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { useContractWrite } from "@/hooks/useContractWrite";
import { binBookAbi } from "@/lib/abi/binBook";
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
import {
  formatPriceHuman,
  priceToSqrtPriceX96,
  sqrtPriceX96ToPrice,
  poolPriceFromQuotePerBase,
  humanPoolPriceToRaw,
  rawPoolPriceToQuotePerBase,
  quotePerBaseToRawPoolPrice,
} from "@/lib/priceMath";
import { unpackBalanceDelta } from "@/lib/balanceDelta";
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
  const { book, preview, refetch: refetchBook } = useBook(pair);
  const { series: liveSeries, maxL: liveMaxL } = useBinLiquidity(pair);

  const currency0Meta = useTokenMeta(key?.currency0);
  const currency1Meta = useTokenMeta(key?.currency1);
  const pickBase = useTokenMeta(baseAddr ?? key?.currency0);
  const pickQuote = useTokenMeta(quoteAddr ?? key?.currency1);
  const dec0 = currency0Meta.decimals;
  const dec1 = currency1Meta.decimals;

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
  const needsSeed = Boolean(book?.configured && !book.seeded);
  const showDemoRamp = preview || needsCreate;
  const rampInteractive = !preview;

  const previewBinSize = Number(binSize) || 60;
  const userStartingPrice = Number(startingPrice) > 0 ? Number(startingPrice) : 1;
  const humanPoolPrice = useMemo(
    () => poolPriceFromQuotePerBase(userStartingPrice, baseIsCurrency0),
    [userStartingPrice, baseIsCurrency0]
  );
  const rawPoolPrice = useMemo(() => {
    if (dec0 === undefined || dec1 === undefined) return humanPoolPrice;
    return humanPoolPriceToRaw(humanPoolPrice, dec0, dec1);
  }, [humanPoolPrice, dec0, dec1]);
  const previewCurBin = useMemo(
    () => binAtTick(Math.round(Math.log(rawPoolPrice) / Math.log(1.0001)), previewBinSize),
    [rawPoolPrice, previewBinSize]
  );
  const rampPreview = useMemo(
    () => buildRampPreview(previewBinSize, DEFAULT_RAMP, DEFAULT_BINS_PER_SIDE, previewCurBin),
    [previewBinSize, previewCurBin]
  );
  const rampPreviewMaxL = useMemo(
    () => rampPreview.reduce((m, b) => (b.liquidity > m ? b.liquidity : m), 0n),
    [rampPreview]
  );
  const previewAxisBook = useMemo(
    () => ({
      binSize: previewBinSize,
      currentBin: previewCurBin,
      minBin: previewCurBin - DEFAULT_BINS_PER_SIDE,
      maxBin: previewCurBin + DEFAULT_BINS_PER_SIDE - 1,
      sqrtPriceX96: priceToSqrtPriceX96(rawPoolPrice),
      configured: false,
      seeded: false,
    }),
    [previewBinSize, rawPoolPrice, previewCurBin]
  );

  const emptyRampPreview = useMemo(
    () =>
      book ? buildRampPreview(book.binSize, book.ramp, book.numBinsPerSide, book.currentBin) : [],
    [book]
  );
  const emptyRampMaxL = useMemo(
    () => emptyRampPreview.reduce((m, b) => (b.liquidity > m ? b.liquidity : m), 0n),
    [emptyRampPreview]
  );
  const showEmptyRamp = needsSeed && !showDemoRamp && liveMaxL === 0n;

  const series = showDemoRamp ? rampPreview : showEmptyRamp ? emptyRampPreview : liveSeries;
  const maxL = showDemoRamp ? rampPreviewMaxL : showEmptyRamp ? emptyRampMaxL : liveMaxL;
  const axisBook = showDemoRamp ? previewAxisBook : book;

  const bookPoolPriceRaw =
    book && book.sqrtPriceX96 > 0n ? sqrtPriceX96ToPrice(book.sqrtPriceX96) : null;
  const displayPoolPrice = useMemo(() => {
    const raw = needsCreate ? rawPoolPrice : (bookPoolPriceRaw ?? rawPoolPrice);
    if (dec0 === undefined || dec1 === undefined) {
      return baseIsCurrency0 ? raw : 1 / raw;
    }
    return rawPoolPriceToQuotePerBase(raw, baseIsCurrency0, dec0, dec1);
  }, [needsCreate, rawPoolPrice, bookPoolPriceRaw, baseIsCurrency0, dec0, dec1]);

  // Range composition uses on-chain orientation (currency1 / currency0) in wei-ratio space.
  const compositionPrice = showDemoRamp ? rawPoolPrice : (bookPoolPriceRaw ?? rawPoolPrice);
  const baseRamp = showDemoRamp ? DEFAULT_RAMP : (book?.ramp ?? DEFAULT_RAMP);
  const numBinsPerSide = showDemoRamp
    ? DEFAULT_BINS_PER_SIDE
    : (book?.numBinsPerSide ?? DEFAULT_BINS_PER_SIDE);
  const curBin = needsCreate ? previewCurBin : (axisBook?.currentBin ?? 0);
  const effLower = lowerBin ?? curBin - numBinsPerSide;
  const effUpper = upperBin ?? curBin + numBinsPerSide - 1;
  const effBinSize = axisBook?.binSize ?? previewBinSize;

  const composition = useMemo(
    () => composeRangeAmounts(effLower, effUpper, curBin, effBinSize, baseRamp, compositionPrice),
    [effLower, effUpper, curBin, effBinSize, baseRamp, compositionPrice]
  );

  const depositRatioQuotePerBase = useMemo(() => {
    if (composition.mode !== "straddle" || composition.need0 <= 0) return null;
    if (dec0 === undefined || dec1 === undefined) return null;
    const rawC1PerC0 = composition.need1 / composition.need0;
    return rawPoolPriceToQuotePerBase(rawC1PerC0, baseIsCurrency0, dec0, dec1);
  }, [composition, baseIsCurrency0, dec0, dec1]);

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
    const ref = needsCreate ? previewAxisBook : book;
    if (!ref) return;
    if (next === "auto") {
      setLowerBin(null);
      setUpperBin(null);
    } else if (next === "full") {
      setLowerBin(ref.minBin);
      setUpperBin(ref.maxBin);
    } else if (next === "tight" || next === "wide") {
      const half = next === "tight" ? 5 : 20;
      setLowerBin(Math.max(ref.minBin, ref.currentBin - half));
      setUpperBin(Math.min(ref.maxBin, ref.currentBin + half));
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

  const { writeContractAsync } = useContractWrite();
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
  const decBase = baseIsCurrency0 ? dec0 : dec1;
  const decQuote = baseIsCurrency0 ? dec1 : dec0;

  const txSummary =
    (baseAmount !== "0" || quoteAmount !== "0") && pickBase.symbol && pickQuote.symbol
      ? `${baseAmount !== "0" ? `${baseAmount} ${pickBase.symbol}` : ""}${baseAmount !== "0" && quoteAmount !== "0" ? " + " : ""}${quoteAmount !== "0" ? `${quoteAmount} ${pickQuote.symbol}` : ""}`
      : undefined;

  const binsCovered = lowerBin !== null && upperBin !== null ? upperBin - lowerBin + 1 : null;

  const fmtUserPrice = (rawC1PerC0: number) => {
    if (dec0 === undefined || dec1 === undefined) {
      return formatPriceHuman(baseIsCurrency0 ? rawC1PerC0 : 1 / rawC1PerC0);
    }
    return formatPriceHuman(rawPoolPriceToQuotePerBase(rawC1PerC0, baseIsCurrency0, dec0, dec1));
  };
  const pricePairLabel = `${pickQuote.symbol ?? "quote"}/${pickBase.symbol ?? "base"}`;

  const binPriceLabel = (info: ReturnType<typeof binPriceInfo>) => {
    const userPrice = fmtUserPrice(info.arithmeticMean);
    return `1 ${pickBase.symbol ?? "base"} = ${userPrice} ${pickQuote.symbol ?? "quote"}`;
  };

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
    if (needsApproval0) allSteps.push({ label: `Approve ${currency0Meta.symbol}`, done: false });
    if (needsApproval1) allSteps.push({ label: `Approve ${currency1Meta.symbol}`, done: false });
    allSteps.push({ label: "Add liquidity", done: false });
    setTxSteps(allSteps);

    let stepIdx = 0;
    const markDone = () => {
      setTxSteps((prev) => prev.map((s, i) => (i === stepIdx ? { ...s, done: true } : s)));
      stepIdx++;
    };

    const sendAndConfirm = async (params: Parameters<typeof writeContractAsync>[0]) => {
      const sim = await publicClient.simulateContract({
        ...params,
        account: address,
      } as Parameters<typeof publicClient.simulateContract>[0]);
      const estimatedGas = sim.request.gas;
      const gas = estimatedGas ? (estimatedGas * 12n) / 10n : params.gas;
      const hash = await writeContractAsync(gas ? { ...params, gas } : params);
      setTxHash(hash);
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
        const initSqrtPrice = priceToSqrtPriceX96(
          quotePerBaseToRawPoolPrice(price, baseIsCurrency0, dec0, dec1)
        );
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
          args: [key, initSqrtPrice, bs],
          gas: 500_000n,
        });
        await refetchBook();
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

      const tickLower = tickAtBin(effLower, effBinSize);
      const tickUpper = tickAtBin(effUpper + 1, effBinSize);

      const pct = Math.min(Math.max(Number(slippage) || 0.5, 0), 99);
      const minScale = (amount: bigint) =>
        amount > 0n ? (amount * BigInt(Math.round((100 - pct) * 100))) / 10_000n : 0n;

      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
      const userInputSalt = ("0x" + "00".repeat(32)) as `0x${string}`;
      const addLiquidityArgsBase = {
        amount0Desired: a0,
        amount1Desired: a1,
        amount0Min: 0n,
        amount1Min: 0n,
        deadline,
        tickLower,
        tickUpper,
        userInputSalt,
      };

      const addLiqSim = await publicClient.simulateContract({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "addLiquidity",
        args: [key, addLiquidityArgsBase],
        account: address,
      } as Parameters<typeof publicClient.simulateContract>[0]);
      const [expected0, expected1] = unpackBalanceDelta(addLiqSim.result as bigint);

      const addLiquidityParams = {
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "addLiquidity",
        args: [
          key,
          {
            ...addLiquidityArgsBase,
            amount0Min: minScale(expected0),
            amount1Min: minScale(expected1),
          },
        ],
        gas: 3_000_000n,
      } as const;

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
      allowQ.refetch();
      void refetchBook();
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
      <div className="console-topbar">
        <span className="mono">
          {pickBase.symbol ?? "…"} / {pickQuote.symbol ?? "…"}
        </span>
        <span className="fee-badge mono">
          {((deployment?.poolFee ?? 3000) / 10000).toFixed(2)}% fee
        </span>
        {ready && !pairInvalid && (
          <span className={needsCreate ? "pool-status warn" : needsSeed ? "pool-status warn" : "pool-status ok"}>
            <span className="pool-status-dot" />
            {needsCreate ? "Not deployed" : needsSeed ? "Empty pool" : "Pool live"}
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
            <label>
              Starting price ({pickQuote.symbol ?? "quote"} per {pickBase.symbol ?? "base"})
            </label>
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
            Initializes the {pickBase.symbol ?? "base"} / {pickQuote.symbol ?? "quote"} pool at this
            price, locks the bin size, then deposits the amounts below as the first bins of the ramp
            — one confirmation flow instead of a separate create-pool page.
          </p>
        </div>
      )}

      <div className="console-grid">
        <div className={preview ? "panel preview" : "panel"}>
          <div className="ramp-card-head">
            <div>
              <h2>Liquidity ramp</h2>
              <p>
                {preview
                  ? "Computed from the default ramp decay for this bin size — per-bin liquidity turns real once the pool is live."
                  : needsCreate
                    ? "Click a bin to choose your first deposit range, or pick a shape below — centered on your starting price."
                    : needsSeed
                      ? "Pool created — click bins to choose where to add your first liquidity, or pick a shape below."
                      : "Click a bin to start a range, click another to finish it — or pick a shape below."}
              </p>
            </div>
            {!preview && (
              <span className="ramp-price-chip mono">
                1 {pickBase.symbol ?? "base"} = {formatPriceHuman(displayPoolPrice)}{" "}
                {pickQuote.symbol ?? "quote"}
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
                const clickable = rampInteractive;
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
                        ? `bin ${b.binIndex}\n${binPriceLabel(info)}\nedges ${fmtUserPrice(info.priceLower)} – ${fmtUserPrice(info.priceUpper)}`
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
          {hoveredBinPrice && rampInteractive && (
            <p className="ramp-bin-price mono">
              Bin <b>{hoveredBin}</b> · mean {fmtUserPrice(hoveredBinPrice.arithmeticMean)}{" "}
              {pricePairLabel} · edges {fmtUserPrice(hoveredBinPrice.priceLower)} –{" "}
              {fmtUserPrice(hoveredBinPrice.priceUpper)}
            </p>
          )}
          <div className="ramp-axis">
            <span>
              lower · {fmtUserPrice((selectedRangePrice ?? defaultRangePrice).priceMin)}{" "}
              {pricePairLabel}
            </span>
            <span>
              upper · {fmtUserPrice((selectedRangePrice ?? defaultRangePrice).priceMax)}{" "}
              {pricePairLabel}
            </span>
          </div>

          <p className="ramp-caption">
            {binsCovered !== null ? (
              <>
                Bins <b>{lowerBin}</b> to <b>{upperBin}</b> selected ({binsCovered} bins)
                {selectedRangePrice && (
                  <>
                    {" "}
                    · price {fmtUserPrice(selectedRangePrice.priceMin)} –{" "}
                    {fmtUserPrice(selectedRangePrice.priceMax)} {pricePairLabel}
                  </>
                )}
              </>
            ) : (
              <>
                Default ramp window around the active bin
                {" · price "}
                {fmtUserPrice(defaultRangePrice.priceMin)} –{" "}
                {fmtUserPrice(defaultRangePrice.priceMax)} {pricePairLabel}
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
              disabled={!rampInteractive}
            >
              Auto
            </button>
            <button
              type="button"
              className={shape === "tight" ? "shape-pill active" : "shape-pill"}
              onClick={() => applyShape("tight")}
              disabled={!rampInteractive}
            >
              Tight · ±5
            </button>
            <button
              type="button"
              className={shape === "wide" ? "shape-pill active" : "shape-pill"}
              onClick={() => applyShape("wide")}
              disabled={!rampInteractive}
            >
              Wide · ±20
            </button>
            <button
              type="button"
              className={shape === "full" ? "shape-pill active" : "shape-pill"}
              onClick={() => applyShape("full")}
              disabled={!rampInteractive}
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
          {preview && (
            <p className="ramp-caption">
              Connect a wallet to interact with the ramp — preview shows the default shape only.
            </p>
          )}

          <div className="stat-strip">
            <div className="meta-chip">
              <dt>Bins covered</dt>
              <dd>{binsCovered ?? "Auto"}</dd>
            </div>
            <div className="meta-chip">
              <dt>Bin size</dt>
              <dd>{showDemoRamp ? binSize : (book?.binSize ?? "—")}</dd>
            </div>
            <div className="meta-chip">
              <dt>Active bin</dt>
              <dd>{axisBook?.currentBin ?? "—"}</dd>
            </div>
          </div>

          {needsSeed && !needsCreate && (
            <p className="ramp-caption">
              No liquidity on-chain yet — the ramp preview is centered on the pool&apos;s starting
              price so you can pick a range for your first deposit.
            </p>
          )}
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
