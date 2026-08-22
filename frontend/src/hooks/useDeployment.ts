'use client'

import { useMemo } from 'react'
import { useAccount } from 'wagmi'
import { getContracts } from '@/config/contracts'
import { defaultChainId, isAddressConfigured, type SupportedChainId } from '@/config/chains'

/**
 * Resolves the BinBook deployment for the connected wallet's chain, falling back to
 * the default chain when the wallet is on an unsupported or unconfigured network.
 *
 * - `ready`        — deployment has all contract addresses configured
 * - `isWrongNetwork`  — wallet is on a chain the app doesn't know at all
 * - `needsNetworkSwitch` — wallet should switch to `targetChainId`
 */
export function useDeployment() {
  const { address, isConnected, chainId: walletChainId } = useAccount()

  return useMemo(() => {
    const walletDeployment =
      walletChainId != null ? getContracts(walletChainId) : null
    const walletReady =
      !!walletDeployment &&
      isAddressConfigured(walletDeployment.binBook) &&
      isAddressConfigured(walletDeployment.token0) &&
      isAddressConfigured(walletDeployment.token1)

    const target = walletReady ? walletChainId! : defaultChainId
    const deployment = walletReady ? walletDeployment : getContracts(target)
    const ready =
      !!deployment &&
      isAddressConfigured(deployment.binBook) &&
      isAddressConfigured(deployment.token0) &&
      isAddressConfigured(deployment.token1)

    const isWrongNetwork = isConnected && walletDeployment == null
    const needsNetworkSwitch = isConnected && !walletReady && target !== walletChainId

    return {
      address,
      isConnected,
      chainId: target as SupportedChainId,
      walletChainId,
      targetChainId: target as SupportedChainId,
      deployment,
      ready,
      isWrongNetwork,
      needsNetworkSwitch,
    }
  }, [address, isConnected, walletChainId])
}
