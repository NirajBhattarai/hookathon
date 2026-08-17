// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Pure bin arithmetic for the BinRatchet hook.
/// @dev Extracted into a library so it can be property-tested (Echidna) and unit-tested
/// without deploying the hook itself (deploying the hook requires a mined address that
/// matches its `getHookPermissions`).
library BinRatchetMath {
    /// @notice Ticks per bin (~0.6% width at the default 3000 fee tier).
    int24 public constant BIN_SIZE = 60;

    /// @notice Bins per side of the active bin (50 bins total, roughly +/-16%).
    int24 public constant HALF_WIDTH_BINS = 25;

    /// @notice The bin that contains a tick (floor division, so bins tile the number line).
    function tickToBin(int24 tick) internal pure returns (int24) {
        return floorDiv(tick, BIN_SIZE);
    }

    /// @notice Inclusive lower tick boundary of a bin.
    function binLowerTick(int24 binId) internal pure returns (int24) {
        return binId * BIN_SIZE;
    }

    /// @notice Exclusive upper tick boundary of a bin.
    function binUpperTick(int24 binId) internal pure returns (int24) {
        return (binId + 1) * BIN_SIZE;
    }

    /// @notice Whether a tick sits on a bin boundary.
    function isBinAligned(int24 tick) internal pure returns (bool) {
        return tick % BIN_SIZE == 0;
    }

    /// @notice Floor division for signed integers (rounds toward negative infinity).
    function floorDiv(int24 a, int24 b) internal pure returns (int24) {
        int24 q = a / b;
        if (a % b != 0 && ((a < 0) != (b < 0))) {
            q--;
        }
        return q;
    }
}
