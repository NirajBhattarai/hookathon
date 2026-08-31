// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BinBook} from "../../src/BinBook.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {BinBookBase} from "./BinBookBase.s.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Seeds a FRESH USDC/WETH pool (tickSpacing=10) priced at 1 WETH = PRICE_USDC USDC.
///         Env: PRICE_USDC (default 3000), AMOUNT0 (USDC raw), AMOUNT1 (WETH raw).
contract SeedFreshPool is BinBookBase {
    using PoolIdLibrary for PoolKey;

    function run() external {
        Deployment memory d = loadDeployment();
        BinBook binBook = BinBook(d.binBook);

        uint256 priceUsdc = vm.envOr("PRICE_USDC", uint256(3000));
        uint256 amount0 = vm.envOr("AMOUNT0", uint256(10_000e6));
        // pair-side value balance at priceUsdc: amount0_human / priceUsdc => WETH raw
        uint256 amount1 = vm.envOr("AMOUNT1", uint256(((amount0 / 1e6) * 1e18) / priceUsdc));

        // p_raw = c1_raw/c0_raw so that priceUsdc human USDC == 1 human WETH
        // sqrtP = floor( sqrt(p_raw) * 2^96 ), computed off-chain for exactness
        string memory sqrtEnv = vm.envOr("SQRT_PRICE_X96", string(""));
        uint160 sqrtP = bytes(sqrtEnv).length > 0 ? uint160(vm.parseUint(sqrtEnv)) : uint160(_sqrtPriceX96(priceUsdc));

        int24 ts = int24(int256(vm.envUint("TICK_SPACING")));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(d.token0),
            currency1: Currency.wrap(d.token1),
            fee: d.fee,
            tickSpacing: ts, // new spacing => new poolId
            hooks: IHooks(d.binBook)
        });

        console2.log("poolId:", uint256(PoolId.unwrap(key.toId())));
        console2.log("sqrtPriceX96:", uint256(sqrtP));
        console2.log("tickSpacing:", int256(ts));

        vm.startBroadcast();

        if (binBook.getBinSize(key.toId()) == 0) {
            binBook.createPool(key, sqrtP, ts);
        }

        IERC20(d.token0).approve(d.binBook, type(uint256).max);
        IERC20(d.token1).approve(d.binBook, type(uint256).max);

        // Default ramp window around the pool's starting price (not tick 0 — that only works at 1:1).
        int24 bs = ts;
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 curBin = tick / bs;
        if (tick % bs != 0 && tick < 0) curBin -= 1;
        binBook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600,
                tickLower: (curBin - 10) * bs,
                tickUpper: (curBin + 10) * bs,
                userInputSalt: bytes32(0)
            })
        );

        vm.stopBroadcast();

        console2.log("seeded a0 (raw):", amount0);
        console2.log("seeded a1 (raw):", amount1);
    }

    /// @dev integer sqrt of (priceUsdc-scaled ratio) times 2^96.
    function _sqrtPriceX96(uint256 priceUsdc) internal pure returns (uint160) {
        // p_raw = 1e12 / priceUsdc ; sqrtP = isqrt(p_raw << 192)
        uint256 num = (1e12 << 192) / priceUsdc;
        return uint160(_isqrt(num));
    }

    function _isqrt(uint256 x) private pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        r = x;
        while (z < r) {
            r = z;
            z = (x / z + z) / 2;
        }
    }
}
