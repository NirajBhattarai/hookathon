// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract BinBookCreatePoolTest is BaseTest {
    using PoolIdLibrary for PoolKey;
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

    function _freshKey(BinBook hook) internal returns (PoolKey memory) {
        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        return
            PoolKey({
                currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
            });
    }

    function test_revert_createPoolWithUnSortedCurrencies() public {
        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key =
            PoolKey({currency0: currency1, currency1: currency0, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});

        vm.expectRevert(abi.encodeWithSelector(IPoolManager.CurrenciesOutOfOrderOrEqual.selector, currency1, currency0));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function test_revert_createPoolWithEqualCurrencies() public {
        Currency currencyA = deployCurrency();

        PoolKey memory key =
            PoolKey({currency0: currencyA, currency1: currencyA, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});

        vm.expectRevert(abi.encodeWithSelector(IPoolManager.CurrenciesOutOfOrderOrEqual.selector, currencyA, currencyA));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    function test_revert_createPoolTwiceOnSameKey() public {
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);
        int24 binSize = 100;

        hook.createPool(key, Constants.SQRT_PRICE_1_1, binSize);

        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        hook.createPool(key, Constants.SQRT_PRICE_1_1, binSize);
    }

    function test_revert_createPoolWithInvalidBinSize() public {
        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        BinBook hook = BinBook(flags);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 0);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(key, Constants.SQRT_PRICE_1_1, -10);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 2001);
    }

    function test_revert_createPoolWithBinSizeAtBoundaries() public {
        BinBook hook = BinBook(flags);

        PoolKey memory keyMin = _freshKey(hook);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(keyMin, Constants.SQRT_PRICE_1_1, type(int24).min);

        PoolKey memory keyMax = _freshKey(hook);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(keyMax, Constants.SQRT_PRICE_1_1, type(int24).max);

        PoolKey memory keyOver = _freshKey(hook);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(keyOver, Constants.SQRT_PRICE_1_1, 2001);

        // Exact valid boundaries must succeed.
        hook.createPool(_freshKey(hook), Constants.SQRT_PRICE_1_1, 1);
        hook.createPool(_freshKey(hook), Constants.SQRT_PRICE_1_1, 2_000);
    }

    function testFuzz_createPool_validBinSizeSucceeds(int24 binSize) public {
        binSize = int24(bound(int256(binSize), 1, 2_000));
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);

        hook.createPool(key, Constants.SQRT_PRICE_1_1, binSize);

        PoolId id = key.toId();
        (int24 storedBinSize,,,,,, uint160 storedSqrtPriceX96, bool seeded) = hook.books(id);
        assertEq(storedBinSize, binSize);
        assertEq(storedSqrtPriceX96, Constants.SQRT_PRICE_1_1, "starting sqrtPriceX96 stored as requested");
        assertFalse(seeded);
        assertTrue(hook.initializedPools(id));
    }

    function testFuzz_createPool_RevertWhen_invalidBinSize(int24 binSize) public {
        vm.assume(binSize <= 0 || binSize > 2_000);
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);

        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(key, Constants.SQRT_PRICE_1_1, binSize);
    }

    function test_createPoolWithValidArguments() public {
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);
        int24 binSize = 100;

        hook.createPool(key, Constants.SQRT_PRICE_1_1, binSize);

        PoolId id = key.toId();
        (int24 storedBinSize,,,,,, uint160 storedSqrtPriceX96, bool seeded) = hook.books(id);
        assertEq(storedBinSize, binSize);
        assertEq(storedSqrtPriceX96, Constants.SQRT_PRICE_1_1, "starting sqrtPriceX96 stored as requested");
        assertFalse(seeded);
        assertTrue(hook.initializedPools(id));
    }

    function test_fuzz_createPoolWithValidArguments(uint160 rawSqrtPriceX96, int24 binSize) public {
        binSize = int24(bound(int256(binSize), 1, 2_000));
        uint160 sqrtPriceX96 = uint160(bound(rawSqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);

        hook.createPool(key, sqrtPriceX96, binSize);

        PoolId id = key.toId();
        (int24 storedBinSize,,,,,, uint160 storedSqrtPriceX96, bool seeded) = hook.books(id);
        assertEq(storedBinSize, binSize);
        assertEq(storedSqrtPriceX96, sqrtPriceX96, "starting sqrtPriceX96 stored as requested");
        assertFalse(seeded);
        assertTrue(hook.initializedPools(id));
    }

    function testFuzz_createPool_poolCreatorAttribution(address caller) public {
        vm.assume(caller != address(0));
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);

        vm.prank(caller);
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 100);

        assertEq(hook.poolCreator(key.toId()), caller);
    }

    function test_directInitialize_alwaysReverts_gatewayIsPermanent() public {
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);
        PoolId id = key.toId();

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(BinBook.InitializeViaCreatePool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Nothing registered: the failed initialize rolled back entirely.
        assertFalse(hook.initializedPools(id));
        assertEq(hook.poolCreator(id), address(0));
        assertFalse(hook.initializedPools(key.toId()));
    }

    function test_revert_createPool_invalidHook_wrongHookAddress() public {
        BinBook hookA = BinBook(flags);

        // A second, distinct, validly-flagged hook instance — not the one createPool is called on.
        address flagsB = address(uint160(HOOK_FLAGS) | (uint160(1) << 20));
        deployCodeTo("BinBook.sol:BinBook", abi.encode(poolManager), flagsB);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(flagsB)});

        vm.expectRevert(BinBook.InvalidHook.selector);
        hookA.createPool(key, Constants.SQRT_PRICE_1_1, 10);
    }

    function test_revert_createPool_invalidHook_zeroAddress() public {
        BinBook hook = BinBook(flags);

        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(0))});

        vm.expectRevert(BinBook.InvalidHook.selector);
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);
    }

    /// @dev The two "equal/unsorted currencies" reverts above (lines 47-68) call
    ///      `poolManager.initialize` directly with `hooks: address(0)` — testing v4-core's own
    ///      validation, not BinBook's. This exercises BinBook's own currency-order check (the
    ///      same `if` branch that also catches unsorted currencies) through the real gateway.
    function test_revert_createPoolViaHook_withEqualCurrencies() public {
        BinBook hook = BinBook(flags);
        Currency currencyA = deployCurrency();

        PoolKey memory key = PoolKey({
            currency0: currencyA, currency1: currencyA, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        vm.expectRevert(abi.encodeWithSelector(IPoolManager.CurrenciesOutOfOrderOrEqual.selector, currencyA, currencyA));
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);
    }

    /// @dev Unlike the pair of direct `poolManager.initialize` tests above (which use
    ///      `hooks: address(0)` and test v4-core's own check), this drives BinBook's order check
    ///      through the real gateway with a genuinely *unsorted* (non-equal) pair.
    function test_revert_createPoolViaHook_withUnSortedCurrencies() public {
        BinBook hook = BinBook(flags);
        Currency currencyA = deployCurrency();
        Currency currencyB = deployCurrency();
        (Currency currency0, Currency currency1) =
            currencyA > currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        PoolKey memory key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 100, tickSpacing: 1, hooks: IHooks(address(hook))
        });

        vm.expectRevert(abi.encodeWithSelector(IPoolManager.CurrenciesOutOfOrderOrEqual.selector, currency0, currency1));
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 10);
    }

    function test_revert_createPoolWithInvalidSqrtPrice() public {
        BinBook hook = BinBook(flags);

        PoolKey memory keyZero = _freshKey(hook);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        hook.createPool(keyZero, uint160(0), 100);

        PoolKey memory keyTooLow = _freshKey(hook);
        uint160 sqrtTooLow = uint160(TickMath.MIN_SQRT_PRICE - 1);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, sqrtTooLow));
        hook.createPool(keyTooLow, sqrtTooLow, 100);

        // MAX_SQRT_PRICE is exclusive as a valid price (getTickAtSqrtPrice reverts at-or-above it).
        PoolKey memory keyAtMax = _freshKey(hook);
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, TickMath.MAX_SQRT_PRICE));
        hook.createPool(keyAtMax, TickMath.MAX_SQRT_PRICE, 100);

        PoolKey memory keyOverMax = _freshKey(hook);
        uint160 sqrtOverMax = TickMath.MAX_SQRT_PRICE + 1;
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, sqrtOverMax));
        hook.createPool(keyOverMax, sqrtOverMax, 100);
    }

    function test_createPool_sqrtPriceBoundaries_succeed() public {
        BinBook hook = BinBook(flags);

        hook.createPool(_freshKey(hook), TickMath.MIN_SQRT_PRICE, 100);
        hook.createPool(_freshKey(hook), TickMath.MAX_SQRT_PRICE - 1, 100);
    }

    function test_revert_createPoolWithInvalidTickSpacing() public {
        BinBook hook = BinBook(flags);

        PoolKey memory keyZero = _freshKey(hook);
        keyZero.tickSpacing = 0;
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector, int24(0)));
        hook.createPool(keyZero, Constants.SQRT_PRICE_1_1, 100);

        PoolKey memory keyNegative = _freshKey(hook);
        keyNegative.tickSpacing = -2;
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector, int24(-2)));
        hook.createPool(keyNegative, Constants.SQRT_PRICE_1_1, 100);

        PoolKey memory keyTooLarge = _freshKey(hook);
        keyTooLarge.tickSpacing = TickMath.MAX_TICK_SPACING + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IPoolManager.TickSpacingTooLarge.selector, TickMath.MAX_TICK_SPACING + 1)
        );
        hook.createPool(keyTooLarge, Constants.SQRT_PRICE_1_1, 100);
    }

    function test_revert_createPoolWithFeeTooLarge() public {
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);
        key.fee = uint24(LPFeeLibrary.MAX_LP_FEE) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, uint24(LPFeeLibrary.MAX_LP_FEE) + 1)
        );
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 100);
    }

    /// @dev The duplicate-key guard is keyed on the pool key, not the binSize request: re-creating
    ///      the same pool with a *different* binSize must still fail, locking binSize for the pool's
    ///      lifetime (mirrors Uniswap v4 tickSpacing / Trader Joe binStep semantics).
    function test_revert_createPoolTwice_differentBinSize_sameKey() public {
        BinBook hook = BinBook(flags);
        PoolKey memory key = _freshKey(hook);

        hook.createPool(key, Constants.SQRT_PRICE_1_1, 100);

        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 200);
    }

    /// @dev Asserts the rest of the book/accounting state createPool initializes, not just what the
    ///      existing fuzz tests check (binSize, sqrtPriceX96, seeded, initializedPools).
    function test_createPool_setsDefaultBookAndAccountingState() public {
        BinBook hook = BinBook(flags);
        address creator = makeAddr("creator");
        PoolKey memory key = _freshKey(hook);
        PoolId id = key.toId();
        int24 binSize = 100;
        uint160 sqrtPrice = Constants.SQRT_PRICE_1_1;

        vm.prank(creator);
        hook.createPool(key, sqrtPrice, binSize);

        (
            int24 storedBinSize,
            uint16 baseRamp,
            uint16 numBinsPerSide,
            int24 currentBin,
            int24 minBin,
            int24 maxBin,
            uint160 storedSqrtPriceX96,
            bool seeded
        ) = hook.books(id);
        assertEq(storedBinSize, binSize);
        assertEq(baseRamp, hook.DEFAULT_RAMP(), "baseRamp defaults to DEFAULT_RAMP");
        assertEq(numBinsPerSide, hook.DEFAULT_BINS_PER_SIDE(), "numBinsPerSide defaults to DEFAULT_BINS_PER_SIDE");
        assertEq(currentBin, 0, "currentBin starts at 0");
        assertEq(minBin, 0, "minBin starts at 0");
        assertEq(maxBin, 0, "maxBin starts at 0");
        assertEq(storedSqrtPriceX96, sqrtPrice);
        assertFalse(seeded, "book stays unseeded until the first deposit");
        assertEq(hook.totalShares(id), 0, "fresh pool has no shares outstanding");
        assertEq(hook.sharesOf(id, creator), 0, "fresh pool has no per-user shares");
    }
}
