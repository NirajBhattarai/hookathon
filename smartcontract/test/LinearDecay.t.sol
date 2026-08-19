// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LinearDecay} from "../src/libraries/LinearDecay.sol";

contract LinearDecayTest is Test {
    uint256 constant L_BASE = 1000e18;
    uint256 constant RAMP = 10;

    function test_distanceZero_returnsLBase() public pure {
        assertEq(LinearDecay.computeLPerBin(L_BASE, RAMP, 0), L_BASE);
    }

    function test_distanceOne_nineTenths() public pure {
        assertEq(LinearDecay.computeLPerBin(L_BASE, RAMP, 1), L_BASE * 9 / 10);
    }

    function test_distanceRampMinusOne_oneTenth() public pure {
        assertEq(LinearDecay.computeLPerBin(L_BASE, RAMP, 9), L_BASE / 10);
    }

    function test_distanceEqualsRamp_zero() public pure {
        assertEq(LinearDecay.computeLPerBin(L_BASE, RAMP, 10), 0);
    }

    function test_distanceBeyondRamp_zero() public pure {
        assertEq(LinearDecay.computeLPerBin(L_BASE, RAMP, 11), 0);
        assertEq(LinearDecay.computeLPerBin(L_BASE, RAMP, 100), 0);
    }

    function test_monotonicDecreasingUntilZero() public pure {
        uint256 prev = LinearDecay.computeLPerBin(L_BASE, RAMP, 0);
        for (uint256 d = 1; d < RAMP; d++) {
            uint256 cur = LinearDecay.computeLPerBin(L_BASE, RAMP, d);
            assertLt(cur, prev);
            prev = cur;
        }
        assertEq(LinearDecay.computeLPerBin(L_BASE, RAMP, RAMP), 0);
    }

    function test_rampFive_formula() public pure {
        assertEq(LinearDecay.computeLPerBin(100, 5, 1), 80);
        assertEq(LinearDecay.computeLPerBin(100, 5, 2), 60);
        assertEq(LinearDecay.computeLPerBin(100, 5, 4), 20);
        assertEq(LinearDecay.computeLPerBin(100, 5, 5), 0);
    }

    function test_zeroLBase() public pure {
        assertEq(LinearDecay.computeLPerBin(0, RAMP, 1), 0);
    }
}
