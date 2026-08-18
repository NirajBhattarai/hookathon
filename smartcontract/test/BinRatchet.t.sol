// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {BinRatchet} from "../src/BinRatchet.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract BinRatchetTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    BinRatchet hook;
    PoolId poolId;

    // Pool creator is this test contract (since we call poolManager.initialize)
    address poolCreator = address(this);

    function setUp() public {
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        // Deploy the hook with BEFORE_INITIALIZE_FLAG | AFTER_INITIALIZE_FLAG | BEFORE_ADD_LIQUIDITY_FLAG
        address flags =
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("BinRatchet.sol:BinRatchet", constructorArgs, flags);
        hook = BinRatchet(flags);

        // Create pool WITH the hook attached
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // afterInitialize fired -> poolCreator[poolId] = address(this) (msg.sender of initialize)
    }

    // ─────────────────────────────────────────────────────────────────────
    //   SETUP VERIFICATION
    // ─────────────────────────────────────────────────────────────────────

    function test_BeforeInitializeFlagEnabled() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize);
    }

    function test_AfterInitializeFlagEnabled() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize);
    }

    function test_BeforeAddLiquidityFlagEnabled() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeAddLiquidity);
    }

    function test_PoolCreatorCaptured() public view {
        assertEq(hook.poolCreator(poolId), poolCreator);
    }

    // ─────────────────────────────────────────────────────────────────────
    //   setBinSize - SUCCESS
    // ─────────────────────────────────────────────────────────────────────

    function test_setBinSize_succeeds() public {
        int24 binSize = 60;

        hook.setBinSize(poolKey, binSize);

        assertEq(hook.getBinSize(poolId), binSize);
        assertTrue(hook.isConfigured(poolId));
        assertEq(hook.binSizeSet(poolId), true);
    }

    function test_setBinSize_emitsEvent() public {
        int24 binSize = 60;

        vm.expectEmit(address(hook));
        emit BinRatchet.BinSizeSet(poolId, poolCreator, binSize);

        hook.setBinSize(poolKey, binSize);
    }

    function test_setBinSize_variousSizes() public {
        int24[] memory sizes = new int24[](4);
        sizes[0] = 10;
        sizes[1] = 60;
        sizes[2] = 200;
        sizes[3] = 1;

        int24[] memory spacings = new int24[](4);
        spacings[0] = 10;
        spacings[1] = 30;
        spacings[2] = 200;
        spacings[3] = 3;

        for (uint256 i = 0; i < sizes.length; i++) {
            PoolKey memory freshKey = PoolKey(currency0, currency1, 3000, spacings[i], IHooks(address(hook)));
            poolManager.initialize(freshKey, Constants.SQRT_PRICE_1_1);

            hook.setBinSize(freshKey, sizes[i]);
            assertEq(hook.getBinSize(freshKey.toId()), sizes[i]);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //   setBinSize - REVERTS
    // ─────────────────────────────────────────────────────────────────────

    function test_setBinSize_reverts_notCreator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BinRatchet.NotPoolCreator.selector);
        hook.setBinSize(poolKey, 60);
    }

    function test_setBinSize_reverts_alreadySet() public {
        hook.setBinSize(poolKey, 60);

        vm.expectRevert(BinRatchet.BinSizeAlreadySet.selector);
        hook.setBinSize(poolKey, 120);
    }

    function test_setBinSize_reverts_invalidSize_zero() public {
        vm.expectRevert(BinRatchet.InvalidBinSize.selector);
        hook.setBinSize(poolKey, 0);
    }

    function test_setBinSize_reverts_invalidSize_negative() public {
        vm.expectRevert(BinRatchet.InvalidBinSize.selector);
        hook.setBinSize(poolKey, -10);
    }

    // ─────────────────────────────────────────────────────────────────────
    //   VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────

    function test_isConfigured_beforeSet() public view {
        assertFalse(hook.isConfigured(poolId));
    }

    function test_isConfigured_afterSet() public {
        hook.setBinSize(poolKey, 60);
        assertTrue(hook.isConfigured(poolId));
    }

    function test_getBinSize_beforeSet() public view {
        assertEq(hook.getBinSize(poolId), 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    //   PER-POOL ISOLATION
    // ─────────────────────────────────────────────────────────────────────

    function test_twoPools_independentConfig() public {
        // Pool 1: binSize = 60
        hook.setBinSize(poolKey, 60);

        // Pool 2: different token pair, binSize = 200
        (Currency otherCurrency0, Currency otherCurrency1) = deployCurrencyPair();

        address flags2 =
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
        bytes memory constructorArgs2 = abi.encode(poolManager);
        deployCodeTo("BinRatchet.sol:BinRatchet", constructorArgs2, flags2);
        BinRatchet hook2 = BinRatchet(flags2);

        PoolKey memory poolKey2 = PoolKey(otherCurrency0, otherCurrency1, 3000, 60, IHooks(address(hook2)));
        PoolId poolId2 = poolKey2.toId();
        poolManager.initialize(poolKey2, Constants.SQRT_PRICE_1_1);

        hook2.setBinSize(poolKey2, 200);

        assertEq(hook.getBinSize(poolId), 60);
        assertEq(hook2.getBinSize(poolId2), 200);
    }

    // ─────────────────────────────────────────────────────────────────────
    //   LIQUIDITY - PRE-CONFIGURATION CHECKS
    // ─────────────────────────────────────────────────────────────────────

    function testLiquidityRequiresConfig() public {
        vm.expectRevert(BinRatchet.PoolNotConfigured.selector);
        positionManager.mint(
            poolKey, 0, 60, 100e18, type(uint256).max, type(uint256).max, address(this), block.timestamp, Constants.ZERO_BYTES
        );
    }
}
