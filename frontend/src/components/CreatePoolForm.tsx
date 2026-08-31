"use client";

import { FormEvent, useMemo, useState } from "react";
import { parseUnits, type Address } from "viem";
import { useAccount, useWaitForTransactionReceipt, useReadContract } from "wagmi";
import { useContractWrite } from "@/hooks/useContractWrite";
import { binBookAbi } from "@/lib/abi/binBook";
import { useAppPublicClient } from "@/hooks/useAppPublicClient";
import { useDeployment } from "@/hooks/useDeployment";
import { NetworkGate } from "@/components/NetworkGate";
import { priceToSqrtPriceX96, quotePerBaseToRawPoolPrice } from "@/lib/priceMath";
import { unpackBalanceDelta } from "@/lib/balanceDelta";
import { binAtTick, tickAtBin, DEFAULT_BINS_PER_SIDE } from "@/lib/bins";

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
    name: "symbol",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint8" }],
  },
] as const;

export function CreatePoolForm() {
  const { address, isConnected } = useAccount();
  const { deployment, ready, needsNetworkSwitch } = useDeployment();
  const publicClient = useAppPublicClient(deployment);
  const [startingPrice, setStartingPrice] = useState("1");
  const [binSize, setBinSize] = useState("60");
  const [seed0, setSeed0] = useState("1000");
  const [seed1, setSeed1] = useState("1000");
  const [withSeed, setWithSeed] = useState(true);
  const [slippage, setSlippage] = useState("0.50");
  const [status, setStatus] = useState<string | null>(null);

  const { writeContractAsync, data: hash, isPending } = useContractWrite();
  const { isLoading: confirming } = useWaitForTransactionReceipt({ hash });

  const { data: symbol0 } = useReadContract({
    address: deployment?.token0,
    abi: erc20Abi,
    functionName: "symbol",
    query: { enabled: !!deployment?.token0 && ready },
  });
  const { data: symbol1 } = useReadContract({
    address: deployment?.token1,
    abi: erc20Abi,
    functionName: "symbol",
    query: { enabled: !!deployment?.token1 && ready },
  });
  const { data: decimals0 } = useReadContract({
    address: deployment?.token0,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: !!deployment?.token0 && ready },
  });
  const { data: decimals1 } = useReadContract({
    address: deployment?.token1,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: !!deployment?.token1 && ready },
  });

  const label0 = symbol0 ?? "TOKEN0";
  const label1 = symbol1 ?? "TOKEN1";
  const dec0 = Number(decimals0 ?? 18);
  const dec1 = Number(decimals1 ?? 18);

  const poolKey = useMemo(() => {
    if (!deployment) return null;
    // Ensure currency0 < currency1 ordering
    const t0 = deployment.token0;
    const t1 = deployment.token1;
    const [currency0, currency1] = t0.toLowerCase() < t1.toLowerCase() ? [t0, t1] : [t1, t0];
    return {
      currency0,
      currency1,
      fee: deployment.poolFee,
      tickSpacing: deployment.tickSpacing,
      hooks: deployment.binBook,
    };
  }, [deployment]);

  const deploymentToken0IsCurrency0 = useMemo(
    () =>
      poolKey
        ? deployment!.token0.toLowerCase() === poolKey.currency0.toLowerCase()
        : true,
    [poolKey, deployment]
  );

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (!isConnected) {
      setStatus("Connect your wallet first");
      return;
    }
    if (needsNetworkSwitch || !ready || !deployment || !address || !poolKey || !publicClient) {
      setStatus("Switch to a configured network first");
      return;
    }
    const userPrice = Number(startingPrice);
    if (!Number.isFinite(userPrice) || userPrice <= 0) {
      setStatus(`Enter a valid starting price (${label1} per ${label0})`);
      return;
    }
    const poolPrice = quotePerBaseToRawPoolPrice(userPrice, deploymentToken0IsCurrency0, dec0, dec1);
    const bs = Number(binSize);
    if (!Number.isFinite(bs) || bs <= 0) {
      setStatus("Enter a valid bin size");
      return;
    }

    setStatus(null);
    try {
      const sqrtPriceX96 = priceToSqrtPriceX96(poolPrice);

      await writeContractAsync({
        address: deployment.binBook,
        abi: binBookAbi,
        functionName: "createPool",
        args: [poolKey, sqrtPriceX96, bs],
      });

      if (withSeed) {
        const a0 = parseUnits(seed0 || "0", dec0);
        const a1 = parseUnits(seed1 || "0", dec1);
        const token0IsCurrency0 =
          deployment.token0.toLowerCase() === poolKey.currency0.toLowerCase();
        const amount0 = token0IsCurrency0 ? a0 : a1;
        const amount1 = token0IsCurrency0 ? a1 : a0;

        if (amount0 > 0n) {
          await writeContractAsync({
            address: poolKey.currency0,
            abi: erc20Abi,
            functionName: "approve",
            args: [deployment.binBook, amount0],
          });
        }
        if (amount1 > 0n) {
          await writeContractAsync({
            address: poolKey.currency1,
            abi: erc20Abi,
            functionName: "approve",
            args: [deployment.binBook, amount1],
          });
        }
        if (amount0 > 0n || amount1 > 0n) {
          const curBin = binAtTick(Math.round(Math.log(poolPrice) / Math.log(1.0001)), bs);
          const tickLower = tickAtBin(curBin - DEFAULT_BINS_PER_SIDE, bs);
          const tickUpper = tickAtBin(curBin + DEFAULT_BINS_PER_SIDE, bs);
          const pct = Math.min(Math.max(Number(slippage) || 0.5, 0), 99);
          const minScale = (v: bigint) =>
            v > 0n ? (v * BigInt(Math.round((100 - pct) * 100))) / 10_000n : 0n;
          const addArgsBase = {
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0n,
            amount1Min: 0n,
            deadline: BigInt(Math.floor(Date.now() / 1000) + 600),
            tickLower,
            tickUpper,
            userInputSalt: ("0x" + "00".repeat(32)) as `0x${string}`,
          };
          const sim = await publicClient.simulateContract({
            address: deployment.binBook,
            abi: binBookAbi,
            functionName: "addLiquidity",
            args: [poolKey, addArgsBase],
            account: address,
          } as Parameters<typeof publicClient.simulateContract>[0]);
          const [expected0, expected1] = unpackBalanceDelta(sim.result as bigint);

          await writeContractAsync({
            address: deployment.binBook,
            abi: binBookAbi,
            functionName: "addLiquidity",
            args: [
              poolKey,
              {
                ...addArgsBase,
                amount0Min: minScale(expected0),
                amount1Min: minScale(expected1),
              },
            ],
          });
        }
      }

      setStatus("Pool created successfully");
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "Failed");
    }
  }

  const cta = !isConnected
    ? "Connect wallet"
    : needsNetworkSwitch
      ? "Wrong network"
      : !ready
        ? "Network not configured"
        : isPending || confirming
          ? "Confirm in wallet…"
          : "Create pool";

  const canSubmit = isConnected && !needsNetworkSwitch && ready && !isPending && !confirming;

  return (
    <div className="page-wrap" style={{ maxWidth: 520 }}>
      <h1 className="page-title">Create pool</h1>
      <p className="page-sub">
        Initialize a BinBook pool for the configured token pair, set bin size, and optionally seed
        liquidity.
      </p>

      <NetworkGate blockChildren>
        {!isConnected ? (
          <div className="connect-prompt">
            <p>Connect your wallet to create a pool</p>
          </div>
        ) : (
          <form className="form-card" onSubmit={onSubmit}>
            <div className="form-grid">
              <div className="field">
                <label>Pair</label>
                <p className="muted tiny" style={{ margin: 0 }}>
                  {label0} / {label1} · fee {(deployment?.poolFee ?? 3000) / 10000}% · tick spacing{" "}
                  {deployment?.tickSpacing ?? 60}
                </p>
              </div>

              <div className="field">
                <label>Starting price</label>
                <div className="starting-price-input">
                  <input
                    value={startingPrice}
                    onChange={(e) => setStartingPrice(e.target.value)}
                    inputMode="decimal"
                    placeholder="1"
                  />
                  <span className="starting-price-suffix">
                    {label1} per {label0}
                  </span>
                </div>
                <p className="field-hint">
                  Enter {label1} per {label0} — converted to on-chain currency1/currency0 before
                  deploying.
                </p>
              </div>

              <div className="field">
                <label>Bin size</label>
                <select value={binSize} onChange={(e) => setBinSize(e.target.value)}>
                  <option value="10">10</option>
                  <option value="60">60 (match 0.30% tick spacing)</option>
                  <option value="100">100</option>
                  <option value="200">200</option>
                </select>
                <p className="field-hint">Must be &gt; 0 and ≤ 2000. Wider bins = lower gas.</p>
              </div>

              <div className="field">
                <label className="checkbox-row">
                  <input
                    type="checkbox"
                    checked={withSeed}
                    onChange={(e) => setWithSeed(e.target.checked)}
                  />
                  Seed liquidity after creating
                </label>
              </div>

              {withSeed && (
                <>
                  <div className="token-field">
                    <div className="token-field-top">
                      <span>Seed {label0}</span>
                    </div>
                    <div className="token-field-row">
                      <input
                        value={seed0}
                        onChange={(e) => setSeed0(e.target.value)}
                        inputMode="decimal"
                        placeholder="0"
                      />
                    </div>
                  </div>
                  <div className="token-field">
                    <div className="token-field-top">
                      <span>Seed {label1}</span>
                    </div>
                    <div className="token-field-row">
                      <input
                        value={seed1}
                        onChange={(e) => setSeed1(e.target.value)}
                        inputMode="decimal"
                        placeholder="0"
                      />
                    </div>
                  </div>
                  <div className="field">
                    <label>Seed slippage %</label>
                    <input
                      value={slippage}
                      onChange={(e) => setSlippage(e.target.value)}
                      inputMode="decimal"
                    />
                  </div>
                </>
              )}

              <button type="submit" className="cta" disabled={!canSubmit}>
                {cta}
              </button>
              {status && <p className="status">{status}</p>}
            </div>
          </form>
        )}
      </NetworkGate>
    </div>
  );
}
