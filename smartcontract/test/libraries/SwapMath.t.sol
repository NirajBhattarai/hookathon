// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "src/libraries/SwapMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract SwapMathTest is Test {
    uint256 internal constant MAX_FUZZ_BINS = 100;
    uint256 internal constant MAX_FEE = 100_000;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    function _bin(int24 sqrtLoTick, int24 sqrtHiTick) internal pure returns (SwapMath.Bin memory bin) {
        bin.sqrtLo = TickMath.getSqrtPriceAtTick(sqrtLoTick);
        bin.sqrtHi = TickMath.getSqrtPriceAtTick(sqrtHiTick);
    }

    function _fuzzBook(uint256 nSeed, uint256 lSeed, uint256 baseSeed)
        internal
        pure
        returns (SwapMath.Bin[] memory bins)
    {
        uint256 n = bound(nSeed, 1, MAX_FUZZ_BINS);

        uint256 span = uint256(int256(n)) * 60;
        int24 baseTick = int24(
            int256(bound(baseSeed, 0, uint256(int256(TickMath.MAX_TICK - TickMath.MIN_TICK)) - span))
                + int256(TickMath.MIN_TICK)
        );

        bins = new SwapMath.Bin[](n);

        for (uint256 i; i < n; ++i) {
            bins[i] = _bin(baseTick + int24(int256(i)) * 60, baseTick + int24(int256(i + 1)) * 60);
            uint256 li = uint256(keccak256(abi.encodePacked(lSeed, i)));
            bins[i].L = li % 5 == 0 ? 0 : uint128(bound(li, 1, 1e20));
        }
    }

    function test_fuzz_walk_multiBin_up(
        uint256 nSeed,
        uint256 lSeed,
        uint256 baseSeed,
        uint256 activeSeed,
        uint256 startSeed,
        uint256 loSeed,
        uint256 hiSeed,
        uint256 amountSeed,
        uint24 feePips
    ) public pure {
        SwapMath.Bin[] memory bins = _fuzzBook(nSeed, lSeed, baseSeed);
        uint256 last = bins.length - 1;
        uint256 active = bound(activeSeed, 0, last);
        uint160 start = uint160(bound(startSeed, bins[active].sqrtLo, bins[active].sqrtHi));
        uint256 lo = bound(loSeed, 0, active);
        uint256 hi = bound(hiSeed, active, last);
        uint256 amount = bound(amountSeed, 0, 2e18);
        feePips = uint24(bound(feePips, 0, MAX_FEE));

        (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, start, active, amount, false, lo, hi, feePips);

        assertLe(used, amount);
        assertLe(fee, used);
        assertTrue(endIndex >= active && endIndex <= hi);
        assertGe(end, start);
        assertLe(end, bins[hi].sqrtHi);

        if (used < amount) {
            assertEq(endIndex, hi);
            assertEq(uint256(end), uint256(bins[hi].sqrtHi));
        }
        if (end < bins[hi].sqrtHi) {
            assertEq(used, amount);
        }

        (uint256 refOut, uint256 refUsed, uint256 refFee, uint160 refEnd, uint256 refEndIndex) =
            _refWalkUp(bins, start, active, amount, hi, feePips);
        assertEq(out, refOut);
        assertEq(used, refUsed);
        assertEq(fee, refFee);
        assertEq(uint256(end), uint256(refEnd));
        assertEq(endIndex, refEndIndex);
    }

    function test_fuzz_walk_multiBin_down(
        uint256 nSeed,
        uint256 lSeed,
        uint256 baseSeed,
        uint256 activeSeed,
        uint256 startSeed,
        uint256 loSeed,
        uint256 hiSeed,
        uint256 amountSeed,
        uint24 feePips
    ) public pure {
        SwapMath.Bin[] memory bins = _fuzzBook(nSeed, lSeed, baseSeed);
        uint256 last = bins.length - 1;
        uint256 active = bound(activeSeed, 0, last);
        uint160 start = uint160(bound(startSeed, bins[active].sqrtLo, bins[active].sqrtHi));
        uint256 lo = bound(loSeed, 0, active);
        uint256 hi = bound(hiSeed, active, last);
        uint256 amount = bound(amountSeed, 0, 2e18);
        feePips = uint24(bound(feePips, 0, MAX_FEE));

        (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, start, active, amount, true, lo, hi, feePips);

        assertLe(used, amount);
        assertLe(fee, used);
        assertTrue(endIndex >= lo && endIndex <= active);
        assertLe(end, start);
        assertGe(end, bins[lo].sqrtLo);

        if (used < amount) {
            assertEq(endIndex, lo);
            assertEq(uint256(end), uint256(bins[lo].sqrtLo));
        }
        if (end > bins[lo].sqrtLo) {
            assertEq(used, amount);
        }

        (uint256 refOut, uint256 refUsed, uint256 refFee, uint160 refEnd, uint256 refEndIndex) =
            _refWalkDown(bins, start, active, amount, lo, feePips);
        assertEq(out, refOut);
        assertEq(used, refUsed);
        assertEq(fee, refFee);
        assertEq(uint256(end), uint256(refEnd));
        assertEq(endIndex, refEndIndex);
    }

    /// @dev Independent exact-in replay toward higher prices, mirroring v4-core per-step math.
    function _refWalkUp(
        SwapMath.Bin[] memory bins,
        uint160 start,
        uint256 active,
        uint256 gross,
        uint256 hi,
        uint24 feePips
    ) internal pure returns (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) {
        uint160 q = start;
        endIndex = active;
        for (uint256 i = active; i <= hi && gross > 0; ++i) {
            uint128 l = bins[i].L;
            uint160 tgt = bins[i].sqrtHi;
            if (l == 0) {
                q = tgt;
                endIndex = i;
                continue;
            }
            uint160 prev = q;
            uint256 required = SqrtPriceMath.getAmount1Delta(q, tgt, l, true);
            uint256 maxNet = FullMath.mulDiv(gross, FEE_DENOMINATOR - feePips, FEE_DENOMINATOR);
            if (maxNet >= required) {
                uint256 stepFee = FullMath.mulDivRoundingUp(required, feePips, FEE_DENOMINATOR - feePips);
                out += SqrtPriceMath.getAmount0Delta(prev, tgt, l, false);
                fee += stepFee;
                used += required + stepFee;
                gross -= required + stepFee;
                q = tgt;
            } else {
                q = SqrtPriceMath.getNextSqrtPriceFromInput(prev, l, maxNet, false);
                out += SqrtPriceMath.getAmount0Delta(prev, q, l, false);
                fee += gross - maxNet;
                used += gross;
                gross = 0;
            }
            endIndex = i;
        }
        end = q;
    }

    /// @dev Independent exact-in replay toward lower prices, mirroring v4-core per-step math.
    function _refWalkDown(
        SwapMath.Bin[] memory bins,
        uint160 start,
        uint256 active,
        uint256 gross,
        uint256 lo,
        uint24 feePips
    ) internal pure returns (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) {
        uint160 q = start;
        endIndex = active;
        uint256 i = active;
        while (gross > 0) {
            uint128 l = bins[i].L;
            uint160 tgt = bins[i].sqrtLo;
            if (l == 0) {
                q = tgt;
                endIndex = i;
                if (i == lo) break;
                --i;
                continue;
            }
            uint160 prev = q;
            uint256 required = SqrtPriceMath.getAmount0Delta(tgt, prev, l, true);
            uint256 maxNet = FullMath.mulDiv(gross, FEE_DENOMINATOR - feePips, FEE_DENOMINATOR);
            if (maxNet >= required) {
                uint256 stepFee = FullMath.mulDivRoundingUp(required, feePips, FEE_DENOMINATOR - feePips);
                out += SqrtPriceMath.getAmount1Delta(prev, tgt, l, false);
                fee += stepFee;
                used += required + stepFee;
                gross -= required + stepFee;
                q = tgt;
            } else {
                q = SqrtPriceMath.getNextSqrtPriceFromInput(prev, l, maxNet, true);
                out += SqrtPriceMath.getAmount1Delta(prev, q, l, false);
                fee += gross - maxNet;
                used += gross;
                gross = 0;
            }
            endIndex = i;
            if (i == lo) break;
            --i;
        }
        end = q;
    }
}
