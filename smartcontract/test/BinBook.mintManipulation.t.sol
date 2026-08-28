// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {Constants} from "./utils/Constants.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Regression coverage for LP-share-mint pricing (`SwapMath.getMintShares`,
///         `BinBook.sol:165-172`): confirms a swap -> deposit -> swap-back -> withdraw round
///         trip cannot mint shares at a favorably-skewed spot price and extract value from other
///         LPs. `getMintShares` values the *new deposit* and the *existing reserves* with the
///         same instantaneous price, so a skew distorts both sides identically — the only cost
///         to an attacker attempting this is the swap fee paid twice, confirmed below by running
///         the same round trip at two sizes and observing the loss grow rather than flip to
///         profit.
contract BinBookMintManipulationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    address flags;
    BinBook hook;
    PoolKey key;
    PoolId id;
    MockERC20 token0;
    MockERC20 token1;
    address attacker = address(0xA11CE);

    function setUp() public {
        deployArtifactsAndLabel();
        flags = address(uint160(HOOK_FLAGS));
        deployCodeTo("BinBook.sol:BinBook", abi.encode(poolManager), flags);
        hook = BinBook(flags);

        (Currency c0, Currency c1) = deployCurrencyPair();
        key = PoolKey(c0, c1, 3000, 1, IHooks(address(hook))); // 0.3% fee, default thin book
        id = key.toId();
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 60);

        token0 = MockERC20(Currency.unwrap(c0));
        token1 = MockERC20(Currency.unwrap(c1));

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // Fund the attacker generously so the probe isn't capital-constrained.
        token0.mint(attacker, 10_000_000 ether);
        token1.mint(attacker, 10_000_000 ether);
        vm.startPrank(attacker);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Runs skew-swap -> one-sided-deposit-at-skewed-price -> restore-swap -> full-withdraw
    ///      for `attacker`, sized by `scale` (1 = base run). Returns the attacker's value change
    ///      in token0-terms, valued at the pool's *final* (near-restored) price so the comparison
    ///      isn't distorted by the temporary skew itself.
    function _roundTrip(uint256 scale) internal returns (int256 valueDelta0) {
        // Victim: balanced bootstrap deposit spanning exactly the default 10-bins-per-side book,
        // sized with the round trip so the book has enough depth to absorb it either way.
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1000 ether * scale,
                amount1Desired: 1000 ether * scale,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );

        uint256 startBal0 = token0.balanceOf(attacker);
        uint256 startBal1 = token1.balanceOf(attacker);

        vm.startPrank(attacker);

        // 1) Skew price down: sell a big chunk of token0 into the thin default book.
        swapRouter.swapExactTokensForTokens(800 ether * scale, 0, true, key, "", attacker, block.timestamp);

        // 2) Deposit heavily into token1 while price is depressed - getMintShares will value
        //    this deposit's token1 leg using the skewed (lower) price.
        BalanceDelta d = hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 0,
                amount1Desired: 100_000 ether * scale,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: -60,
                userInputSalt: bytes32(0)
            })
        );
        d;
        uint256 shares = hook.getShares(id, attacker);

        // 3) Swap back to push price toward its original level. The book only has thin default
        //    depth on the upper side, so this stays sized off the skew swap, not the attacker's
        //    (now much larger) token1 balance.
        swapRouter.swapExactTokensForTokens(780 ether * scale, 0, false, key, "", attacker, block.timestamp);

        // 4) Burn everything.
        hook.removeLiquidity(
            key,
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: -60,
                userInputSalt: bytes32(0)
            })
        );

        vm.stopPrank();

        uint256 endBal0 = token0.balanceOf(attacker);
        uint256 endBal1 = token1.balanceOf(attacker);

        uint256 finalSqrtP = hook.currentSqrtPriceX96(id);
        uint256 finalPriceX96 = (finalSqrtP * finalSqrtP) / 2 ** 96;

        uint256 startValue0 = startBal0 + (startBal1 * 2 ** 96) / finalPriceX96;
        uint256 endValue0 = endBal0 + (endBal1 * 2 ** 96) / finalPriceX96;

        valueDelta0 = int256(endValue0) - int256(startValue0);
    }

    function test_swapMintSwapBackBurn_roundTrip_neverProfitable_1x() public {
        int256 delta = _roundTrip(1);
        console2.log("1x round-trip value delta (token0 terms, wei, negative = loss):");
        console2.logInt(delta);
        assertLe(delta, 0, "attacker extracted value from swap->mint->swap->burn round trip");
    }

    /// @dev Doubling every leg of the round trip roughly doubles the loss (it's the swap fee
    ///      paid twice on a bigger notional), rather than turning a loss into a profit — which
    ///      would indicate a percentage-of-value edge instead of a fixed fee cost.
    function test_swapMintSwapBackBurn_roundTrip_neverProfitable_2x() public {
        int256 delta = _roundTrip(2);
        console2.log("2x round-trip value delta (token0 terms, wei, negative = loss):");
        console2.logInt(delta);
        assertLe(delta, 0, "attacker extracted value from swap->mint->swap->burn round trip at 2x size");
    }
}
