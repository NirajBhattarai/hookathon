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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract BinBookTest is BaseTest {
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

    function _add(uint256 a0, uint256 a1) internal returns (BalanceDelta delta) {
        return _addRange(a0, a1, 0, 0);
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
        assertEq(hook.DEFAULT_RAMP(), 10);
        assertEq(hook.DEFAULT_BINS_PER_SIDE(), 10);
    }

    function test_poolCreatorCaptured() public view {
        assertEq(hook.poolCreator(poolId), address(this));
    }

    function test_setBinSize_succeeds() public {
        vm.expectEmit(address(hook));
        emit BinBook.BinSizeSet(poolId, address(this), 60);
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
        vm.expectRevert(BinBook.NotPoolCreator.selector);
        hook.setBinSize(poolKey, 60);

        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.setBinSize(poolKey, 0);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.setBinSize(poolKey, -10);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.setBinSize(poolKey, 2001);

        hook.setBinSize(poolKey, 60);
        vm.expectRevert(BinBook.BinSizeAlreadySet.selector);
        hook.setBinSize(poolKey, 120);
    }

    function test_twoHooks_independentConfig() public {
        hook.setBinSize(poolKey, 60);
        (Currency c0, Currency c1) = deployCurrencyPair();
        address flags2 = address(uint160(HOOK_FLAGS) | (uint160(1) << 20));
        deployCodeTo("BinBook.sol:BinBook", abi.encode(poolManager), flags2);
        BinBook hook2 = BinBook(flags2);
        PoolKey memory key2 = PoolKey(c0, c1, 3000, 60, IHooks(address(hook2)));
        poolManager.initialize(key2, Constants.SQRT_PRICE_1_1);
        hook2.setBinSize(key2, 200);
        assertEq(hook.getBinSize(poolId), 60);
        assertEq(hook2.getBinSize(key2.toId()), 200);
    }

    // ── createPool gateway ───────────────────────────────────────────────

    function _altKey(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, fee, 60, IHooks(address(hook)));
    }

    function test_createPool_succeeds() public {
        PoolKey memory key2 = _altKey(500);
        PoolId id2 = key2.toId();

        vm.expectEmit(address(hook));
        emit BinBook.BinSizeSet(id2, address(this), 120);
        vm.expectEmit(address(hook));
        emit BinBook.PoolCreated(id2, address(this), key2, 120);
        hook.createPool(key2, Constants.SQRT_PRICE_1_1, 120);

        assertEq(hook.poolCreator(id2), address(this));
        assertEq(hook.getBinSize(id2), 120);
        assertTrue(hook.isConfigured(id2));
        assertTrue(hook.initializedPools(id2));
        assertEq(hook.currentSqrtPriceX96(id2), Constants.SQRT_PRICE_1_1);
    }

    function test_createPool_thenAddLiquidity_works() public {
        PoolKey memory key2 = _altKey(500);
        hook.createPool(key2, Constants.SQRT_PRICE_1_1, 60);

        _approve();
        hook.addLiquidity(
            key2,
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
        assertGt(hook.getTotalShares(key2.toId()), 0);
    }

    function test_createPool_reverts_invalidBinSize() public {
        PoolKey memory key2 = _altKey(500);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(key2, Constants.SQRT_PRICE_1_1, 0);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(key2, Constants.SQRT_PRICE_1_1, -10);
        vm.expectRevert(BinBook.InvalidBinSize.selector);
        hook.createPool(key2, Constants.SQRT_PRICE_1_1, 2001);
    }

    function test_createPool_reverts_unsortedCurrencies() public {
        PoolKey memory bad = PoolKey(currency1, currency0, 500, 60, IHooks(address(hook)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoolManager.CurrenciesOutOfOrderOrEqual.selector,
                Currency.unwrap(currency1),
                Currency.unwrap(currency0)
            )
        );
        hook.createPool(bad, Constants.SQRT_PRICE_1_1, 60);
    }

    function test_createPool_reverts_alreadyInitialized() public {
        PoolKey memory key2 = _altKey(500);
        hook.createPool(key2, Constants.SQRT_PRICE_1_1, 60);
        vm.expectRevert();
        hook.createPool(key2, Constants.SQRT_PRICE_1_1, 60);
    }

    function test_gateway_on_blocksDirectInitialize() public {
        hook.setGatewayRequired(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(BinBook.InitializeViaCreatePool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(_altKey(700), Constants.SQRT_PRICE_1_1);

        PoolKey memory key2 = _altKey(500);
        hook.createPool(key2, Constants.SQRT_PRICE_1_1, 60);
        assertTrue(hook.isConfigured(key2.toId()));
    }

    function test_setGateway_ownerOnly() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BinBook.Unauthorized.selector);
        hook.setGatewayRequired(true);
        assertFalse(hook.requireGateway());

        hook.setGatewayRequired(true);
        assertTrue(hook.requireGateway());
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
        vm.expectRevert(BinBook.PoolNotConfigured.selector);
        _add(1 ether, 1 ether);
    }

    function test_addLiquidity_reverts_zero() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        vm.expectRevert(BinBook.ZeroAmounts.selector);
        _add(0, 0);
    }

    function test_addLiquidity_secondDeposit_increasesL() public {
        _seed();
        int24 cur = hook.currentBin(poolId);
        uint128 l1 = hook.liquidity(poolId, cur);
        _add(50 ether, 50 ether);
        assertGt(hook.liquidity(poolId, cur), l1);
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

    function test_removeLiquidity_basic() public {
        _seed();
        uint256 sharesBefore = hook.getShares(poolId, address(this));
        uint256 supplyBefore = hook.getTotalShares(poolId);
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        uint256 bal0 = t0.balanceOf(address(this));
        uint256 bal1 = t1.balanceOf(address(this));

        hook.removeLiquidity(
            poolKey,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: sharesBefore / 2,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        assertEq(hook.getShares(poolId, address(this)), sharesBefore - sharesBefore / 2);
        assertEq(hook.getTotalShares(poolId), supplyBefore - sharesBefore / 2);
        assertGt(t0.balanceOf(address(this)), bal0);
        assertGt(t1.balanceOf(address(this)), bal1);

        vm.expectRevert(BinBook.InsufficientShares.selector);
        hook.removeLiquidity(
            poolKey,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: sharesBefore + 1,
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
        int24 cur = hook.currentBin(poolId);
        uint128 L0 = hook.liquidity(poolId, cur);
        uint128 L1 = hook.liquidity(poolId, cur + 1);
        assertGt(L0, L1);
        assertApproxEqAbs(uint256(L1) * 9, uint256(L0) * 8, 100);
        assertEq(hook.liquidity(poolId, cur + 9), 0);
    }

    function test_addLiquidity_range_expandsBookBelow() public {
        _seed();
        int24 cur = hook.currentBin(poolId);
        int24 minBefore = hook.minBin(poolId);
        uint128 spotL = hook.liquidity(poolId, cur);

        // 15 bins fully below spot: [-30, -15) * binSize, all token1.
        int24 lo = (cur - 30) * 60;
        int24 hi = (cur - 15) * 60;
        _addRange(0, 50 ether, lo, hi);

        assertLt(hook.minBin(poolId), minBefore);
        assertEq(hook.minBin(poolId), cur - 30);
        assertEq(hook.liquidity(poolId, cur), spotL);
        assertGt(hook.liquidity(poolId, cur - 16), 0);
        assertGt(hook.liquidity(poolId, cur - 30), 0);
        assertEq(hook.liquidity(poolId, cur - 14), 0);
    }

    function test_addLiquidity_range_expandsBookAbove() public {
        _seed();
        int24 cur = hook.currentBin(poolId);
        int24 maxBefore = hook.maxBin(poolId);

        int24 lo = (cur + 12) * 60;
        int24 hi = (cur + 22) * 60;
        _addRange(50 ether, 0, lo, hi);

        assertGt(hook.maxBin(poolId), maxBefore);
        assertEq(hook.maxBin(poolId), cur + 21);
        assertGt(hook.liquidity(poolId, cur + 12), 0);
        assertGt(hook.liquidity(poolId, cur + 21), 0);
        assertEq(hook.liquidity(poolId, cur + 11), 0);
    }

    function test_addLiquidity_range_closerGetsMoreL() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        int24 cur = 0;
        _addRange(0, 100 ether, (cur - 25) * 60, (cur - 15) * 60);
        assertGt(hook.liquidity(poolId, cur - 16), hook.liquidity(poolId, cur - 25));
    }

    function test_addLiquidity_range_farBinsGetL() public {
        _seed();
        int24 cur = hook.currentBin(poolId);
        // Default ramp is 10, so distance 20 used to be L = 0.
        // tickUpper is exclusive, so (cur-19)*60 fills through bin cur-20.
        _addRange(0, 20 ether, (cur - 25) * 60, (cur - 19) * 60);
        assertGt(hook.liquidity(poolId, cur - 20), 0);
        assertGt(hook.liquidity(poolId, cur - 25), 0);
    }

    function test_addLiquidity_range_firstDepositIncludesSpotWindow() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        _addRange(0, 50 ether, -30 * 60, -15 * 60);
        assertEq(hook.minBin(poolId), -30);
        assertEq(hook.maxBin(poolId), 9);
        assertEq(hook.currentBin(poolId), 0);
        assertEq(hook.liquidity(poolId, 0), 0);
        assertGt(hook.liquidity(poolId, -16), 0);
    }

    function test_addLiquidity_range_reverts_misaligned() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        vm.expectRevert(BinBook.TicksNotAlignedToBins.selector);
        _addRange(0, 1 ether, -181, -60);
    }

    function test_addLiquidity_range_reverts_tooManyBins() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        // 257 bins of size 60
        vm.expectRevert(BinBook.TooManyBins.selector);
        _addRange(0, 1 ether, -257 * 60, 0);
    }

    function test_addLiquidity_range_usdcOnlyWrongSide_reverts() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        // Above spot needs token0; USDC-only (token1) cannot fill it.
        vm.expectRevert();
        _addRange(0, 10 ether, 12 * 60, 22 * 60);
    }

    function test_swap_walksEmptyGapToFarBin() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        _addRange(0, 200 ether, -25 * 60, -15 * 60);
        uint160 before = hook.currentSqrtPriceX96(poolId);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, poolKey, "", address(this), block.timestamp);
        assertLt(hook.currentSqrtPriceX96(poolId), before);
        assertLt(hook.currentBin(poolId), 0);
    }

    // ── user ramp (addLiquidityWithRamp) ─────────────────────────────────

    function _rampParams(uint256 a0, uint256 a1, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (BaseCustomAccounting.AddLiquidityParams memory)
    {
        return BaseCustomAccounting.AddLiquidityParams({
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            tickLower: tickLower,
            tickUpper: tickUpper,
            userInputSalt: bytes32(0)
        });
    }

    function test_ramp_customRange_exactMinimumDistribution() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        // Bins [-5..4], cur = 0: distances below = |idx|, above = idx + 1 → farthest 5, min ramp 6.
        hook.addLiquidityWithRamp(poolKey, _rampParams(100 ether, 100 ether, -5 * 60, 5 * 60), 6);

        uint128 lBelow1 = hook.liquidity(poolId, -1);
        uint128 lSpot = hook.liquidity(poolId, 0);
        uint128 lBelow2 = hook.liquidity(poolId, -2);
        uint128 lAbove3 = hook.liquidity(poolId, 3);

        // ramp 6: L_i ∝ (6 - d) / 6 → d=1 bins tie at 5/6, d=2 gets 4/6, d=4 gets 2/6.
        assertEq(lBelow1, lSpot);
        assertEq(uint256(lBelow2) * 5, uint256(lBelow1) * 4);
        assertEq(uint256(lAbove3) * 5, uint256(lSpot) * 2);
        for (int24 i = -5; i <= 4; ++i) {
            assertGt(hook.liquidity(poolId, i), 0);
        }
    }

    function test_ramp_customRange_reverts_belowMinimum() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        vm.expectRevert(abi.encodeWithSelector(BinBook.InvalidRamp.selector, uint256(6)));
        hook.addLiquidityWithRamp(poolKey, _rampParams(100 ether, 100 ether, -5 * 60, 5 * 60), 5);
        assertEq(hook.getTotalShares(poolId), 0);
        assertEq(hook.liquidity(poolId, 0), 0);
    }

    function test_ramp_zero_reverts() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        vm.expectRevert(abi.encodeWithSelector(BinBook.InvalidRamp.selector, uint256(0)));
        hook.addLiquidityWithRamp(poolKey, _rampParams(100 ether, 100 ether, 0, 0), 0);
    }

    function test_ramp_defaultWindow_flatterThanLegacy() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        PoolKey memory keyB = _altKey(500);
        hook.createPool(keyB, Constants.SQRT_PRICE_1_1, 60);

        hook.addLiquidityWithRamp(poolKey, _rampParams(50 ether, 50 ether, 0, 0), 25);
        hook.addLiquidityWithRamp(keyB, _rampParams(50 ether, 50 ether, 0, 0), 10);

        // Seeded window spans cur - 10 .. cur + 9; edge bin sits at distance 10.
        int24 edge = hook.currentBin(poolId) - 10;
        assertGt(hook.liquidity(poolId, edge), 0);
        assertEq(hook.liquidity(keyB.toId(), edge), 0);
    }

    function test_ramp_legacyPath_stillFloorsAtDefaultRamp() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        // Narrow range needs only ramp 4, but the no-ramp path keeps the DEFAULT_RAMP = 10 floor.
        _addRange(100 ether, 100 ether, -3 * 60, 3 * 60);
        assertEq(hook.liquidity(poolId, -1), hook.liquidity(poolId, 0));
        assertEq(uint256(hook.liquidity(poolId, -3)) * 9, uint256(hook.liquidity(poolId, 0)) * 7);
    }

    // ── swap ─────────────────────────────────────────────────────────────

    function test_swap_revertsBeforeSeed() public {
        hook.setBinSize(poolKey, 60);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens(1 ether, 0, false, poolKey, "", address(this), block.timestamp);
    }

    function test_swap_exactIn_movesPrice() public {
        _seed();
        uint160 before = hook.currentSqrtPriceX96(poolId);
        swapRouter.swapExactTokensForTokens(0.1 ether, 0, false, poolKey, "", address(this), block.timestamp);
        assertGt(hook.currentSqrtPriceX96(poolId), before);
    }

    function test_swap_token0In_lowersPrice() public {
        _seed();
        uint160 before = hook.currentSqrtPriceX96(poolId);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, poolKey, "", address(this), block.timestamp);
        assertLt(hook.currentSqrtPriceX96(poolId), before);
    }

    function test_swap_doesNotChangeL() public {
        _seed();
        int24 cur = hook.currentBin(poolId);
        uint128 lBefore = hook.liquidity(poolId, cur);
        swapRouter.swapExactTokensForTokens(1 ether, 0, false, poolKey, "", address(this), block.timestamp);
        assertEq(hook.liquidity(poolId, cur), lBefore);
    }

    function test_swap_sameBlock_reverseWalksBack() public {
        _seed();
        uint160 start = hook.currentSqrtPriceX96(poolId);
        swapRouter.swapExactTokensForTokens(5 ether, 0, false, poolKey, "", address(this), block.timestamp);
        uint160 afterUp = hook.currentSqrtPriceX96(poolId);
        assertGt(afterUp, start);
        swapRouter.swapExactTokensForTokens(5 ether, 0, true, poolKey, "", address(this), block.timestamp);
        assertLt(hook.currentSqrtPriceX96(poolId), afterUp);
    }

    // ── fee shares ───────────────────────────────────────────────────────

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

    function test_fees_sameRange_splitByL() public {
        hook.setBinSize(poolKey, 60);
        _approve();
        address bob = _bob();
        _addRange(0, 100 ether, -20 * 60, -5 * 60);
        vm.prank(bob);
        _addRange(0, 50 ether, -20 * 60, -5 * 60);

        int24 bin = -6;
        uint128 lAlice = hook.liquidityOf(poolId, address(this), bin);
        uint128 lBob = hook.liquidityOf(poolId, bob, bin);
        assertApproxEqAbs(uint256(lAlice), uint256(lBob) * 2, 2);

        swapRouter.swapExactTokensForTokens(2 ether, 0, true, poolKey, "", address(this), block.timestamp);

        (uint256 a0,) = hook.pendingFees(poolId, address(this));
        (uint256 b0,) = hook.pendingFees(poolId, bob);
        assertGt(a0, 0);
        assertGt(b0, 0);
        assertApproxEqRel(a0, b0 * 2, 0.02e18);
    }

    function test_fees_onlyBinsTouchedEarn() public {
        hook.setBinSize(poolKey, 60);
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

    function test_fees_collectPaysUser() public {
        hook.setBinSize(poolKey, 60);
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

    function test_fees_overlapAliceBob() public {
        hook.setBinSize(poolKey, 60);
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
        hook.setBinSize(poolKey, 60);
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
}
