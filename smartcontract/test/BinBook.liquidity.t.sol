// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "./utils/Constants.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract BinBookLiquidityTest is BaseTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    address flags;

    function setUp() public {
        deployArtifactsAndLabel();
        flags = address(uint160(HOOK_FLAGS));
        deployCodeTo("BinBook.sol:BinBook", abi.encode(poolManager), flags);
    }

    function test_revert_addLiquidityForUninitializedPool() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        vm.expectRevert(BaseCustomAccounting.PoolNotInitialized.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidityOnExpiredPastDeadline() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 1);

        vm.warp(block.timestamp + 100);
        vm.expectRevert(BaseCustomAccounting.ExpiredPastDeadline.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp - 10,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidityWithNativeValueForErc20Pool() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 1);

        vm.expectRevert(BaseCustomAccounting.InvalidNativeValue.selector);
        hook.addLiquidity{value: 1 ether}(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        assertEq(address(hook).balance, 0);
    }

    function test_revert_addLiquidityWithZeroAmounts() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 1);

        vm.expectRevert(BinBook.ZeroAmounts.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 0,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        assertEq(hook.getTotalShares(key.toId()), 0);
    }

    function test_revert_addLiquidityWithTicksNotAlignedToBins() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        vm.expectRevert(BinBook.TicksNotAlignedToBins.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 5,
                tickUpper: 15,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidityForTooMuchSlippage() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.expectRevert(BaseCustomAccounting.TooMuchSlippage.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 2 ether,
                amount1Min: 2 ether,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 10,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidityTickLowerBelowMinTick() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.expectRevert(BinBook.InvalidTickRange.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -887280,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidityTickUpperAboveMaxTick() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.expectRevert(BinBook.InvalidTickRange.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 887280,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidity_tickLowerEqualsTickUpper() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.expectRevert(BinBook.InvalidTickRange.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 60,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidity_tickLowerGreaterThanTickUpper() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.expectRevert(BinBook.InvalidTickRange.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 60,
                tickUpper: -60,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidity_zeroTickLowerZeroTickUpper() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.expectRevert(BinBook.InvalidTickRange.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_addLiquidity() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_100000, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 100000 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -115230,
                tickUpper: -115030,
                userInputSalt: bytes32(0)
            })
        );

        PoolId id = key.toId();
        uint256 total = hook.getTotalShares(id);
        uint256 userShares = hook.getShares(id, address(this));
        int24 cur = hook.currentBin(id);
        int24 min = hook.minBin(id);
        int24 max = hook.maxBin(id);

        console2.log("=== POOL STATE ===");
        console2.log("totalShares:", total);
        console2.log("userShares:", userShares);
        console2.log("currentBin:");
        console2.logInt(cur);
        console2.log("minBin:");
        console2.logInt(min);
        console2.log("maxBin:");
        console2.logInt(max);

        uint256 bal0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 bal1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        console2.log("token0 remaining:", bal0);
        console2.log("token1 remaining:", bal1);

        console2.log("=== PER-BIN LIQUIDITY ===");
        for (int24 i = min; i <= max; ++i) {
            uint128 liq = hook.liquidityOf(id, address(this), i);
            if (liq > 0) {
                console2.log("bin:");
                console2.logInt(i);
                console2.log("  L:", liq);
            }
        }
    }
}
