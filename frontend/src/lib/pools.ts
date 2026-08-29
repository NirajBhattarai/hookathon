import { parseAbiItem, type Address, type PublicClient } from "viem";
import type { PoolKeyLike } from "./pool";

/** Native BinBook PoolCreated event — the only source of truth for "which pools exist", no indexer needed. */
const poolCreatedEvent = parseAbiItem(
  "event PoolCreated(bytes32 indexed poolId, address indexed creator, (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, int24 binSize)"
);

export type CreatedPool = {
  poolId: `0x${string}`;
  key: PoolKeyLike;
  binSize: number;
  creator: Address;
  blockNumber: bigint;
};

const CHUNK_BLOCKS = 9000n;
const CONCURRENCY = 2;
const MAX_RETRIES = 4;

function callGetLogs(client: PublicClient, binBook: Address, fromBlock: bigint, toBlock: bigint) {
  return client.getLogs({ address: binBook, event: poolCreatedEvent, fromBlock, toBlock });
}

type PoolLog = Awaited<ReturnType<typeof callGetLogs>>[number];

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Retries the same range with exponential backoff first (handles transient/rate-limit errors —
 * e.g. a free-tier RPC's 429 — without amplifying them), then falls back to bisecting the range
 * once retries are exhausted (handles a genuine "range too large" RPC error). Bisecting on every
 * error unconditionally, as a naive implementation does, turns one rate-limited call into an
 * exponentially growing storm of further-rate-limited sub-calls.
 */
async function getLogsChunk(
  client: PublicClient,
  binBook: Address,
  fromBlock: bigint,
  toBlock: bigint
): Promise<PoolLog[]> {
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    try {
      return await callGetLogs(client, binBook, fromBlock, toBlock);
    } catch (err) {
      if (attempt < MAX_RETRIES) {
        await sleep(300 * 2 ** attempt + Math.random() * 200);
        continue;
      }
      const mid = fromBlock + (toBlock - fromBlock) / 2n;
      if (mid <= fromBlock) throw err;
      const [a, b] = await Promise.all([
        getLogsChunk(client, binBook, fromBlock, mid),
        getLogsChunk(client, binBook, mid + 1n, toBlock),
      ]);
      return [...a, ...b];
    }
  }
  /* istanbul ignore next — loop always returns or throws */
  throw new Error("unreachable");
}

/** Every pool ever created against this BinBook deployment, oldest first — reads chain history directly, no database. */
export async function fetchCreatedPools(
  client: PublicClient,
  params: { binBook: Address; fromBlock: bigint; toBlock: bigint }
): Promise<CreatedPool[]> {
  const { binBook, fromBlock, toBlock } = params;
  if (toBlock < fromBlock) return [];

  const ranges: Array<[bigint, bigint]> = [];
  for (let start = fromBlock; start <= toBlock; ) {
    const end = start + CHUNK_BLOCKS - 1n > toBlock ? toBlock : start + CHUNK_BLOCKS - 1n;
    ranges.push([start, end]);
    start = end + 1n;
  }

  const logs: PoolLog[] = [];
  for (let i = 0; i < ranges.length; i += CONCURRENCY) {
    const batch = ranges.slice(i, i + CONCURRENCY);
    const results = await Promise.all(batch.map(([from, to]) => getLogsChunk(client, binBook, from, to)));
    for (const r of results) logs.push(...r);
  }

  logs.sort((a, b) => {
    const d = a.blockNumber! - b.blockNumber!;
    if (d !== 0n) return d < 0n ? -1 : 1;
    return a.logIndex! - b.logIndex!;
  });

  return logs.map((l) => {
    const { poolId, creator, key, binSize } = l.args as {
      poolId: `0x${string}`;
      creator: Address;
      key: PoolKeyLike;
      binSize: number;
    };
    return { poolId, creator, key, binSize: Number(binSize), blockNumber: l.blockNumber! };
  });
}
