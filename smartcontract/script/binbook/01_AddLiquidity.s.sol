// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BinBook} from "../../src/BinBook.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {BinBookBase} from "./BinBookBase.s.sol";

/// @notice Adds full-range liquidity to the deployed pool and prints resulting shares.
contract AddLiquidity is BinBookBase {
    using PoolIdLibrary for PoolKey;
    function run() external {
        Deployment memory d = loadDeployment();
        BinBook binBook = BinBook(d.binBook);
        PoolKey memory key = poolKeyOf(d);
        address broadcaster = vm.getWallets()[0];

        uint256 a0 = vm.envOr("AMOUNT0", uint256(100e18));
        uint256 a1 = vm.envOr("AMOUNT1", uint256(100e18));

        vm.startBroadcast();

        IERC20(d.token0).approve(d.binBook, type(uint256).max);
        IERC20(d.token1).approve(d.binBook, type(uint256).max);

        if (!binBook.isConfigured(key.toId()) || binBook.getBinSize(key.toId()) == 0) {
            binBook.setBinSize(key, d.tickSpacing);
        }

        binBook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        vm.stopBroadcast();

        console2.log("added a0:", a0);
        console2.log("added a1:", a1);
        console2.log("shares (you):", binBook.sharesOf(key.toId(), broadcaster));
        console2.log("totalShares :", binBook.getTotalShares(key.toId()));
    }
}
