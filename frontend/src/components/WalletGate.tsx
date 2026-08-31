"use client";

import { useAppKit } from "@reown/appkit/react";
import { useSwitchChain } from "wagmi";
import { CHAIN_BY_ID } from "@/config/chains";
import { useDeployment } from "@/hooks/useDeployment";

type Props = {
  children: React.ReactNode;
};

/**
 * Blocks trading UI until the user connects a wallet and is on a supported network.
 * Shows a modal with connect / switch-network actions.
 */
export function WalletGate({ children }: Props) {
  const { isConnected, needsNetworkSwitch, isWrongNetwork, targetChainId, walletChainId } =
    useDeployment();
  const { open } = useAppKit();
  const { switchChain, isPending: switching, error: switchError } = useSwitchChain();

  const blocked = !isConnected || needsNetworkSwitch;
  const target = CHAIN_BY_ID[targetChainId];

  if (!blocked) return <>{children}</>;

  const hint = !isConnected
    ? "Connect your wallet to swap, view live quotes, and submit transactions."
    : isWrongNetwork
      ? `Your wallet is on an unsupported network (${walletChainId ?? "unknown"}). Switch to ${target.name} to use BinBook.`
      : `Switch to ${target.name} to use BinBook.`;

  return (
    <>
      <div className="wallet-gate-content" aria-hidden={true}>
        {children}
      </div>
      <div className="tx-overlay wallet-gate-overlay" role="dialog" aria-modal="true">
        <div className="tx-modal wallet-gate-modal" onClick={(e) => e.stopPropagation()}>
          <div className="tx-modal-body">
            <h3>{!isConnected ? "Connect wallet" : "Switch network"}</h3>
            <p className="tx-hint">{hint}</p>
            {!isConnected ? (
              <button type="button" className="cta" onClick={() => void open()}>
                Connect wallet
              </button>
            ) : (
              <button
                type="button"
                className="cta"
                disabled={switching}
                onClick={() => switchChain({ chainId: targetChainId })}
              >
                {switching ? "Switching…" : `Switch to ${target.name}`}
              </button>
            )}
            {switchError && <p className="status warn">{switchError.message}</p>}
          </div>
        </div>
      </div>
    </>
  );
}
