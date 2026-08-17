// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BinRatchetMath} from "../../src/libraries/BinRatchetMath.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Echidna fork invariants checked against real on-chain Uniswap v4 pools.
/// @dev Run against a mainnet fork:
///   echidna . --contract BinRatchetForkFuzz --config echidna.yaml \
///     --fork-url https://eth-mainnet.example.com/v2/YOUR_KEY --fork-block 25600000
contract BinRatchetForkFuzz {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Canonical mainnet v4 PoolManager (see hookmate's AddressConstants).
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Candidate real mainnet v4 pools, all using BinRatchet's config (fee 3000, tickSpacing 60).
    // Pools that don't exist at the forked block are skipped; adjust or extend as needed.
    function _candidatePools() internal pure returns (PoolKey[] memory pools) {
        pools = new PoolKey[](4);
        pools[0] = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 3000, 60, IHooks(address(0)));
        pools[1] = PoolKey(Currency.wrap(USDC), Currency.wrap(WETH), 3000, 60, IHooks(address(0)));
        pools[2] = PoolKey(Currency.wrap(WETH), Currency.wrap(USDT), 3000, 60, IHooks(address(0)));
        pools[3] = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDT), 3000, 60, IHooks(address(0)));
    }

    /// Every real pool's current tick must fall inside its active bin and the price
    /// must be a valid sqrt ratio (nonzero). Pools that don't exist are skipped.
    /// When not running against a fork (canonical PoolManager has no code), this
    /// trivially passes.
    function echidna_test_real_pool_ticks_in_active_bins() public view returns (bool) {
        if (address(POOL_MANAGER).code.length == 0) return true;

        PoolKey[] memory pools = _candidatePools();
        for (uint256 i = 0; i < pools.length; i++) {
            (uint160 sqrtPriceX96, int24 tick,,) = POOL_MANAGER.getSlot0(pools[i].toId());
            if (sqrtPriceX96 == 0) continue; // pool does not exist at this fork block

            int24 b = BinRatchetMath.tickToBin(tick);
            if (!(BinRatchetMath.binLowerTick(b) <= tick && tick < BinRatchetMath.binUpperTick(b))) return false;
        }
        return true;
    }
}
