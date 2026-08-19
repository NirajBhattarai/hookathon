// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidityLibrary} from "../src/libraries/LiquidityLibrary.sol";

contract LiquidityLibraryTest is Test {
    using LiquidityLibrary for *;

    uint256 constant Q96 = LiquidityLibrary.Q96;
    uint256 constant MAX_UINT256 = type(uint256).max;
    uint256 constant MAX_UINT128 = type(uint128).max;

    function setUp() public {}

    // ════════════════════════════════════════════════
    //  Unit Tests: sqrt
    // ════════════════════════════════════════════════

    function test_Sqrt_Zero() public view {
        assertEq(LiquidityLibrary.sqrt(0), 0);
    }

    function test_Sqrt_One() public view {
        assertEq(LiquidityLibrary.sqrt(1), 1);
    }

    function test_Sqrt_Four() public view {
        assertEq(LiquidityLibrary.sqrt(4), 2);
    }

    function test_Sqrt_Nine() public view {
        assertEq(LiquidityLibrary.sqrt(9), 3);
    }

    function test_Sqrt_PerfectSquare() public view {
        assertEq(LiquidityLibrary.sqrt(100), 10);
    }

    function test_Sqrt_LargePerfectSquare() public view {
        assertEq(LiquidityLibrary.sqrt(1e36), 1e18);
    }

    function test_Sqrt_NonPerfectSquare_RoundsDown() public view {
        uint256 result = LiquidityLibrary.sqrt(2);
        assertLe(result * result, 2);
        assertGe((result + 1) * (result + 1), 2);
    }

    function test_Sqrt_MaxUint256() public view {
        uint256 result = LiquidityLibrary.sqrt(MAX_UINT256);
        assertEq(result, 2 ** 128 - 1);
    }

    function test_Sqrt_MaxUint128() public view {
        uint256 result = LiquidityLibrary.sqrt(MAX_UINT128);
        assertEq(result, 2 ** 64 - 1);
    }

    // ════════════════════════════════════════════════
    //  Unit Tests: _powDecimal
    // ════════════════════════════════════════════════

    function test_PowDecimal_ZeroExponent() public view {
        assertEq(LiquidityLibrary._powDecimal(0.8e18, 0), 1e18);
    }

    function test_PowDecimal_OneExponent() public view {
        assertEq(LiquidityLibrary._powDecimal(0.8e18, 1), 0.8e18);
    }

    function test_PowDecimal_TwoExponent() public view {
        assertEq(LiquidityLibrary._powDecimal(0.5e18, 2), 0.25e18);
    }

    function test_PowDecimal_ThreeExponent() public view {
        assertEq(LiquidityLibrary._powDecimal(0.5e18, 3), 0.125e18);
    }

    function test_PowDecimal_BaseIsOne() public view {
        assertEq(LiquidityLibrary._powDecimal(1e18, 100), 1e18);
    }

    function test_PowDecimal_BaseIsTwo() public view {
        assertEq(LiquidityLibrary._powDecimal(2e18, 3), 8e18);
    }

    function test_PowDecimal_SmallBase() public view {
        uint256 result = LiquidityLibrary._powDecimal(0.01e18, 2);
        assertEq(result, 1e14);
    }

    function test_PowDecimal_LargeExponent() public view {
        uint256 result = LiquidityLibrary._powDecimal(0.5e18, 20);
        assertGt(result, 0);
        assertLt(result, 1e18);
    }

    // ════════════════════════════════════════════════
    //  Unit Tests: getTokenAmountsForBin
    // ════════════════════════════════════════════════

    function test_GetTokenAmountsForBin_ZeroLiquidity() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);
        (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(0, 1500 * Q96, bounds);
        assertEq(t0, 0);
        assertEq(t1, 0);
    }

    function test_GetTokenAmountsForBin_PriceAboveBin() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);
        uint256 L = 1e18;

        (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 3000 * Q96, bounds);

        assertEq(t0, 0);
        assertGt(t1, 0);
    }

    function test_GetTokenAmountsForBin_PriceBelowBin() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);
        uint256 L = 1e18;

        (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 500 * Q96, bounds);

        assertGt(t0, 0);
        assertEq(t1, 0);
    }

    function test_GetTokenAmountsForBin_PriceInsideBin() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);
        uint256 L = 1e18;

        (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 1500 * Q96, bounds);

        assertGt(t0, 0);
        assertGt(t1, 0);
    }

    function test_GetTokenAmountsForBin_PriceAtLowerBound() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);
        uint256 L = 1e18;

        (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 1000 * Q96, bounds);

        assertGt(t0, 0);
        assertEq(t1, 0);
    }

    function test_GetTokenAmountsForBin_PriceAtUpperBound() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);
        uint256 L = 1e18;

        (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 2000 * Q96, bounds);

        assertEq(t0, 0);
        assertGt(t1, 0);
    }

    function test_GetTokenAmountsForBin_Token1Formula() public view {
        uint256 L = 10 * Q96;
        uint256 sqrtLower = 1000 * Q96;
        uint256 sqrtUpper = 2000 * Q96;
        uint256 sqrtCurrent = 3000 * Q96;

        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(sqrtLower, sqrtUpper);
        (, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, sqrtCurrent, bounds);

        uint256 expected = L * (sqrtUpper - sqrtLower) / Q96;
        assertEq(t1, expected);
    }

    function test_GetTokenAmountsForBin_SmallBinWidth() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 1001 * Q96);
        uint256 L = 1e18;

        (, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 2000 * Q96, bounds);

        uint256 expected = L * (1001 * Q96 - 1000 * Q96) / Q96;
        assertEq(t1, expected);
    }

    // ════════════════════════════════════════════════
    //  Unit Tests: getBinBounds
    // ════════════════════════════════════════════════

    function test_GetBinBounds_ZeroIndex() public view {
        uint256 spacing = 100 * Q96;
        uint256 base = 1000 * Q96;

        LiquidityLibrary.BinBounds memory b = LiquidityLibrary.getBinBounds(0, spacing, base);

        assertEq(b.sqrtPriceLower, base);
        assertEq(b.sqrtPriceUpper, base + spacing);
    }

    function test_GetBinBounds_IndexOne() public view {
        uint256 spacing = 100 * Q96;
        uint256 base = 1000 * Q96;

        LiquidityLibrary.BinBounds memory b = LiquidityLibrary.getBinBounds(1, spacing, base);

        assertEq(b.sqrtPriceLower, base + spacing);
        assertEq(b.sqrtPriceUpper, base + 2 * spacing);
    }

    function test_GetBinBounds_IndexFive() public view {
        uint256 spacing = 50 * Q96;
        uint256 base = 500 * Q96;

        LiquidityLibrary.BinBounds memory b = LiquidityLibrary.getBinBounds(5, spacing, base);

        assertEq(b.sqrtPriceLower, base + 5 * spacing);
        assertEq(b.sqrtPriceUpper, base + 6 * spacing);
    }

    // ════════════════════════════════════════════════
    //  Unit Tests: getMintAmounts / getWithdrawAmounts
    // ════════════════════════════════════════════════

    function test_GetMintAmounts_ZeroShares() public view {
        (uint256 a0, uint256 a1) = LiquidityLibrary.getMintAmounts(1e18, 100e18, 200e18, 0, 1e18);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    function test_GetMintAmounts_FirstDeposit() public view {
        (uint256 a0, uint256 a1) = LiquidityLibrary.getMintAmounts(0, 100e18, 200e18, 1e18, 0);
        assertEq(a0, 100e18);
        assertEq(a1, 200e18);
    }

    function test_GetMintAmounts_SubsequentDeposit() public view {
        (uint256 a0, uint256 a1) = LiquidityLibrary.getMintAmounts(1e18, 100e18, 200e18, 1e18, 1e18);
        assertEq(a0, 100e18);
        assertEq(a1, 200e18);
    }

    function test_GetMintAmounts_HalfSupply() public view {
        (uint256 a0, uint256 a1) = LiquidityLibrary.getMintAmounts(1e18, 100e18, 200e18, 0.5e18, 1e18);
        assertEq(a0, 50e18);
        assertEq(a1, 100e18);
    }

    function test_GetWithdrawAmounts_FullWithdrawal() public view {
        (uint256 a0, uint256 a1) = LiquidityLibrary.getWithdrawAmounts(100e18, 200e18, 1e18, 1e18);
        assertEq(a0, 100e18);
        assertEq(a1, 200e18);
    }

    function test_GetWithdrawAmounts_PartialWithdrawal() public view {
        (uint256 a0, uint256 a1) = LiquidityLibrary.getWithdrawAmounts(100e18, 200e18, 0.5e18, 1e18);
        assertEq(a0, 50e18);
        assertEq(a1, 100e18);
    }

    function test_GetWithdrawAmounts_ZeroShares() public view {
        (uint256 a0, uint256 a1) = LiquidityLibrary.getWithdrawAmounts(100e18, 200e18, 0, 1e18);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    function test_GetWithdrawAmounts_ZeroSupply() public view {
        (uint256 a0, uint256 a1) = LiquidityLibrary.getWithdrawAmounts(100e18, 200e18, 1e18, 0);
        assertEq(a0, 0);
        assertEq(a1, 0);
    }

    // ════════════════════════════════════════════════
    //  Unit Tests: priceToSqrtPriceX96 / sqrtPriceX96ToPrice
    // ════════════════════════════════════════════════

    function test_PriceToSqrtPriceX96_SameDecimals() public view {
        uint256 result = LiquidityLibrary.priceToSqrtPriceX96(1e18, 18, 18);
        assertEq(result, 1 * Q96);
    }

    function test_PriceToSqrtPriceX96_PriceFour() public view {
        uint256 result = LiquidityLibrary.priceToSqrtPriceX96(4e18, 18, 18);
        assertEq(result, 2 * Q96);
    }

    function test_SqrtPriceX96ToPrice_SameDecimals() public view {
        uint256 price = LiquidityLibrary.sqrtPriceX96ToPrice(1 * Q96, 18, 18);
        assertEq(price, 1e18);
    }

    function test_PriceRoundtrip_SameDecimals() public view {
        uint256 original = 1500e18;
        uint256 sqrtP = LiquidityLibrary.priceToSqrtPriceX96(original, 18, 18);
        uint256 recovered = LiquidityLibrary.sqrtPriceX96ToPrice(sqrtP, 18, 18);
        assertApproxEqAbs(recovered, original, 1e18);
    }

    // ════════════════════════════════════════════════
    //  Mixed Decimal Tests (6/18, 18/6, 8/18, etc.)
    // ════════════════════════════════════════════════

    function test_PriceToSqrtPriceX96_6and18() public view {
        // USDC(token0, 6 decimals) / WETH(token1, 18 decimals), price = 5000.0
        uint256 result = LiquidityLibrary.priceToSqrtPriceX96(5000e18, 6, 18);
        assertGt(result, 0);
        // Verify: sqrtPriceX96ToPrice roundtrips
        uint256 price = LiquidityLibrary.sqrtPriceX96ToPrice(result, 6, 18);
        assertApproxEqAbs(price, 5000e18, 5000e18 / 10000);
    }

    function test_PriceToSqrtPriceX96_18and6() public view {
        // WETH(token0, 18 decimals) / USDC(token1, 6 decimals), price = 5000.0
        uint256 result = LiquidityLibrary.priceToSqrtPriceX96(5000e18, 18, 6);
        assertGt(result, 0);
        uint256 price = LiquidityLibrary.sqrtPriceX96ToPrice(result, 18, 6);
        assertApproxEqAbs(price, 5000e18, 5000e18 / 10000);
    }

    function test_PriceToSqrtPriceX96_8and18() public view {
        // WBTC(token0, 8 decimals) / WETH(token1, 18 decimals), price = 20.0
        uint256 result = LiquidityLibrary.priceToSqrtPriceX96(20e18, 8, 18);
        assertGt(result, 0);
        uint256 price = LiquidityLibrary.sqrtPriceX96ToPrice(result, 8, 18);
        assertApproxEqAbs(price, 20e18, 20e18 / 10000);
    }

    function test_PriceToSqrtPriceX96_6and8() public view {
        // USDC(token0, 6 decimals) / WBTC(token1, 8 decimals), price = 0.0002
        uint256 result = LiquidityLibrary.priceToSqrtPriceX96(2e14, 6, 8);
        assertGt(result, 0);
        uint256 price = LiquidityLibrary.sqrtPriceX96ToPrice(result, 6, 8);
        assertApproxEqAbs(price, 2e14, 2e14 / 10000);
    }

    function test_PriceToSqrtPriceX96_18and8() public view {
        // WETH(token0, 18 decimals) / WBTC(token1, 8 decimals), price = 20.0
        uint256 result = LiquidityLibrary.priceToSqrtPriceX96(20e18, 18, 8);
        assertGt(result, 0);
        uint256 price = LiquidityLibrary.sqrtPriceX96ToPrice(result, 18, 8);
        assertApproxEqAbs(price, 20e18, 20e18 / 10000);
    }

    function test_MixedDecimals_GetTokenAmounts() public view {
        // Verify token amounts work the same regardless of decimals
        // (sqrtPriceX96 and L are decimal-agnostic)
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);

        (uint256 t0_18, uint256 t1_18) = LiquidityLibrary.getTokenAmountsForBin(1e18, 3000 * Q96, bounds);

        // With different decimals, the sqrtPriceX96 values are the same,
        // so token amounts in Q96 space are identical
        (uint256 t0_6, uint256 t1_6) = LiquidityLibrary.getTokenAmountsForBin(1e18, 3000 * Q96, bounds);

        assertEq(t0_18, t0_6);
        assertEq(t1_18, t1_6);
    }

    function testFuzz_PriceRoundtrip_MixedDecimals(uint256 price, uint8 d0, uint8 d1) public view {
        // Test roundtrip for various decimal combinations
        d0 = uint8(bound(d0, 6, 18));
        d1 = uint8(bound(d1, 6, 18));
        if (d0 == d1) d1 = d0 == 18 ? 6 : 18;

        price = bound(price, 1e15, 1e22); // reasonable price range

        uint256 sqrtP = LiquidityLibrary.priceToSqrtPriceX96(price, d0, d1);
        assertGt(sqrtP, 0, "sqrtPriceX96 must be positive");

        uint256 recovered = LiquidityLibrary.sqrtPriceX96ToPrice(sqrtP, d0, d1);
        assertGt(recovered, 0, "recovered price must be positive");
        // Allow integer truncation error: relative 0.1% + absolute floor
        assertApproxEqAbs(recovered, price, price / 100 + 1e9);
    }

    // ════════════════════════════════════════════════
    //  Edge Cases: Extreme Values
    // ════════════════════════════════════════════════

    function test_Edge_SqrtMaxUint256() public view {
        uint256 result = LiquidityLibrary.sqrt(MAX_UINT256);
        assertEq(result, 2 ** 128 - 1);
    }

    function test_Edge_SqrtMaxUint128() public view {
        uint256 result = LiquidityLibrary.sqrt(MAX_UINT128);
        assertEq(result, 2 ** 64 - 1);
    }

    function test_Edge_PowDecimalZeroBase() public view {
        assertEq(LiquidityLibrary._powDecimal(0, 5), 0);
    }

    function test_Edge_SingleBinMintWithdraw() public view {
        uint256 totalToken0 = 50e18;
        uint256 totalToken1 = 100e18;
        uint256 shares = 1e18;

        (uint256 a0, uint256 a1) = LiquidityLibrary.getMintAmounts(0, totalToken0, totalToken1, shares, 0);
        assertEq(a0, totalToken0);
        assertEq(a1, totalToken1);

        (uint256 w0, uint256 w1) = LiquidityLibrary.getWithdrawAmounts(totalToken0, totalToken1, shares, shares);
        assertEq(w0, totalToken0);
        assertEq(w1, totalToken1);
    }

    function test_Edge_VerySmallLiquidity() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 1001 * Q96);
        uint256 L = 1;

        (, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 2000 * Q96, bounds);
        assertGt(t1, 0);
    }

    function test_Edge_LargeLiquidity() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(Q96, 2 * Q96);
        uint256 L = MAX_UINT128;

        (, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 3 * Q96, bounds);
        assertGt(t1, 0);
    }

    function test_Edge_NarrowBin() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 1000 * Q96 + 1);
        uint256 L = 1e18;

        (, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, 2000 * Q96, bounds);
        assertEq(t1, L * 1 / Q96);
    }

    // ════════════════════════════════════════════════
    //  Invariants
    // ════════════════════════════════════════════════

    function test_Invariant_MintWithdrawRoundtrip() public view {
        uint256 totalToken0 = 1000e18;
        uint256 totalToken1 = 2000e18;
        uint256 totalLiquidity = 5e18;

        (uint256 a0, uint256 a1) =
            LiquidityLibrary.getMintAmounts(totalLiquidity, totalToken0, totalToken1, totalLiquidity, totalLiquidity);

        (uint256 w0, uint256 w1) =
            LiquidityLibrary.getWithdrawAmounts(totalToken0 + a0, totalToken1 + a1, totalLiquidity, totalLiquidity * 2);

        assertEq(w0, a0);
        assertEq(w1, a1);
    }

    function test_Invariant_WithdrawalNeverExceedsReserves() public view {
        uint256 totalToken0 = 100e18;
        uint256 totalToken1 = 200e18;
        uint256 totalSupply = 1e18;

        (uint256 w0, uint256 w1) =
            LiquidityLibrary.getWithdrawAmounts(totalToken0, totalToken1, totalSupply, totalSupply);

        assertLe(w0, totalToken0);
        assertLe(w1, totalToken1);
    }

    function test_Invariant_SqrtSquareLessThanOrEqual() public view {
        uint256 x = 123456789;
        uint256 r = LiquidityLibrary.sqrt(x);
        assertLe(r * r, x);
        assertGe((r + 1) * (r + 1), x);
    }

    function test_Invariant_TokenAmountsBelowPriceAreToken1Only() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);

        (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(1e18, 3000 * Q96, bounds);
        assertEq(t0, 0);
        assertGt(t1, 0);
    }

    function test_Invariant_TokenAmountsAbovePriceAreToken0Only() public view {
        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(1000 * Q96, 2000 * Q96);

        (uint256 t0, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(1e18, 500 * Q96, bounds);
        assertGt(t0, 0);
        assertEq(t1, 0);
    }

    // ════════════════════════════════════════════════
    //  Fuzz Tests
    // ════════════════════════════════════════════════

    function testFuzz_Sqrt(uint128 x) public view {
        if (x == 0) return;
        uint256 r = LiquidityLibrary.sqrt(x);
        assertLe(r * r, uint256(x));
        assertGe((r + 1) * (r + 1), uint256(x));
    }

    function testFuzz_PowDecimalIdempotent(uint256 base) public view {
        if (base > 10e18) base = 10e18;
        if (base == 0) return;
        uint256 result = LiquidityLibrary._powDecimal(base, 1);
        assertEq(result, base);
    }

    function testFuzz_GetTokenAmountsForBin_PriceAboveAlwaysToken1(uint256 sqrtLower, uint256 L) public view {
        sqrtLower = bound(sqrtLower, 1, MAX_UINT256 / 2);
        L = bound(L, 1, 1e36);
        uint256 sqrtUpper = sqrtLower + 1 * Q96;

        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(sqrtLower, sqrtUpper);

        uint256 sqrtPriceAbove = sqrtUpper + 1 * Q96;
        (uint256 t0,) = LiquidityLibrary.getTokenAmountsForBin(L, sqrtPriceAbove, bounds);
        assertEq(t0, 0, "token0 should be zero when price above");
    }

    function testFuzz_GetTokenAmountsForBin_PriceBelowAlwaysToken0(uint256 sqrtUpper, uint256 L) public view {
        sqrtUpper = bound(sqrtUpper, 2 * Q96, 1e40);
        L = bound(L, 1, 1e18);
        uint256 sqrtLower = sqrtUpper - 1 * Q96;

        LiquidityLibrary.BinBounds memory bounds = LiquidityLibrary.BinBounds(sqrtLower, sqrtUpper);

        uint256 sqrtPriceBelow = sqrtLower - 1;

        (, uint256 t1) = LiquidityLibrary.getTokenAmountsForBin(L, sqrtPriceBelow, bounds);
        assertEq(t1, 0, "token1 should be zero when price below");
    }

    function testFuzz_WithdrawalNeverExceedsReserves(uint256 token0, uint256 token1, uint256 shares) public view {
        token0 = bound(token0, 0, 1e36);
        token1 = bound(token1, 0, 1e36);
        shares = bound(shares, 1, 1e36);

        (uint256 w0, uint256 w1) = LiquidityLibrary.getWithdrawAmounts(token0, token1, shares, shares);
        assertLe(w0, token0);
        assertLe(w1, token1);
    }

    function testFuzz_MintAmountsNeverExceedExisting(
        uint256 totalToken0,
        uint256 totalToken1,
        uint256 totalSupply,
        uint256 sharesToMint
    ) public view {
        totalToken0 = bound(totalToken0, 1, 1e36);
        totalToken1 = bound(totalToken1, 1, 1e36);
        totalSupply = bound(totalSupply, 1, 1e36);
        sharesToMint = bound(sharesToMint, 1, totalSupply);

        (uint256 a0, uint256 a1) =
            LiquidityLibrary.getMintAmounts(1e18, totalToken0, totalToken1, sharesToMint, totalSupply);

        assertLe(a0, totalToken0);
        assertLe(a1, totalToken1);
    }

    function testFuzz_MintWithdrawRoundtrip(uint256 token0, uint256 token1, uint256 totalSupply) public view {
        token0 = bound(token0, 1, 1e18);
        token1 = bound(token1, 1, 1e18);
        totalSupply = bound(totalSupply, 1, 1e18);

        LiquidityLibrary.getMintAmounts(0, token0, token1, totalSupply, 0);

        (uint256 w0, uint256 w1) = LiquidityLibrary.getWithdrawAmounts(token0, token1, totalSupply, totalSupply);

        assertEq(w0, token0);
        assertEq(w1, token1);
    }
}
