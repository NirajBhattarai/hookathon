// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title SwapMath
/// @notice Bin swap-step math, linear-decay liquidity sizing, and LP withdraw helpers for BinBook.
library SwapMath {
    /// @dev Uniswap-style max fee in pips (100%).
    uint256 internal constant MAX_SWAP_FEE = 1_000_000;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q192 = 2 ** 192;

    error InsufficientLiquidity();

    struct Bin {
        uint128 L;
        uint160 sqrtLo;
        uint160 sqrtHi;
    }

    struct BinBounds {
        uint256 sqrtPriceLower;
        uint256 sqrtPriceUpper;
    }

    /// @dev One computeSwapStep result, boxed so walkers hold a single stack slot.
    struct CoreStep {
        uint160 sqrtNext;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    /// @dev Running totals for a multi-bin walk.
    struct WalkState {
        uint256 amountOut;
        uint256 amountInUsed;
        uint256 feeAmount;
        uint160 sqrtEnd;
        uint256 endIndex;
        uint256 remaining;
    }

    // ── Uniswap-style bin swap step ──────────────────────────────────────

    /// @notice Computes the sqrt price target for a swap step within a bin.
    /// @dev Mirrors v4-core SwapMath.getSqrtPriceTarget, where the bin boundary plays
    ///      the role of the next initialized tick.
    /// @param zeroForOne The direction of the swap: true swaps currency0 for currency1 (price down)
    /// @param sqrtLo Lower sqrt price bound of the bin
    /// @param sqrtHi Upper sqrt price bound of the bin
    /// @return sqrtPriceTargetX96 The boundary price the step is capped at
    function getSqrtPriceTarget(bool zeroForOne, uint160 sqrtLo, uint160 sqrtHi)
        internal
        pure
        returns (uint160 sqrtPriceTargetX96)
    {
        assembly ("memory-safe") {
            sqrtPriceTargetX96 := xor(sqrtHi, mul(zeroForOne, xor(sqrtLo, sqrtHi)))
        }
    }

    /// @notice Computes the result of a swap within a single bin holding the invariant x*y = k
    ///         confined to the price range [bin.sqrtLo, bin.sqrtHi].
    /// @dev Mirrors v4-core SwapMath.computeSwapStep. The fee is taken per-step, Uniswap-style:
    ///      `feeAmount = mulDivRoundingUp(amountIn, feePips, MAX_SWAP_FEE - feePips)` when the
    ///      step caps at the bin boundary, otherwise the unconsumed remainder of the max input.
    ///      A bin with zero liquidity is crossed for free (no input consumed), analogous to
    ///      passing through an uninitialized tick range.
    /// @param bin The bin to swap against: liquidity L and sqrt price bounds [sqrtLo, sqrtHi]
    /// @param sqrtPriceCurrentX96 The current sqrt price; clamped into the bin bounds
    /// @param amountRemaining Signed remaining amount: negative = exact-in, positive = exact-out
    /// @param feePips The fee taken from the input amount, in hundredths of a bip (3000 = 0.30%)
    /// @param zeroForOne The direction of the swap
    /// @return sqrtPriceNextX96 The sqrt price after the step, not exceeding the bin boundary
    /// @return amountIn The input consumed by the step, net of fee
    /// @return amountOut The output produced by the step
    /// @return feeAmount The portion of the gross input taken as fee
    function computeSwapStep(
        Bin memory bin,
        uint160 sqrtPriceCurrentX96,
        int256 amountRemaining,
        uint24 feePips,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        unchecked {
            uint256 _feePips = feePips;
            sqrtPriceCurrentX96 = _clamp(sqrtPriceCurrentX96, bin.sqrtLo, bin.sqrtHi);
            uint160 target = getSqrtPriceTarget(zeroForOne, bin.sqrtLo, bin.sqrtHi);
            bool exactIn = amountRemaining < 0;

            if (amountRemaining == 0 || sqrtPriceCurrentX96 == target) {
                return (sqrtPriceCurrentX96, 0, 0, 0);
            }

            if (bin.L == 0) {
                return (target, 0, 0, 0);
            }

            if (exactIn) {
                uint256 amountRemainingLessFee =
                    FullMath.mulDiv(uint256(-amountRemaining), MAX_SWAP_FEE - _feePips, MAX_SWAP_FEE);
                amountIn = _amountIn(sqrtPriceCurrentX96, target, bin.L, zeroForOne);
                if (amountRemainingLessFee >= amountIn) {
                    // input suffices to reach the bin boundary: cap the step there
                    sqrtPriceNextX96 = target;
                    feeAmount = _feePips == MAX_SWAP_FEE
                        ? amountIn  // amountIn is always 0 here, as amountRemainingLessFee == 0
                        : FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
                } else {
                    // exhaust the remaining amount inside the bin
                    amountIn = amountRemainingLessFee;
                    sqrtPriceNextX96 =
                        SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceCurrentX96, bin.L, amountIn, zeroForOne);
                    feeAmount = uint256(-amountRemaining) - amountIn;
                }
                amountOut = _amountOut(sqrtPriceCurrentX96, sqrtPriceNextX96, bin.L, zeroForOne);
            } else {
                amountOut = _amountOut(sqrtPriceCurrentX96, target, bin.L, zeroForOne);
                if (uint256(amountRemaining) >= amountOut) {
                    // output demand reaches the bin boundary: cap the step there
                    sqrtPriceNextX96 = target;
                } else {
                    amountOut = uint256(amountRemaining);
                    sqrtPriceNextX96 =
                        SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPriceCurrentX96, bin.L, amountOut, zeroForOne);
                }
                amountIn = _amountIn(sqrtPriceCurrentX96, sqrtPriceNextX96, bin.L, zeroForOne);
                feeAmount = FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
            }
        }
    }

    /// @notice Exact-in walk across `bins` (ascending price), mirroring Pool.swap's tick loop.
    /// @dev Each iteration runs computeSwapStep against one bin and consumes
    ///      `amountIn + feeAmount` from the remaining gross input, until the input is exhausted
    ///      or the book edge (`lo`/`hi`, inclusive) is reached. Empty bins are crossed for free.
    /// @param bins Bins ordered by ascending price; index 0 is the lowest priced bin
    /// @param sqrtP Current sqrt price; clamped into the active bin's bounds
    /// @param active Index of the bin containing `sqrtP`
    /// @param amountIn Gross input amount (fee inclusive)
    /// @param zeroForOne The direction of the swap
    /// @param lo Lowest bin index that may be entered
    /// @param hi Highest bin index that may be entered (capped at the last bin)
    /// @param feePips The fee taken per step, in hundredths of a bip
    /// @return amountOut Total output received across all steps
    /// @return amountInUsed Total gross input consumed across all steps (net inputs + fees)
    /// @return feeAmount Total fee charged across all steps
    /// @return sqrtEnd Sqrt price after the walk
    /// @return endIndex Index of the last bin touched
    function swapExactInMulti(
        Bin[] memory bins,
        uint160 sqrtP,
        uint256 active,
        uint256 amountIn,
        bool zeroForOne,
        uint256 lo,
        uint256 hi,
        uint24 feePips
    )
        internal
        pure
        returns (uint256 amountOut, uint256 amountInUsed, uint256 feeAmount, uint160 sqrtEnd, uint256 endIndex)
    {
        if (bins.length == 0 || amountIn == 0) {
            return (0, 0, 0, sqrtP, active);
        }

        WalkState memory a;
        a.sqrtEnd = sqrtP;
        a.endIndex = active;
        a.remaining = amountIn;

        if (zeroForOne) _walkDown(bins, a, lo, hi, feePips);
        else _walkUp(bins, a, lo, hi, feePips);

        return (a.amountOut, a.amountInUsed, a.feeAmount, a.sqrtEnd, a.endIndex);
    }

    /// @dev Walk from the active bin toward lower prices, mutating `a`.
    function _walkDown(Bin[] memory bins, WalkState memory a, uint256 lo, uint256 hi, uint24 feePips) private pure {
        uint256 last = bins.length - 1;
        uint256 hiC = hi > last ? last : hi;
        uint256 start = a.endIndex < hiC ? a.endIndex : hiC;
        if (start < lo) return;

        for (uint256 i = start;;) {
            CoreStep memory c = _coreStep(bins[i], a.sqrtEnd, a.remaining, feePips, true);
            a.remaining -= c.amountIn + c.feeAmount;
            a.amountInUsed += c.amountIn + c.feeAmount;
            a.amountOut += c.amountOut;
            a.feeAmount += c.feeAmount;
            a.sqrtEnd = c.sqrtNext;
            a.endIndex = i;
            if (a.remaining == 0 || i == lo) break;
            unchecked {
                --i;
            }
        }
    }

    /// @dev Walk from the active bin toward higher prices, mutating `a`.
    function _walkUp(Bin[] memory bins, WalkState memory a, uint256 lo, uint256 hi, uint24 feePips) private pure {
        uint256 last = bins.length - 1;
        uint256 hiC = hi > last ? last : hi;
        uint256 start = a.endIndex > lo ? a.endIndex : lo;

        for (uint256 i = start; i <= hiC;) {
            CoreStep memory c = _coreStep(bins[i], a.sqrtEnd, a.remaining, feePips, false);
            a.remaining -= c.amountIn + c.feeAmount;
            a.amountInUsed += c.amountIn + c.feeAmount;
            a.amountOut += c.amountOut;
            a.feeAmount += c.feeAmount;
            a.sqrtEnd = c.sqrtNext;
            a.endIndex = i;
            if (a.remaining == 0 || i == hiC) break;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Box computeSwapStep's tuple into one memory slot.
    function _coreStep(Bin memory bin, uint160 sqrtP, uint256 remaining, uint24 feePips, bool zeroForOne)
        private
        pure
        returns (CoreStep memory c)
    {
        (c.sqrtNext, c.amountIn, c.amountOut, c.feeAmount) =
            computeSwapStep(bin, sqrtP, -int256(remaining), feePips, zeroForOne);
    }

    // ── Linear decay (from LinearDecay) ──────────────────────────────────

    /// @notice L_i = LBase * (ramp - distance) / ramp. L reaches 0 at distance >= ramp.
    function lForDistance(uint256 lBase, uint256 ramp, uint256 distance) internal pure returns (uint256) {
        if (distance == 0) return lBase;
        if (distance >= ramp) return 0;
        return lBase * (ramp - distance) / ramp;
    }

    /// @dev Alias kept for call-site clarity in BinBook.
    function computeLPerBin(uint256 lBase, uint256 ramp, uint256 distance) internal pure returns (uint256) {
        return lForDistance(lBase, ramp, distance);
    }

    // ── Liquidity / CPMM helpers (from LiquidityLibrary) ─────────────────

    /// @notice Compute token amounts required to fund liquidity `L` within a single price bin.
    /// @dev Standard Uniswap v3 concentrated-liquidity formulas for a bin spanning [sqrtLo, sqrtHi]:
    ///
    ///      Case 1 — price at or below bin (sqrtPriceCurrent ≤ sqrtLo):
    ///        All liquidity is above the current price → only token0 needed.
    ///        token0 = L × (1/√lo − 1/√hi) × Q96
    ///             rewritten as L × (Q96²/√lo − Q96²/√hi) / Q96
    ///
    ///      Case 2 — price at or above bin (sqrtPriceCurrent ≥ sqrtHi):
    ///        All liquidity is below the current price → only token1 needed.
    ///        token1 = L × (√hi − √lo) / Q96
    ///
    ///      Case 3 — price inside the bin (sqrtLo < sqrtPriceCurrent < sqrtHi):
    ///        Liquidity straddles the price → both tokens needed.
    ///        token0 = L × (1/√P − 1/√hi) × Q96   (left side of price, above √P)
    ///        token1 = L × (√P − √lo) / Q96         (right side of price, below √P)
    ///
    ///      Where L = liquidity (the x·y = L² invariant), Q96 = 2^96 (fixed-point scale).
    function getTokenAmountsForBin(uint256 L, uint256 sqrtPriceCurrent, BinBounds memory bounds)
        internal
        pure
        returns (uint256 token0, uint256 token1)
    {
        if (L == 0) return (0, 0);
        if (sqrtPriceCurrent <= bounds.sqrtPriceLower) {
            token0 = L * (Q96 * Q96 / bounds.sqrtPriceLower - Q96 * Q96 / bounds.sqrtPriceUpper) / Q96;
        } else if (sqrtPriceCurrent >= bounds.sqrtPriceUpper) {
            token1 = L * (bounds.sqrtPriceUpper - bounds.sqrtPriceLower) / Q96;
        } else {
            token0 = L * (Q96 * Q96 / sqrtPriceCurrent - Q96 * Q96 / bounds.sqrtPriceUpper) / Q96;
            token1 = L * (sqrtPriceCurrent - bounds.sqrtPriceLower) / Q96;
        }
    }

    function getWithdrawAmounts(uint256 totalToken0, uint256 totalToken1, uint256 sharesToBurn, uint256 totalSupply)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sharesToBurn == 0 || totalSupply == 0) return (0, 0);
        amount0 = totalToken0 * sharesToBurn / totalSupply;
        amount1 = totalToken1 * sharesToBurn / totalSupply;
    }

    /// @notice Mints shares proportional to a deposit's value, not its raw token amounts.
    /// @dev Converts amount1/reserve1 into token0-equivalent terms via the pool's live price
    ///      before comparing anything — token0 and token1 units are otherwise incomparable
    ///      (different decimals, different real value per unit), so summing them directly
    ///      (`amount0 + amount1`) would misprice a deposit based on which token it happened to
    ///      land in. Numerator (this deposit) and denominator (the pool's existing reserves) are
    ///      valued with the *same* live price, so it doesn't matter what price was in effect for
    ///      any prior deposit — every mint is a fresh, self-consistent snapshot.
    /// @param amount0 This deposit's token0 amount
    /// @param amount1 This deposit's token1 amount
    /// @param reserve0 Pool's token0 claim balance before this deposit settles
    /// @param reserve1 Pool's token1 claim balance before this deposit settles
    /// @param sqrtPriceX96 Pool's current sqrt price
    /// @param totalSupply Existing total shares outstanding; 0 signals the bootstrap deposit
    /// @return shares Shares to mint for this deposit
    function getMintShares(
        uint256 amount0,
        uint256 amount1,
        uint256 reserve0,
        uint256 reserve1,
        uint160 sqrtPriceX96,
        uint256 totalSupply
    ) internal pure returns (uint256 shares) {
        uint256 depositValue = valueOf(amount0, amount1, sqrtPriceX96);

        if (totalSupply == 0) {
            // Bootstrap: no existing value to compare against, so this deposit necessarily sets
            // the initial shares-per-value exchange rate.
            return depositValue;
        }

        uint256 totalValueBefore = valueOf(reserve0, reserve1, sqrtPriceX96);
        shares = FullMath.mulDiv(depositValue, totalSupply, totalValueBefore);
    }

    /// @notice Converts amount0/amount1 into token0-equivalent value at `sqrtPriceX96`.
    /// @dev Shared by `getMintShares` and BinBook's removeLiquidity value-target formula, so
    ///      minting and burning price a position with the exact same formula — no drift between
    ///      the two directions.
    function valueOf(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        return amount0 + FullMath.mulDiv(amount1, Q96, priceX96);
    }

    // ── private ──────────────────────────────────────────────────────────

    function _clamp(uint160 p, uint160 lo, uint160 hi) private pure returns (uint160) {
        if (p < lo) return lo;
        if (p > hi) return hi;
        return p;
    }

    function _amountIn(uint160 from, uint160 to, uint128 L, bool zeroForOne) private pure returns (uint256) {
        return zeroForOne
            ? SqrtPriceMath.getAmount0Delta(to, from, L, true)
            : SqrtPriceMath.getAmount1Delta(from, to, L, true);
    }

    function _amountOut(uint160 from, uint160 to, uint128 L, bool zeroForOne) private pure returns (uint256) {
        return zeroForOne
            ? SqrtPriceMath.getAmount1Delta(to, from, L, false)
            : SqrtPriceMath.getAmount0Delta(from, to, L, false);
    }
}
