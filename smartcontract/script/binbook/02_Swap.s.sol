// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {BinBook} from "../../src/BinBook.sol";
import {BinBookBase} from "./BinBookBase.s.sol";

/// @notice Swaps through the existing hookmate V4SwapRouter and prints pool state after.
contract Swap is BinBookBase {
    using PoolIdLibrary for PoolKey;

    function run() external {
        Deployment memory d = loadDeployment();
        BinBook binBook = BinBook(d.binBook);
        PoolKey memory key = poolKeyOf(d);
        address broadcaster = vm.getWallets()[0];

        uint256 amountIn = vm.envOr("AMOUNT_IN", uint256(1e18));
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);

        IERC20 tokenIn = IERC20(zeroForOne ? d.token0 : d.token1);
        IERC20 tokenOut = IERC20(zeroForOne ? d.token1 : d.token0);

        uint256 inBalBefore = tokenIn.balanceOf(broadcaster);
        uint256 outBalBefore = tokenOut.balanceOf(broadcaster);
        uint160 priceBefore = binBook.currentSqrtPriceX96(key.toId());

        vm.startBroadcast();

        tokenIn.approve(address(PERMIT2), type(uint256).max);
        tokenIn.approve(SWAP_ROUTER, type(uint256).max);

        IUniswapV4Router04(payable(SWAP_ROUTER)).swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: broadcaster,
            deadline: block.timestamp + 600
        });

        vm.stopBroadcast();

        console2.log("amountIn        :", amountIn);
        console2.log("zeroForOne      :", zeroForOne ? 1 : 0);
        console2.log("tokenOut received:", tokenOut.balanceOf(broadcaster) - outBalBefore);
        console2.log("sqrtPrice before:", priceBefore);
        console2.log("sqrtPrice after :", binBook.currentSqrtPriceX96(key.toId()));
        console2.log("currentBin      :", binBook.currentBin(key.toId()));
        (uint256 f0, uint256 f1) = binBook.pendingFees(key.toId(), broadcaster);
        console2.log("pending fee0    :", f0);
        console2.log("pending fee1    :", f1);
        console2.log("inBal delta     :", inBalBefore - tokenIn.balanceOf(broadcaster));
    }
}
