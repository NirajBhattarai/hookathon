// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @title BinBook Frontend Flow Test
/// @notice Simulates what a user does from the Uniswap frontend:
///         create pool -> approve tokens -> add liquidity -> swap -> collect fees -> remove liquidity
contract BinBookFrontendTest is BaseTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

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
    }

    function _approve() internal {
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function _logBalances(string memory label) internal {
        uint256 bal0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 bal1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        console2.log(label);
        console2.log("  token0 balance:", bal0);
        console2.log("  token1 balance:", bal1);
    }

    function _logPoolState() internal {
        int24 cur = hook.currentBin(poolId);
        int24 min = hook.minBin(poolId);
        int24 max = hook.maxBin(poolId);
        uint256 total = hook.getTotalShares(poolId);
        uint256 shares = hook.getShares(poolId, address(this));
        console2.log("  currentBin:", cur);
        console2.log("  minBin:", min);
        console2.log("  maxBin:", max);
        console2.log("  totalShares:", total);
        console2.log("  myShares:", shares);
    }

    function _logPerBinL() internal {
        int24 min = hook.minBin(poolId);
        int24 max = hook.maxBin(poolId);
        int24 cur = hook.currentBin(poolId);
        (, uint16 ramp,,,,,,) = hook.books(poolId);
        console2.log("  ramp:", ramp);
        console2.log("  --- per-bin L ---");
        for (int24 i = min; i <= max; ++i) {
            uint128 liq = hook.liquidity(poolId, i);
            uint128 myL = hook.liquidityOf(poolId, address(this), i);
            if (liq > 0) {
                console2.logInt(i);
                console2.log("    Ltotal:", liq, " Lmine:", myL);
                if (i == cur) console2.log("    <--- SPOT");
            }
        }
    }

    function _currentBinFromPrice(uint160 sqrtPriceX96) internal pure returns (int24) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 binSize = 60;
        int24 q = tick / binSize;
        if (tick % binSize != 0 && tick < 0) q -= 1;
        return q;
    }

    // ── SCENARIO 1: Custom range near spot ────────────────────────────────

    /// @notice Scenario 1: User clicks "Add Liquidity" with a custom range around spot.
    ///         Must always specify explicit tickLower < tickUpper.
    function test_frontend_defaultRange_seedPool() public {
        console2.log("========================================");
        console2.log("SCENARIO 1: Custom range near spot");
        console2.log("========================================");

        _logBalances("BEFORE createPool");
        hook.createPool(poolKey, Constants.SQRT_PRICE_1_1, 60);
        console2.log("Pool created at 1:1 price");
        _logPoolState();

        _approve();
        _logBalances("AFTER approve, BEFORE addLiquidity");

        BalanceDelta delta = hook.addLiquidity(
            poolKey,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );

        console2.log("addLiquidity returned delta:");
        console2.log("  amount0 pulled:", delta.amount0());
        console2.log("  amount1 pulled:", delta.amount1());

        _logBalances("AFTER addLiquidity");
        _logPoolState();
        _logPerBinL();

        assertGt(hook.getTotalShares(poolId), 0);
        assertEq(hook.getShares(poolId, address(this)), hook.getTotalShares(poolId));
    }

    // ── SCENARIO 2: Tight symmetric range around spot ──────────────────────

    /// @notice Scenario 2: User drags the range slider to a tight range around spot.
    ///         Only ~4 bins on each side get funded. More concentrated = more L per bin.
    function test_frontend_tightRange() public {
        console2.log("========================================");
        console2.log("SCENARIO 2: Tight symmetric range");
        console2.log("========================================");

        hook.createPool(poolKey, Constants.SQRT_PRICE_1_1, 60);
        _approve();

        int24 cur = _currentBinFromPrice(Constants.SQRT_PRICE_1_1);
        int24 lo = (cur - 4) * 60; // 4 bins below
        int24 hi = (cur + 5) * 60; // 4 bins above
        console2.log("  actual currentBin:", cur);
        console2.log("  tickLower:", lo);
        console2.log("  tickUpper:", hi);

        // Now use the correct ticks around currentBin
        BalanceDelta delta = hook.addLiquidity(
            poolKey,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: lo,
                tickUpper: hi,
                userInputSalt: bytes32(0)
            })
        );

        console2.log("  amount0 pulled:", delta.amount0());
        console2.log("  amount1 pulled:", delta.amount1());

        _logPoolState();
        _logPerBinL();

        uint256 nonZero = 0;
        for (int24 i = hook.minBin(poolId); i <= hook.maxBin(poolId); ++i) {
            if (hook.liquidity(poolId, i) > 0) nonZero++;
        }
        console2.log("  non-zero bins:", nonZero);
    }

    // ── SCENARIO 3: Meme coin pool — 1 ETH = 100,000 MEME ─────────────────

    /// @notice Scenario 3: Full meme coin lifecycle.
    ///         Pool at SQRT_PRICE_1_100000. User adds liquidity with a wide range.
    ///         Then someone swaps, user earns fees, user removes liquidity.
    function test_frontend_memeCoin_fullLifecycle() public {
        console2.log("========================================");
        console2.log("SCENARIO 3: Meme coin (1 ETH = 100K MEME)");
        console2.log("========================================");

        console2.log("\n--- Step 1: Create Pool ---");
        hook.createPool(poolKey, 250541448375047936131727360, 10);

        int24 cur = hook.currentBin(poolId);
        console2.log("  Pool created, currentBin:", cur);

        console2.log("\n--- Step 2: Add Liquidity ---");
        _approve();
        _logBalances("  BEFORE addLiquidity");

        BalanceDelta delta = hook.addLiquidity(
            poolKey,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100_000 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -115230,
                tickUpper: -115030,
                userInputSalt: bytes32(0)
            })
        );

        console2.log("  MEME pulled (token0):", delta.amount0());
        console2.log("  ETH pulled (token1):", delta.amount1());

        _logBalances("  AFTER addLiquidity");
        _logPoolState();
        _logPerBinL();

        console2.log("\n--- Step 3: Swapper buys MEME ---");
        swapRouter.swapExactTokensForTokens(0.01 ether, 0, false, poolKey, "", address(this), block.timestamp);

        console2.log("  Swapper sent 0.01 ETH, received MEME");
        console2.log("  new currentBin:", hook.currentBin(poolId));

        console2.log("\n--- Step 4: Collect Fees ---");
        (uint256 pending0, uint256 pending1) = hook.pendingFees(poolId, address(this));
        console2.log("  pending MEME fees:", pending0);
        console2.log("  pending ETH fees:", pending1);

        if (pending0 > 0 || pending1 > 0) {
            (uint256 got0, uint256 got1) = hook.collectFees(poolKey);
            console2.log("  collected MEME:", got0);
            console2.log("  collected ETH:", got1);
        }

        _logBalances("  AFTER collectFees");

        console2.log("\n--- Step 5: Remove Liquidity ---");
        uint256 myShares = hook.getShares(poolId, address(this));
        console2.log("  shares to remove:", myShares);

        if (myShares > 0) {
            BalanceDelta removeDelta = hook.removeLiquidity(
                poolKey,
                BaseCustomAccounting.RemoveLiquidityParams({
                    liquidity: myShares,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp,
                    tickLower: -115230,
                    tickUpper: -115030,
                    userInputSalt: bytes32(0)
                })
            );
            console2.log("  MEME returned:", removeDelta.amount0());
            console2.log("  ETH returned:", removeDelta.amount1());
        }

        _logBalances("  AFTER removeLiquidity");
        console2.log("  final shares:", hook.getShares(poolId, address(this)));
        console2.log("  final totalShares:", hook.getTotalShares(poolId));
    }

    // ── SCENARIO 4: Second LP adds to existing pool ───────────────────────

    /// @notice Scenario 4: Alice seeds, Bob adds on top.
    ///         Shows how second deposit scales L proportionally.
    function test_frontend_secondLp() public {
        console2.log("========================================");
        console2.log("SCENARIO 4: Second LP joins");
        console2.log("========================================");

        hook.createPool(poolKey, Constants.SQRT_PRICE_1_1, 60);
        _approve();

        hook.addLiquidity(
            poolKey,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 50 ether,
                amount1Desired: 50 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );

        int24 cur = hook.currentBin(poolId);
        uint128 aliceL = hook.liquidity(poolId, cur);
        uint256 aliceShares = hook.getShares(poolId, address(this));
        console2.log("  After Alice: L[cur]:", aliceL, " shares:", aliceShares);

        address bob = address(0xB0B);
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t0.mint(bob, 200 ether);
        t1.mint(bob, 200 ether);
        vm.startPrank(bob);
        t0.approve(address(hook), type(uint256).max);
        t1.approve(address(hook), type(uint256).max);

        hook.addLiquidity(
            poolKey,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );
        vm.stopPrank();

        uint128 totalL = hook.liquidity(poolId, cur);
        uint256 bobShares = hook.getShares(poolId, bob);
        console2.log("  After Bob:  L[cur]:", totalL, " bobShares:", bobShares);

        assertGt(bobShares, aliceShares);
        assertApproxEqAbs(uint256(totalL), uint256(aliceL) * 3, aliceL / 10);
    }

    // ── SCENARIO 5: One-sided deposit (only token1/ETH below spot) ────────

    /// @notice Scenario 5: User deposits ONLY token1 (ETH) below current price.
    ///         Below-spot bins are 100% token1, so this works.
    function test_frontend_oneSided_belowSpot() public {
        console2.log("========================================");
        console2.log("SCENARIO 5: One-sided deposit (ETH only)");
        console2.log("========================================");

        hook.createPool(poolKey, Constants.SQRT_PRICE_1_1, 60);
        _approve();

        int24 cur = _currentBinFromPrice(Constants.SQRT_PRICE_1_1);
        console2.log("  actual currentBin:", cur);

        // Deposit only token1 (ETH) into bins below spot.
        // Above-spot bins are skipped because amount0Desired=0 and they need token0.
        BalanceDelta delta = hook.addLiquidity(
            poolKey,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 0,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );

        console2.log("  amount0 (token0) pulled:", delta.amount0());
        console2.log("  amount1 (token1) pulled:", delta.amount1());

        _logPoolState();

        int24 min = hook.minBin(poolId);
        int24 max = hook.maxBin(poolId);
        for (int24 i = min; i <= max; ++i) {
            uint128 liq = hook.liquidity(poolId, i);
            if (liq > 0) {
                console2.logInt(i);
                console2.log("    L:", liq);
            }
        }
    }

    // ── SCENARIO 6: Slippage protection ───────────────────────────────────

    /// @notice Scenario 6: User sets amount0Min / amount1Min too high -> reverts.
    ///         This tests the slippage guard that the frontend shows as "slippage tolerance".
    function test_frontend_slippageProtection_reverts() public {
        console2.log("========================================");
        console2.log("SCENARIO 6: Slippage protection");
        console2.log("========================================");

        hook.createPool(poolKey, Constants.SQRT_PRICE_1_1, 60);
        _approve();

        vm.expectRevert(BaseCustomAccounting.TooMuchSlippage.selector);
        hook.addLiquidity(
            poolKey,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 200 ether,
                amount1Min: 200 ether,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );

        console2.log("  Reverted as expected with TooMuchSlippage");
    }
}
