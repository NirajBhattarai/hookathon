// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BinLayout} from "src/libraries/BinLayout.sol";
import {SwapMath} from "src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

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
        book.ramp = BASE_RAMP;
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
        book.ramp = BASE_RAMP;
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

    /// @dev Bin sqrt-price bounds helper mirroring BinLayout.amountsFor's tick math.
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
}
