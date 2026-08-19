// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LiquidityLibrary} from "./LiquidityLibrary.sol";

/// @title LinearDecay
/// @notice L_i = LBase * (ramp - distance) / ramp. L reaches 0 at distance >= ramp.
/// @dev Uniform decrease. Simpler than exponential, less concentrated near price.
library LinearDecay {
    uint256 internal constant Q96 = LiquidityLibrary.Q96;

    function computeLPerBin(uint256 LBase, uint256 ramp, uint256 distance) internal pure returns (uint256) {
        if (distance == 0) return LBase;
        if (distance >= ramp) return 0;
        return LBase * (ramp - distance) / ramp;
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
            (uint256 t0, uint256 t1) =
                LiquidityLibrary.getTokenAmountsForBin(L, sqrtPriceCurrent, LiquidityLibrary.BinBounds(lo, hi));
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
            (uint256 t0, uint256 t1) =
                LiquidityLibrary.getTokenAmountsForBin(L, sqrtPriceCurrent, LiquidityLibrary.BinBounds(lo, hi));
            totalToken0 += t0;
            totalToken1 += t1;
        }
    }

    function distributeToken1WithBudget(uint256 token1Budget, uint256 binSpacing, uint256 numBins, uint256 ramp)
        internal
        pure
        returns (uint256 LBase, LiquidityLibrary.DepositAmounts memory amounts)
    {
        if (numBins == 0 || token1Budget == 0) return (0, LiquidityLibrary.DepositAmounts(0, 0));
        LBase = computeLBase(token1Budget, binSpacing, ramp, numBins);
        uint256 totalToken0;
        uint256 totalToken1;
        for (uint256 i = 0; i < numBins; i++) {
            uint256 distance = numBins - i;
            uint256 L = computeLPerBin(LBase, ramp, distance);
            uint256 lo = i * binSpacing;
            uint256 hi = (i + 1) * binSpacing;
            (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, hi, LiquidityLibrary.BinBounds(lo, hi));
            totalToken0 += t0;
            totalToken1 += t1;
        }
        amounts = LiquidityLibrary.DepositAmounts(totalToken0, totalToken1);
    }
}
