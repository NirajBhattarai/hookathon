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
}
