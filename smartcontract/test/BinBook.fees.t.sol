// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Fee accrual and collection: distribution across overlapping ranges, `collectFees`
///         payouts, and the no-op paths (no position, already-collected).
contract BinBookFeesTest is BaseTest {
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
        hook.createPool(poolKey, Constants.SQRT_PRICE_1_1, 60);
    }

    function _approve() internal {
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function _addRange(uint256 a0, uint256 a1, int24 tickLower, int24 tickUpper) internal returns (BalanceDelta delta) {
        delta = hook.addLiquidity(
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

    function _bob() internal returns (address user2) {
        user2 = address(0xB0B);
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t0.mint(user2, 1_000 ether);
        t1.mint(user2, 1_000 ether);
        vm.startPrank(user2);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // ── distribution ────────────────────────────────────────────────────

    function test_fees_sameRange_splitByL() public {
        _approve();
        address bob = _bob();
        _addRange(0, 100 ether, -20 * 60, -5 * 60);
        vm.prank(bob);
        _addRange(0, 50 ether, -20 * 60, -5 * 60);

        int24 bin = -6;
        uint128 lAlice = hook.liquidityOf(poolId, address(this), bin);
        uint128 lBob = hook.liquidityOf(poolId, bob, bin);
        // See test_ramp_legacyPath_stillFloorsAtDefaultRamp: depositLBase's budget clamp can
        // trim the last bin(s) by a relative amount far smaller than the 2:1 ratio being tested.
        assertApproxEqRel(uint256(lAlice), uint256(lBob) * 2, 1e9);

        swapRouter.swapExactTokensForTokens(2 ether, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 a0,) = hook.pendingFees(poolId, address(this));
        (uint256 b0,) = hook.pendingFees(poolId, bob);
        assertGt(a0, 0);
        assertGt(b0, 0);
        assertApproxEqRel(a0, b0 * 2, 0.02e18);
    }

    function test_fees_onlyBinsTouchedEarn() public {
        _approve();
        address bob = _bob();
        _addRange(0, 100 ether, -30 * 60, -20 * 60);
        vm.prank(bob);
        _addRange(0, 100 ether, -8 * 60, 0);

        swapRouter.swapExactTokensForTokens(0.2 ether, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 a0,) = hook.pendingFees(poolId, address(this));
        (uint256 b0,) = hook.pendingFees(poolId, bob);
        assertEq(a0, 0);
        assertGt(b0, 0);
    }

    function test_fees_overlapAliceBob() public {
        _approve();
        address bob = _bob();
        _addRange(0, 100 ether, -30 * 60, -15 * 60);
        vm.prank(bob);
        _addRange(0, 100 ether, -20 * 60, 0);

        int24 overlap = -16;
        assertGt(hook.liquidityOf(poolId, address(this), overlap), 0);
        assertGt(hook.liquidityOf(poolId, bob, overlap), 0);
        assertEq(hook.liquidityOf(poolId, address(this), -2), 0);
        assertGt(hook.liquidityOf(poolId, bob, -2), 0);

        swapRouter.swapExactTokensForTokens(3 ether, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 a0,) = hook.pendingFees(poolId, address(this));
        (uint256 b0,) = hook.pendingFees(poolId, bob);
        assertGt(b0, a0);
        assertGt(a0 + b0, 0);
    }

    function test_fees_secondAddRealizesThenCollect() public {
        _approve();
        _addRange(0, 50 ether, -20 * 60, -5 * 60);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, poolKey, "", address(this), block.timestamp);
        (uint256 pending0,) = hook.pendingFees(poolId, address(this));
        _addRange(0, 50 ether, -20 * 60, -5 * 60);
        (uint256 still,) = hook.pendingFees(poolId, address(this));
        assertApproxEqAbs(still, pending0, 1);
        (uint256 got0,) = hook.collectFees(poolKey);
        assertApproxEqAbs(got0, pending0, 1);
    }

    // ── collectFees payout ──────────────────────────────────────────────

    function test_fees_collectPaysUser() public {
        _approve();
        _addRange(0, 100 ether, -20 * 60, -5 * 60);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 pending0,) = hook.pendingFees(poolId, address(this));
        assertGt(pending0, 0);

        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        uint256 before = t0.balanceOf(address(this));
        (uint256 got0, uint256 got1) = hook.collectFees(poolKey);
        assertEq(got0, pending0);
        assertEq(got1, 0);
        assertEq(t0.balanceOf(address(this)), before + got0);

        (uint256 after0,) = hook.pendingFees(poolId, address(this));
        assertEq(after0, 0);
    }

    function test_collectFees_emitsFeesCollected() public {
        _approve();
        _addRange(0, 100 ether, -20 * 60, -5 * 60);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 pending0, uint256 pending1) = hook.pendingFees(poolId, address(this));
        assertGt(pending0, 0);

        vm.expectEmit(address(hook));
        emit BinBook.FeesCollected(poolId, address(this), pending0, pending1);
        hook.collectFees(poolKey);
    }

    // ── no-op paths ──────────────────────────────────────────────────────

    /// @dev `BinBook.sol:293`: `if (!r.set) return (0, 0);` — a user who never opened a position
    ///      in this pool gets a clean no-op, not a revert.
    function test_collectFees_noPosition_returnsZeroWithoutRevert() public {
        address bob = _bob();

        vm.prank(bob);
        (uint256 got0, uint256 got1) = hook.collectFees(poolKey);

        assertEq(got0, 0);
        assertEq(got1, 0);
    }

    /// @dev `BinBook.sol:305`: `if (amount0 == 0 && amount1 == 0) return (0, 0);` — collecting
    ///      again immediately after a full collect is a clean no-op, not a double payout or a
    ///      revert on an empty settle.
    function test_collectFees_secondCall_returnsZeroWithoutRevert() public {
        _approve();
        _addRange(0, 100 ether, -20 * 60, -5 * 60);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 got0First,) = hook.collectFees(poolKey);
        assertGt(got0First, 0);

        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 bal0Before = t0.balanceOf(address(this));
        uint256 bal1Before = t1.balanceOf(address(this));

        (uint256 got0Second, uint256 got1Second) = hook.collectFees(poolKey);

        assertEq(got0Second, 0, "nothing left to collect");
        assertEq(got1Second, 0, "nothing left to collect");
        assertEq(t0.balanceOf(address(this)), bal0Before, "no second payout");
        assertEq(t1.balanceOf(address(this)), bal1Before, "no second payout");
    }
}
