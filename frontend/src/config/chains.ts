import { defineChain, type Address, type Chain } from 'viem'
import { mainnet, sepolia } from '@reown/appkit/networks'
import type { AppKitNetwork } from '@reown/appkit/networks'

export type SupportedChainId = 1 | 11155111 | 31337

export type ChainDeployment = {
  chainId: SupportedChainId
  binBook: Address
  poolManager: Address
  swapRouter: Address
  token0: Address
  token1: Address
  poolFee: number
  tickSpacing: number
  rpcUrl?: string
}

const ZERO = '0x0000000000000000000000000000000000000000' as Address

function env(key: string): string | undefined {
  const v = process.env[key]
  return v && v.length > 0 ? v : undefined
}

function envAddress(key: string): Address {
  return (env(key) as Address | undefined) ?? ZERO
}

function envInt(key: string, fallback: number): number {
  const raw = env(key)
  if (!raw) return fallback
  const n = Number(raw)
  return Number.isFinite(n) ? n : fallback
}

/** Local Anvil — overridable via NEXT_PUBLIC_RPC_URL_31337 */
export const anvil = defineChain({
  id: 31337,
  name: 'Anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: {
    default: { http: [env('NEXT_PUBLIC_RPC_URL_31337') ?? 'http://127.0.0.1:8545'] },
  },
})

/**
 * Registry of chains the app knows about.
 * Enable/disable via NEXT_PUBLIC_ENABLED_CHAINS (comma-separated IDs).
 */
export const CHAIN_BY_ID: Record<SupportedChainId, AppKitNetwork> = {
  1: mainnet,
  11155111: {
    ...sepolia,
    rpcUrls: {
      ...sepolia.rpcUrls,
      default: {
        http: [env('NEXT_PUBLIC_RPC_URL_11155111') ?? sepolia.rpcUrls.default.http[0]!],
      },
    },
  },
  31337: anvil,
}

function parseEnabledIds(): SupportedChainId[] {
  const raw = env('NEXT_PUBLIC_ENABLED_CHAINS') ?? '31337,11155111'
  const ids = raw
    .split(',')
    .map((s) => Number(s.trim()))
    .filter((id): id is SupportedChainId => id === 1 || id === 11155111 || id === 31337)
  return ids.length > 0 ? ids : [31337]
}

export const enabledChainIds = parseEnabledIds()

export const networks = enabledChainIds.map((id) => CHAIN_BY_ID[id]) as [
  AppKitNetwork,
  ...AppKitNetwork[],
]

export const defaultChainId = ((): SupportedChainId => {
  const raw = Number(env('NEXT_PUBLIC_DEFAULT_CHAIN_ID') ?? enabledChainIds[0])
  if (enabledChainIds.includes(raw as SupportedChainId)) return raw as SupportedChainId
  return enabledChainIds[0]!
})()

export const defaultNetwork = CHAIN_BY_ID[defaultChainId]

export function deploymentFor(chainId: number): ChainDeployment {
  const id = chainId as SupportedChainId
  if (!(id in CHAIN_BY_ID)) {
    throw new Error(`Unsupported chain ${chainId}`)
  }
  return {
    chainId: id,
    binBook: envAddress(`NEXT_PUBLIC_BINBOOK_${chainId}`),
    poolManager: envAddress(`NEXT_PUBLIC_POOL_MANAGER_${chainId}`),
    swapRouter: envAddress(`NEXT_PUBLIC_SWAP_ROUTER_${chainId}`),
    token0: envAddress(`NEXT_PUBLIC_TOKEN0_${chainId}`),
    token1: envAddress(`NEXT_PUBLIC_TOKEN1_${chainId}`),
    poolFee: envInt(`NEXT_PUBLIC_POOL_FEE_${chainId}`, 3000),
    tickSpacing: envInt(`NEXT_PUBLIC_TICK_SPACING_${chainId}`, 60),
    rpcUrl: env(`NEXT_PUBLIC_RPC_URL_${chainId}`),
  }
}

export function isAddressConfigured(addr: Address): boolean {
  return addr !== ZERO
}

export type { Chain }
