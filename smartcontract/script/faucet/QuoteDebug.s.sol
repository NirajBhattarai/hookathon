// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {BinQuoter} from "./BinQuoter.sol";

contract QuoteDebug is Test {
    function run() external {
        vm.createSelectFork(vm.envString("FORK_RPC"));
        IERC20 usdc = IERC20(0x4B8DFabf9389182F33eaaC56A8746fED88554E75);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(0x4B8DFabf9389182F33eaaC56A8746fED88554E75),
            currency1: Currency.wrap(0xdc21FDB62477277166410a23eA03eD3D43854e3e),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(0x12d591f01E17d9Be48eb0fa78Ad8b8d166dbbA88)
        });
        address trader = makeAddr("trader");
        deal(address(usdc), trader, 1e6);
        vm.startPrank(trader);
        usdc.approve(address(0xf13D190e9117920c703d79B5F33732e10049b115), type(uint256).max);
        BalanceDelta delta = IUniswapV4Router04(payable(0xf13D190e9117920c703d79B5F33732e10049b115))
            .swapExactTokensForTokens(1e6, 0, true, key, "", trader, block.timestamp + 600);
        console2.log("amount0", uint256(int256(delta.amount0())));
        console2.log("amount1", uint256(int256(delta.amount1())));
        console2.log("bal after", usdc.balanceOf(trader));
        vm.stopPrank();

        // now the quoter path
        BinQuoter q = BinQuoter(0xaBfb6a5F03FC9F12164B665F50F989ad53240520);
        console2.log("canonical calldata:");
        console2.logBytes(
            abi.encodeWithSelector(
                BinQuoter.quoteExactInput.selector,
                BinQuoter.QuoteParams({key: key, zeroForOne: true, amountIn: 1e6, receiver: trader})
            )
        );
        try q.quoteExactInput(BinQuoter.QuoteParams({key: key, zeroForOne: true, amountIn: 1e6, receiver: trader})) {
            console2.log("quoter: no revert?!");
        } catch (bytes memory reason) {
            console2.log("quoter revert bytes:");
            console2.logBytes(reason);
        }
    }
}
