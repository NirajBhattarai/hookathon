// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Test-only quoter. Performs a real swap inside unlock() and reverts with
///         the resulting deltas so an eth_call can decode the quote. State changes
///         are discarded by eth_call — DO NOT call in a real transaction.
contract BinQuoter is IUnlockCallback {
    IPoolManager public immutable manager;

    error Quote(int128 amount0, int128 amount1);

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    struct QuoteParams {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address receiver;
    }

    function quoteExactInput(QuoteParams calldata p) external {
        manager.unlock(abi.encode(p));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        QuoteParams memory p = abi.decode(data, (QuoteParams));

        BalanceDelta delta = manager.swap(
            p.key,
            SwapParams({
                zeroForOne: p.zeroForOne,
                amountSpecified: -int256(uint256(p.amountIn)),
                sqrtPriceLimitX96: p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        revert Quote(delta.amount0(), delta.amount1());
    }
}
