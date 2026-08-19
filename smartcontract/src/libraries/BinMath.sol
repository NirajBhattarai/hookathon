// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title BinMath
/// @notice Per-bin constant-product swap (Uniswap v3 tick-range math).
/// @dev This is the curve, not the book shape. LinearDecay does not live here.
library BinMath {
    uint24 internal constant FEE_DENOMINATOR = 1_000_000;

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
