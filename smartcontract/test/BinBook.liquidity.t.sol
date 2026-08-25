// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract BinBookLiquidityTest is BaseTest {
    using CurrencyLibrary for Currency;

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
                tickLower: 0,
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
                tickLower: 0,
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
                tickLower: 0,
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
                tickLower: 0,
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
}
