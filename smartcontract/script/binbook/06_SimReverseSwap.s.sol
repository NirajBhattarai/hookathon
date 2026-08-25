// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {BinBookBase} from "./BinBookBase.s.sol";

/// @notice SIMULATION ONLY: reverse swap 0.01 WETH -> USDC on the ts=10 pool.
contract SimReverseSwap is BinBookBase {
    function run() external {
        Deployment memory d = loadDeployment();
        address me = vm.getWallets()[0];
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(d.token0),
            currency1: Currency.wrap(d.token1),
            fee: d.fee,
            tickSpacing: 10,
            hooks: IHooks(d.binBook)
        });

        uint256 wethBefore = IERC20(d.token1).balanceOf(me);
        uint256 usdcBefore = IERC20(d.token0).balanceOf(me);

        vm.startBroadcast();
        IERC20(d.token1).approve(SWAP_ROUTER, type(uint256).max);
        bytes memory ret = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,bool,(address,address,uint24,int24,address),bytes,address,uint256)",
            0.01e18,
            0,
            false,
            key,
            "",
            me,
            block.timestamp + 600
        );
        (bool ok, bytes memory data) = SWAP_ROUTER.call(ret);
        vm.stopBroadcast();

        require(ok, "swap reverted");
        (int128 delta0Int, int128 delta1Int) = abi.decode(data, (int128, int128));
        console2.log("delta0:", delta0Int);
        console2.log("delta1:", delta1Int);
        console2.log("usdc delta:", IERC20(d.token0).balanceOf(me) - usdcBefore);
        console2.log("weth delta:", wethBefore - IERC20(d.token1).balanceOf(me));
    }
}
