import { defineChain, type Address, type Chain } from "viem";
import { mainnet, sepolia } from "@reown/appkit/networks";
import type { AppKitNetwork } from "@reown/appkit/networks";

export type SupportedChainId = 1 | 11155111;

export type ChainDeployment = {
  chainId: SupportedChainId;
  binBook: Address;
  poolManager: Address;
  swapRouter: Address;
  /** Optional test quoter — reverts with Quote(amount0, amount1) on eth_call. */
  quoter?: Address;
  token0: Address;
  token1: Address;
  poolFee: number;
  tickSpacing: number;
  rpcUrl?: string;
};

const ZERO = "0x0000000000000000000000000000000000000000" as Address;

// NOTE: process.env must be accessed via STATIC member expressions so Next.js
// inlines the values into the client bundle. Dynamic access (process.env[key])
// silently yields undefined in the browser.
type ChainEnv = Partial<Omit<ChainDeployment, "chainId" | "rpcUrl" | "poolFee" | "tickSpacing">> & {
  rpcUrl?: string;
  /** Raw env strings — converted via envInt(). */
  poolFee?: string;
  tickSpacing?: string;
};

function envAddress(value: string | undefined): Address {
  return value && value.length > 0 ? (value as Address) : ZERO;
}

function envInt(value: string | undefined, fallback: number): number {
  if (!value) return fallback;
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

/** Static NEXT_PUBLIC_* values, inlined at build time. */
const CHAIN_ENV: Record<SupportedChainId, ChainEnv> = {
  1: {},
  11155111: {
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL_11155111,
    binBook: process.env.NEXT_PUBLIC_BINBOOK_11155111 as Address | undefined,
    poolManager: process.env.NEXT_PUBLIC_POOL_MANAGER_11155111 as Address | undefined,
    swapRouter: process.env.NEXT_PUBLIC_SWAP_ROUTER_11155111 as Address | undefined,
    quoter: process.env.NEXT_PUBLIC_QUOTER_11155111 as Address | undefined,
    token0: process.env.NEXT_PUBLIC_TOKEN0_11155111 as Address | undefined,
    token1: process.env.NEXT_PUBLIC_TOKEN1_11155111 as Address | undefined,
    poolFee: process.env.NEXT_PUBLIC_POOL_FEE_11155111,
    tickSpacing: process.env.NEXT_PUBLIC_TICK_SPACING_11155111,
  },
};

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
        http: [process.env.NEXT_PUBLIC_RPC_URL_11155111 ?? sepolia.rpcUrls.default.http[0]!],
      },
    },
  },
};

function parseEnabledIds(): SupportedChainId[] {
  const raw = process.env.NEXT_PUBLIC_ENABLED_CHAINS ?? "11155111";
  const ids = raw
    .split(",")
    .map((s) => Number(s.trim()))
    .filter((id): id is SupportedChainId => id === 1 || id === 11155111);
  return ids.length > 0 ? ids : [11155111];
}

export const enabledChainIds = parseEnabledIds();

export const networks = enabledChainIds.map((id) => CHAIN_BY_ID[id]) as [
  AppKitNetwork,
  ...AppKitNetwork[],
];

export const defaultChainId = ((): SupportedChainId => {
  const raw = Number(process.env.NEXT_PUBLIC_DEFAULT_CHAIN_ID ?? enabledChainIds[0]);
  if (enabledChainIds.includes(raw as SupportedChainId)) return raw as SupportedChainId;
  return enabledChainIds[0]!;
})();

export const defaultNetwork = CHAIN_BY_ID[defaultChainId];

export function deploymentFor(chainId: number): ChainDeployment {
  const id = chainId as SupportedChainId;
  if (!(id in CHAIN_BY_ID)) {
    throw new Error(`Unsupported chain ${chainId}`);
  }
  const env = CHAIN_ENV[id] ?? {};
  return {
    chainId: id,
    binBook: envAddress(env.binBook),
    poolManager: envAddress(env.poolManager),
    swapRouter: envAddress(env.swapRouter),
    quoter: env.quoter && env.quoter.length > 0 ? envAddress(env.quoter) : undefined,
    token0: envAddress(env.token0),
    token1: envAddress(env.token1),
    poolFee: envInt(env.poolFee, 3000),
    tickSpacing: envInt(env.tickSpacing, 60),
    rpcUrl: env.rpcUrl,
  };
}

export function isAddressConfigured(addr: Address): boolean {
  return addr !== ZERO;
}

export type { Chain };
