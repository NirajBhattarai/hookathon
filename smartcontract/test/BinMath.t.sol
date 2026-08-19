// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {BinMath} from "../src/libraries/BinMath.sol";

contract BinMathTest is Test {
    uint128 constant L = 1e18;

    function _bin(int24 tickLo, int24 tickHi) internal pure returns (BinMath.Bin memory) {
        return BinMath.Bin({
            L: L,
            sqrtLo: TickMath.getSqrtPriceAtTick(tickLo),
            sqrtHi: TickMath.getSqrtPriceAtTick(tickHi)
        });
    }

    function test_singleBin_exactIn_token1_matchesDelta() public pure {
        BinMath.Bin memory bin = _bin(0, 60);
        uint160 start = bin.sqrtLo;

        uint256 amount1In = 1e15;
        BinMath.Step memory step = BinMath.swapExactInSingle(bin, start, amount1In, false);

        assertFalse(step.crossed);
        assertEq(step.amountInUsed, amount1In);
        assertGt(step.sqrtEnd, start);
        assertLt(step.sqrtEnd, bin.sqrtHi);

        uint256 expectedOut = SqrtPriceMath.getAmount0Delta(start, step.sqrtEnd, L, false);
        assertEq(step.amountOut, expectedOut);
    }

    function test_singleBin_exactIn_token0_matchesDelta() public pure {
        BinMath.Bin memory bin = _bin(0, 60);
        uint160 start = bin.sqrtHi;

        uint256 amount0In = 1e15;
        BinMath.Step memory step = BinMath.swapExactInSingle(bin, start, amount0In, true);

        assertFalse(step.crossed);
        assertEq(step.amountInUsed, amount0In);
        assertLt(step.sqrtEnd, start);
        assertGt(step.sqrtEnd, bin.sqrtLo);

        uint256 expectedOut = SqrtPriceMath.getAmount1Delta(step.sqrtEnd, start, L, false);
        assertEq(step.amountOut, expectedOut);
    }

    function test_singleBin_fullCross_usesBound() public pure {
        BinMath.Bin memory bin = _bin(0, 60);
        uint256 toCross = SqrtPriceMath.getAmount1Delta(bin.sqrtLo, bin.sqrtHi, L, true);
        BinMath.Step memory step = BinMath.swapExactInSingle(bin, bin.sqrtLo, toCross * 2, false);

        assertTrue(step.crossed);
        assertEq(step.sqrtEnd, bin.sqrtHi);
        assertEq(step.amountInUsed, SqrtPriceMath.getAmount1Delta(bin.sqrtLo, bin.sqrtHi, L, true));
        assertEq(step.amountOut, SqrtPriceMath.getAmount0Delta(bin.sqrtLo, bin.sqrtHi, L, false));
    }

    function test_emptyBin_skipsToBound() public pure {
        BinMath.Bin memory bin = _bin(0, 60);
        bin.L = 0;
        BinMath.Step memory step = BinMath.swapExactInSingle(bin, bin.sqrtLo, 1e18, false);
        assertTrue(step.crossed);
        assertEq(step.amountInUsed, 0);
        assertEq(step.amountOut, 0);
        assertEq(step.sqrtEnd, bin.sqrtHi);
    }

    function test_walk_twoBins_priceUp() public pure {
        BinMath.Bin[] memory bins = new BinMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 drain0 = SqrtPriceMath.getAmount1Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, true);
        uint256 extra = drain0 / 10;

        (uint256 out, uint256 used, uint160 sqrtEnd, uint256 endIndex) =
            BinMath.swapExactIn(bins, bins[0].sqrtLo, 0, drain0 + extra, false, 0, 1);

        assertEq(endIndex, 1);
        assertGt(sqrtEnd, bins[1].sqrtLo);
        assertLt(sqrtEnd, bins[1].sqrtHi);
        assertEq(used, drain0 + extra);
        assertGt(out, 0);
    }

    function test_walk_ratchetClamp_blocksSecondBin() public pure {
        BinMath.Bin[] memory bins = new BinMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 drain0 = SqrtPriceMath.getAmount1Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, true);
        uint256 extra = drain0 / 2;

        // hi = 0: cannot enter bin 1
        (uint256 out, uint256 used, uint160 sqrtEnd, uint256 endIndex) =
            BinMath.swapExactIn(bins, bins[0].sqrtLo, 0, drain0 + extra, false, 0, 0);

        assertEq(endIndex, 0);
        assertEq(sqrtEnd, bins[0].sqrtHi);
        assertEq(used, drain0);
        assertLt(used, drain0 + extra);
        assertGt(out, 0);
    }

    function test_applyFee_3000pips() public pure {
        assertEq(BinMath.applyFee(1_000_000, 3000), 997_000);
        assertEq(BinMath.applyFee(100, 0), 100);
        assertEq(BinMath.applyFee(0, 3000), 0);
        assertEq(BinMath.applyFee(1e18, 1), 1e18 * 999_999 / 1_000_000);
    }

    function test_singleBin_zeroAmount_noMove() public pure {
        BinMath.Bin memory bin = _bin(0, 60);
        BinMath.Step memory step = BinMath.swapExactInSingle(bin, bin.sqrtLo, 0, false);
        assertEq(step.amountInUsed, 0);
        assertEq(step.amountOut, 0);
        assertEq(step.sqrtEnd, bin.sqrtLo);
        assertFalse(step.crossed);
    }

    function test_singleBin_alreadyAtTarget_noMove() public pure {
        BinMath.Bin memory bin = _bin(0, 60);
        BinMath.Step memory up = BinMath.swapExactInSingle(bin, bin.sqrtHi, 1e18, false);
        assertEq(up.amountInUsed, 0);
        assertEq(up.sqrtEnd, bin.sqrtHi);

        BinMath.Step memory down = BinMath.swapExactInSingle(bin, bin.sqrtLo, 1e18, true);
        assertEq(down.amountInUsed, 0);
        assertEq(down.sqrtEnd, bin.sqrtLo);
    }

    function test_singleBin_clampsPriceOutsideRange() public pure {
        BinMath.Bin memory bin = _bin(0, 60);
        uint160 below = TickMath.getSqrtPriceAtTick(-60);
        BinMath.Step memory up = BinMath.swapExactInSingle(bin, below, 1e15, false);
        assertGt(up.sqrtEnd, bin.sqrtLo);
        assertLe(up.sqrtEnd, bin.sqrtHi);

        uint160 above = TickMath.getSqrtPriceAtTick(120);
        BinMath.Step memory down = BinMath.swapExactInSingle(bin, above, 1e15, true);
        assertLt(down.sqrtEnd, bin.sqrtHi);
        assertGe(down.sqrtEnd, bin.sqrtLo);
    }

    function test_singleBin_fullCross_token0In() public pure {
        BinMath.Bin memory bin = _bin(0, 60);
        uint256 toCross = SqrtPriceMath.getAmount0Delta(bin.sqrtLo, bin.sqrtHi, L, true);
        BinMath.Step memory step = BinMath.swapExactInSingle(bin, bin.sqrtHi, toCross * 2, true);
        assertTrue(step.crossed);
        assertEq(step.sqrtEnd, bin.sqrtLo);
        assertEq(step.amountInUsed, toCross);
    }

    function test_swapExactIn_emptyBook() public pure {
        BinMath.Bin[] memory bins = new BinMath.Bin[](0);
        (uint256 out, uint256 used, uint160 sqrtEnd, uint256 endIndex) =
            BinMath.swapExactIn(bins, 1, 0, 1e18, false, 0, 0);
        assertEq(out, 0);
        assertEq(used, 0);
        assertEq(sqrtEnd, 1);
        assertEq(endIndex, 0);
    }

    function test_swapExactIn_zeroAmount() public pure {
        BinMath.Bin[] memory bins = new BinMath.Bin[](1);
        bins[0] = _bin(0, 60);
        (uint256 out, uint256 used, uint160 sqrtEnd, uint256 endIndex) =
            BinMath.swapExactIn(bins, bins[0].sqrtLo, 0, 0, false, 0, 0);
        assertEq(out, 0);
        assertEq(used, 0);
        assertEq(sqrtEnd, bins[0].sqrtLo);
        assertEq(endIndex, 0);
    }

    function test_walk_twoBins_priceDown() public pure {
        BinMath.Bin[] memory bins = new BinMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 drain1 = SqrtPriceMath.getAmount0Delta(bins[1].sqrtLo, bins[1].sqrtHi, L, true);
        uint256 extra = drain1 / 10;

        (uint256 out, uint256 used, uint160 sqrtEnd, uint256 endIndex) =
            BinMath.swapExactIn(bins, bins[1].sqrtHi, 1, drain1 + extra, true, 0, 1);

        assertEq(endIndex, 0);
        assertLt(sqrtEnd, bins[0].sqrtHi);
        assertGt(sqrtEnd, bins[0].sqrtLo);
        assertEq(used, drain1 + extra);
        assertGt(out, 0);
    }

    function test_walk_upThenDown_sameBook() public pure {
        BinMath.Bin[] memory bins = new BinMath.Bin[](2);
        bins[0] = _bin(0, 60);
        bins[1] = _bin(60, 120);

        uint256 inUp = SqrtPriceMath.getAmount1Delta(bins[0].sqrtLo, bins[0].sqrtHi, L, true) / 4;
        (uint256 outUp, uint256 usedUp, uint160 p1,) =
            BinMath.swapExactIn(bins, bins[0].sqrtLo, 0, inUp, false, 0, 1);
        assertEq(usedUp, inUp);
        assertGt(p1, bins[0].sqrtLo);

        (uint256 outDown, uint256 usedDown, uint160 p2,) = BinMath.swapExactIn(bins, p1, 0, outUp, true, 0, 1);
        assertGt(usedDown, 0);
        assertGt(outDown, 0);
        assertLt(p2, p1);
    }
}
