// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BinRatchetMath} from "./libraries/BinRatchetMath.sol";

struct BinState {
    int8 currentBin;
    uint104 offSetnBIn;
    uint16 lengthE6;
}

contract BinRatchet is BaseHook {
    // -------------------------------------------------------------------
    // Bin configuration (defaults until per-pool config is added)
    // -------------------------------------------------------------------

    // -------------------------------------------------------------------
    // Per-pool state
    // ------------------------------------------------------------------

    mapping(PoolId => BinState) public bins;

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
