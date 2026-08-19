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

import {BinRatchet} from "../src/BinRatchet.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract BinRatchetTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    BinRatchet hook;
    PoolId poolId;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(uint160(HOOK_FLAGS));
        deployCodeTo("BinRatchet.sol:BinRatchet", abi.encode(poolManager), flags);
        hook = BinRatchet(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
    }

    function _approve() internal {
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function _add(uint256 a0, uint256 a1) internal returns (BalanceDelta delta) {
        delta = hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function _seed() internal {
        hook.setBinSize(poolKey, 60);
        _approve();
        _add(100 ether, 100 ether);
    }

    // ── permissions / config ─────────────────────────────────────────────

    function test_permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterInitialize && p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity && p.beforeSwap && p.beforeSwapReturnDelta);
        assertFalse(hook.RATCHET_ENABLED());
        assertEq(hook.DEFAULT_RAMP(), 10);
        assertEq(hook.DEFAULT_BINS_PER_SIDE(), 10);
    }

    function test_poolCreatorCaptured() public view {
        assertEq(hook.poolCreator(poolId), address(this));
    }

    function test_setBinSize_succeeds() public {
        vm.expectEmit(address(hook));
        emit BinRatchet.BinSizeSet(poolId, address(this), 60);
        hook.setBinSize(poolKey, 60);
        assertEq(hook.getBinSize(poolId), 60);
        assertTrue(hook.isConfigured(poolId));
    }

    function test_setBinSize_bounds() public {
        hook.setBinSize(poolKey, 1);
        assertEq(hook.getBinSize(poolId), 1);
    }

    function test_setBinSize_reverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BinRatchet.NotPoolCreator.selector);
        hook.setBinSize(poolKey, 60);

        vm.expectRevert(BinRatchet.InvalidBinSize.selector);
        hook.setBinSize(poolKey, 0);
        vm.expectRevert(BinRatchet.InvalidBinSize.selector);
        hook.setBinSize(poolKey, -10);
        vm.expectRevert(BinRatchet.InvalidBinSize.selector);
        hook.setBinSize(poolKey, 2001);

        hook.setBinSize(poolKey, 60);
        vm.expectRevert(BinRatchet.BinSizeAlreadySet.selector);
        hook.setBinSize(poolKey, 120);
    }

    function test_twoHooks_independentConfig() public {
        hook.setBinSize(poolKey, 60);
        (Currency c0, Currency c1) = deployCurrencyPair();
        address flags2 = address(uint160(HOOK_FLAGS) | (uint160(1) << 20));
        deployCodeTo("BinRatchet.sol:BinRatchet", abi.encode(poolManager), flags2);
        BinRatchet hook2 = BinRatchet(flags2);
        PoolKey memory key2 = PoolKey(c0, c1, 3000, 60, IHooks(address(hook2)));
        poolManager.initialize(key2, Constants.SQRT_PRICE_1_1);
        hook2.setBinSize(key2, 200);
        assertEq(hook.getBinSize(poolId), 60);
        assertEq(hook2.getBinSize(key2.toId()), 200);
    }

    // ── liquidity ────────────────────────────────────────────────────────

    function test_addLiquidity_basic() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        BalanceDelta delta = _add(1 ether, 1 ether);
        assertGt(hook.getTotalShares(poolId), 0);
        assertEq(hook.getShares(poolId, address(this)), hook.getTotalShares(poolId));
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0);
    }

    function test_addLiquidity_reverts_notConfigured() public {
        _approve();
        vm.expectRevert(BinRatchet.PoolNotConfigured.selector);
        _add(1 ether, 1 ether);
    }

    function test_addLiquidity_reverts_zero() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        vm.expectRevert(BinRatchet.ZeroAmounts.selector);
        _add(0, 0);
    }

    function test_addLiquidity_secondDeposit_increasesL() public {
        _seed();
        int24 cur = hook.currentBin();
        uint128 l1 = hook.liquidity(cur);
        _add(50 ether, 50 ether);
        assertGt(hook.liquidity(cur), l1);
    }

    function test_addLiquidity_twoUsers() public {
        _seed();
        uint256 s1 = hook.getShares(poolId, address(this));
        address user2 = address(0xBEEF);
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        vm.startPrank(user2);
        t0.mint(user2, 200 ether);
        t1.mint(user2, 200 ether);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);
        _add(100 ether, 100 ether);
        vm.stopPrank();
        assertEq(hook.getTotalShares(poolId), s1 + hook.getShares(poolId, user2));
        assertGt(hook.getShares(poolId, user2), 0);
    }

    function test_removeLiquidity_reverts() public {
        _seed();
        vm.expectRevert(BinRatchet.RemovalNotSupported.selector);
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: 1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function test_linearDecay_onBook() public {
        _seed();
        int24 cur = hook.currentBin();
        uint128 L0 = hook.liquidity(cur);
        uint128 L1 = hook.liquidity(cur + 1);
        assertGt(L0, L1);
        assertApproxEqAbs(uint256(L1) * 9, uint256(L0) * 8, 100);
        assertEq(hook.liquidity(cur + 9), 0);
    }

    // ── swap ─────────────────────────────────────────────────────────────

    function test_swap_revertsBeforeSeed() public {
        hook.setBinSize(poolKey, 60);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(1 ether, 0, false, poolKey, "", address(this), block.timestamp);
    }

    function test_swap_exactIn_movesPrice() public {
        _seed();
        uint160 before = hook.currentSqrtPriceX96();
        swapRouter.swapExactTokensForTokens(0.1 ether, 0, false, poolKey, "", address(this), block.timestamp);
        assertGt(hook.currentSqrtPriceX96(), before);
    }

    function test_swap_token0In_lowersPrice() public {
        _seed();
        uint160 before = hook.currentSqrtPriceX96();
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, poolKey, "", address(this), block.timestamp);
        assertLt(hook.currentSqrtPriceX96(), before);
    }

    function test_swap_doesNotChangeL() public {
        _seed();
        int24 cur = hook.currentBin();
        uint128 lBefore = hook.liquidity(cur);
        swapRouter.swapExactTokensForTokens(1 ether, 0, false, poolKey, "", address(this), block.timestamp);
        assertEq(hook.liquidity(cur), lBefore);
    }

    function test_swap_sameBlock_reverseWalksBack() public {
        _seed();
        uint160 start = hook.currentSqrtPriceX96();
        swapRouter.swapExactTokensForTokens(5 ether, 0, false, poolKey, "", address(this), block.timestamp);
        uint160 afterUp = hook.currentSqrtPriceX96();
        assertGt(afterUp, start);
        swapRouter.swapExactTokensForTokens(5 ether, 0, true, poolKey, "", address(this), block.timestamp);
        assertLt(hook.currentSqrtPriceX96(), afterUp);
    }
}
