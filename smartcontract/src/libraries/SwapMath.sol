// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title SwapMath
/// @notice Consolidated bin CPMM, linear-decay sizing, and LP mint/withdraw helpers for BinBook.
library SwapMath {
    uint24 internal constant FEE_DENOMINATOR = 1_000_000;
    /// @dev Uniswap-style alias of FEE_DENOMINATOR: max fee in pips (100%).
    uint256 internal constant MAX_SWAP_FEE = 1_000_000;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q192 = 2 ** 192;

    error InsufficientLiquidity();

    struct Bin {
        uint128 L;
        uint160 sqrtLo;
        uint160 sqrtHi;
    }

    struct Step {
        uint256 amountInUsed;
        uint256 amountOut;
        uint160 sqrtEnd;
        bool crossed;
    }

    struct BinBounds {
        uint256 sqrtPriceLower;
        uint256 sqrtPriceUpper;
    }

    struct DepositAmounts {
        uint256 amount0;
        uint256 amount1;
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

    // ── Bin swap (from BinMath) ──────────────────────────────────────────

    /// @dev Exact-in through one bin. `sqrtP` is clamped into [sqrtLo, sqrtHi].
    function swapExactInSingle(Bin memory bin, uint160 sqrtP, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (Step memory step)
    {
        sqrtP = _clamp(sqrtP, bin.sqrtLo, bin.sqrtHi);
        uint160 target = zeroForOne ? bin.sqrtLo : bin.sqrtHi;

        if (amountIn == 0 || sqrtP == target) {
            step.sqrtEnd = sqrtP;
            return step;
        }

        if (bin.L == 0) {
            step.sqrtEnd = target;
            step.crossed = true;
            return step;
        }

        uint160 sqrtNext = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, bin.L, amountIn, zeroForOne);
        bool crossed = zeroForOne ? sqrtNext <= target : sqrtNext >= target;

        if (crossed) {
            step.sqrtEnd = target;
            step.crossed = true;
            step.amountInUsed = _amountIn(sqrtP, target, bin.L, zeroForOne);
            step.amountOut = _amountOut(sqrtP, target, bin.L, zeroForOne);
        } else {
            step.sqrtEnd = sqrtNext;
            step.amountInUsed = amountIn;
            step.amountOut = _amountOut(sqrtP, sqrtNext, bin.L, zeroForOne);
        }
    }

    /// @dev Exact-in walk across `bins` (ascending price). `lo`/`hi` are inclusive index clamps.
    function swapExactIn(
        Bin[] memory bins,
        uint160 sqrtP,
        uint256 active,
        uint256 amountIn,
        bool zeroForOne,
        uint256 lo,
        uint256 hi
    ) internal pure returns (uint256 amountOut, uint256 amountInUsed, uint160 sqrtEnd, uint256 endIndex) {
        if (bins.length == 0 || amountIn == 0) {
            return (0, 0, sqrtP, active);
        }

        uint256 remaining = amountIn;
        sqrtEnd = sqrtP;
        endIndex = active;

        if (zeroForOne) {
            uint256 start = active < hi ? active : hi;
            if (start < lo) {
                return (0, 0, sqrtP, active);
            }
            for (uint256 i = start; i >= lo;) {
                Step memory step = swapExactInSingle(bins[i], sqrtEnd, remaining, true);
                amountOut += step.amountOut;
                amountInUsed += step.amountInUsed;
                remaining -= step.amountInUsed;
                sqrtEnd = step.sqrtEnd;
                endIndex = i;
                if (remaining == 0) break;
                if (i == lo) break;
                unchecked {
                    --i;
                }
            }
        } else {
            uint256 start = active > lo ? active : lo;
            for (uint256 i = start; i <= hi; ++i) {
                Step memory step = swapExactInSingle(bins[i], sqrtEnd, remaining, false);
                amountOut += step.amountOut;
                amountInUsed += step.amountInUsed;
                remaining -= step.amountInUsed;
                sqrtEnd = step.sqrtEnd;
                endIndex = i;
                if (remaining == 0) break;
            }
        }
    }

    /// @dev Apply pool fee to amount-in. `feePips` is Uniswap-style (3000 = 0.30%).
    function applyFee(uint256 amountIn, uint24 feePips) internal pure returns (uint256) {
        if (feePips == 0) return amountIn;
        return amountIn * (FEE_DENOMINATOR - feePips) / FEE_DENOMINATOR;
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
    function lForDistance(uint256 LBase, uint256 ramp, uint256 distance) internal pure returns (uint256) {
        if (distance == 0) return LBase;
        if (distance >= ramp) return 0;
        return LBase * (ramp - distance) / ramp;
    }

    /// @dev Alias kept for call-site clarity in BinBook.
    function computeLPerBin(uint256 LBase, uint256 ramp, uint256 distance) internal pure returns (uint256) {
        return lForDistance(LBase, ramp, distance);
    }

    function computeLBase(uint256 token1Budget, uint256 binSpacing, uint256 ramp, uint256 numBins)
        internal
        pure
        returns (uint256)
    {
        if (numBins == 0 || token1Budget == 0 || ramp == 0) return 0;
        uint256 weightedSum = 0;
        for (uint256 i = 0; i < numBins; i++) {
            uint256 distance = numBins - i;
            uint256 lFraction = computeLPerBin(1e18, ramp, distance);
            weightedSum += lFraction * binSpacing / 1e18;
        }
        if (weightedSum == 0) return 0;
        return token1Budget * Q96 / weightedSum;
    }

    function getDepositAmountsBelowPrice(
        uint256 sqrtPriceCurrent,
        uint256 binSpacing,
        uint256 numBins,
        uint256 ramp,
        uint256 LBase
    ) internal pure returns (uint256 totalToken0, uint256 totalToken1) {
        if (numBins == 0 || LBase == 0) return (0, 0);
        for (uint256 i = 0; i < numBins; i++) {
            uint256 distance = numBins - i;
            uint256 L = computeLPerBin(LBase, ramp, distance);
            uint256 lo = sqrtPriceCurrent - (i + 1) * binSpacing;
            uint256 hi = sqrtPriceCurrent - i * binSpacing;
            (uint256 t0, uint256 t1) = getTokenAmountsForBin(L, sqrtPriceCurrent, BinBounds(lo, hi));
            totalToken0 += t0;
            totalToken1 += t1;
        }
    }

    function getDepositAmountsAbovePrice(
        uint256 sqrtPriceCurrent,
        uint256 binSpacing,
        uint256 numBins,
        uint256 ramp,
        uint256 LBase
    ) internal pure returns (uint256 totalToken0, uint256 totalToken1) {
        if (numBins == 0 || LBase == 0) return (0, 0);
        for (uint256 i = 0; i < numBins; i++) {
            uint256 distance = i + 1;
            uint256 L = computeLPerBin(LBase, ramp, distance);
            uint256 lo = sqrtPriceCurrent + i * binSpacing;
            uint256 hi = sqrtPriceCurrent + (i + 1) * binSpacing;
            (uint256 t0, uint256 t1) = getTokenAmountsForBin(L, sqrtPriceCurrent, BinBounds(lo, hi));
            totalToken0 += t0;
            totalToken1 += t1;
        }
    }

    function distributeToken1WithBudget(uint256 token1Budget, uint256 binSpacing, uint256 numBins, uint256 ramp)
        internal
        pure
        returns (uint256 LBase, DepositAmounts memory amounts)
    {
        if (numBins == 0 || token1Budget == 0) return (0, DepositAmounts(0, 0));
        LBase = computeLBase(token1Budget, binSpacing, ramp, numBins);
        uint256 totalToken0;
        uint256 totalToken1;
        for (uint256 i = 0; i < numBins; i++) {
            uint256 distance = numBins - i;
            uint256 L = computeLPerBin(LBase, ramp, distance);
            uint256 lo = i * binSpacing;
            uint256 hi = (i + 1) * binSpacing;
            (uint256 t0, uint256 t1) = getTokenAmountsForBin(L, hi, BinBounds(lo, hi));
            totalToken0 += t0;
            totalToken1 += t1;
        }
        amounts = DepositAmounts(totalToken0, totalToken1);
    }

    // ── Liquidity / CPMM helpers (from LiquidityLibrary) ─────────────────

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = x;
        uint256 y;
        if (x == type(uint256).max) {
            y = (x >> 1) + 1;
        } else {
            y = (x + 1) >> 1;
        }
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
        return z;
    }

    function priceToSqrtPriceX96(uint256 price, uint8 decimals0, uint8 decimals1) internal pure returns (uint256) {
        uint256 scaledPrice = price * (10 ** decimals0) / (10 ** decimals1);
        uint8 adj = 18 + decimals0 - decimals1;
        uint256 bigScaled = scaledPrice * 1e12;
        if (adj % 2 == 0) {
            return sqrt(bigScaled) * Q96 / (10 ** (adj / 2)) / 1e6;
        } else {
            return sqrt(bigScaled * 10) * Q96 / (10 ** (adj / 2 + 1)) / 1e6;
        }
    }

    function sqrtPriceX96ToPrice(uint256 sqrtPriceX96, uint8, uint8) internal pure returns (uint256) {
        uint256 a = sqrtPriceX96 >> 48;
        uint256 b = sqrtPriceX96 & ((1 << 48) - 1);
        uint256 price = a * a * 1e18 / Q96;
        price += (2 * a * b * 1e18) >> 144;
        return price;
    }

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

    function getAmountsForBin(uint256 L, uint256 sqrtPriceCurrent, BinBounds memory bounds)
        internal
        pure
        returns (uint256 token0, uint256 token1)
    {
        return getTokenAmountsForBin(L, sqrtPriceCurrent, bounds);
    }

    function getBinBounds(uint256 binIndex, uint256 spacing, uint256 sqrtPriceBase)
        internal
        pure
        returns (BinBounds memory)
    {
        uint256 sqrtPriceLower = sqrtPriceBase + binIndex * spacing;
        uint256 sqrtPriceUpper = sqrtPriceLower + spacing;
        return BinBounds(sqrtPriceLower, sqrtPriceUpper);
    }

    function getMintAmounts(
        uint256 totalLiquidity,
        uint256 totalToken0,
        uint256 totalToken1,
        uint256 sharesToMint,
        uint256 totalSupply
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sharesToMint == 0) return (0, 0);
        if (totalSupply == 0 || totalLiquidity == 0) {
            return (totalToken0, totalToken1);
        }
        amount0 = totalToken0 * sharesToMint / totalSupply;
        amount1 = totalToken1 * sharesToMint / totalSupply;
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
