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
