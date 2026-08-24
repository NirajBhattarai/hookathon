// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {SwapMath} from "../src/libraries/SwapMath.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @dev Validates that BinBook's on-chain swap engine matches a pure-library simulation of
///      the same book state bit-exactly, plus general add/swap/remove/collect workflows.
contract BinBookSwapEngineTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    BinBook hook;
    PoolId poolId;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(uint160(HOOK_FLAGS));
        deployCodeTo("BinBook.sol:BinBook", abi.encode(poolManager), flags);
        hook = BinBook(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
    }

    function _approve() internal {
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function _add(uint256 a0, uint256 a1) internal {
        _addRange(a0, a1, 0, 0);
    }

    function _addRange(uint256 a0, uint256 a1, int24 tickLower, int24 tickUpper) internal {
        hook.addLiquidity(
            poolKey,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                userInputSalt: bytes32(0)
            })
        );
    }

    function _seed() internal {
        hook.setBinSize(poolKey, 60);
        _approve();
        _add(100 ether, 100 ether);
    }

    /// @dev Rebuild the on-chain book from public views so the library walker can simulate it.
    function _simulate() internal view returns (SwapMath.Bin[] memory bins, uint256 active, uint160 sqrtP) {
        int24 lo = hook.minBin(poolId);
        int24 hi = hook.maxBin(poolId);
        int24 size = hook.getBinSize(poolId);
        sqrtP = hook.currentSqrtPriceX96(poolId);
        int24 cur = hook.currentBin(poolId);

        bins = new SwapMath.Bin[](uint256(int256(hi - lo + 1)));
        for (uint256 i = 0; i < bins.length; ++i) {
            int24 idx = lo + int24(int256(i));
            int24 tickLo = idx * size;
            bins[i] = SwapMath.Bin({
                L: hook.liquidity(poolId, idx),
                sqrtLo: TickMath.getSqrtPriceAtTick(tickLo),
                sqrtHi: TickMath.getSqrtPriceAtTick(tickLo + size)
            });
            if (idx == cur) active = i;
        }
    }

    // Simulation scratch (stack-too-deep hygiene for non-IR builds).
    uint256 internal s_simOut;
    uint256 internal s_simUsed;
    uint256 internal s_simFee;

    function _sim(uint256 inAmt, bool zeroForOne) internal {
        (SwapMath.Bin[] memory bins, uint256 active, uint160 sqrtP) = _simulate();
        (uint256 out, uint256 used, uint256 fee,,) =
            SwapMath.swapExactInMulti(bins, sqrtP, active, inAmt, zeroForOne, 0, bins.length - 1, poolKey.fee);
        s_simOut = out;
        s_simUsed = used;
        s_simFee = fee;
    }

    // ── engine vs pure-library simulation ────────────────────────────────

    function test_swap_zeroForOne_matchesLibrarySimulation() public {
        _seed();
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 inAmt = 2 ether;
        uint256 sqrtP0 = hook.currentSqrtPriceX96(poolId);
        uint256 t0Before = t0.balanceOf(address(this));
        uint256 t1Before = t1.balanceOf(address(this));
        (uint256 fB0, uint256 fB1) = hook.pendingFees(poolId, address(this));
        uint256 feesBefore = fB0 + fB1;

        _sim(inAmt, true);
        swapRouter.swapExactTokensForTokens(inAmt, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 fA0, uint256 fA1) = hook.pendingFees(poolId, address(this));
        uint256 feesAfter = fA0 + fA1;

        assertEq(t0.balanceOf(address(this)), t0Before - inAmt, "trader pays gross input");
        assertEq(t1.balanceOf(address(this)) - t1Before, s_simOut, "output must match simulation exactly");
        assertEq(s_simUsed, inAmt, "simulation should consume all input");
        assertApproxEqAbs(feesAfter - feesBefore, s_simFee, 10, "LP fee growth ~= summed per-step fees");
        assertLt(hook.currentSqrtPriceX96(poolId), sqrtP0, "price moved down");
    }

    function test_swap_oneForZero_matchesLibrarySimulation() public {
        _seed();
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 inAmt = 2 ether;
        uint256 sqrtP0 = hook.currentSqrtPriceX96(poolId);
        uint256 t0Before = t0.balanceOf(address(this));
        uint256 t1Before = t1.balanceOf(address(this));
        (uint256 fB0, uint256 fB1) = hook.pendingFees(poolId, address(this));
        uint256 feesBefore = fB0 + fB1;

        _sim(inAmt, false);
        swapRouter.swapExactTokensForTokens(inAmt, 0, false, poolKey, "", address(this), block.timestamp);

        (uint256 fA0, uint256 fA1) = hook.pendingFees(poolId, address(this));
        uint256 feesAfter = fA0 + fA1;

        assertEq(t1.balanceOf(address(this)), t1Before - inAmt, "trader pays gross input");
        assertEq(t0.balanceOf(address(this)) - t0Before, s_simOut, "output must match simulation exactly");
        assertEq(s_simUsed, inAmt, "simulation should consume all input");
        assertApproxEqAbs(feesAfter - feesBefore, s_simFee, 10, "LP fee growth ~= summed per-step fees");
        assertGt(hook.currentSqrtPriceX96(poolId), sqrtP0, "price moved up");
    }

    function test_swap_throughEmptyGap_matchesLibrarySimulation() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        // First add fills ONLY [-25,-16]; bins [-15,-1] and spot stay empty.
        _addRange(0, 200 ether, -25 * 60, -15 * 60);

        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 inAmt = 3 ether;
        uint256 t1Before = t1.balanceOf(address(this));
        (uint256 fB0, uint256 fB1) = hook.pendingFees(poolId, address(this));
        uint256 feesBefore = fB0 + fB1;

        _sim(inAmt, true);
        swapRouter.swapExactTokensForTokens(inAmt, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 fA0, uint256 fA1) = hook.pendingFees(poolId, address(this));
        uint256 feesAfter = fA0 + fA1;

        assertEq(t1.balanceOf(address(this)) - t1Before, s_simOut, "gap-crossing output must match simulation");
        assertApproxEqAbs(feesAfter - feesBefore, s_simFee, 10, "empty bins charged nothing");
        assertLt(hook.currentBin(poolId), 0, "walked into far bins");
    }

    function test_swap_revertsWhenBookTooThin() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        _add(0.001 ether, 0.001 ether);

        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(1000 ether, 0, true, poolKey, "", address(this), block.timestamp);
    }

    // ── general workflows ────────────────────────────────────────────────

    function test_workflow_addSwapRemoveCollect() public {
        _seed();

        // Swap generates fees for the sole LP.
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, poolKey, "", address(this), block.timestamp);
        (uint256 pend0,) = hook.pendingFees(poolId, address(this));
        assertGt(pend0, 0);

        // Remove half the position; accrued fees are preserved.
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 shares = hook.getShares(poolId, address(this));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));

        hook.removeLiquidity(
            poolKey,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        assertEq(hook.getShares(poolId, address(this)), shares - shares / 2);
        assertEq(hook.getTotalShares(poolId), shares - shares / 2);
        assertGt(t0.balanceOf(address(this)), b0, "removal pays token0");
        assertGt(t1.balanceOf(address(this)), b1, "removal pays token1");

        // Fees earned before removal remain fully collectable.
        (uint256 got0, uint256 got1) = hook.collectFees(poolKey);
        assertEq(got0, pend0, "fees realized before burn are intact");
        assertEq(got1, 0, "zeroForOne swaps pay fees in token0 only");
        (uint256 after0,) = hook.pendingFees(poolId, address(this));
        assertEq(after0, 0);
    }

    function test_twoPools_swapsIndependent() public {
        _seed(); // pool A on this hook

        // Second pool on the SAME hook instance.
        (Currency c0b, Currency c1b) = deployCurrencyPair();
        PoolKey memory keyB = PoolKey(c0b, c1b, 3000, 60, IHooks(address(hook)));
        PoolId idB = keyB.toId();
        poolManager.initialize(keyB, Constants.SQRT_PRICE_1_1);
        hook.setBinSize(keyB, 120);
        MockERC20(Currency.unwrap(c0b)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1b)).approve(address(hook), type(uint256).max);
        hook.addLiquidity(
            keyB,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        uint160 priceA0 = hook.currentSqrtPriceX96(poolId);
        uint160 priceB0 = hook.currentSqrtPriceX96(idB);

        swapRouter.swapExactTokensForTokens(1 ether, 0, false, keyB, "", address(this), block.timestamp);

        assertGt(hook.currentSqrtPriceX96(idB), priceB0, "pool B moved");
        assertEq(hook.currentSqrtPriceX96(poolId), priceA0, "pool A untouched");
        assertEq(hook.getTotalShares(poolId), hook.getShares(poolId, address(this)));
        assertEq(hook.getTotalShares(idB), hook.getShares(idB, address(this)));
    }
}
