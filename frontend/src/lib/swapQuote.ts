import {
  encodeAbiParameters,
  keccak256,
  type Address,
  type PublicClient,
} from "viem";
import { asInt128 } from "@/lib/balanceDelta";
import { isAddressConfigured } from "@/config/chains";
import type { PoolKeyLike } from "@/lib/pool";

/** Single-pool router04 ABI — BalanceDelta is a packed int256 on-chain. */
export const swapRouterAbi = [
  {
    type: "function",
    name: "swapExactTokensForTokens",
    stateMutability: "payable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "zeroForOne", type: "bool" },
      {
        name: "poolKey",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      { name: "hookData", type: "bytes" },
      { name: "receiver", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
] as const;

const binQuoterAbi = [
  {
    type: "error",
    name: "Quote",
    inputs: [
      { name: "amount0", type: "int128" },
      { name: "amount1", type: "int128" },
    ],
  },
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          {
            name: "key",
            type: "tuple",
            components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ],
          },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint256" },
          { name: "receiver", type: "address" },
        ],
      },
    ],
    outputs: [],
  },
] as const;

const UINT256_MAX = (1n << 256n) - 1n;
const PADDED_MAX = `0x${UINT256_MAX.toString(16).padStart(64, "0")}` as `0x${string}`;

/** Solmate-style ERC20: `balanceOf` mapping at slot 0. */
function erc20BalanceSlot(holder: Address): `0x${string}` {
  return keccak256(
    encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [holder, 0n])
  );
}

/** Solmate-style ERC20: `allowance` nested mapping at slot 1. */
function erc20AllowanceSlot(owner: Address, spender: Address): `0x${string}` {
  const ownerSlot = keccak256(
    encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [owner, 1n])
  );
  return keccak256(
    encodeAbiParameters([{ type: "address" }, { type: "bytes32" }], [spender, ownerSlot])
  );
}

export type SwapQuoteErrorCode = "NO_LIQUIDITY" | "TOO_LARGE" | "QUOTE_FAILED";

export class SwapQuoteError extends Error {
  readonly code: SwapQuoteErrorCode;

  constructor(code: SwapQuoteErrorCode, message?: string) {
    super(message ?? code);
    this.name = "SwapQuoteError";
    this.code = code;
  }
}

export function classifySwapQuoteError(message: string): SwapQuoteErrorCode {
  if (/InsufficientLiquidity|PoolNotConfigured|PoolNotInitialized|CurrencyNotSettled/i.test(message)) {
    return "NO_LIQUIDITY";
  }
  if (/0x90bfb865|WrappedError/i.test(message)) {
    return "TOO_LARGE";
  }
  return "QUOTE_FAILED";
}

function outputAmountFromDelta(delta: bigint, zeroForOne: boolean): bigint {
  const amount0 = asInt128(delta >> 128n);
  const amount1 = asInt128(delta);
  const outSide = zeroForOne ? amount1 : amount0;
  return outSide < 0n ? -outSide : outSide;
}

function outputAmountFromQuoteDeltas(amount0: bigint, amount1: bigint, zeroForOne: boolean): bigint {
  const a0 = asInt128(amount0);
  const a1 = asInt128(amount1);
  const outSide = zeroForOne ? a1 : a0;
  return outSide < 0n ? -outSide : outSide;
}

function extractQuoteRevertArgs(err: unknown): readonly [bigint, bigint] | null {
  let cur: unknown = err;
  for (let i = 0; i < 6 && cur; i++) {
    const data = (cur as { data?: { args?: readonly unknown[] } }).data;
    if (data?.args?.length === 2) {
      return [BigInt(data.args[0] as string | bigint), BigInt(data.args[1] as string | bigint)];
    }
    cur = (cur as { cause?: unknown }).cause;
  }
  return null;
}

/**
 * Quote via BinQuoter — performs a real swap inside unlock() and reverts with deltas.
 * Works on public RPCs without faking ERC20 balances.
 */
export async function quoteViaBinQuoter(params: {
  publicClient: PublicClient;
  quoter: Address;
  receiver: Address;
  poolKey: PoolKeyLike;
  zeroForOne: boolean;
  amountIn: bigint;
}): Promise<bigint> {
  const { publicClient, quoter, receiver, poolKey, zeroForOne, amountIn } = params;

  try {
    await publicClient.simulateContract({
      address: quoter,
      abi: binQuoterAbi,
      functionName: "quoteExactInput",
      args: [{ key: poolKey, zeroForOne, amountIn, receiver }],
      account: receiver,
    });
    throw new SwapQuoteError("QUOTE_FAILED", "BinQuoter did not revert with Quote");
  } catch (err) {
    const args = extractQuoteRevertArgs(err);
    if (args) {
      return outputAmountFromQuoteDeltas(args[0], args[1], zeroForOne);
    }
    const msg = err instanceof Error ? err.message : String(err);
    throw new SwapQuoteError(classifySwapQuoteError(msg), msg);
  }
}

/**
 * Quote an exact-input swap by simulating the real router call via eth_call.
 * State overrides fake balance + allowance so quotes work before the user approves.
 */
export async function simulateSwapQuote(params: {
  publicClient: PublicClient;
  router: Address;
  payToken: Address;
  receiver: Address;
  poolKey: PoolKeyLike;
  zeroForOne: boolean;
  amountIn: bigint;
}): Promise<bigint> {
  const { publicClient, router, payToken, receiver, poolKey, zeroForOne, amountIn } = params;
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);

  try {
    const { result } = await publicClient.simulateContract({
      address: router,
      abi: swapRouterAbi,
      functionName: "swapExactTokensForTokens",
      args: [amountIn, 0n, zeroForOne, poolKey, "0x", receiver, deadline],
      account: receiver,
      stateOverride: [
        {
          address: payToken,
          stateDiff: [
            { slot: erc20BalanceSlot(receiver), value: PADDED_MAX },
            { slot: erc20AllowanceSlot(receiver, router), value: PADDED_MAX },
          ],
        },
      ],
    });
    return outputAmountFromDelta(result as bigint, zeroForOne);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new SwapQuoteError(classifySwapQuoteError(msg), msg);
  }
}

/** Prefer router simulation when connected; fall back to BinQuoter on public RPC quirks. */
export async function fetchSwapQuote(params: {
  publicClient: PublicClient;
  router: Address;
  quoter?: Address;
  payToken: Address;
  receiver: Address;
  poolKey: PoolKeyLike;
  zeroForOne: boolean;
  amountIn: bigint;
  /** When true, try router eth_call simulation before BinQuoter. */
  preferSimulation?: boolean;
}): Promise<bigint> {
  const { quoter, preferSimulation = false, ...rest } = params;

  const attempts: Array<() => Promise<bigint>> = [];
  if (preferSimulation) {
    attempts.push(() => simulateSwapQuote(rest));
  }
  if (quoter && isAddressConfigured(quoter)) {
    attempts.push(() => quoteViaBinQuoter({ ...rest, quoter }));
  }
  if (!preferSimulation) {
    attempts.push(() => simulateSwapQuote(rest));
  }

  let lastErr: unknown;
  for (const attempt of attempts) {
    try {
      return await attempt();
    } catch (err) {
      lastErr = err;
      if (err instanceof SwapQuoteError && err.code === "NO_LIQUIDITY") throw err;
    }
  }

  if (lastErr instanceof SwapQuoteError) throw lastErr;
  const msg = lastErr instanceof Error ? lastErr.message : String(lastErr);
  throw new SwapQuoteError("QUOTE_FAILED", msg);
}
