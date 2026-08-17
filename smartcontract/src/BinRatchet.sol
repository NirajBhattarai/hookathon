// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BinRatchetMath} from "./libraries/BinRatchetMath.sol";

// ─────────────────────────────────────────────────────────────────────────────────────
// BIN CONCEPT
// ─────────────────────────────────────────────────────────────────────────────────────
// Uniswap v4 prices live on a tick scale where each tick = 0.01% price change.
// Instead of tracking every tick, we group ticks into larger buckets called BINS.
//
//   binSize = number of ticks per bin
//
//   binSize = 60   →  each bin spans ~0.6% price   →  tight bins for stable pairs
//   binSize = 200  →  each bin spans ~2.0% price   →  wide bins for volatile pairs
//   binSize = 10   →  each bin spans ~0.1% price   →  very fine for pegged assets
//
// Bins tile the tick number line symmetrically around 0:
//
//         ... | bin -2        | bin -1        | bin 0         | bin 1         | bin 2        | ...
//   ticks: ... [-120, -60)    [-60, 0)        [0, 60)         [60, 120)       [120, 180)     ...
//   price: ...  low  ◄──────────────────── center (1:1) ──────────────────►  high
//
// The hook tracks which bin the pool price currently sits in (currentBin).
// When a swap pushes price across a bin boundary, currentBin ratchets forward.
// The ratchet is one-directional per swap direction — preventing sandwich attacks
// from pulling price back to a previous bin.
//
// halfWidthBins controls how many bins away from center the price is allowed to move.
// If price tries to go beyond ±halfWidthBins, the swap reverts.
// ─────────────────────────────────────────────────────────────────────────────────────

struct BinConfig {
    /// @notice Number of ticks per bin.
    ///   60  = ~0.6% per bin  → stable pairs
    ///   200 = ~2.0% per bin  → volatile pairs
    int24 binSize;
    // TODO: We will see it later how we charge mathmatically
}

struct BinState {
    int24 currentBin;
    BinConfig config;
}

contract BinRatchet is BaseHook {
    // -------------------------------------------------------------------
    // Per-pool state
    // -------------------------------------------------------------------

    mapping(PoolId => BinState) public binStates;

    // -------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------

    error InvalidPoolConfig();
    error PoolNotInitialized();
    error RangeNotAlignedToBins();

    // -------------------------------------------------------------------

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------
    // Bin math
    // -------------------------------------------------------------------
}
