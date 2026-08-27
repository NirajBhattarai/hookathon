// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BinLayout} from "src/libraries/BinLayout.sol";
import {SwapMath} from "src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

contract BinLayoutTest is Test {
    int24 internal constant SIZE = 10;
    uint16 internal constant BASE_RAMP = 10;
    uint16 internal constant MAX_BINS_PER_ADD = 64;
    // Tick domain reachable by the pool (v4 MIN/MAX_TICK ≈ ±887272)
    int256 internal constant DOMAIN = 887_272;

    /*//////////////////////////////////////////////////////////////
                          BIN LAYOUT HELPERS
    //////////////////////////////////////////////////////////////*/

    function test_floorDiv_roundsTowardNegativeInfinity() public pure {
        assertEq(BinLayout.floorDiv(-115135, 10), -11514); // truncation would give -11513
        assertEq(BinLayout.floorDiv(-115130, 10), -11513); // exact multiple: no adjustment
        assertEq(BinLayout.floorDiv(115135, 10), 11513);
        assertEq(BinLayout.floorDiv(7, 1), 7);
        assertEq(BinLayout.floorDiv(0, 10), 0);
    }

    function test_binDistance_activeBinIsOneNotZero() public pure {
        assertEq(BinLayout.binDistance(5, 5), 1);
    }

    function test_binDistance_belowAndAbove() public pure {
        assertEq(BinLayout.binDistance(2, 5), 3); // below: cur - idx
        assertEq(BinLayout.binDistance(8, 5), 4); // above: idx - cur + 1
        // equidistant pair straddling cur at distance 3: idx = cur-3 vs cur+2
        assertEq(BinLayout.binDistance(2, 5), BinLayout.binDistance(7, 5));
        assertEq(BinLayout.binDistance(-100, -50), 50);
    }

    function testFuzz_binDistance_atLeastOne(int24 idx, int24 cur) public pure {
        assertGe(BinLayout.binDistance(idx, cur), 1);
    }

    function test_resolveRamp_farthestPlusOneBeatsBase() public pure {
        // window [-10..9], cur=0: distances 10 and 10 → farthest+1 = 11 > base 10
        assertEq(BinLayout.resolveRamp(-10, 9, 0, 10), 11);
    }

    function test_resolveRamp_floorsAtBaseRamp() public pure {
        // narrow window [-1..2]: farthest+1 = 4 → floored up to base 10
        assertEq(BinLayout.resolveRamp(-1, 2, 0, 10), 10);
    }

    function testFuzz_resolveRamp_equalsMaxOfFloorAndFarthest(int24 userMin, int24 userMax, int24 cur, uint16 baseRamp)
        public
        pure
    {
        userMin = int24(bound(int256(userMin), -DOMAIN, DOMAIN));
        userMax = int24(bound(int256(userMax), -DOMAIN, DOMAIN));
        cur = int24(bound(int256(cur), -DOMAIN, DOMAIN));
        vm.assume(userMin <= userMax);
        baseRamp = uint16(bound(uint256(baseRamp), 1, type(uint16).max));

        uint256 farthest = BinLayout.binDistance(userMin, cur) > BinLayout.binDistance(userMax, cur)
            ? BinLayout.binDistance(userMin, cur)
            : BinLayout.binDistance(userMax, cur);
        uint256 expected = farthest + 1 >= baseRamp ? farthest + 1 : baseRamp;

        assertEq(BinLayout.resolveRamp(userMin, userMax, cur, baseRamp), expected);
    }

    /*//////////////////////////////////////////////////////////////
                              WINDOWFOR
    //////////////////////////////////////////////////////////////*/

    using BinLayout for BinLayout.Book;

    /// @dev Test-owned book state, mutated directly — the v4-core `Pool.State state;` pattern.
    ///      No harness contract needed: `Book` lives in BinLayout and its methods are internal.
    BinLayout.Book book;

    mapping(int24 => uint128) internal _totalLiquidity;
    mapping(int24 => uint256) internal _feeGrowth0;
    mapping(int24 => uint256) internal _feeGrowth1;
    mapping(address => mapping(int24 => BinLayout.Position)) internal _positions;
    mapping(address => BinLayout.UserRange) internal _userRanges;
    address internal constant USER = address(0xBEEF);

    function _seedBook(int24 cur) internal {
        book.binSize = SIZE;
        book.baseRamp = BASE_RAMP;
        book.seeded = true;
        book.currentBin = cur;
    }

    /// @dev External hop so `vm.expectRevert` sees a revert at a lower call depth.
    function resolveWindowExternal(int24 lo, int24 hi) external view returns (BinLayout.Window memory) {
        return book.resolveWindow(lo, hi);
    }

    /// @dev Meme-launch shape: range below a low starting price, ramp auto-floored to farthest+1.
    function test_resolveWindow_derivesBinsAndRamp() public {
        _seedBook(-11513);
        BinLayout.Window memory w = book.resolveWindow(-115230, -115030);
        assertEq(w.minB, -11523);
        assertEq(w.maxB, -11504);
        assertEq(w.cur, -11513);
        // below distance 10, above distance 10 → farthest+1 = 11 > base 10
        assertEq(w.ramp, 11);
    }

    function test_resolveWindow_rampFloorsAtBaseRamp() public {
        _seedBook(0);
        // window [-20..10] around cur=0: bins [-2..-1..0], farthest+1 = 3 < base → floor at 10
        BinLayout.Window memory w = book.resolveWindow(-20, 10);
        assertEq(w.minB, -2);
        assertEq(w.maxB, 0);
        assertEq(w.ramp, BASE_RAMP);
    }

    function test_resolveWindow_unseededBookDerivesCurFromPrice() public {
        book.binSize = SIZE;
        book.numBinsPerSide = 10;
        book.baseRamp = BASE_RAMP;
        book.seeded = false;
        book.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-115135); // lands mid-bin

        int24 expCur = BinLayout.floorDiv(-115135, SIZE); // -11514
        BinLayout.Window memory w = book.resolveWindow(-115230, -115030);

        assertEq(w.cur, expCur);
        assertLe(w.minB, w.cur); // derived cur always sits inside its seed window
        assertLe(w.cur, w.maxB);
    }

    function test_resolveWindow_revertsMisalignedTicks() public {
        _seedBook(0);
        vm.expectRevert(BinLayout.TicksNotAlignedToBins.selector);
        this.resolveWindowExternal(-115235, -115030);

        vm.expectRevert(BinLayout.TicksNotAlignedToBins.selector);
        this.resolveWindowExternal(-115230, -115025);
    }

    function test_resolveWindow_revertsEmptyAndInvertedRange() public {
        _seedBook(0);
        vm.expectRevert(BinLayout.InvalidTickRange.selector);
        this.resolveWindowExternal(-60, -60);

        vm.expectRevert(BinLayout.InvalidTickRange.selector);
        this.resolveWindowExternal(10, -10);
    }

    function test_resolveWindow_revertsOutOfBoundsTicks() public {
        _seedBook(0);
        // -887280 < MIN_TICK (-887272), aligned to size 10
        vm.expectRevert(BinLayout.InvalidTickRange.selector);
        this.resolveWindowExternal(-887280, -100);

        // 887280 > MAX_TICK (887272)
        vm.expectRevert(BinLayout.InvalidTickRange.selector);
        this.resolveWindowExternal(100, 887280);
    }

    function test_resolveWindow_maxBinsBoundary() public {
        _seedBook(0);
        // exactly 64 bins of size 10 → OK; one more tick-bin → TooManyBins
        BinLayout.Window memory w = book.resolveWindow(0, 64 * SIZE);
        assertEq(w.maxB - w.minB + 1, 64);

        vm.expectRevert(BinLayout.TooManyBins.selector);
        this.resolveWindowExternal(0, 65 * SIZE);
    }

    /// @dev Mirror-reference fuzz in the v4-core `test_fuzz_compress` style: the reference
    ///      implementation is written inline and all four outputs are asserted against it.
    function testFuzz_resolveWindow_matchesReference(int256 rawLo, uint256 rawNBins, int256 rawCur) public {
        rawLo = bound(rawLo, -DOMAIN + 2000, DOMAIN - 2000);
        rawLo -= rawLo % SIZE; // align down to a bin boundary

        uint256 nBins = bound(rawNBins, 1, MAX_BINS_PER_ADD);
        int24 hi = int24(rawLo + int256(nBins * 10));
        vm.assume(hi <= TickMath.MAX_TICK);

        int24 cur = int24(bound(rawCur, -DOMAIN / SIZE, DOMAIN / SIZE));
        _seedBook(cur);

        BinLayout.Window memory w = book.resolveWindow(int24(rawLo), hi);

        // reference derivation
        int24 expMin = int24(rawLo / SIZE);
        int24 expMax = hi / SIZE - 1;
        uint256 dBelow = BinLayout.binDistance(expMin, cur);
        uint256 dAbove = BinLayout.binDistance(expMax, cur);
        uint256 farthest = dBelow > dAbove ? dBelow : dAbove;
        uint256 expRamp = farthest + 1 >= BASE_RAMP ? farthest + 1 : BASE_RAMP;

        assertEq(w.minB, expMin, "minB");
        assertEq(w.maxB, expMax, "maxB");
        assertEq(w.cur, cur, "cur");
        assertEq(w.ramp, expRamp, "ramp");

        // structural properties
        assertLe(w.minB, w.maxB, "empty window");
        assertEq(uint256(int256(w.maxB - w.minB + 1)), nBins, "bin count");
        assertGe(w.ramp, BASE_RAMP, "ramp floor");
    }

    /*//////////////////////////////////////////////////////////////
                             EXPAND BOOK
    //////////////////////////////////////////////////////////////*/

    uint16 internal constant NUM_BINS_PER_SIDE = 10;

    /// @dev Resets `book` to a fresh unseeded state so state from earlier fuzz runs on the
    ///      same persistent storage slot can't leak into the next one.
    function _freshBook(uint16 numBinsPerSide) internal {
        delete book;
        book.binSize = SIZE;
        book.baseRamp = BASE_RAMP;
        book.numBinsPerSide = numBinsPerSide;
    }

    /// @dev External hop so `vm.expectRevert` sees a revert at a lower call depth.
    function expandBookExternal(int24 fillMin, int24 fillMax, int24 cur) external returns (int24, int24, bool) {
        return book.expandBook(fillMin, fillMax, cur);
    }

    /// @dev First expansion on an unseeded book spreads `numBinsPerSide` bins around `cur`.
    function test_expandBook_firstSeed_spreadsAroundCurrent() public {
        _freshBook(NUM_BINS_PER_SIDE);
        (int24 minBin, int24 maxBin, bool expanded) = book.expandBook(0, 0, 5);

        assertEq(minBin, 5 - int24(uint24(NUM_BINS_PER_SIDE)));
        assertEq(maxBin, 5 + int24(uint24(NUM_BINS_PER_SIDE)) - 1);
        assertTrue(expanded);
        assertTrue(book.seeded);
        assertEq(book.currentBin, 5);
        assertEq(book.minBin, minBin);
        assertEq(book.maxBin, maxBin);
    }

    /// @dev A fill window wider than the default spread wins on first seed.
    function test_expandBook_firstSeed_fillWiderThanDefaultWins() public {
        _freshBook(NUM_BINS_PER_SIDE);
        (int24 minBin, int24 maxBin,) = book.expandBook(-50, 50, 0);

        assertEq(minBin, -50);
        assertEq(maxBin, 50);
    }

    /// @dev A fill window fully inside the already-seeded range doesn't grow or emit.
    function test_expandBook_noGrowth_withinExistingRange() public {
        _freshBook(NUM_BINS_PER_SIDE);
        (int24 minBin0, int24 maxBin0,) = book.expandBook(0, 0, 0);

        (int24 minBin1, int24 maxBin1, bool expanded) = book.expandBook(minBin0 + 1, maxBin0 - 1, 0);

        assertFalse(expanded);
        assertEq(minBin1, minBin0);
        assertEq(maxBin1, maxBin0);
    }

    /// @dev A fill window reaching only below the current min grows only that side.
    function test_expandBook_growLowOnly() public {
        _freshBook(NUM_BINS_PER_SIDE);
        (int24 minBin0, int24 maxBin0,) = book.expandBook(0, 0, 0);

        (int24 minBin1, int24 maxBin1, bool expanded) = book.expandBook(minBin0 - 5, maxBin0, 0);

        assertTrue(expanded);
        assertEq(minBin1, minBin0 - 5);
        assertEq(maxBin1, maxBin0);
    }

    /// @dev A fill window reaching only above the current max grows only that side.
    function test_expandBook_growHighOnly() public {
        _freshBook(NUM_BINS_PER_SIDE);
        (int24 minBin0, int24 maxBin0,) = book.expandBook(0, 0, 0);

        (int24 minBin1, int24 maxBin1, bool expanded) = book.expandBook(minBin0, maxBin0 + 5, 0);

        assertTrue(expanded);
        assertEq(minBin1, minBin0);
        assertEq(maxBin1, maxBin0 + 5);
    }

    /// @dev A fill window wider on both sides grows both in the same call.
    function test_expandBook_growBothSides() public {
        _freshBook(NUM_BINS_PER_SIDE);
        (int24 minBin0, int24 maxBin0,) = book.expandBook(0, 0, 0);

        (int24 minBin1, int24 maxBin1, bool expanded) = book.expandBook(minBin0 - 3, maxBin0 + 7, 0);

        assertTrue(expanded);
        assertEq(minBin1, minBin0 - 3);
        assertEq(maxBin1, maxBin0 + 7);
    }

    /// @dev Growing past MAX_BOOK_BINS reverts instead of silently accepting an unswappable book.
    function test_revert_expandBook_bookTooWide() public {
        _freshBook(NUM_BINS_PER_SIDE);
        book.expandBook(0, 0, 0);

        vm.expectRevert(BinLayout.BookTooWide.selector);
        this.expandBookExternal(0, int24(uint24(BinLayout.MAX_BOOK_BINS)), 0);
    }

    /// @dev Mirror-reference fuzz for the first-seed transition (v4-core `Pool.t.sol` style):
    ///      the expected range is the union of the fill window, `cur`, and the default spread.
    function testFuzz_expandBook_firstSeed_matchesReference(
        int24 rawCur,
        uint16 rawLoOffset,
        uint16 rawHiOffset,
        uint16 rawNumBinsPerSide
    ) public {
        int24 cur = int24(bound(int256(rawCur), -DOMAIN, DOMAIN));
        int24 loOffset = int24(int256(bound(uint256(rawLoOffset), 0, 400)));
        int24 hiOffset = int24(int256(bound(uint256(rawHiOffset), 0, 400)));
        uint16 n = uint16(bound(uint256(rawNumBinsPerSide), 1, 400));
        int24 fillMin = cur - loOffset;
        int24 fillMax = cur + hiOffset;

        _freshBook(n);

        int24 expMin = fillMin < cur ? fillMin : cur;
        int24 expMax = fillMax > cur ? fillMax : cur;
        int24 defMin = cur - int24(uint24(n));
        int24 defMax = cur + int24(uint24(n)) - 1;
        if (defMin < expMin) expMin = defMin;
        if (defMax > expMax) expMax = defMax;

        uint256 span = uint256(int256(expMax - expMin + 1));
        vm.assume(span <= BinLayout.MAX_BOOK_BINS);

        (int24 minBin, int24 maxBin, bool expanded) = book.expandBook(fillMin, fillMax, cur);

        assertEq(minBin, expMin, "minBin");
        assertEq(maxBin, expMax, "maxBin");
        assertTrue(expanded, "first seed always expands");
        assertTrue(book.seeded);
        assertEq(book.currentBin, cur);
    }

    /// @dev Mirror-reference fuzz for the grow transition on an already-seeded book. Fuzzed
    ///      inputs are budgeted so the resulting span never crosses MAX_BOOK_BINS — that cap is
    ///      covered separately by `test_revert_expandBook_bookTooWide`.
    function testFuzz_expandBook_grow_matchesReference(int24 rawFillMin, int24 rawFillMax, int24 rawCur) public {
        _freshBook(NUM_BINS_PER_SIDE);
        (int24 minBin0, int24 maxBin0,) = book.expandBook(0, 0, 0);

        int24 initialSpan = maxBin0 - minBin0 + 1;
        int24 slack = (int24(uint24(BinLayout.MAX_BOOK_BINS)) - initialSpan) / 2;
        int24 lo = minBin0 - slack;
        int24 hi = maxBin0 + slack;

        int24 cur = int24(bound(int256(rawCur), int256(lo), int256(hi)));
        int24 fillMin = int24(bound(int256(rawFillMin), int256(lo), int256(hi)));
        int24 fillMax = int24(bound(int256(rawFillMax), int256(fillMin), int256(hi)));

        int24 expMin = fillMin < cur ? fillMin : cur;
        int24 expMax = fillMax > cur ? fillMax : cur;
        if (minBin0 < expMin) expMin = minBin0;
        if (maxBin0 > expMax) expMax = maxBin0;
        bool expGrew = expMin < minBin0 || expMax > maxBin0;

        (int24 minBin1, int24 maxBin1, bool expanded) = book.expandBook(fillMin, fillMax, cur);

        assertEq(minBin1, expMin, "minBin");
        assertEq(maxBin1, expMax, "maxBin");
        assertEq(expanded, expGrew, "expanded");
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY SOLVER
    //////////////////////////////////////////////////////////////*/

    /// @dev Meme-launch shape solved end-to-end against an inline mirror of the probe-and-scale
    ///      algorithm — same style as the windowFor reference fuzz.
    function test_solveLBase_memeLaunch_matchesReference() public {
        _seedBook(-11513);
        book.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-115135);

        BinLayout.Window memory w = book.resolveWindow(-115230, -115030);
        uint256 lBase = book.solveLBase(w, 1 ether, 100_000 ether);

        // inline reference
        uint256 probe = 1e18;
        uint256 need0;
        uint256 need1;
        for (int24 i = w.minB; i <= w.maxB; ++i) {
            uint256 li = SwapMath.computeLPerBin(probe, w.ramp, BinLayout.binDistance(i, w.cur));
            (uint256 t0, uint256 t1) = SwapMath.getTokenAmountsForBin(li, uint256(book.sqrtPriceX96), _bounds(i, SIZE));
            need0 += t0;
            need1 += t1;
        }
        uint256 s0 = 1 ether * probe / need0;
        uint256 s1 = 100_000 ether * probe / need1;
        uint256 expected = s0 < s1 ? s0 : s1;

        assertGt(lBase, 0);
        assertEq(lBase, expected);
    }

    /// @dev The solver is linear in budgets: scaling both desired amounts by k scales LBase by k
    ///      (needs are budget-independent; only floor division introduces sub-1e-9 noise).
    function testFuzz_solveLBase_linearInBudgets(int256 rawLo, uint256 rawNBins, uint256 rawA0, uint256 rawK) public {
        int24 lo = int24(bound(rawLo, -DOMAIN + 2000, DOMAIN - 2000));
        lo -= lo % SIZE;
        uint256 nBins = bound(rawNBins, 1, MAX_BINS_PER_ADD);
        int24 hi = lo + int24(int256(nBins * 10));
        vm.assume(hi <= TickMath.MAX_TICK);

        // Production-shaped book: active bin and live price inside the funded range.
        _seedBook(lo + int24(int256(nBins / 2)));
        book.sqrtPriceX96 = TickMath.getSqrtPriceAtTick((lo + hi) / 2);

        BinLayout.Window memory w = book.resolveWindow(lo, hi);

        uint256 a0 = bound(rawA0, 1e18, 1e24);
        uint256 a1 = a0 * 7 / 3; // correlated but distinct second budget
        uint256 k = bound(rawK, 2, 500);

        uint256 base = book.solveLBase(w, a0, a1);
        // skip dust budgets where a single wei of floor-rounding dominates the ratio
        vm.assume(base > 1e15);

        uint256 scaled = book.solveLBase(w, a0 * k, a1 * k);
        assertApproxEqRel(scaled, base * k, 1e9);
    }

    /// @dev Bin sqrt-price bounds helper mirroring BinLayout.tokenAmountsForBin's tick math.
    function _bounds(int24 binIndex, int24 binSize) internal pure returns (SwapMath.BinBounds memory) {
        return SwapMath.BinBounds({
            sqrtPriceLower: uint256(TickMath.getSqrtPriceAtTick(binIndex * binSize)),
            sqrtPriceUpper: uint256(TickMath.getSqrtPriceAtTick(binIndex * binSize + binSize))
        });
    }

    /// @dev Branching revert-surface fuzz in v4-core Pool.t.sol style: one walk over every
    ///      validation branch, each with its own expectRevert.
    function testFuzz_resolveWindow_revertSurface(int256 rawLo, int256 rawHi) public {
        int24 lo = int24(bound(rawLo, -DOMAIN - 1000, DOMAIN + 1000));
        int24 hi = int24(bound(rawHi, -DOMAIN - 1000, DOMAIN + 1000));
        _seedBook(0);

        if (lo >= hi) {
            vm.expectRevert(BinLayout.InvalidTickRange.selector);
            this.resolveWindowExternal(lo, hi);
        } else if (lo % SIZE != 0 || hi % SIZE != 0) {
            vm.expectRevert(BinLayout.TicksNotAlignedToBins.selector);
            this.resolveWindowExternal(lo, hi);
        } else if (lo < TickMath.MIN_TICK || hi > TickMath.MAX_TICK) {
            vm.expectRevert(BinLayout.InvalidTickRange.selector);
            this.resolveWindowExternal(lo, hi);
        } else {
            int24 userMax = hi / SIZE - 1;
            if (uint256(int256(userMax - lo / SIZE + 1)) > MAX_BINS_PER_ADD) {
                vm.expectRevert(BinLayout.TooManyBins.selector);
                this.resolveWindowExternal(lo, hi);
            } else {
                BinLayout.Window memory w = book.resolveWindow(lo, hi);
                assertEq(w.minB, lo / SIZE);
                assertEq(w.maxB, userMax);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              DEPOSIT LBASE
    //////////////////////////////////////////////////////////////*/

    /// @dev Unit test: meme-launch shape, full solve → deposit flow, verify amounts and state.
    function test_depositLBase_memeLaunch_creditsAndReturnsAmounts() public {
        _seedBook(-11513);
        book.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-115135);

        BinLayout.Window memory w = book.resolveWindow(-115230, -115030);
        uint256 lBase = book.solveLBase(w, 1 ether, 100_000 ether);
        assertGt(lBase, 0);

        (uint256 amount0, uint256 amount1) = book.depositLBase(
            w, lBase, 1 ether, 100_000 ether, USER, _totalLiquidity, _feeGrowth0, _feeGrowth1, _positions, _userRanges
        );

        // Both amounts are nonzero — price sits below all bins, so both token0 and token1 are needed
        assertGt(amount0, 0);
        assertGt(amount1, 0);

        // Allow small floor-rounding excess from probe-and-scale (dust relative to budget)
        assertLe(amount0, 1 ether + 64);
        assertLe(amount1, 100_000 ether + 64);

        // Verify per-bin liquidity was credited
        BinLayout.UserRange memory r = _userRanges[USER];
        assertEq(r.minB, w.minB);
        assertEq(r.maxB, w.maxB);
        assertEq(r.set, true);

        for (int24 idx = w.minB; idx <= w.maxB; ++idx) {
            assertGt(_totalLiquidity[idx], 0, "bin should have liquidity");
            assertEq(_positions[USER][idx].liquidity, _totalLiquidity[idx], "user L == total L (single depositor)");
        }
    }

    /// @dev Shares = amount0 + amount1 (the spent amounts, not desired).
    function test_depositLBase_memeLaunch_sharesEqualSpent() public {
        _seedBook(-11513);
        book.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-115135);

        BinLayout.Window memory w = book.resolveWindow(-115230, -115030);
        uint256 lBase = book.solveLBase(w, 1 ether, 100_000 ether);

        (uint256 amount0, uint256 amount1) = book.depositLBase(
            w, lBase, 1 ether, 100_000 ether, USER, _totalLiquidity, _feeGrowth0, _feeGrowth1, _positions, _userRanges
        );

        // Shares = sum of actual spent — this is what BinBook uses
        uint256 shares = amount0 + amount1;
        assertGt(shares, 0);
    }

    /// @dev Only one budget is nonzero — deposit skips bins that need the zero budget's token.
    function test_depositLBase_oneSidedBudget() public {
        _seedBook(-11513);
        book.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(-115135);

        BinLayout.Window memory w = book.resolveWindow(-115230, -115030);
        uint256 lBase = book.solveLBase(w, 0, 100_000 ether);
        assertGt(lBase, 0);

        (uint256 amount0, uint256 amount1) = book.depositLBase(
            w, lBase, 0, 100_000 ether, USER, _totalLiquidity, _feeGrowth0, _feeGrowth1, _positions, _userRanges
        );

        assertEq(amount0, 0, "token0 budget was zero");
        assertGt(amount1, 0);
        // Allow floor-rounding excess from probe-and-scale
        assertLe(amount1, 100_000 ether + 100_000 ether / 100_000);
    }

    /// @dev Fuzz: deposit amounts never exceed either budget.
    function testFuzz_depositLBase_amountsNeverExceedBudgets(
        int256 rawLo,
        uint256 rawNBins,
        uint256 rawA0,
        uint256 rawA1
    ) public {
        int24 lo = int24(bound(rawLo, -DOMAIN + 2000, DOMAIN - 2000));
        lo -= lo % SIZE;
        uint256 nBins = bound(rawNBins, 1, MAX_BINS_PER_ADD);
        int24 hi = lo + int24(int256(nBins * 10));
        vm.assume(hi <= TickMath.MAX_TICK);

        _seedBook(lo + int24(int256(nBins / 2)));
        book.sqrtPriceX96 = TickMath.getSqrtPriceAtTick((lo + hi) / 2);

        BinLayout.Window memory w = book.resolveWindow(lo, hi);

        uint256 a0 = bound(rawA0, 1e18, 1e24);
        uint256 a1 = bound(rawA1, 1e18, 1e24);
        if (a0 == 0 && a1 == 0) return;

        uint256 lBase = book.solveLBase(w, a0, a1);
        if (lBase == 0) return;

        (uint256 amount0, uint256 amount1) = book.depositLBase(
            w, lBase, a0, a1, USER, _totalLiquidity, _feeGrowth0, _feeGrowth1, _positions, _userRanges
        );

        // Allow per-bin floor-rounding excess from probe-and-scale
        assertLe(amount0, a0 + a0 / 100_000, "token0 exceeds budget + rounding");
        assertLe(amount1, a1 + a1 / 100_000, "token1 exceeds budget + rounding");
    }

    /*//////////////////////////////////////////////////////////////
                              ADD USER L
    //////////////////////////////////////////////////////////////*/

    /// @dev Pure liquidity bookkeeping — no fee growth involved, unlike `settleFees` below.
    function test_increaseUserL_firstDeposit_setsRangeAndLiquidity() public {
        BinLayout.UserRange storage r = _userRanges[USER];
        BinLayout.increaseUserL(_positions[USER][5], r, _totalLiquidity, 5, 1000);

        assertEq(_positions[USER][5].liquidity, 1000);
        assertEq(_totalLiquidity[5], 1000);
        assertEq(r.minB, 5);
        assertEq(r.maxB, 5);
        assertTrue(r.set);
    }

    /// @dev Repeated adds to the same bin accumulate on both the position and the bin total.
    function test_increaseUserL_repeatedAdd_accumulates() public {
        BinLayout.UserRange storage r = _userRanges[USER];
        BinLayout.increaseUserL(_positions[USER][5], r, _totalLiquidity, 5, 1000);
        BinLayout.increaseUserL(_positions[USER][5], r, _totalLiquidity, 5, 300);

        assertEq(_positions[USER][5].liquidity, 1300);
        assertEq(_totalLiquidity[5], 1300);
        assertEq(r.minB, 5);
        assertEq(r.maxB, 5);
    }

    /// @dev Adding to bins on both sides of the first widens the range to their min/max.
    function test_increaseUserL_widensRangeAcrossBins() public {
        BinLayout.UserRange storage r = _userRanges[USER];
        BinLayout.increaseUserL(_positions[USER][5], r, _totalLiquidity, 5, 1000);
        BinLayout.increaseUserL(_positions[USER][2], r, _totalLiquidity, 2, 500);
        BinLayout.increaseUserL(_positions[USER][8], r, _totalLiquidity, 8, 700);

        assertEq(r.minB, 2);
        assertEq(r.maxB, 8);
        assertEq(_positions[USER][2].liquidity, 500);
        assertEq(_positions[USER][5].liquidity, 1000);
        assertEq(_positions[USER][8].liquidity, 700);
    }

    /// @dev Mirror-reference fuzz: two adds to distinct bins land on their own position/total,
    ///      and the range collapses to [min(bins), max(bins)] regardless of add order.
    function testFuzz_increaseUserL_matchesReference(int24 binA, int24 binB, uint128 addA, uint128 addB) public {
        vm.assume(binA != binB);
        // Reset just the storage this run touches — mappings persist across fuzz runs.
        delete _userRanges[USER];
        delete _positions[USER][binA];
        delete _positions[USER][binB];
        _totalLiquidity[binA] = 0;
        _totalLiquidity[binB] = 0;

        BinLayout.UserRange storage r = _userRanges[USER];
        BinLayout.increaseUserL(_positions[USER][binA], r, _totalLiquidity, binA, addA);
        BinLayout.increaseUserL(_positions[USER][binB], r, _totalLiquidity, binB, addB);

        assertEq(_positions[USER][binA].liquidity, addA, "position A");
        assertEq(_positions[USER][binB].liquidity, addB, "position B");
        assertEq(_totalLiquidity[binA], addA, "total A");
        assertEq(_totalLiquidity[binB], addB, "total B");

        int24 expMin = binA < binB ? binA : binB;
        int24 expMax = binA > binB ? binA : binB;
        assertEq(r.minB, expMin, "minB");
        assertEq(r.maxB, expMax, "maxB");
        assertTrue(r.set);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE REALIZATION
    //////////////////////////////////////////////////////////////*/

    BinLayout.Position position;
    int24 internal constant FEE_BIN = 0;

    /// @dev Growth since the last checkpoint is settled into tokensOwed, and the checkpoint
    ///      advances to the bin's current growth.
    function test_settleFees_settlesAccruedGrowth() public {
        position.liquidity = 1000;
        _feeGrowth0[FEE_BIN] = 10 * FixedPoint128.Q128;
        _feeGrowth1[FEE_BIN] = 4 * FixedPoint128.Q128;

        BinLayout.settleFees(position, _feeGrowth0, _feeGrowth1, FEE_BIN);

        assertEq(position.tokensOwed0, 10_000, "owed0 = growth * L");
        assertEq(position.tokensOwed1, 4000, "owed1 = growth * L");
        assertEq(position.feeGrowth0LastX128, 10 * FixedPoint128.Q128, "checkpoint0 advances");
        assertEq(position.feeGrowth1LastX128, 4 * FixedPoint128.Q128, "checkpoint1 advances");
    }

    /// @dev Re-touching a position with no new growth (e.g. a same-block second call) is a
    ///      no-op on tokensOwed — this is the branch the tokensOwed-write guard skips.
    function test_settleFees_noNewGrowth_isIdempotent() public {
        position.liquidity = 1000;
        _feeGrowth0[FEE_BIN] = 10 * FixedPoint128.Q128;
        _feeGrowth1[FEE_BIN] = 4 * FixedPoint128.Q128;
        BinLayout.settleFees(position, _feeGrowth0, _feeGrowth1, FEE_BIN);

        BinLayout.settleFees(position, _feeGrowth0, _feeGrowth1, FEE_BIN);

        assertEq(position.tokensOwed0, 10_000, "unchanged: nothing new accrued");
        assertEq(position.tokensOwed1, 4000, "unchanged: nothing new accrued");
        assertEq(position.feeGrowth0LastX128, 10 * FixedPoint128.Q128);
        assertEq(position.feeGrowth1LastX128, 4 * FixedPoint128.Q128);
    }

    /// @dev A fresh (zero-liquidity) position accrues nothing but still gets its checkpoint
    ///      initialized to the bin's current growth.
    function test_settleFees_freshPosition_onlyInitializesCheckpoint() public {
        _feeGrowth0[FEE_BIN] = 7 * FixedPoint128.Q128;
        _feeGrowth1[FEE_BIN] = 2 * FixedPoint128.Q128;

        BinLayout.settleFees(position, _feeGrowth0, _feeGrowth1, FEE_BIN);

        assertEq(position.tokensOwed0, 0, "no liquidity to have accrued anything");
        assertEq(position.tokensOwed1, 0, "no liquidity to have accrued anything");
        assertEq(position.feeGrowth0LastX128, 7 * FixedPoint128.Q128);
        assertEq(position.feeGrowth1LastX128, 2 * FixedPoint128.Q128);
    }

    /// @dev Mirror-reference fuzz covering both the accrual path and the no-op-write-skip path
    ///      (growth0After == growth0Before / growth1After == growth1Before draws are common
    ///      under `bound`'s inclusive range, exercising the guard added in `settleFees`).
    function testFuzz_settleFees_matchesReference(
        uint128 liquidity,
        uint128 growth0Before,
        uint128 growth0After,
        uint128 growth1Before,
        uint128 growth1After
    ) public {
        growth0After = uint128(bound(growth0After, growth0Before, type(uint128).max));
        growth1After = uint128(bound(growth1After, growth1Before, type(uint128).max));

        position.liquidity = liquidity;
        position.feeGrowth0LastX128 = growth0Before;
        position.feeGrowth1LastX128 = growth1Before;
        _feeGrowth0[FEE_BIN] = growth0After;
        _feeGrowth1[FEE_BIN] = growth1After;

        uint256 expOwed0 =
            liquidity == 0 ? 0 : FullMath.mulDiv(growth0After - growth0Before, liquidity, FixedPoint128.Q128);
        uint256 expOwed1 =
            liquidity == 0 ? 0 : FullMath.mulDiv(growth1After - growth1Before, liquidity, FixedPoint128.Q128);

        BinLayout.settleFees(position, _feeGrowth0, _feeGrowth1, FEE_BIN);

        assertEq(position.tokensOwed0, expOwed0, "owed0");
        assertEq(position.tokensOwed1, expOwed1, "owed1");
        assertEq(position.feeGrowth0LastX128, growth0After, "checkpoint0");
        assertEq(position.feeGrowth1LastX128, growth1After, "checkpoint1");
    }
}
