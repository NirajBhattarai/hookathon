// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Constants} from "./utils/Constants.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {BinBook} from "../src/BinBook.sol";
import {SwapMath} from "../src/libraries/SwapMath.sol";
import {BinLayout} from "../src/libraries/BinLayout.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract BinBookSharesStressTest is BaseTest {
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

    function _createPool(int24 binSize) internal returns (PoolKey memory key, PoolId id, BinBook hook) {
        (Currency c0, Currency c1) = deployCurrencyPair();
        hook = BinBook(flags);
        key = PoolKey(c0, c1, 3000, 1, IHooks(address(hook)));
        id = key.toId();
        hook.createPool(key, Constants.SQRT_PRICE_1_1, binSize);
    }

    function _approveAndAdd(BinBook hook, PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 a0, uint256 a1)
        internal
        returns (BalanceDelta delta)
    {
        MockERC20(Currency.unwrap(key.currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        delta = hook.addLiquidity(
            key,
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

    function _swap(BinBook hook, PoolKey memory key, uint256 amountIn, bool zeroForOne) internal {
        MockERC20(Currency.unwrap(key.currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, key, "", address(this), block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                     A. EXACT SHARE VALUE (4 UNIT TESTS)
    //////////////////////////////////////////////////////////////*/

    function test_singleBin_balancedBudget() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);
        _approveAndAdd(hook, key, 0, 60, 100 ether, 100 ether);
        assertGt(hook.getTotalShares(id), 0, "totalShares should be > 0");
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id), "sole depositor owns all");
    }

    function test_singleBin_priceAtLowerEdge() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(10);
        int24 tickLower = -100;
        int24 tickUpper = -90;
        _approveAndAdd(hook, key, tickLower, tickUpper, 100 ether, 100 ether);
        assertGt(hook.getTotalShares(id), 0, "totalShares should be > 0");
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id), "sole depositor owns all");
    }

    function test_singleBin_priceAtUpperEdge() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(10);
        int24 tickLower = 90;
        int24 tickUpper = 100;
        _approveAndAdd(hook, key, tickLower, tickUpper, 100 ether, 100 ether);
        assertGt(hook.getTotalShares(id), 0, "totalShares should be > 0");
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id), "sole depositor owns all");
    }

    function test_multiBin_wideRange() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);
        int24 tickLower = -12 * 60;
        int24 tickUpper = 12 * 60;
        _approveAndAdd(hook, key, tickLower, tickUpper, 100 ether, 100 ether);
        assertGt(hook.getTotalShares(id), 0, "totalShares should be > 0");
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id), "sole depositor owns all");
    }

    /*//////////////////////////////////////////////////////////////
                     B. BUDGET STRESS (3 UNIT TESTS)
    //////////////////////////////////////////////////////////////*/

    function test_dustBudget() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);
        _approveAndAdd(hook, key, 0, 60, 1e3, 1e3);
        assertGt(hook.getTotalShares(id), 0, "shares should be > 0 even for dust");
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id), "sole depositor owns all");
    }

    function test_extremeImbalance() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);
        _approveAndAdd(hook, key, 0, 60, 1 ether, 100_000 ether);
        assertGt(hook.getTotalShares(id), 0, "totalShares should be > 0");
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id), "sole depositor owns all");
    }

    function test_zeroOneSide() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);
        _approveAndAdd(hook, key, 0, 60, 100 ether, 0);
        assertGt(hook.getTotalShares(id), 0, "totalShares should be > 0");
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id), "sole depositor owns all");
    }

    /*//////////////////////////////////////////////////////////////
                    C. ROUND-TRIP INVARIANT (2 UNIT TESTS)
    //////////////////////////////////////////////////////////////*/

    function test_roundTrip_burnAll_recoverTokens() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);
        MockERC20 t0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(key.currency1));

        t0.mint(address(this), 1_000 ether);
        t1.mint(address(this), 1_000 ether);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        uint256 bal0Before = t0.balanceOf(address(this));
        uint256 bal1Before = t1.balanceOf(address(this));

        _approveAndAdd(hook, key, 0, 60, 100 ether, 100 ether);
        uint256 totalShares = hook.getShares(id, address(this));
        assertGt(totalShares, 0, "should have shares after deposit");

        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: totalShares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );

        assertEq(hook.getShares(id, address(this)), 0, "shares should be 0 after burn all");
        assertEq(t0.balanceOf(address(this)), bal0Before, "token0 fully recovered");
        assertEq(t1.balanceOf(address(this)), bal1Before, "token1 fully recovered");
    }

    function test_roundTrip_burnHalf_recoverHalf() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);
        MockERC20 t0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(key.currency1));

        t0.mint(address(this), 1_000 ether);
        t1.mint(address(this), 1_000 ether);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        _approveAndAdd(hook, key, -60, 60, 100 ether, 100 ether);
        uint256 totalShares = hook.getShares(id, address(this));
        uint256 halfShares = totalShares / 2;

        uint256 bal0Before = t0.balanceOf(address(this));
        uint256 bal1Before = t1.balanceOf(address(this));

        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: halfShares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -60,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );

        uint256 received0 = t0.balanceOf(address(this)) - bal0Before;
        uint256 received1 = t1.balanceOf(address(this)) - bal1Before;

        assertEq(hook.getShares(id, address(this)), totalShares - halfShares, "half shares burned");
        assertGt(received0, 0, "received some token0");
        assertGt(received1, 0, "received some token1");
    }

    /*//////////////////////////////////////////////////////////////
                           D. FUZZ (2 TESTS)
    //////////////////////////////////////////////////////////////*/

    function testFuzz_sharesAlwaysPositive(uint24 binSizeRaw, uint256 a0, uint256 a1) public {
        uint24 binSize = uint24(bound(uint256(binSizeRaw), 10, 120));
        a0 = bound(a0, 1e3, 1e24);
        a1 = bound(a1, 1e3, 1e24);

        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(int24(binSize));

        _approveAndAdd(hook, key, 0, int24(binSize), a0, a1);
        assertGt(hook.getTotalShares(id), 0, "totalShares > 0");
        assertEq(hook.getShares(id, address(this)), hook.getTotalShares(id));
    }

    function testFuzz_proportionalWithdraw(uint256 a0, uint256 a1, uint256 burnPct) public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);
        MockERC20 t0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(key.currency1));

        a0 = bound(a0, 1e6, 1e22);
        a1 = bound(a1, 1e6, 1e22);
        burnPct = bound(burnPct, 10, 90);

        t0.mint(address(this), a0);
        t1.mint(address(this), a1);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );

        uint256 totalShares = hook.getShares(id, address(this));
        vm.assume(totalShares > 0);

        uint256 toBurn = totalShares * burnPct / 100;
        vm.assume(toBurn > 0 && toBurn <= totalShares);

        uint256 bal0Before = t0.balanceOf(address(this));
        uint256 bal1Before = t1.balanceOf(address(this));

        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: toBurn,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );

        uint256 received0 = t0.balanceOf(address(this)) - bal0Before;
        uint256 received1 = t1.balanceOf(address(this)) - bal1Before;

        assertEq(hook.getShares(id, address(this)), totalShares - toBurn);
        assertApproxEqRel(received0, t0.balanceOf(address(this)) == bal0Before ? 1 : received0, 1e4, "received0");
    }

    /// @dev Regression: full withdrawal (100% of a sole depositor's shares) must never revert.
    ///      `_getAmountOut` recomputes a position's token amounts fresh from its L via
    ///      `tokenAmountsForBin`, while `depositLBase` derives what was actually taken in by
    ///      proportionally scaling a shared per-bin reference — the two paths can drift apart by
    ///      a few wei under floor rounding, and a full-burn withdrawal (where the drift isn't
    ///      masked by only burning a fraction) could try to pull more claim tokens out than the
    ///      hook actually held, underflowing. `testFuzz_proportionalWithdraw` above deliberately
    ///      excludes the 100% case (bounds burnPct to [10, 90]); this test fuzzes exactly that
    ///      edge across a range of deposit sizes and bin granularities.
    function testFuzz_fullWithdraw_neverReverts(uint24 binSizeRaw, uint256 a0, uint256 a1) public {
        uint24 binSize = uint24(bound(uint256(binSizeRaw), 10, 120));
        a0 = bound(a0, 1e6, 1e24);
        a1 = bound(a1, 1e6, 1e24);

        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(int24(binSize));
        MockERC20 t0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(key.currency1));

        _approveAndAdd(hook, key, 0, int24(binSize), a0, a1);
        uint256 totalShares = hook.getShares(id, address(this));
        vm.assume(totalShares > 0);

        uint256 bal0Before = t0.balanceOf(address(this));
        uint256 bal1Before = t1.balanceOf(address(this));

        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: totalShares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: int24(binSize),
                userInputSalt: bytes32(0)
            })
        );

        assertEq(hook.getShares(id, address(this)), 0, "shares should be 0 after full burn");
        // Never pays out more than what this depositor put in — the invariant the claim-balance
        // clamp in _getAmountOut exists to guarantee.
        assertLe(t0.balanceOf(address(this)) - bal0Before, a0, "received0 must not exceed spent");
        assertLe(t1.balanceOf(address(this)) - bal1Before, a1, "received1 must not exceed spent");
    }

    /*//////////////////////////////////////////////////////////////
                  E. STRESS EDGE CASES (2 TESTS)
    //////////////////////////////////////////////////////////////*/

    function test_twoDeposits_proportionalShares() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);

        _approveAndAdd(hook, key, 0, 60, 100 ether, 100 ether);
        uint256 aliceShares = hook.getShares(id, address(this));

        address bob = address(0xBEEF);
        MockERC20 t0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(key.currency1));
        t0.mint(bob, 400 ether);
        t1.mint(bob, 400 ether);
        vm.startPrank(bob);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 200 ether,
                amount1Desired: 200 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 60,
                userInputSalt: bytes32(0)
            })
        );
        vm.stopPrank();

        uint256 bobShares = hook.getShares(id, bob);
        assertGt(bobShares, aliceShares, "bob should have more shares");
        assertApproxEqRel(bobShares, aliceShares * 2, 1e4, "bob ~2x alice shares");
        assertEq(hook.getTotalShares(id), aliceShares + bobShares);
    }

    function test_depositAfterSwap_sharesStillCorrect() public {
        (PoolKey memory key, PoolId id, BinBook hook) = _createPool(60);

        _approveAndAdd(hook, key, 0, 60, 100 ether, 100 ether);
        uint256 sharesBefore = hook.getShares(id, address(this));

        _swap(hook, key, 50 ether, false);

        _approveAndAdd(hook, key, 0, 60, 50 ether, 50 ether);

        uint256 totalAfter = hook.getTotalShares(id);
        assertGt(totalAfter, sharesBefore, "totalShares increased after second deposit");
        assertEq(hook.getShares(id, address(this)), totalAfter, "sole depositor owns all");
    }

    /// @dev Regression: two one-sided deposits of *equal real value*, on opposite sides of a
    ///      100,000:1 price-skewed pair, must mint (roughly) equal shares. With the old
    ///      `shares = amount0 + amount1` formula, a token0-only deposit needs ~100,000x more raw
    ///      units than a token1-only deposit of the same real value (that's exactly what the
    ///      price ratio means) — so the old formula would have minted Bob ~100,000x more shares
    ///      than Carol for contributing the same value, purely because of which token he used.
    ///      This is magnitude-independent: it isolates the bug regardless of what the existing
    ///      pool's supply-to-value ratio happens to be at the time.
    function test_oneSidedDeposits_equalValue_opposingSides_mintEqualShares() public {
        BinBook hook = BinBook(flags);
        (Currency c0, Currency c1) = deployCurrencyPair();
        PoolKey memory key = PoolKey(c0, c1, 100, 1, IHooks(address(hook)));
        PoolId id = key.toId();
        // Same price skew as the meme-launch scenario (1 token0 : 100,000 token1).
        hook.createPool(key, Constants.SQRT_PRICE_1_100000, 10);

        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);

        // Alice: balanced bootstrap deposit straddling the active price, so supply > 0 for both
        // of the one-sided deposits below.
        _approveAndAdd(hook, key, -115230, -115030, 1 ether, 100_000 ether);

        // Bob: one-sided, entirely token0, into a range fully above the active price.
        address bob = address(0xB0B);
        MockERC20 token0 = MockERC20(Currency.unwrap(c0));
        token0.mint(bob, 1 ether);
        vm.startPrank(bob);
        token0.approve(address(hook), type(uint256).max);
        BalanceDelta bobDelta = hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1 ether,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -115030,
                tickUpper: -114930,
                userInputSalt: bytes32(0)
            })
        );
        vm.stopPrank();
        uint256 bobShares = hook.getShares(id, bob);
        uint256 bobAmount0 = uint256(uint128(-bobDelta.amount0()));
        assertEq(uint256(uint128(-bobDelta.amount1())), 0, "bob: one-sided, token0 only");

        // Carol: one-sided, entirely token1, into a range fully below the active price. At this
        // pool's price (1 token0 : 100,000 token1), `bobAmount0 / 100_000` of token1 is worth
        // the same as bob's whole deposit.
        address carol = address(0xCA401);
        MockERC20 token1 = MockERC20(Currency.unwrap(c1));
        uint256 carolAmount1Desired = bobAmount0 / 100_000;
        token1.mint(carol, carolAmount1Desired);
        vm.startPrank(carol);
        token1.approve(address(hook), type(uint256).max);
        BalanceDelta carolDelta = hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 0,
                amount1Desired: carolAmount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -115330,
                tickUpper: -115230,
                userInputSalt: bytes32(0)
            })
        );
        vm.stopPrank();
        uint256 carolShares = hook.getShares(id, carol);
        assertEq(uint256(uint128(-carolDelta.amount0())), 0, "carol: one-sided, token1 only");

        // Equal real value on opposite sides of the pair must mint (approximately) equal shares.
        // With the old amount0+amount1 formula this would be off by ~100,000x instead.
        assertApproxEqRel(bobShares, carolShares, 0.01e18, "equal-value deposits must mint equal shares");
    }

    /// @dev 50 independent LPs, mixed deposit shapes (balanced / token0-only / token1-only) and
    ///      sizes, no swaps in between — so the pool's shares-per-value exchange rate should
    ///      never drift between any two of them. Checks two things end to end:
    ///      1) every provider gets the same shares-per-value rate at mint time, regardless of
    ///         deposit shape or size (the bug this whole fix targets), and
    ///      2) withdrawing everyone afterward returns (approximately) what each one put in, with
    ///         nothing lost or created in aggregate.
    function test_fiftyProviders_fairSharesAndFullWithdrawal() public {
        BinBook hook = BinBook(flags);
        (Currency c0, Currency c1) = deployCurrencyPair();
        PoolKey memory key = PoolKey(c0, c1, 100, 1, IHooks(address(hook)));
        PoolId id = key.toId();
        // 100,000:1 price skew — exactly the shape that exposes the old amount0+amount1 bug.
        hook.createPool(key, Constants.SQRT_PRICE_1_100000, 10);

        MockERC20 token0 = MockERC20(Currency.unwrap(c0));
        MockERC20 token1 = MockERC20(Currency.unwrap(c1));
        uint160 price = hook.currentSqrtPriceX96(id); // fixed throughout: no swaps in this test
        uint256 priceX96 = FullMath.mulDiv(price, price, 2 ** 96);

        uint256 n = 50;
        address[] memory providers = new address[](n);
        uint256[] memory value = new uint256[](n);
        uint256[] memory shares = new uint256[](n);
        uint256[] memory spent0 = new uint256[](n);
        uint256[] memory spent1 = new uint256[](n);

        for (uint256 i = 0; i < n; ++i) {
            address user = address(uint160(0x10000 + i));
            providers[i] = user;
            uint256 scale = 1 + (i % 7); // 1x..7x size variation

            int24 tickLower;
            int24 tickUpper;
            uint256 a0;
            uint256 a1;
            uint256 mode = i % 3;
            if (mode == 0) {
                // balanced, straddling the active price
                tickLower = -115230;
                tickUpper = -115030;
                a0 = scale * 1 ether;
                a1 = scale * 100_000 ether;
            } else if (mode == 1) {
                // one-sided token0, range fully above the active price
                tickLower = -115030;
                tickUpper = -114930;
                a0 = scale * 1 ether;
                a1 = 0;
            } else {
                // one-sided token1, range fully below the active price
                tickLower = -115330;
                tickUpper = -115230;
                a0 = 0;
                a1 = scale * 1 ether / 100_000;
            }

            token0.mint(user, a0);
            token1.mint(user, a1);
            vm.startPrank(user);
            token0.approve(address(hook), type(uint256).max);
            token1.approve(address(hook), type(uint256).max);
            BalanceDelta delta = hook.addLiquidity(
                key,
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
            vm.stopPrank();

            spent0[i] = uint256(uint128(-delta.amount0()));
            spent1[i] = uint256(uint128(-delta.amount1()));
            value[i] = spent0[i] + FullMath.mulDiv(spent1[i], 2 ** 96, priceX96);
            shares[i] = hook.getShares(id, user);
            assertGt(shares[i], 0, "every provider must receive nonzero shares");
        }

        // 1) Fairness at mint time: shares-per-unit-value must be the same for everyone.
        uint256 refRatio = FullMath.mulDiv(shares[0], 1e18, value[0]);
        for (uint256 i = 1; i < n; ++i) {
            uint256 ratio = FullMath.mulDiv(shares[i], 1e18, value[i]);
            assertApproxEqRel(ratio, refRatio, 0.001e18, "every provider must get the same shares-per-value rate");
        }

        // 2) Withdraw everyone; each should recover (approximately) what they put in, and nothing
        //    should be lost or created in aggregate.
        for (uint256 i = 0; i < n; ++i) {
            address user = providers[i];
            uint256 bal0Before = token0.balanceOf(user);
            uint256 bal1Before = token1.balanceOf(user);

            vm.prank(user);
            hook.removeLiquidity(
                key,
                BaseCustomAccounting.RemoveLiquidityParams({
                    liquidity: shares[i],
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp,
                    tickLower: 0,
                    tickUpper: 0,
                    userInputSalt: bytes32(0)
                })
            );

            uint256 got0 = token0.balanceOf(user) - bal0Before;
            uint256 got1 = token1.balanceOf(user) - bal1Before;
            uint256 gotValue = got0 + FullMath.mulDiv(got1, 2 ** 96, priceX96);
            assertApproxEqRel(gotValue, value[i], 0.001e18, "withdrawal must return what this provider put in");
        }

        assertEq(hook.getTotalShares(id), 0, "all shares burned");
    }
}
