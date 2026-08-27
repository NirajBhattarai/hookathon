// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SwapMath} from "./SwapMath.sol";

/// @title BinLayout
/// @notice Static book geometry for BinBook: bin distances, addLiquidity window resolution,
///         and linear-decay ramps. Owns the `Book`, `Position`, and `UserRange` types and
///         operates on them via `using`, mirroring v4-core's `Pool.State` pattern — callers
///         pass their storage explicitly.
library BinLayout {
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Per-pool book state. Lives here (not in BinBook) so layout logic can take
    ///      `Book storage` as its subject, exactly like `Pool.State`.
    struct Book {
        int24 binSize;
        uint16 baseRamp;
        uint16 numBinsPerSide;
        int24 currentBin;
        int24 minBin;
        int24 maxBin;
        uint160 sqrtPriceX96;
        bool seeded;
    }

    /// @dev Resolved addLiquidity window. Bins are inclusive `[minB, maxB]`; `cur` is the
    ///      active bin; `ramp` is the decay radius fed into linear-decay sizing.
    struct Window {
        int24 minB;
        int24 maxB;
        int24 cur;
        uint256 ramp;
    }

    /// @dev Per-user per-bin position: credited liquidity plus Uniswap-style fee accounting.
    struct Position {
        uint128 liquidity;
        uint256 feeGrowth0LastX128;
        uint256 feeGrowth1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

    /// @dev The contiguous bin range a user has deposited across.
    struct UserRange {
        int24 minB;
        int24 maxB;
        bool set;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Cap on bins filled in a single add. Far ranges should use a larger `binSize`.
    uint16 public constant MAX_BINS_PER_ADD = 64;

    /// @dev Cap on the total contiguous bin span a book may ever grow to.
    uint16 public constant MAX_BOOK_BINS = 1024;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error TicksNotAlignedToBins();
    error InvalidTickRange();
    error TooManyBins();
    error BookTooWide();

    /*//////////////////////////////////////////////////////////////
                              BOOK RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the min, max, and current bin indices for a pool's book.
    /// @dev Think of bins like price buckets for a PEPE/USDC pair. The pool sits in the
    ///      "current" bin; liquidity extends `numBinsPerSide` bins to each side.
    ///      Unseeded books derive `cur` from the starting price instead of trusting storage.
    /// @param b The pool's book state
    /// @return minB Lowest bin index in the contiguous book
    /// @return maxB Highest bin index in the contiguous book
    /// @return cur Active bin index containing the current price
    function bookRange(Book storage b) internal view returns (int24 minB, int24 maxB, int24 cur) {
        // If already seeded, bins are cached — just return them (saves gas)
        if (b.seeded) {
            return (b.minBin, b.maxBin, b.currentBin);
        }
        // Convert the pool's sqrtPriceX96 → raw tick, snap down to the nearest bin index,
        // and spread numBinsPerSide around it.
        int24 tick = TickMath.getTickAtSqrtPrice(b.sqrtPriceX96);
        cur = floorDiv(tick, b.binSize);
        int24 n = int24(uint24(b.numBinsPerSide));
        minB = cur - n;
        maxB = cur + n - 1;
    }

    /// @notice Resolves the bin window for an addLiquidity tick range against pool state.
    /// @dev Validates alignment (`tick % binSize == 0` on both edges), tick bounds, and the
    ///      per-add bin cap, then derives the inclusive bin range `[tickLower/binSize, tickUpper/binSize - 1]`
    ///      and its auto-floored decay radius. `cur` is resolved from `b` itself.
    /// @param book The pool's book state (binSize, ramp, and active-bin source)
    /// @param tickLower Lower tick of the requested range, must be bin-aligned
    /// @param tickUpper Upper tick of the requested range, must be bin-aligned and greater than tickLower
    /// @return window Resolved window ready for liquidity distribution
    function resolveWindow(Book storage book, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (Window memory window)
    {
        if (tickLower >= tickUpper) revert InvalidTickRange();

        (,, int24 cur) = bookRange(book);
        window.cur = cur;

        if (tickLower % book.binSize != 0 || tickUpper % book.binSize != 0) revert TicksNotAlignedToBins();
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) revert InvalidTickRange();

        int24 userMin = tickLower / book.binSize;
        int24 userMax = tickUpper / book.binSize - 1;
        if (userMax < userMin) revert InvalidTickRange();

        uint256 n = uint256(int256(userMax - userMin + 1));
        if (n > MAX_BINS_PER_ADD) revert TooManyBins();

        window.minB = userMin;
        window.maxB = userMax;
        window.ramp = resolveRamp(userMin, userMax, cur, book.baseRamp);
    }

    /// @notice Grows a book's contiguous bin range to cover `[fillMin, fillMax]` (and `cur`),
    ///         seeding it on first use with `numBinsPerSide` bins spread around `cur`.
    /// @dev Pure state-transition on `Book storage`; the caller owns event emission (mirrors
    ///      how `BinBook` calls `resolveWindow`/`depositLBase` and stays event-owner).
    /// @param b The pool's book state
    /// @param fillMin Lowest bin index that must be covered
    /// @param fillMax Highest bin index that must be covered
    /// @param cur Active bin index containing the current price
    /// @return minBin Book's minimum bin index after expansion
    /// @return maxBin Book's maximum bin index after expansion
    /// @return expanded True if the book's range changed (first seed, or an actual grow)
    function expandBook(Book storage b, int24 fillMin, int24 fillMax, int24 cur)
        internal
        returns (int24 minBin, int24 maxBin, bool expanded)
    {
        int24 minB = fillMin;
        int24 maxB = fillMax;
        if (cur < minB) minB = cur;
        if (cur > maxB) maxB = cur;

        if (!b.seeded) {
            int24 n = int24(uint24(b.numBinsPerSide));
            int24 defMin = cur - n;
            int24 defMax = cur + n - 1;
            if (defMin < minB) minB = defMin;
            if (defMax > maxB) maxB = defMax;
            b.currentBin = cur;
            b.seeded = true;
            b.minBin = minB;
            b.maxBin = maxB;
            minBin = minB;
            maxBin = maxB;
            expanded = true;
        } else {
            minBin = b.minBin;
            maxBin = b.maxBin;
            if (minB < minBin) {
                b.minBin = minB;
                minBin = minB;
                expanded = true;
            }
            if (maxB > maxBin) {
                b.maxBin = maxB;
                maxBin = maxB;
                expanded = true;
            }
        }

        uint256 span = uint256(int256(maxBin - minBin + 1));
        if (span > MAX_BOOK_BINS) revert BookTooWide();
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY SOLVER
    //////////////////////////////////////////////////////////////*/

    /// @notice Lower tick boundary of bin `idx`.
    /// @dev Reverts if the bin falls outside the v4 tick domain.
    function tickLowerAtBin(Book storage b, int24 idx) internal view returns (int24) {
        int256 tick = int256(idx) * int256(b.binSize);
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert InvalidTickRange();
        return int24(tick);
    }

    /// @notice Token0/token1 required to fund liquidity `L` in bin `idx` at the book's price.
    /// @dev Reads the price from the book itself (`sqrtPriceX96`) — the same field swaps mutate,
    ///      so every solve/deposit prices against live state without extra plumbing.
    function tokenAmountsForBin(Book storage book, int24 binIndex, uint256 liquidity)
        internal
        view
        returns (uint256 token0, uint256 token1)
    {
        int24 tickLo = tickLowerAtBin(book, binIndex);
        uint160 sqrtLo = TickMath.getSqrtPriceAtTick(tickLo);
        uint160 sqrtHi = TickMath.getSqrtPriceAtTick(tickLo + book.binSize);
        return SwapMath.getTokenAmountsForBin(
            liquidity, uint256(book.sqrtPriceX96), SwapMath.BinBounds(uint256(sqrtLo), uint256(sqrtHi))
        );
    }

    /// @notice Read-only solve for the root liquidity `LBase` across a resolved window.
    /// @dev Probes the window with a unit LBase, sums the token0/token1 each bin would need
    ///      (ramp-decayed via linear decay), then scales by the desired amounts and takes the
    ///      smaller scalar so the result never exceeds either token budget when deployed.
    ///      Returns 0 when the budgets are too dust to fund probe-scale liquidity — the caller
    ///      owns the revert policy (BinBook reverts `ZeroAmounts` there).
    /// @param book The pool's book state (price source)
    /// @param window Window from `resolveWindow` (bins, active bin, ramp)
    /// @param amount0Desired Caller's token0 budget; 0 skips token0-needing bins
    /// @param amount1Desired Caller's token1 budget; 0 skips token1-needing bins
    /// @return lBase Root liquidity scaling factor; 0 signals degenerate budgets
    function solveLBase(Book storage book, Window memory window, uint256 amount0Desired, uint256 amount1Desired)
        internal
        view
        returns (uint256 lBase)
    {
        uint256 need0;
        uint256 need1;
        uint256 probe = 1e18;

        for (int24 idx = window.minB; idx <= window.maxB; ++idx) {
            uint256 liquidity = SwapMath.computeLPerBin(probe, window.ramp, binDistance(idx, window.cur));
            if (liquidity == 0) continue;
            (uint256 t0, uint256 t1) = tokenAmountsForBin(book, idx, liquidity);
            if (amount0Desired == 0 && t0 > 0) continue;
            if (amount1Desired == 0 && t1 > 0) continue;
            need0 += t0;
            need1 += t1;
        }

        if (need0 == 0 && need1 == 0) revert SwapMath.InsufficientLiquidity();

        uint256 s0 = need0 == 0 ? type(uint256).max : amount0Desired * probe / need0;
        uint256 s1 = need1 == 0 ? type(uint256).max : amount1Desired * probe / need1;
        lBase = s0 < s1 ? s0 : s1;
    }

    /// @notice State-changing counterpart to `solveLBase`: walks the same window applying the
    ///         solved `lBase` per bin (ramp-decayed) to credit user L and total up the real
    ///         token0/token1 pulled in.
    /// @dev Mirrors the `solveLBase` walk bin-for-bin (same skip rules for zero budgets), so the
    ///      returned amounts always fit the budgets that produced `lBase`. Book expansion is the
    ///      caller's job — it emits the owner contract's `BookExpanded` event.
    /// @param book The pool's book state (price source)
    /// @param window Window from `resolveWindow` (bins, active bin, ramp)
    /// @param lBase Root liquidity from `solveLBase`
    /// @param amount0Desired Caller's token0 budget; 0 skips token0-needing bins
    /// @param amount1Desired Caller's token1 budget; 0 skips token1-needing bins
    /// @param account Depositor whose positions are credited
    /// @param totalLiquidity Per-pool total L per bin (`liquidity[poolId]`)
    /// @param feeGrowth0 Per-pool token0 fee growth per bin (`feeGrowth0X128[poolId]`)
    /// @param feeGrowth1 Per-pool token1 fee growth per bin (`feeGrowth1X128[poolId]`)
    /// @param userPositions Per-pool positions (`positions[poolId]`)
    /// @param ranges Per-pool user ranges (`userRanges[poolId]`)
    /// @return amount0 Total token0 required by the funded bins
    /// @return amount1 Total token1 required by the funded bins
    function depositLBase(
        Book storage book,
        Window memory window,
        uint256 lBase,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address account,
        mapping(int24 binIndex => uint128) storage totalLiquidity,
        mapping(int24 binIndex => uint256) storage feeGrowth0,
        mapping(int24 binIndex => uint256) storage feeGrowth1,
        mapping(
            address depositor => mapping(int24 binIndex => Position)
        ) storage userPositions,
        mapping(address depositor => UserRange) storage ranges
    ) internal returns (uint256 amount0, uint256 amount1) {
        for (int24 idx = window.minB; idx <= window.maxB; ++idx) {
            uint256 addL = SwapMath.computeLPerBin(lBase, window.ramp, binDistance(idx, window.cur));
            if (addL == 0) continue;
            (uint256 t0, uint256 t1) = tokenAmountsForBin(book, idx, addL);
            if (amount0Desired == 0 && t0 > 0) continue;
            if (amount1Desired == 0 && t1 > 0) continue;
            amount0 += t0;
            amount1 += t1;

            Position storage p = userPositions[account][idx];
            // Two independent steps, called out explicitly rather than bundled behind one
            // wrapper: settle fees against the *pre-increase* L, then bump L. Order matters —
            // settleFees must run first or the fee growth since the last checkpoint would be
            // computed against the wrong (post-increase) liquidity.
            settleFees(p, feeGrowth0, feeGrowth1, idx);
            increaseUserL(p, ranges[account], totalLiquidity, idx, addL);
        }
    }

    /// @dev Increases a depositor's L in one bin and widens their contiguous range to cover it.
    ///      Pure liquidity bookkeeping — does not touch fees. Callers with an existing position
    ///      must call `settleFees` first so accrued fees settle against the pre-increase L.
    function increaseUserL(
        Position storage p,
        UserRange storage r,
        mapping(int24 binIndex => uint128) storage totalLiquidity,
        int24 binIndex,
        uint256 addL
    ) internal {
        uint128 add128 = addL.toUint128();
        p.liquidity += add128;
        totalLiquidity[binIndex] += add128;

        if (!r.set) {
            r.minB = binIndex;
            r.maxB = binIndex;
            r.set = true;
        } else {
            if (binIndex < r.minB) r.minB = binIndex;
            if (binIndex > r.maxB) r.maxB = binIndex;
        }
    }

    /// @dev Settles fees accrued to `p` since its last checkpoint into `tokensOwed`, then moves
    ///      the checkpoint up to the bin's current growth.
    /// @dev Mirrors Uniswap v3 `Position.update`: the tokensOwed SSTORE is skipped when nothing
    ///      actually accrued (e.g. a same-block re-touch, or a bin with no swap volume since the
    ///      last checkpoint) — writing back an unchanged value still costs a warm SSTORE. The
    ///      checkpoint itself always advances, same as upstream, so a fresh position's initial
    ///      checkpoint still gets set correctly.
    function settleFees(
        Position storage p,
        mapping(int24 binIndex => uint256) storage feeGrowth0,
        mapping(int24 binIndex => uint256) storage feeGrowth1,
        int24 binIndex
    ) internal {
        uint256 L = p.liquidity;
        if (L != 0) {
            uint256 owed0 = FullMath.mulDiv(feeGrowth0[binIndex] - p.feeGrowth0LastX128, L, FixedPoint128.Q128);
            uint256 owed1 = FullMath.mulDiv(feeGrowth1[binIndex] - p.feeGrowth1LastX128, L, FixedPoint128.Q128);
            if (owed0 > 0) p.tokensOwed0 += owed0;
            if (owed1 > 0) p.tokensOwed1 += owed1;
        }
        p.feeGrowth0LastX128 = feeGrowth0[binIndex];
        p.feeGrowth1LastX128 = feeGrowth1[binIndex];
    }

    /// @notice Decay radius for an addLiquidity range: ramp = max(farthestBinDistance + 1, baseRamp).
    /// @dev The +1 ensures even the farthest bin receives L > 0; the floor at `baseRamp`
    ///      guarantees a minimum spread width regardless of how tight the user range is.
    /// @param userMinBin Lower bound of the user range, in bin indices
    /// @param userMaxBin Upper bound of the user range, inclusive
    /// @param cur Active bin index
    /// @param baseRamp Minimum ramp floor (e.g. BinBook.DEFAULT_RAMP)
    function resolveRamp(int24 userMinBin, int24 userMaxBin, int24 cur, uint16 baseRamp)
        internal
        pure
        returns (uint256 ramp)
    {
        uint256 distanceBelow = binDistance(userMinBin, cur);
        uint256 distanceAbove = binDistance(userMaxBin, cur);
        uint256 farthestDistance = distanceBelow > distanceAbove ? distanceBelow : distanceAbove;
        ramp = farthestDistance + 1;
        if (ramp < baseRamp) ramp = baseRamp;
    }

    /*//////////////////////////////////////////////////////////////
                             BIN LAYOUT HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Signed distance of a bin from the active bin, used to decay liquidity.
    /// @dev Asymmetric by design: the active bin sits at distance 1 (not 0), so every funded
    ///      bin keeps L > 0 under linear decay. Below `cur`: `cur - idx`; at/above: `idx - cur + 1`.
    ///      Arithmetic widened to int256 so extreme int24 spreads cannot overflow; results are
    ///      identical to the original int24 version across the reachable tick domain.
    /// @param binIndex The bin being measured
    /// @param cur The active bin index
    /// @return Distance in bins; increases monotonically away from `cur` in both directions
    function binDistance(int24 binIndex, int24 cur) internal pure returns (uint256) {
        int256 d;
        if (binIndex < cur) {
            d = int256(cur) - int256(binIndex);
        } else {
            d = int256(binIndex) - int256(cur) + 1;
        }
        return uint256(d);
    }

    /// @notice Floor division: rounds toward negative infinity (Solidity `/` truncates toward zero).
    /// @dev Used to snap ticks down onto bin boundaries, e.g. -115135 / 10 → -11514.
    function floorDiv(int24 a, int24 b) internal pure returns (int24) {
        int24 q = a / b;
        if (a % b != 0 && a < 0) q -= 1;
        return q;
    }
}
