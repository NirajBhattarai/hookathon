"use client";

import { useMemo, useState } from "react";
import { formatUnits, maxUint256, type Address } from "viem";
import { useAccount, useReadContracts, useWriteContract } from "wagmi";
import { useAppPublicClient } from "@/hooks/useAppPublicClient";
import { useDeployment } from "@/hooks/useDeployment";
import { FAUCET_TOKENS } from "@/lib/tokens";

const erc20AllowanceAbi = [
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

// approvals at or above this are shown as "Unlimited" rather than a specific number
const UNLIMITED_THRESHOLD = maxUint256 / 2n;

export function AllowancesModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { address } = useAccount();
  const { deployment } = useDeployment();
  const publicClient = useAppPublicClient(deployment);
  const { writeContractAsync } = useWriteContract();
  const [revokingAddr, setRevokingAddr] = useState<Address | null>(null);
  const [revokeError, setRevokeError] = useState<string | null>(null);

  const allowQ = useReadContracts({
    query: { enabled: open && !!address && !!deployment },
    contracts: FAUCET_TOKENS.map((t) => ({
      address: t.address,
      abi: erc20AllowanceAbi,
      functionName: "allowance" as const,
      args: [address!, deployment!.swapRouter],
    })),
  });

  const rows = useMemo(() => {
    return FAUCET_TOKENS.map((t, i) => {
      const raw = (allowQ.data?.[i]?.result as bigint | undefined) ?? 0n;
      return { token: t, raw };
    }).filter((r) => r.raw > 0n);
  }, [allowQ.data]);

  if (!open) return null;

  async function revoke(tokenAddr: Address) {
    if (!deployment || !publicClient) return;
    setRevokeError(null);
    setRevokingAddr(tokenAddr);
    try {
      const hash = await writeContractAsync({
        address: tokenAddr,
        abi: erc20AllowanceAbi,
        functionName: "approve",
        args: [deployment.swapRouter, 0n],
      });
      await publicClient.waitForTransactionReceipt({ hash, timeout: 120_000 });
      await allowQ.refetch();
    } catch (err) {
      setRevokeError(err instanceof Error ? err.message.slice(0, 160) : "Revoke failed");
    } finally {
      setRevokingAddr(null);
    }
  }

  return (
    <div className="tx-overlay" onClick={onClose}>
      <div className="tx-modal allowances-modal" onClick={(e) => e.stopPropagation()}>
        <button className="tx-modal-close" onClick={onClose} aria-label="Close">
          ×
        </button>
        <div className="tx-action-badge">Allowances</div>

        <h3 className="allowance-title">Token allowances</h3>
        <p className="allowance-sub">Tokens BinBook Router can currently spend from your wallet.</p>

        {allowQ.isLoading && <p className="tx-hint">Checking allowances…</p>}

        {!allowQ.isLoading && rows.length === 0 && (
          <p className="tx-hint">No standing allowances — nothing to revoke.</p>
        )}

        {rows.length > 0 && (
          <div className="allow-list">
            {rows.map(({ token, raw }) => {
              const unlimited = raw >= UNLIMITED_THRESHOLD;
              const label = unlimited
                ? "Unlimited"
                : `${Number(formatUnits(raw, token.decimals)).toLocaleString(undefined, {
                    maximumFractionDigits: 4,
                  })} ${token.symbol}`;
              const busy = revokingAddr === token.address;
              return (
                <div className="allow-row" key={token.address}>
                  <div className="tok-icon" style={{ background: token.color }}>
                    {token.symbol.charAt(0)}
                  </div>
                  <div className="tok-info">
                    <div className="tok-symbol">{token.symbol}</div>
                    <div className="tok-spender">BinBook Router</div>
                  </div>
                  <span className={unlimited ? "status-pill unlimited" : "status-pill exact"}>{label}</span>
                  {busy ? (
                    <div className="spin-wrap">
                      <span className="spin" />
                    </div>
                  ) : (
                    <button className="revoke-btn" type="button" onClick={() => revoke(token.address)}>
                      Revoke
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {revokeError && <p className="tx-error-msg">{revokeError}</p>}

        <p className="allowance-foot-note">
          Revoking sets the allowance to zero on-chain — your next swap in that token will ask you to
          approve again.
        </p>
      </div>
    </div>
  );
}
