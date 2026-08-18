// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {BinRatchet} from "../../src/BinRatchet.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract BinRatchetFuzzTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    BinRatchet hook;
    PoolId poolId;

    function setUp() public {
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        address flags = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("BinRatchet.sol:BinRatchet", constructorArgs, flags);
        hook = BinRatchet(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
    }

    function test_setBinSize_validPositiveSize(int24 binSize) public {
        vm.assume(binSize > 0);
        hook.setBinSize(poolKey, binSize);

        assertEq(hook.getBinSize(poolId), binSize);
        assertTrue(hook.isConfigured(poolId));
    }

    function test_fuzz_setBinSize_revertsOnNonPositive(int24 binSize) public {
        vm.assume(binSize <= 0);
        vm.expectRevert(BinRatchet.InvalidBinSize.selector);
        hook.setBinSize(poolKey, binSize);
    }
}
