// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BinRatchetMath} from "../../src/libraries/BinRatchetMath.sol";

/// @notice Echidna property tests for the pure bin arithmetic.
/// @dev Echidna drives the setters with random int24 values and re-checks every
/// `echidna_test_*` property after each call. Out-of-range inputs are skipped so
/// properties only see realistic values (the same ones the hook will observe).
/// Run: `echidna . --contract BinRatchetMathFuzz --config echidna.yaml`
contract BinRatchetMathFuzz {
    // Valid v3 tick range; the hook will only ever process ticks in this range.
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    // Bin ids derived from the valid tick range: floorDiv(MIN_TICK / BIN_SIZE) .. floorDiv(MAX_TICK / BIN_SIZE).
    int24 internal constant MIN_BIN = -14788;
    int24 internal constant MAX_BIN = 14787;

    // Stored inputs for the property checks.
    int24 internal t1;
    int24 internal t2;
    int24 internal bin;
    int24 internal dividend;
    int24 internal denom;

    function setT1(int24 value) public {
        if (value < MIN_TICK || value > MAX_TICK) return;
        t1 = value;
    }

    function setT2(int24 value) public {
        if (value < MIN_TICK || value > MAX_TICK) return;
        t2 = value;
    }

    function setBin(int24 value) public {
        if (value < MIN_BIN || value > MAX_BIN) return;
        bin = value;
    }

    function setDividend(int24 value) public {
        if (value < MIN_TICK || value > MAX_TICK) return;
        dividend = value;
    }

    function setDenom(int24 value) public {
        if (value == 0 || value < MIN_TICK || value > MAX_TICK) return;
        denom = value;
    }

    /// Every bin fully contains its ticks: lower <= tick < upper.
    function echidna_test_bin_contains_tick() public view returns (bool) {
        int24 b = BinRatchetMath.tickToBin(t1);
        return BinRatchetMath.binLowerTick(b) <= t1 && t1 < BinRatchetMath.binUpperTick(b);
    }

    /// Every bin has exactly BIN_SIZE ticks of width.
    function echidna_test_bin_width_is_bin_size() public view returns (bool) {
        return BinRatchetMath.binUpperTick(bin) - BinRatchetMath.binLowerTick(bin) == BinRatchetMath.BIN_SIZE;
    }

    /// Bin boundaries are bin-aligned.
    function echidna_test_bin_bounds_aligned() public view returns (bool) {
        return BinRatchetMath.isBinAligned(BinRatchetMath.binLowerTick(bin))
            && BinRatchetMath.isBinAligned(BinRatchetMath.binUpperTick(bin));
    }

    /// A bin's lower boundary maps back to that same bin.
    function echidna_test_lower_bound_maps_to_bin() public view returns (bool) {
        return BinRatchetMath.tickToBin(BinRatchetMath.binLowerTick(bin)) == bin;
    }

    /// tickToBin is monotonically non-decreasing.
    function echidna_test_tick_to_bin_monotonic() public view returns (bool) {
        if (t1 > t2) return true;
        return BinRatchetMath.tickToBin(t1) <= BinRatchetMath.tickToBin(t2);
    }

    /// floorDiv(a, b) is the mathematical floor of a / b (checked in int256 to avoid
    /// intermediate overflow). For b < 0 the inequalities flip:
    ///   b > 0: q*b <= a < (q+1)*b
    ///   b < 0: (q+1)*b < a <= q*b
    function echidna_test_floor_div_is_floor() public view returns (bool) {
        if (denom == 0) return true;
        int256 q = int256(BinRatchetMath.floorDiv(dividend, denom));
        int256 a = int256(dividend);
        int256 b = int256(denom);
        if (b > 0) {
            return q * b <= a && a < (q + 1) * b;
        } else {
            return (q + 1) * b < a && a <= q * b;
        }
    }
}
