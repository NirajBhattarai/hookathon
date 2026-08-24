import { parseAbiItem, type Address, type PublicClient } from "viem";
import { sqrtPriceX96ToPrice } from "./priceMath";

/** Native v4 PoolManager Swap event — fires on every BinBook swap, no indexer needed. */
const swapEvent = parseAbiItem(
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)"
);

export type SwapEvent = {
  blockNumber: bigint;
  logIndex: number;
  timestamp: number;
  txHash: `0x${string}`;
  sender: Address;
  amount0: bigint;
  amount1: bigint;
  sqrtPriceX96: bigint;
  tick: number;
  /** token1 per token0, from the post-swap sqrtPriceX96 */
  price: number;
  /** true when the pool received token0 (swap was token0 -> token1) */
  zeroForOne: boolean;
};

const CHUNK_BLOCKS = 2000n;
const CONCURRENCY = 5;

function callGetLogs(
  client: PublicClient,
  poolManager: Address,
  poolId: `0x${string}`,
  fromBlock: bigint,
  toBlock: bigint
) {
  return client.getLogs({
    address: poolManager,
    event: swapEvent,
    args: { id: poolId },
    fromBlock,
    toBlock,
  });
}

type SwapLog = Awaited<ReturnType<typeof callGetLogs>>[number];

async function getLogsChunk(
  client: PublicClient,
  poolManager: Address,
  poolId: `0x${string}`,
  fromBlock: bigint,
  toBlock: bigint
): Promise<SwapLog[]> {
  try {
    return await callGetLogs(client, poolManager, poolId, fromBlock, toBlock);
  } catch (err) {
    // RPC "block range too large" (or similar) — split once and retry.
    const mid = fromBlock + (toBlock - fromBlock) / 2n;
    if (mid <= fromBlock) throw err;
    const [a, b] = await Promise.all([
      getLogsChunk(client, poolManager, poolId, fromBlock, mid),
      getLogsChunk(client, poolManager, poolId, mid + 1n, toBlock),
    ]);
    return [...a, ...b];
  }
}

/** Fetch + decode every Swap log for `poolId` in [fromBlock, toBlock], oldest first. */
export async function fetchSwapLogs(
  client: PublicClient,
  params: { poolManager: Address; poolId: `0x${string}`; fromBlock: bigint; toBlock: bigint }
): Promise<SwapEvent[]> {
  const { poolManager, poolId, fromBlock, toBlock } = params;
  if (toBlock < fromBlock) return [];

  const ranges: Array<[bigint, bigint]> = [];
  for (let start = fromBlock; start <= toBlock;) {
    const end = start + CHUNK_BLOCKS - 1n > toBlock ? toBlock : start + CHUNK_BLOCKS - 1n;
    ranges.push([start, end]);
    start = end + 1n;
  }

  const logs: SwapLog[] = [];
  for (let i = 0; i < ranges.length; i += CONCURRENCY) {
    const batch = ranges.slice(i, i + CONCURRENCY);
    const results = await Promise.all(
      batch.map(([from, to]) => getLogsChunk(client, poolManager, poolId, from, to))
    );
    for (const r of results) logs.push(...r);
  }

  logs.sort((a, b) => {
    const d = a.blockNumber! - b.blockNumber!;
    if (d !== 0n) return d < 0n ? -1 : 1;
    return a.logIndex! - b.logIndex!;
  });

  const blockNumbers = [...new Set(logs.map((l) => l.blockNumber!))];
  const tsMap = new Map<bigint, number>();
  for (let i = 0; i < blockNumbers.length; i += CONCURRENCY) {
    const batch = blockNumbers.slice(i, i + CONCURRENCY);
    const blocks = await Promise.all(batch.map((bn) => client.getBlock({ blockNumber: bn })));
    blocks.forEach((b, j) => tsMap.set(batch[j]!, Number(b.timestamp)));
  }

  return logs.map((l) => {
    const { sender, amount0, amount1, sqrtPriceX96, tick } = l.args as {
      sender: Address;
      amount0: bigint;
      amount1: bigint;
      sqrtPriceX96: bigint;
      tick: number;
    };
    return {
      blockNumber: l.blockNumber!,
      logIndex: l.logIndex!,
      timestamp: tsMap.get(l.blockNumber!) ?? 0,
      txHash: l.transactionHash!,
      sender,
      amount0,
      amount1,
      sqrtPriceX96,
      tick,
      price: sqrtPriceX96ToPrice(sqrtPriceX96),
      zeroForOne: amount0 > 0n,
    };
  });
}
