"use client";

import { FormEvent, useEffect, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import {
  useAccount,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import { binBookAbi } from "@/lib/abi/binBook";
import { BinDepthChart, type BinRange } from "@/components/BinDepthChart";
import { StatsBar } from "@/components/StatsBar";
import { useBook } from "@/hooks/useBook";
import { useDeployment } from "@/hooks/useDeployment";
import { usePool } from "@/hooks/usePool";
import { useTokenMeta } from "@/hooks/useTokenMeta";
import { tickAtBin } from "@/lib/bins";

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
] as const;

type Preset = "auto" | 5 | 20 | "full" | "custom";

function TokenAmountField({
  label,
  amount,
  onAmount,
  balance,
  decimals,
}: {
  label: string;
  amount: string;
  onAmount: (v: string) => void;
  balance?: bigint;
  decimals?: number;
}) {
  return (
    <div className="token-field">
      <div className="token-field-top">
        <span>{label}</span>
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
          inputMode="decimal"
          placeholder="0"
        />
      </div>
    </div>
  );
}

export function AddLiquidityForm() {
  const { address, isConnected } = useAccount();
  const { deployment } = useDeployment();
  const { key } = usePool();
  const { book, preview } = useBook();

  const base = useTokenMeta(key?.currency0);
  const quote = useTokenMeta(key?.currency1);

  const [amount0, setAmount0] = useState("1");
  const [amount1, setAmount1] = useState("1");
  const [preset, setPreset] = useState<Preset>("auto");
  const [lowerBin, setLowerBin] = useState<number | null>(null);
  const [upperBin, setUpperBin] = useState<number | null>(null);
  const [rangeStart, setRangeStart] = useState<number | null>(null);
  const [status, setStatus] = useState<string | null>(null);

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

  function applyPreset(next: Preset) {
    setPreset(next);
    setRangeStart(null);
    if (!book) return;
    if (next === "auto") {
      setLowerBin(null);
      setUpperBin(null);
    } else if (next === "full") {
      setLowerBin(book.minBin);
      setUpperBin(book.maxBin);
    } else if (next === 5 || next === 20) {
      const half = Math.floor(next / 2);
      setLowerBin(Math.max(book.minBin, book.currentBin - half));
      setUpperBin(Math.min(book.maxBin, book.currentBin + half));
    }
  }

  function handleSelectBin(bin: number) {
    setPreset("custom");
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

  const { writeContractAsync, data: hash, isPending } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (!isSuccess) return;
    setStatus("Liquidity added");
    balQ.refetch();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess]);

  const dec0 = base.decimals;
  const dec1 = quote.decimals;

  const selection: BinRange | null =
    lowerBin !== null && upperBin !== null ? { lower: lowerBin, upper: upperBin } : null;
  const binsCovered = selection ? selection.upper - selection.lower + 1 : null;

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (!deployment || !address || !key || !book || dec0 === undefined || dec1 === undefined)
      return;
    setStatus(null);
    try {
      const a0 = parseUnits(amount0 || "0", dec0);
      const a1 = parseUnits(amount1 || "0", dec1);
      if (a0 > 0n) {
        await writeContractAsync({
          address: key.currency0,
          abi: erc20Abi,
          functionName: "approve",
          args: [deployment.binBook, a0],
        });
      }
      if (a1 > 0n) {
        await writeContractAsync({
          address: key.currency1,
          abi: erc20Abi,
          functionName: "approve",
          args: [deployment.binBook, a1],
        });
      }
      const auto = lowerBin === null || upperBin === null;
      const tickLower = auto ? 0 : tickAtBin(lowerBin, book.binSize);
      const tickUpper = auto ? 0 : tickAtBin(upperBin + 1, book.binSize);
      await writeContractAsync({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "addLiquidity",
        args: [
          key,
          {
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: 0n,
            amount1Min: 0n,
            deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
            tickLower,
            tickUpper,
            userInputSalt: ("0x" + "00".repeat(32)) as `0x${string}`,
          },
        ],
      });
      setStatus("Liquidity submitted");
    } catch (err) {
      setStatus(err instanceof Error ? err.message.slice(0, 200) : "Failed");
    }
  }

  const cta = !isConnected
    ? "Connect wallet"
    : isPending || confirming
      ? "Confirm in wallet…"
      : "Add liquidity";

  return (
    <div>
      <StatsBar />
      <div className="trade-layout">
        <div className="page-wrap" style={{ maxWidth: 460, width: "100%", margin: 0 }}>
          <h1 className="page-title">Add liquidity</h1>
          <p className="page-sub">Deposit into the bin book across a price range you choose.</p>

          <form className="form-card" onSubmit={onSubmit}>
            <div className="form-grid">
              <TokenAmountField
                label={preview ? "DEMO" : (base.symbol ?? "…")}
                amount={amount0}
                onAmount={setAmount0}
                balance={bal0}
                decimals={dec0}
              />
              <TokenAmountField
                label={preview ? "USDC" : (quote.symbol ?? "…")}
                amount={amount1}
                onAmount={setAmount1}
                balance={bal1}
                decimals={dec1}
              />

              <div>
                <div className="field" style={{ marginBottom: "0.5rem" }}>
                  <label>
                    Range
                    {rangeStart !== null && (
                      <span className="muted tiny"> · click another bin to finish</span>
                    )}
                  </label>
                </div>
                <div className="range-presets">
                  <button
                    type="button"
                    className={preset === "auto" ? "preset active" : "preset"}
                    onClick={() => applyPreset("auto")}
                  >
                    Auto (near spot)
                  </button>
                  <button
                    type="button"
                    className={preset === 5 ? "preset active" : "preset"}
                    onClick={() => applyPreset(5)}
                  >
                    ±5 bins
                  </button>
                  <button
                    type="button"
                    className={preset === 20 ? "preset active" : "preset"}
                    onClick={() => applyPreset(20)}
                  >
                    ±20 bins
                  </button>
                  <button
                    type="button"
                    className={preset === "full" ? "preset active" : "preset"}
                    onClick={() => applyPreset("full")}
                  >
                    Full book
                  </button>
                </div>
                <p className="muted tiny" style={{ marginTop: "0.5rem" }}>
                  {selection
                    ? `Bins ${selection.lower} to ${selection.upper} (${binsCovered} bins) · click the chart to fine-tune`
                    : "Default ramp window around the active bin · click the chart to pick a custom range"}
                </p>
              </div>

              <button
                type="submit"
                className="cta"
                disabled={isPending || confirming || !isConnected}
              >
                {cta}
              </button>

              {status && <p className="status">{status}</p>}
            </div>
          </form>
        </div>
        <BinDepthChart selection={selection} onSelectBin={handleSelectBin} />
      </div>
    </div>
  );
}
