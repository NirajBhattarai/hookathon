'use client'

import { useSwitchChain } from 'wagmi'
import { CHAIN_BY_ID } from '@/config/chains'
import { useDeployment } from '@/hooks/useDeployment'

type Props = {
  /** When true, hide children while a network switch is required. */
  blockChildren?: boolean
  children?: React.ReactNode
}

export function NetworkGate({ blockChildren = false, children }: Props) {
  const {
    isConnected,
    isWrongNetwork,
    needsNetworkSwitch,
    targetChainId,
    walletChainId,
    chainId,
  } = useDeployment()
  const { switchChain, isPending, error } = useSwitchChain()

  if (!isConnected || !needsNetworkSwitch) {
    return <>{children}</>
  }

  const target = CHAIN_BY_ID[targetChainId]
  const currentName =
    chainId != null ? CHAIN_BY_ID[chainId]?.name : `chain ${walletChainId}`

  const message = isWrongNetwork
    ? `Your wallet is on an unsupported network (${walletChainId}). Switch to ${target.name} to use BinBook.`
    : `${currentName} isn’t fully configured for BinBook (missing contract addresses). Switch to ${target.name}.`

  const banner = (
    <div className="network-gate" role="alert">
      <p className="network-gate-msg">{message}</p>
      <button
        type="button"
        className="cta"
        disabled={isPending}
        onClick={() => switchChain({ chainId: targetChainId })}
      >
        {isPending ? 'Switching…' : `Switch to ${target.name}`}
      </button>
      {error && <p className="status">{error.message}</p>}
    </div>
  )

  if (blockChildren) return banner

  return (
    <>
      {banner}
      {children}
    </>
  )
}
