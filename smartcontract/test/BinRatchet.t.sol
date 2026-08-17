// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {BinRatchet} from "../src/BinRatchet.sol";
import {BinRatchetMath} from "../src/libraries/BinRatchetMath.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract BinRatchetTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    BinRatchet hook;
    PoolId poolId;

    function setUp() public {
        // Deploys all required artifacts.
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        // Deploy the hook via CREATE2 with all flags cleared. BaseHook's constructor
        // requires the deployed address to match getHookPermissions() exactly, so the
        // address is mined to have zero bits in the low 14 flag bits.
        address flags = address(uint160(0));
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("BinRatchet.sol:BinRatchet", constructorArgs, flags);
        hook = BinRatchet(flags);

        // The pool is created WITHOUT the hook: with all permissions disabled this
        // v4-core version rejects any non-zero hook address without flags set.
        // Attach the hook once its first permission is re-enabled.
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
    }

    function testPermissionsDisabled() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeSwap);
        assertFalse(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    function testBinMath() public pure {
        // Tick -> bin rounding (floor for negatives)
        assertEq(BinRatchetMath.tickToBin(0), 0);
        assertEq(BinRatchetMath.tickToBin(1), 0);
        assertEq(BinRatchetMath.tickToBin(59), 0);
        assertEq(BinRatchetMath.tickToBin(60), 1);
        assertEq(BinRatchetMath.tickToBin(-1), -1);
        assertEq(BinRatchetMath.tickToBin(-60), -1);
        assertEq(BinRatchetMath.tickToBin(-61), -2);

        // Bin -> tick bounds
        assertEq(BinRatchetMath.binLowerTick(0), 0);
        assertEq(BinRatchetMath.binUpperTick(0), 60);
        assertEq(BinRatchetMath.binLowerTick(1), 60);
        assertEq(BinRatchetMath.binUpperTick(1), 120);
        assertEq(BinRatchetMath.binLowerTick(-1), -60);
        assertEq(BinRatchetMath.binUpperTick(-1), 0);

        // Alignment
        assertTrue(BinRatchetMath.isBinAligned(0));
        assertTrue(BinRatchetMath.isBinAligned(60));
        assertTrue(BinRatchetMath.isBinAligned(-60));
        assertFalse(BinRatchetMath.isBinAligned(30));
        assertFalse(BinRatchetMath.isBinAligned(-30));

        // Floor division
        assertEq(BinRatchetMath.floorDiv(0, 60), 0);
        assertEq(BinRatchetMath.floorDiv(59, 60), 0);
        assertEq(BinRatchetMath.floorDiv(60, 60), 1);
        assertEq(BinRatchetMath.floorDiv(-1, 60), -1);
        assertEq(BinRatchetMath.floorDiv(-60, 60), -1);
        assertEq(BinRatchetMath.floorDiv(-61, 60), -2);
    }

    function testLiquidityAllowed() public {
        uint128 liquidityAmount = 100e18;
        int24 tickLower = 0;
        int24 tickUpper = 60;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function testSwapWorks() public {
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(60), liquidityAmount
        );

        positionManager.mint(
            poolKey,
            0,
            60,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e17,
            amountOutMin: 0,
            zeroForOne: false, // token1 -> token0, moves price up into the [0, 60] range
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        assertGt(currentTick, 0);
        assertLt(currentTick, 60);
    }
}
