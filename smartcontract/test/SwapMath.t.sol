// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapMath as CoreSwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";

import {SwapMath} from "../src/libraries/SwapMath.sol";

contract SwapMathTest is Test {
    uint128 constant L = 1e18;
    uint24 constant FEE = 3000;
    uint256 constant MAX_FEE = 1_000_000;

    // scratch state for stack-heavy comparisons
    uint256 s_out;
    uint256 s_used;
    uint256 s_fee;
    uint160 s_end;
    uint256 s_endIndex;

    function _sqrtAt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function _bin(int24 tickLo, int24 tickHi) internal pure returns (SwapMath.Bin memory) {
        return SwapMath.Bin({L: L, sqrtLo: _sqrtAt(tickLo), sqrtHi: _sqrtAt(tickHi)});
    }

    // ── getSqrtPriceTarget ───────────────────────────────────────────────

    function test_getSqrtPriceTarget_boundaries() public pure {
        assertEq(SwapMath.getSqrtPriceTarget(false, _sqrtAt(0), _sqrtAt(60)), _sqrtAt(60));
        assertEq(SwapMath.getSqrtPriceTarget(true, _sqrtAt(0), _sqrtAt(60)), _sqrtAt(0));
    }

    function test_fuzz_getSqrtPriceTarget(bool zeroForOne, uint160 lo, uint160 hi) public pure {
        uint160 expected = zeroForOne ? lo : hi;
        assertEq(SwapMath.getSqrtPriceTarget(zeroForOne, lo, hi), expected);
    }

    // ── computeSwapStep: exact-in capped at bin boundary ────────────────

    function test_computeSwapStep_exactIn_cappedAtBoundary_oneForZero() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        uint256 toCross = SqrtPriceMath.getAmount1Delta(bin.sqrtLo, bin.sqrtHi, L, true);

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, -int256(toCross * 3), FEE, false);

        assertEq(sqrtQ, bin.sqrtHi);
        assertEq(amountIn, toCross);
        assertEq(feeAmount, FullMath.mulDivRoundingUp(amountIn, FEE, MAX_FEE - FEE));
        assertEq(amountOut, SqrtPriceMath.getAmount0Delta(bin.sqrtLo, bin.sqrtHi, L, false));
    }

    function test_computeSwapStep_exactIn_cappedAtBoundary_zeroForOne() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        uint256 toCross = SqrtPriceMath.getAmount0Delta(bin.sqrtLo, bin.sqrtHi, L, true);

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtHi, -int256(toCross * 3), FEE, true);

        assertEq(sqrtQ, bin.sqrtLo);
        assertEq(amountIn, toCross);
        assertEq(feeAmount, FullMath.mulDivRoundingUp(amountIn, FEE, MAX_FEE - FEE));
        assertEq(amountOut, SqrtPriceMath.getAmount1Delta(bin.sqrtLo, bin.sqrtHi, L, false));
    }

    // ── computeSwapStep: exact-in fully spent within bin ─────────────────

    function test_computeSwapStep_exactIn_fullySpentWithinBin_oneForZero() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        uint256 amountRemaining = 1e15;

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, -int256(amountRemaining), FEE, false);

        assertLt(sqrtQ, bin.sqrtHi);
        assertEq(amountIn + feeAmount, amountRemaining);
        assertEq(feeAmount, amountRemaining - FullMath.mulDiv(amountRemaining, MAX_FEE - FEE, MAX_FEE));
        assertEq(sqrtQ, SqrtPriceMath.getNextSqrtPriceFromInput(bin.sqrtLo, L, amountIn, false));
        assertEq(amountOut, SqrtPriceMath.getAmount0Delta(bin.sqrtLo, sqrtQ, L, false));
    }

    function test_computeSwapStep_exactIn_fullySpentWithinBin_zeroForOne() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        uint256 amountRemaining = 1e15;

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtHi, -int256(amountRemaining), FEE, true);

        assertGt(sqrtQ, bin.sqrtLo);
        assertEq(amountIn + feeAmount, amountRemaining);
        assertEq(sqrtQ, SqrtPriceMath.getNextSqrtPriceFromInput(bin.sqrtHi, L, amountIn, true));
        assertEq(amountOut, SqrtPriceMath.getAmount1Delta(sqrtQ, bin.sqrtHi, L, false));
    }

    // ── computeSwapStep: exact-out ───────────────────────────────────────

    function test_computeSwapStep_exactOut_cappedAtBoundary_oneForZero() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        uint256 fullOut = SqrtPriceMath.getAmount0Delta(bin.sqrtLo, bin.sqrtHi, L, false);

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, int256(fullOut * 2), FEE, false);

        assertEq(sqrtQ, bin.sqrtHi);
        assertEq(amountOut, fullOut);
        assertEq(amountIn, SqrtPriceMath.getAmount1Delta(bin.sqrtLo, bin.sqrtHi, L, true));
        assertEq(feeAmount, FullMath.mulDivRoundingUp(amountIn, FEE, MAX_FEE - FEE));
    }

    function test_computeSwapStep_exactOut_fullyReceived_oneForZero() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        uint256 requestedOut = 1e12;

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, int256(requestedOut), FEE, false);

        assertLt(sqrtQ, bin.sqrtHi);
        assertEq(amountOut, requestedOut);
        assertEq(sqrtQ, SqrtPriceMath.getNextSqrtPriceFromOutput(bin.sqrtLo, L, requestedOut, false));
        assertEq(amountIn, SqrtPriceMath.getAmount1Delta(bin.sqrtLo, sqrtQ, L, true));
        assertEq(feeAmount, FullMath.mulDivRoundingUp(amountIn, FEE, MAX_FEE - FEE));
    }

    // ── computeSwapStep: fee edges ───────────────────────────────────────

    function test_computeSwapStep_feeAtMax_takesAllInput() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, -int256(1e18), uint24(MAX_FEE), false);

        assertEq(sqrtQ, bin.sqrtLo);
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 1e18);
    }

    function test_computeSwapStep_zeroFee() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        uint256 toCross = SqrtPriceMath.getAmount1Delta(bin.sqrtLo, bin.sqrtHi, L, true);

        (,, uint256 amountOutCapped, uint256 feeCapped) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, -int256(toCross * 3), 0, false);
        assertEq(feeCapped, 0);
        assertEq(amountOutCapped, SqrtPriceMath.getAmount0Delta(bin.sqrtLo, bin.sqrtHi, L, false));

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, -int256(1e15), 0, false);
        assertEq(feeAmount, 0);
        assertEq(amountIn, 1e15);
        assertGt(amountOut, 0);
        assertEq(sqrtQ, SqrtPriceMath.getNextSqrtPriceFromInput(bin.sqrtLo, L, 1e15, false));
    }

    // ── computeSwapStep: empty bins, clamping, no-ops ────────────────────

    function test_computeSwapStep_emptyBin_crossesFree() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        bin.L = 0;

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, -int256(1e18), FEE, false);
        assertEq(sqrtQ, bin.sqrtHi);
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);

        (sqrtQ, amountIn, amountOut, feeAmount) = SwapMath.computeSwapStep(bin, bin.sqrtLo, int256(1e12), FEE, false);
        assertEq(sqrtQ, bin.sqrtHi);
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);
    }

    function test_computeSwapStep_clampsPriceOutsideBin() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);
        uint160 below = _sqrtAt(-120);
        uint160 above = _sqrtAt(120);

        (uint160 qClamped, uint256 inClamped, uint256 outClamped, uint256 feeClamped) =
            SwapMath.computeSwapStep(bin, below, -int256(1e15), FEE, false);
        (uint160 qAtEdge, uint256 inEdge, uint256 outEdge, uint256 feeEdge) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, -int256(1e15), FEE, false);
        assertEq(qClamped, qAtEdge);
        assertEq(inClamped, inEdge);
        assertEq(outClamped, outEdge);
        assertEq(feeClamped, feeEdge);

        (qClamped, inClamped, outClamped, feeClamped) = SwapMath.computeSwapStep(bin, above, -int256(1e15), FEE, true);
        (qAtEdge, inEdge, outEdge, feeEdge) = SwapMath.computeSwapStep(bin, bin.sqrtHi, -int256(1e15), FEE, true);
        assertEq(qClamped, qAtEdge);
        assertEq(inClamped, inEdge);
        assertEq(outClamped, outEdge);
        assertEq(feeClamped, feeEdge);
    }

    function test_computeSwapStep_noOp_zeroAmountOrAtTarget() public pure {
        SwapMath.Bin memory bin = _bin(0, 60);

        (uint160 sqrtQ, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(bin, bin.sqrtLo, 0, FEE, false);
        assertEq(sqrtQ, bin.sqrtLo);
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);

        (sqrtQ, amountIn, amountOut, feeAmount) = SwapMath.computeSwapStep(bin, bin.sqrtHi, -int256(1e18), FEE, false);
        assertEq(sqrtQ, bin.sqrtHi);
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);

        (sqrtQ, amountIn, amountOut, feeAmount) = SwapMath.computeSwapStep(bin, bin.sqrtLo, -int256(1e18), FEE, true);
        assertEq(sqrtQ, bin.sqrtLo);
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);
    }

    // ── equivalence with v4-core computeSwapStep ─────────────────────────

    function test_equivalence_coreSwapStep_spentWithinRange_bothDirections() public pure {
        SwapMath.Bin memory up = _bin(0, 60);
        SwapMath.Bin memory down = _bin(0, 60);
        uint256 r = 1e15;

        (uint160 cq, uint256 cin, uint256 cout, uint256 cfee) =
            CoreSwapMath.computeSwapStep(up.sqrtLo, up.sqrtHi, L, -int256(r), FEE);
        (uint160 bq, uint256 bin_, uint256 bout, uint256 bfee) =
            SwapMath.computeSwapStep(up, up.sqrtLo, -int256(r), FEE, false);
        assertEq(bq, cq);
        assertEq(bin_, cin);
        assertEq(bout, cout);
        assertEq(bfee, cfee);

        (cq, cin, cout, cfee) = CoreSwapMath.computeSwapStep(down.sqrtHi, down.sqrtLo, L, -int256(r), FEE);
        (bq, bin_, bout, bfee) = SwapMath.computeSwapStep(down, down.sqrtHi, -int256(r), FEE, true);
        assertEq(bq, cq);
        assertEq(bin_, cin);
        assertEq(bout, cout);
        assertEq(bfee, cfee);
    }

    function test_equivalence_coreSwapStep_cappedAtTarget_bothDirections() public pure {
        SwapMath.Bin memory up = _bin(0, 60);
        SwapMath.Bin memory down = _bin(0, 60);
        uint256 r = 1e30;

        (uint160 cq, uint256 cin, uint256 cout, uint256 cfee) =
            CoreSwapMath.computeSwapStep(up.sqrtLo, up.sqrtHi, L, -int256(r), FEE);
        (uint160 bq, uint256 bin_, uint256 bout, uint256 bfee) =
            SwapMath.computeSwapStep(up, up.sqrtLo, -int256(r), FEE, false);
        assertEq(bq, cq);
        assertEq(bin_, cin);
        assertEq(bout, cout);
        assertEq(bfee, cfee);

        (cq, cin, cout, cfee) = CoreSwapMath.computeSwapStep(down.sqrtHi, down.sqrtLo, L, -int256(r), FEE);
        (bq, bin_, bout, bfee) = SwapMath.computeSwapStep(down, down.sqrtHi, -int256(r), FEE, true);
        assertEq(bq, cq);
        assertEq(bin_, cin);
        assertEq(bout, cout);
        assertEq(bfee, cfee);
    }

    function test_fuzz_equivalence_coreSwapStep(uint128 liquidity, uint256 amount, uint24 feePips, bool zeroForOne)
        public
    {
        liquidity = uint128(bound(liquidity, 1e9, 1e21));
        amount = bound(amount, 1, 1e18);
        feePips = uint24(bound(feePips, 0, MAX_FEE - 1));

        SwapMath.Bin memory bin = _bin(0, 60);
        bin.L = liquidity;
        uint160 start = zeroForOne ? bin.sqrtHi : bin.sqrtLo;
        uint160 target = zeroForOne ? bin.sqrtLo : bin.sqrtHi;

        (s_end, s_used, s_out, s_fee) = CoreSwapMath.computeSwapStep(start, target, liquidity, -int256(amount), feePips);

        (uint160 bq, uint256 bIn, uint256 bOut, uint256 bFee) =
            SwapMath.computeSwapStep(bin, start, -int256(amount), feePips, zeroForOne);

        assertEq(bq, s_end);
        assertEq(bIn, s_used);
        assertEq(bOut, s_out);
        assertEq(bFee, s_fee);
    }

    // ── swapExactInMulti: multi-bin walks ────────────────────────────────

    function test_walk_twoBins_priceUp_feeZero() public pure {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 drain0 = SqrtPriceMath.getAmount1Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, true);
        uint256 extra = drain0 / 10;

        (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, bins[0].sqrtLo, 0, drain0 + extra, false, 0, 1, 0);

        assertEq(endIndex, 1);
        assertGt(end, bins[1].sqrtLo);
        assertLt(end, bins[1].sqrtHi);
        assertEq(used, drain0 + extra);
        assertEq(fee, 0);
        assertGt(out, 0);
    }

    function test_walk_twoBins_priceDown_feeZero() public pure {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 drain1 = SqrtPriceMath.getAmount0Delta(bins[1].sqrtLo, bins[1].sqrtHi, L, true);
        uint256 extra = drain1 / 10;

        (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, bins[1].sqrtHi, 1, drain1 + extra, true, 0, 1, 0);

        assertEq(endIndex, 0);
        assertGt(end, bins[0].sqrtLo);
        assertLt(end, bins[0].sqrtHi);
        assertEq(used, drain1 + extra);
        assertEq(fee, 0);
        assertGt(out, 0);
    }

    function test_walk_hiClamp_blocksSecondBin() public pure {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 drain0 = SqrtPriceMath.getAmount1Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, true);
        uint256 extra = drain0 / 2;

        (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, bins[0].sqrtLo, 0, drain0 + extra, false, 0, 0, 0);

        assertEq(endIndex, 0);
        assertEq(end, bins[0].sqrtHi);
        assertEq(used, drain0);
        assertLt(used, drain0 + extra);
        assertEq(fee, 0);
        assertEq(out, SqrtPriceMath.getAmount0Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, false));
    }

    function test_walk_loClamp_blocksFirstBin() public pure {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 drain1 = SqrtPriceMath.getAmount0Delta(bins[1].sqrtLo, bins[1].sqrtHi, L, true);
        uint256 extra = drain1 / 2;

        (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, bins[1].sqrtHi, 1, drain1 + extra, true, 1, 1, 0);

        assertEq(endIndex, 1);
        assertEq(end, bins[1].sqrtLo);
        assertEq(used, drain1);
        assertLt(used, drain1 + extra);
        assertEq(fee, 0);
        assertEq(out, SqrtPriceMath.getAmount1Delta(bins[1].sqrtLo, bins[1].sqrtHi, L, false));
    }

    function test_walk_crossesEmptyBins_free() public pure {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](3);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);
        bins[1].L = 0;
        bins[2] = _bin(120, 180);

        uint256 drain0 = SqrtPriceMath.getAmount1Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, true);
        uint256 into2 = 1e14;

        (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, bins[0].sqrtLo, 0, drain0 + into2, false, 0, 2, 0);

        uint160 endRef = SqrtPriceMath.getNextSqrtPriceFromInput(bins[2].sqrtLo, L, into2, false);
        uint256 expectedOut = SqrtPriceMath.getAmount0Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, false)
            + SqrtPriceMath.getAmount0Delta(bins[2].sqrtLo, endRef, L, false);

        assertEq(endIndex, 2);
        assertEq(end, endRef);
        assertGt(end, bins[2].sqrtLo);
        assertLt(end, bins[2].sqrtHi);
        assertEq(used, drain0 + into2);
        assertEq(fee, 0);
        assertEq(out, expectedOut);
    }

    function test_walk_roundTrip_upThenDown_lossesToSpreadAndFees() public pure {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 inUp = SqrtPriceMath.getAmount1Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, true) / 4;
        (uint256 outUp, uint256 usedUp,, uint160 p1,) =
            SwapMath.swapExactInMulti(bins, bins[0].sqrtLo, 0, inUp, false, 0, 1, FEE);
        assertEq(usedUp, inUp);
        assertGt(p1, bins[0].sqrtLo);

        (uint256 outDown, uint256 usedDown,, uint160 p2,) =
            SwapMath.swapExactInMulti(bins, p1, 0, outUp, true, 0, 1, FEE);

        assertEq(usedDown, outUp);
        assertGt(outDown, 0);
        assertLt(p2, p1);
        assertGt(p2, bins[0].sqrtLo);
    }

    function test_walk_totalsMatchManualPerStepReplay_withFees() public {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 amountIn = SqrtPriceMath.getAmount1Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, true) + 1e14;

        (s_out, s_used, s_fee, s_end, s_endIndex) =
            SwapMath.swapExactInMulti(bins, bins[0].sqrtLo, 0, amountIn, false, 0, 1, FEE);

        _assertReplayMatches(bins, amountIn);
    }

    function _assertReplayMatches(SwapMath.Bin[] memory bins, uint256 amountIn) internal view {
        uint256 remaining = amountIn;
        uint256 stepIn;
        uint256 stepOut;
        uint256 stepFee;
        uint160 q;

        (q, stepIn, stepOut, stepFee) =
            SwapMath.computeSwapStep(bins[0], bins[0].sqrtLo, -int256(remaining), FEE, false);
        remaining -= stepIn + stepFee;
        uint256 expUsed = stepIn + stepFee;
        uint256 expFee = stepFee;
        uint256 expOut = stepOut;

        (q, stepIn, stepOut, stepFee) = SwapMath.computeSwapStep(bins[1], q, -int256(remaining), FEE, false);
        remaining -= stepIn + stepFee;
        expUsed += stepIn + stepFee;
        expFee += stepFee;
        expOut += stepOut;

        assertEq(remaining, 0);
        assertEq(s_out, expOut);
        assertEq(s_used, expUsed);
        assertEq(s_fee, expFee);
        assertEq(s_end, q);
        assertEq(s_endIndex, 1);
    }

    function test_walk_guards_emptyBookAndZeroAmount() public pure {
        SwapMath.Bin[] memory noBins = new SwapMath.Bin[](0);
        (uint256 out, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(noBins, 1, 0, 1e18, false, 0, 0, FEE);
        assertEq(out, 0);
        assertEq(used, 0);
        assertEq(fee, 0);
        assertEq(end, 1);
        assertEq(endIndex, 0);

        SwapMath.Bin[] memory bins = new SwapMath.Bin[](1);
        bins[0] = _bin(0, 60);
        (out, used, fee, end, endIndex) = SwapMath.swapExactInMulti(bins, bins[0].sqrtLo, 0, 0, false, 0, 0, FEE);
        assertEq(out, 0);
        assertEq(used, 0);
        assertEq(fee, 0);
        assertEq(end, bins[0].sqrtLo);
        assertEq(endIndex, 0);
    }

    // ── fuzz: computeSwapStep vs reference implementation ────────────────

    function test_fuzz_computeSwapStep_exactIn_matchesReference(
        uint128 liquidity,
        uint256 priceSeed,
        uint256 amount,
        uint24 feePips,
        bool zeroForOne
    ) public {
        liquidity = uint128(bound(liquidity, 1e9, 1e21));
        feePips = uint24(bound(feePips, 0, MAX_FEE - 1));

        SwapMath.Bin memory bin = _bin(0, 60);
        bin.L = liquidity;
        uint160 sqrtP = uint160(bound(priceSeed, bin.sqrtLo, bin.sqrtHi));
        uint256 gross = bound(amount, 1, 1e18);

        (s_end, s_used, s_out, s_fee) = _refExactIn(bin, sqrtP, gross, feePips, zeroForOne);

        (uint160 q, uint256 amtIn, uint256 amtOut, uint256 feeAmt) =
            SwapMath.computeSwapStep(bin, sqrtP, -int256(gross), feePips, zeroForOne);

        assertEq(q, s_end);
        assertEq(amtIn, s_used);
        assertEq(amtOut, s_out);
        assertEq(feeAmt, s_fee);
    }

    function test_fuzz_computeSwapStep_exactOut_matchesReference(
        uint128 liquidity,
        uint256 priceSeed,
        uint256 amount,
        uint24 feePips,
        bool zeroForOne
    ) public {
        liquidity = uint128(bound(liquidity, 1e9, 1e21));
        feePips = uint24(bound(feePips, 0, MAX_FEE - 1));

        SwapMath.Bin memory bin = _bin(0, 60);
        bin.L = liquidity;
        uint160 sqrtP = uint160(bound(priceSeed, bin.sqrtLo, bin.sqrtHi));

        uint256 maxOut = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(bin.sqrtLo, bin.sqrtHi, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(bin.sqrtLo, bin.sqrtHi, liquidity, false);
        if (maxOut < 2) return;
        uint256 requested = bound(amount, 1, maxOut - 1);

        (s_end, s_used, s_out, s_fee) = _refExactOut(bin, sqrtP, requested, feePips, zeroForOne);

        (uint160 q, uint256 amtIn, uint256 amtOut, uint256 feeAmt) =
            SwapMath.computeSwapStep(bin, sqrtP, int256(requested), feePips, zeroForOne);

        assertEq(q, s_end);
        assertEq(amtIn, s_used);
        assertEq(amtOut, s_out);
        assertEq(feeAmt, s_fee);
    }

    function _refExactIn(SwapMath.Bin memory bin, uint160 sqrtP, uint256 gross, uint24 feePips, bool zeroForOne)
        internal
        pure
        returns (uint160 q, uint256 amtIn, uint256 amtOut, uint256 feeAmt)
    {
        uint256 netMax = FullMath.mulDiv(gross, MAX_FEE - feePips, MAX_FEE);
        uint256 toTarget = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(bin.sqrtLo, sqrtP, bin.L, true)
            : SqrtPriceMath.getAmount1Delta(sqrtP, bin.sqrtHi, bin.L, true);

        if (netMax >= toTarget) {
            q = zeroForOne ? bin.sqrtLo : bin.sqrtHi;
            amtIn = toTarget;
            feeAmt = FullMath.mulDivRoundingUp(toTarget, feePips, MAX_FEE - feePips);
        } else {
            amtIn = netMax;
            feeAmt = gross - netMax;
            q = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtP, bin.L, netMax, zeroForOne);
        }
        amtOut = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(q, sqrtP, bin.L, false)
            : SqrtPriceMath.getAmount0Delta(sqrtP, q, bin.L, false);
    }

    function _refExactOut(SwapMath.Bin memory bin, uint160 sqrtP, uint256 requested, uint24 feePips, bool zeroForOne)
        internal
        pure
        returns (uint160 q, uint256 amtIn, uint256 amtOut, uint256 feeAmt)
    {
        uint256 availToTarget = zeroForOne
            ? SqrtPriceMath.getAmount1Delta(bin.sqrtLo, sqrtP, bin.L, false)
            : SqrtPriceMath.getAmount0Delta(sqrtP, bin.sqrtHi, bin.L, false);

        if (requested >= availToTarget) {
            q = zeroForOne ? bin.sqrtLo : bin.sqrtHi;
            amtOut = availToTarget;
        } else {
            amtOut = requested;
            q = SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtP, bin.L, requested, zeroForOne);
        }
        amtIn = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(q, sqrtP, bin.L, true)
            : SqrtPriceMath.getAmount1Delta(sqrtP, q, bin.L, true);
        feeAmt = FullMath.mulDivRoundingUp(amtIn, feePips, MAX_FEE - feePips);
    }

    // ── fuzz: swapExactInMulti invariants ────────────────────────────────

    function test_fuzz_swapExactInMulti_invariants_up(uint128 l0, uint128 l1, uint256 amount, uint24 feePips)
        public
        pure
    {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[0].L = uint128(bound(l0, 0, 1e20));
        bins[1] = _bin(60, 120);
        bins[1].L = uint128(bound(l1, 0, 1e20));

        amount = bound(amount, 1, 1e18);
        feePips = uint24(bound(feePips, 0, MAX_FEE));

        (, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, bins[0].sqrtLo, 0, amount, false, 0, 1, feePips);

        assertLe(used, amount);
        assertLe(fee, used);
        assertTrue(endIndex == 0 || endIndex == 1);
        assertGe(end, bins[0].sqrtLo);
    }

    function test_fuzz_swapExactInMulti_invariants_down(uint128 l0, uint128 l1, uint256 amount, uint24 feePips)
        public
        pure
    {
        SwapMath.Bin[] memory bins = new SwapMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[0].L = uint128(bound(l0, 0, 1e20));
        bins[1] = _bin(60, 120);
        bins[1].L = uint128(bound(l1, 0, 1e20));

        amount = bound(amount, 1, 1e18);
        feePips = uint24(bound(feePips, 0, MAX_FEE));

        (, uint256 used, uint256 fee, uint160 end, uint256 endIndex) =
            SwapMath.swapExactInMulti(bins, bins[1].sqrtHi, 1, amount, true, 0, 1, feePips);

        assertLe(used, amount);
        assertLe(fee, used);
        assertTrue(endIndex == 0 || endIndex == 1);
        assertLe(end, bins[1].sqrtHi);
    }
}
