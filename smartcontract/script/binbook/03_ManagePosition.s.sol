// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BinBook} from "../../src/BinBook.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {BinBookBase} from "./BinBookBase.s.sol";

/// @notice Removes a fraction of the caller's shares and collects accrued fees.
contract ManagePosition is BinBookBase {
    using PoolIdLibrary for PoolKey;

    function run() external {
        Deployment memory d = loadDeployment();
        BinBook binBook = BinBook(d.binBook);
        PoolKey memory key = poolKeyOf(d);
        address broadcaster = vm.getWallets()[0];

        uint256 pct = vm.envOr("WITHDRAW_PCT", uint256(50)); // percent of shares to burn

        uint256 shares = binBook.sharesOf(key.toId(), broadcaster);
        uint256 amount = (shares * pct) / 100;
        (uint256 f0Before, uint256 f1Before) = binBook.pendingFees(key.toId(), broadcaster);
        uint256 b0Before = IERC20(d.token0).balanceOf(broadcaster);
        uint256 b1Before = IERC20(d.token1).balanceOf(broadcaster);

        vm.startBroadcast();

        if (amount > 0) {
            binBook.removeLiquidity(
                key,
                BaseCustomAccounting.RemoveLiquidityParams({
                    liquidity: amount,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 600,
                    tickLower: 0,
                    tickUpper: 0,
                    userInputSalt: bytes32(0)
                })
            );
        }
        binBook.collectFees(key);

        vm.stopBroadcast();

        (uint256 f0After, uint256 f1After) = binBook.pendingFees(key.toId(), broadcaster);
        console2.log("shares before   :", shares);
        console2.log("shares burned   :", amount);
        console2.log("shares remaining:", binBook.sharesOf(key.toId(), broadcaster));
        console2.log("fees collected0 :", f0Before - f0After + (IERC20(d.token0).balanceOf(broadcaster) - b0Before));
        console2.log("fees collected1 :", f1Before - f1After + (IERC20(d.token1).balanceOf(broadcaster) - b1Before));
    }
}
