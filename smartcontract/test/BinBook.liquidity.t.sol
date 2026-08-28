// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "./utils/Constants.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BinBook} from "../src/BinBook.sol";
import {BinLayout} from "../src/libraries/BinLayout.sol";
import {SwapMath} from "../src/libraries/SwapMath.sol";
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

    receive() external payable {}

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

        vm.expectRevert(BinLayout.TicksNotAlignedToBins.selector);
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

        vm.expectRevert(BinLayout.InvalidTickRange.selector);
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

        vm.expectRevert(BinLayout.InvalidTickRange.selector);
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

        vm.expectRevert(BinLayout.InvalidTickRange.selector);
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

    function test_revert_addLiquidity_tickLowerEqualsTickUpper_negative() public {
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

        vm.expectRevert(BinLayout.InvalidTickRange.selector);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: -60,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_addLiquidityWithNativeValueForERC20Pool() public {
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

        vm.expectRevert(BinLayout.InvalidTickRange.selector);
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

        vm.expectRevert(BinLayout.InvalidTickRange.selector);
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

    /*//////////////////////////////////////////////////////////////
                        REMOVE LIQUIDITY REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates a pool and funds one position for address(this); returns the key and the
    ///      resulting share balance so revert tests can target boundaries (e.g. userShares + 1).
    function _setupPoolWithLiquidity(int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        returns (PoolKey memory key, uint256 userShares)
    {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                userInputSalt: salt
            })
        );

        userShares = hook.getShares(key.toId(), address(this));
    }

    function test_revert_removeLiquidityForUninitializedPool() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        vm.expectRevert(BaseCustomAccounting.PoolNotInitialized.selector);
        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_removeLiquidityOnExpiredPastDeadline() public {
        (PoolKey memory key,) = _setupPoolWithLiquidity(-60, 0, bytes32(0));
        BinBook hook = BinBook(flags);

        vm.warp(block.timestamp + 100);
        vm.expectRevert(BaseCustomAccounting.ExpiredPastDeadline.selector);
        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: 1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp - 10,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_removeLiquidityWithZeroShares() public {
        (PoolKey memory key,) = _setupPoolWithLiquidity(-60, 0, bytes32(0));
        BinBook hook = BinBook(flags);

        vm.expectRevert(BinBook.InsufficientShares.selector);
        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_removeLiquidityWithMoreSharesThanOwned() public {
        (PoolKey memory key, uint256 userShares) = _setupPoolWithLiquidity(-60, 0, bytes32(0));
        BinBook hook = BinBook(flags);

        vm.expectRevert(BinBook.InsufficientShares.selector);
        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: userShares + 1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_revert_removeLiquidityForTooMuchSlippage() public {
        (PoolKey memory key, uint256 userShares) = _setupPoolWithLiquidity(-60, 0, bytes32(0));
        BinBook hook = BinBook(flags);

        vm.expectRevert(BaseCustomAccounting.TooMuchSlippage.selector);
        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: userShares,
                amount0Min: type(uint128).max,
                amount1Min: type(uint128).max,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                        REMOVE LIQUIDITY SUCCESS
    //////////////////////////////////////////////////////////////*/

    /// @dev Sums a user's liquidity across every bin in [tickLower, tickUpper) at `binSize`.
    function _totalUserL(BinBook hook, PoolId id, address user, int24 tickLower, int24 tickUpper, int24 binSize)
        internal
        view
        returns (uint256 total)
    {
        int24 minB = tickLower / binSize;
        int24 maxB = tickUpper / binSize - 1;
        for (int24 idx = minB; idx <= maxB; ++idx) {
            total += hook.liquidityOf(id, user, idx);
        }
    }

    function test_removeLiquidity_partial_returnsProportionalTokensAndUpdatesState() public {
        (PoolKey memory key, uint256 userShares) = _setupPoolWithLiquidity(-60, 0, bytes32(0));
        BinBook hook = BinBook(flags);
        PoolId id = key.toId();

        uint256 lBefore = _totalUserL(hook, id, address(this), -60, 0, 10);
        uint256 totalSharesBefore = hook.getTotalShares(id);

        uint256 balance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));

        uint256 burnShares = userShares / 2;

        BalanceDelta delta = hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: burnShares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        // removeLiquidity's delta is positive (tokens flow to the caller) — unlike addLiquidity's
        // negative delta — see BaseCustomAccounting.sol:211-217.
        uint256 received0 = uint256(uint128(delta.amount0()));
        uint256 received1 = uint256(uint128(delta.amount1()));

        assertEq(
            MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this)) - balance0Before,
            received0,
            "token0 received == delta"
        );
        assertEq(
            MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(this)) - balance1Before,
            received1,
            "token1 received == delta"
        );
        // The whole [-60, 0) range sits below the pool's tick-0 active price, so the deposit (and
        // every partial withdrawal from it) is entirely token1 — see
        // SwapMath.getTokenAmountsForBin's Case 2.
        assertEq(received0, 0, "range sits below active price: no token0 involved");
        assertGt(received1, 0, "partial withdrawal returns token1");

        assertEq(hook.getShares(id, address(this)), userShares - burnShares, "shares reduced by exactly burnShares");
        assertEq(hook.getTotalShares(id), totalSharesBefore - burnShares, "totalShares reduced by exactly burnShares");
        assertGt(hook.getShares(id, address(this)), 0, "position still has remaining shares");

        uint256 lAfter = _totalUserL(hook, id, address(this), -60, 0, 10);
        assertLt(lAfter, lBefore, "aggregate bin liquidity decreased");
        assertGt(lAfter, 0, "bin liquidity not fully drained by a partial withdrawal");
    }

    function test_removeLiquidity_full_drainsPositionAndReturnsAllTokens() public {
        (PoolKey memory key, uint256 userShares) = _setupPoolWithLiquidity(-60, 0, bytes32(0));
        BinBook hook = BinBook(flags);
        PoolId id = key.toId();

        uint256 balance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));

        BalanceDelta delta = hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: userShares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        uint256 received0 = uint256(uint128(delta.amount0()));
        uint256 received1 = uint256(uint128(delta.amount1()));

        assertEq(
            MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(this)) - balance0Before,
            received0,
            "token0 received == delta"
        );
        assertEq(
            MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(this)) - balance1Before,
            received1,
            "token1 received == delta"
        );
        assertGt(received1, 0, "full withdrawal returns token1");

        assertEq(hook.getShares(id, address(this)), 0, "all shares burned");
        assertEq(hook.getTotalShares(id), 0, "pool fully drained: no shares remain");
        assertEq(
            _totalUserL(hook, id, address(this), -60, 0, 10), 0, "aggregate bin liquidity fully drained"
        );

        // Sole depositor: the bins themselves (not just this user's slice) are empty too.
        for (int24 idx = -6; idx <= -1; ++idx) {
            assertEq(hook.liquidity(id, idx), 0, "no liquidity left in any bin after the sole depositor exits");
        }
    }

    function test_removeLiquidity_atExactSlippageMinimum_succeeds() public {
        (PoolKey memory key, uint256 userShares) = _setupPoolWithLiquidity(-60, 0, bytes32(0));
        BinBook hook = BinBook(flags);

        BaseCustomAccounting.RemoveLiquidityParams memory params = BaseCustomAccounting.RemoveLiquidityParams({
            liquidity: userShares,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            tickLower: -60,
            tickUpper: 0,
            userInputSalt: bytes32(0)
        });

        // Probe the deterministic payout with mins at 0, roll back, then replay with mins pinned
        // exactly to that payout — the boundary must succeed (TooMuchSlippage is a strict `<`,
        // not `<=`, per BaseCustomAccounting.sol:215-217).
        uint256 snapshot = vm.snapshotState();
        BalanceDelta probeDelta = hook.removeLiquidity(key, params);
        uint256 exactReceived0 = uint256(uint128(probeDelta.amount0()));
        uint256 exactReceived1 = uint256(uint128(probeDelta.amount1()));
        vm.revertToState(snapshot);

        params.amount0Min = exactReceived0;
        params.amount1Min = exactReceived1;

        BalanceDelta delta = hook.removeLiquidity(key, params);
        assertEq(uint256(uint128(delta.amount0())), exactReceived0, "payout matches the pinned minimum exactly");
        assertEq(uint256(uint128(delta.amount1())), exactReceived1, "payout matches the pinned minimum exactly");
    }

    /*//////////////////////////////////////////////////////////////
                        USER RANGE STALENESS
    //////////////////////////////////////////////////////////////*/

    /// @dev `BinLayout.increaseUserL` only ever widens `userRanges[user]` (min of mins, max of
    ///      maxes) — nothing shrinks it back when `_decreaseUserL` zeroes out every bin in it.
    ///      So a user who fully drains a position, then deposits again into a disjoint far-away
    ///      range, ends up with a `userRanges` span covering the whole gap between the two —
    ///      permanently. Every future collectFees/pendingFees/removeLiquidity for that user then
    ///      walks that entire stale span (cheaply skipping the empty bins, but still touching
    ///      every index). Bounded by the book's own MAX_BOOK_BINS cap, so not unbounded — but a
    ///      real, non-obvious, self-inflicted gas characteristic worth having on record.
    function test_userRanges_doesNotShrinkAfterFullDrain_thenUnionsWithDisjointRedeposit() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // First position: ticks -60..0 => bins -6..-1.
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

        (int24 minB1, int24 maxB1, bool set1) = hook.userRanges(id, address(this));
        assertEq(minB1, -6, "range lower bound at first deposit");
        assertEq(maxB1, -1, "range upper bound at first deposit");
        assertTrue(set1);

        // Fully drain it.
        uint256 shares = hook.getShares(id, address(this));
        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        assertEq(hook.getShares(id, address(this)), 0);
        for (int24 idx = -6; idx <= -1; ++idx) {
            assertEq(hook.liquidityOf(id, address(this), idx), 0, "bin drained");
        }

        // The range metadata survives the drain untouched, even though every bin in it is now
        // empty for this user.
        (int24 minB2, int24 maxB2, bool set2) = hook.userRanges(id, address(this));
        assertEq(minB2, -6, "stale lower bound survives a full drain");
        assertEq(maxB2, -1, "stale upper bound survives a full drain");
        assertTrue(set2, "range still reports set despite zero liquidity everywhere in it");

        // Depositing again into a disjoint, far-away range (ticks 940..1000 => bins 94..99)
        // unions with the stale range instead of starting fresh.
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 940,
                tickUpper: 1000,
                userInputSalt: bytes32(0)
            })
        );

        (int24 minB3, int24 maxB3,) = hook.userRanges(id, address(this));
        assertEq(minB3, -6, "old stale lower bound still anchors the union");
        assertEq(maxB3, 99, "range now spans the gap all the way to the new, disjoint position");

        // Correctness survives the stale span: pendingFees still resolves to zero, just at the
        // cost of walking the empty gap bins too.
        (uint256 p0, uint256 p1) = hook.pendingFees(id, address(this));
        assertEq(p0, 0);
        assertEq(p1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        USERINPUTSALT BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    /// @dev BinBook keys positions only by (poolId, user, binIndex) — userInputSalt (part of the
    ///      generic BaseCustomAccounting ABI) plays no role in position identity here. Two deposits
    ///      from the same user into the same range land in the same position and accumulate,
    ///      regardless of salt; a single removeLiquidity call (with yet another salt) drains both.
    ///      This test documents that behavior explicitly so it isn't silently assumed to isolate
    ///      positions the way per-salt keying would.
    function test_addLiquidity_differentSalts_sameRange_mergeIntoSamePosition() public {
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

        int24 tickLower = -60;
        int24 tickUpper = 60;

        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                userInputSalt: bytes32(uint256(1))
            })
        );

        PoolId id = key.toId();
        int24 bin = hook.currentBin(id);
        uint128 lAfterFirst = hook.liquidityOf(id, address(this), bin);
        uint256 sharesAfterFirst = hook.getShares(id, address(this));
        assertGt(lAfterFirst, 0, "first deposit landed");

        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                userInputSalt: bytes32(uint256(2))
            })
        );

        uint128 lAfterSecond = hook.liquidityOf(id, address(this), bin);
        uint256 sharesAfterSecond = hook.getShares(id, address(this));

        assertGt(lAfterSecond, lAfterFirst, "second deposit accumulated onto the same position, not a separate one");
        assertGt(sharesAfterSecond, sharesAfterFirst, "shares for the same owner grew");

        // A single withdrawal — using a third salt — drains both deposits: proof that
        // salt has no bearing on which liquidity a removeLiquidity call can reach either.
        uint256 totalShares = hook.getShares(id, address(this));
        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: totalShares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                userInputSalt: bytes32(uint256(3))
            })
        );

        assertEq(hook.liquidityOf(id, address(this), bin), 0, "withdrawal drains both salted deposits");
        assertEq(hook.getShares(id, address(this)), 0, "all shares burned in one call");
    }

    /*//////////////////////////////////////////////////////////////
                        BOOKEXPANDED EVENT
    //////////////////////////////////////////////////////////////*/

    function test_addLiquidity_firstDeposit_emitsBookExpanded() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // Pool starts at tick 0 => currentBin 0. The first deposit hits an unseeded book, which
        // pads out to DEFAULT_BINS_PER_SIDE on each side of cur regardless of the requested
        // window, as long as the window fits inside that default padding (BinLayout.expandBook).
        int24 defaultPad = int24(uint24(hook.DEFAULT_BINS_PER_SIDE()));
        int24 expectedMin = 0 - defaultPad;
        int24 expectedMax = 0 + defaultPad - 1;

        vm.expectEmit(address(hook));
        emit BinBook.BookExpanded(id, expectedMin, expectedMax);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );

        assertEq(hook.minBin(id), expectedMin, "book padded to default lower bound");
        assertEq(hook.maxBin(id), expectedMax, "book padded to default upper bound");
    }

    function test_addLiquidity_withinExistingBounds_doesNotEmitBookExpanded() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // Seeds the book at [-10, 9] (default padding around cur = 0).
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );

        int24 minBefore = hook.minBin(id);
        int24 maxBefore = hook.maxBin(id);

        // Second deposit's window (ticks -20..20 => bins -2..1) sits entirely inside the
        // already-seeded book, so expandBook must be a no-op — no BookExpanded this time.
        vm.recordLogs();
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -20,
                tickUpper: 20,
                userInputSalt: bytes32(0)
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 bookExpandedTopic = keccak256("BookExpanded(bytes32,int24,int24)");
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != bookExpandedTopic, "no BookExpanded on a deposit within existing bounds");
        }

        assertEq(hook.minBin(id), minBefore, "book lower bound unchanged");
        assertEq(hook.maxBin(id), maxBefore, "book upper bound unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                        NATIVE CURRENCY POOL
    //////////////////////////////////////////////////////////////*/

    function test_addLiquidity_nativeCurrency_pullsCorrectAmountAndRefundsExcess() public {
        BinBook hook = BinBook(flags);

        Currency currency0 = CurrencyLibrary.ADDRESS_ZERO;
        Currency currency1 = deployCurrency();

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);

        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        vm.deal(address(this), 10 ether);
        uint256 ethBefore = address(this).balance;
        uint256 token1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // Send more native value than amount0Desired to exercise the refund path
        // (BaseCustomAccounting.sol:169-177).
        BalanceDelta delta = hook.addLiquidity{value: 2 ether}(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );

        uint256 spent0 = uint256(uint128(-delta.amount0()));
        uint256 spent1 = uint256(uint128(-delta.amount1()));
        assertGt(spent0, 0, "active price sits inside range: native leg required");
        assertGt(spent1, 0, "active price sits inside range: token1 leg required");
        assertLe(spent0, 1 ether, "never overspends amount0Desired");

        assertEq(
            ethBefore - address(this).balance, spent0, "only the actual native spend left the caller; excess refunded"
        );
        assertEq(
            token1Before - MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)),
            spent1,
            "token1 pulled == delta"
        );

        PoolId id = key.toId();
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id), "sole depositor owns 100% of shares");
    }

    /*//////////////////////////////////////////////////////////////
                        SLIPPAGE BOUNDARY
    //////////////////////////////////////////////////////////////*/

    function test_addLiquidity_atExactSlippageMinimum_succeeds() public {
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

        BaseCustomAccounting.AddLiquidityParams memory params = BaseCustomAccounting.AddLiquidityParams({
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            tickLower: -60,
            tickUpper: 60,
            userInputSalt: bytes32(0)
        });

        // Probe the deterministic spend with mins at 0, roll back, then replay with mins pinned
        // exactly to that spend — the boundary must succeed (TooMuchSlippage is a strict `<`,
        // not `<=`, per BaseCustomAccounting.sol:165-167).
        uint256 snapshot = vm.snapshotState();
        BalanceDelta probeDelta = hook.addLiquidity(key, params);
        uint256 exactSpent0 = uint256(uint128(-probeDelta.amount0()));
        uint256 exactSpent1 = uint256(uint128(-probeDelta.amount1()));
        vm.revertToState(snapshot);

        params.amount0Min = exactSpent0;
        params.amount1Min = exactSpent1;

        BalanceDelta delta = hook.addLiquidity(key, params);
        assertEq(uint256(uint128(-delta.amount0())), exactSpent0, "spend matches the pinned minimum exactly");
        assertEq(uint256(uint128(-delta.amount1())), exactSpent1, "spend matches the pinned minimum exactly");
    }

    /*//////////////////////////////////////////////////////////////
                        MAX_BINS_PER_ADD BOUNDARY
    //////////////////////////////////////////////////////////////*/

    function test_addLiquidity_exactlyMaxBinsPerAdd_succeeds() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        int24 binSize = 10;
        hook.createPool(key, Constants.SQRT_PRICE_1_1, binSize);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // 64 bins exactly: [0, 63] (bins 0..MAX_BINS_PER_ADD-1).
        uint16 maxBins = BinLayout.MAX_BINS_PER_ADD;
        int24 tickLower = 0;
        int24 tickUpper = int24(uint24(maxBins)) * binSize;

        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                userInputSalt: bytes32(0)
            })
        );

        PoolId id = key.toId();
        int24 userMin = tickLower / binSize;
        int24 userMax = tickUpper / binSize - 1;
        assertEq(uint256(int256(userMax - userMin + 1)), maxBins, "sanity: window is exactly MAX_BINS_PER_ADD wide");

        for (int24 idx = userMin; idx <= userMax; ++idx) {
            assertGt(hook.liquidity(id, idx), 0, "every one of the 64 requested bins received liquidity");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        WIDENING AN EXISTING POSITION
    //////////////////////////////////////////////////////////////*/

    function test_addLiquidity_widenRange_growsOldBinsAndFundsNewOnes() public {
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

        PoolId id = key.toId();

        // Narrow deposit first: ticks -20..20 => bins -2..1.
        int24 narrowLower = -20;
        int24 narrowUpper = 20;
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: narrowLower,
                tickUpper: narrowUpper,
                userInputSalt: bytes32(0)
            })
        );

        int24 narrowMin = narrowLower / 10;
        int24 narrowMax = narrowUpper / 10 - 1;
        uint128[] memory lBefore = new uint128[](uint256(int256(narrowMax - narrowMin + 1)));
        for (int24 idx = narrowMin; idx <= narrowMax; ++idx) {
            lBefore[uint256(int256(idx - narrowMin))] = hook.liquidityOf(id, address(this), idx);
        }

        // Wider deposit second: ticks -60..60 => bins -6..5, strictly containing the narrow range.
        int24 wideLower = -60;
        int24 wideUpper = 60;
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: wideLower,
                tickUpper: wideUpper,
                userInputSalt: bytes32(0)
            })
        );

        int24 wideMin = wideLower / 10;
        int24 wideMax = wideUpper / 10 - 1;

        // Old bins kept their prior liquidity and grew — the second deposit accumulated onto the
        // existing position rather than overwriting it.
        for (int24 idx = narrowMin; idx <= narrowMax; ++idx) {
            uint128 before = lBefore[uint256(int256(idx - narrowMin))];
            assertGt(hook.liquidityOf(id, address(this), idx), before, "old bin grew, not overwritten");
        }

        // Newly-covered bins outside the narrow range now carry liquidity too.
        for (int24 idx = wideMin; idx < narrowMin; ++idx) {
            assertGt(hook.liquidityOf(id, address(this), idx), 0, "new low-side bin funded");
        }
        for (int24 idx = narrowMax + 1; idx <= wideMax; ++idx) {
            assertGt(hook.liquidityOf(id, address(this), idx), 0, "new high-side bin funded");
        }

        // The user's tracked range now spans the full widened window.
        (int24 rMin, int24 rMax, bool set) = hook.userRanges(id, address(this));
        assertTrue(set);
        assertEq(rMin, wideMin, "user range lower bound widened");
        assertEq(rMax, wideMax, "user range upper bound widened");
    }

    /*//////////////////////////////////////////////////////////////
                        SINGLE-BIN RANGE
    //////////////////////////////////////////////////////////////*/

    function test_addLiquidity_singleBinRange_landsEntirelyInOneBin() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        int24 binSize = 10;
        // A price at tick 0 sits exactly on a bin boundary (0 is a multiple of every binSize),
        // which makes any range starting/ending there a one-sided edge deposit — not what this
        // test wants. SQRT_PRICE_101_100 lands at tick 99, strictly inside bin 9 (ticks [90,100)),
        // so both tokens are genuinely required.
        hook.createPool(key, Constants.SQRT_PRICE_101_100, binSize);

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // tickUpper - tickLower == binSize: exactly one bin, and it's the active-price bin.
        int24 tickLower = 90;
        int24 tickUpper = 100;

        BalanceDelta delta = hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                userInputSalt: bytes32(0)
            })
        );

        PoolId id = key.toId();
        int24 theBin = tickLower / binSize;
        assertEq(hook.minBin(id) <= theBin && theBin <= hook.maxBin(id), true, "book covers the single bin");

        uint256 spent0 = uint256(uint128(-delta.amount0()));
        uint256 spent1 = uint256(uint128(-delta.amount1()));
        assertGt(spent0, 0, "active price inside the single bin: token0 required");
        assertGt(spent1, 0, "active price inside the single bin: token1 required");

        assertGt(hook.liquidity(id, theBin), 0, "the single bin received liquidity");
        assertEq(
            hook.liquidityOf(id, address(this), theBin),
            hook.liquidity(id, theBin),
            "sole depositor owns all L in the single bin"
        );

        // No liquidity leaked into neighboring bins.
        assertEq(hook.liquidityOf(id, address(this), theBin - 1), 0, "no liquidity below the requested bin");
        assertEq(hook.liquidityOf(id, address(this), theBin + 1), 0, "no liquidity above the requested bin");
    }

    function test_addLiquidity_memeLaunch_spreadsAcrossBins() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        hook.createPool(key, Constants.SQRT_PRICE_1_100000, 10);

        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        int24 tickLower = -115230;
        int24 tickUpper = -115030;

        BalanceDelta delta = hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 100000 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                userInputSalt: bytes32(0)
            })
        );

        PoolId id = key.toId();

        uint256 spent0 = uint256(uint128(-delta.amount0()));
        uint256 spent1 = uint256(uint128(-delta.amount1()));
        assertEq(balance0Before - token0.balanceOf(address(this)), spent0, "token0 pulled == delta");
        assertEq(balance1Before - token1.balanceOf(address(this)), spent1, "token1 pulled == delta");

        assertGt(spent0, 0, "active price sits inside range: token0 required");
        assertGt(spent1, 0, "active price sits inside range: token1 required");

        // depositLBase clamps each bin's contribution against remaining budget, so spend can
        // never exceed what was authorized (see BinLayout.depositLBase) — no fudge factor needed.
        assertLe(spent0, 1 ether, "never overspends amount0Desired");
        assertLe(spent1, 100_000 ether, "never overspends amount1Desired");

        // 2) Shares: sole depositor owns everything. Bootstrap shares are minted from this
        // deposit's value (spent1 converted to token0-equivalent terms via the pool's live
        // price), not the raw amount0+amount1 sum — see SwapMath.getMintShares.
        uint256 total = hook.getTotalShares(id);
        uint256 userShares = hook.getShares(id, address(this));
        assertEq(userShares, total, "sole depositor owns 100% of shares");
        uint256 expectedShares = SwapMath.getMintShares(spent0, spent1, 0, 0, hook.currentSqrtPriceX96(id), 0);
        assertEq(total, expectedShares, "shares == deposit value at the live price");

        int24 binSize = 10;

        // 3) Book expanded to at least cover the requested tick range.
        int24 userMin = tickLower / binSize;
        int24 userMax = tickUpper / binSize - 1;
        int24 cur = hook.currentBin(id);
        int24 min = hook.minBin(id);
        int24 max = hook.maxBin(id);
        assertLe(min, userMin, "book covers requested lower bound");
        assertGe(max, userMax, "book covers requested upper bound");
        assertTrue(cur >= userMin && cur <= userMax, "active bin sits inside the requested range");

        // 4) Liquidity actually landed in every requested bin, credited solely to us.
        for (int24 idx = userMin; idx <= userMax; ++idx) {
            uint128 binL = hook.liquidity(id, idx);
            assertGt(binL, 0, "every requested bin received liquidity");
            assertEq(hook.liquidityOf(id, address(this), idx), binL, "sole depositor owns all L in the bin");
        }

        // 5) Ramp decay: bins near the active price get >= L than the far edges.
        uint128 centerL = hook.liquidityOf(id, address(this), cur);
        assertGe(centerL, hook.liquidityOf(id, address(this), userMin), "ramp decays toward the low edge");
        assertGe(centerL, hook.liquidityOf(id, address(this), userMax), "ramp decays toward the high edge");

        // 6) Fresh position: fee checkpoint initialized, nothing owed yet.
        (uint256 pending0, uint256 pending1) = hook.pendingFees(id, address(this));
        assertEq(pending0, 0, "no swaps yet: no fees accrued");
        assertEq(pending1, 0, "no swaps yet: no fees accrued");
    }
}
