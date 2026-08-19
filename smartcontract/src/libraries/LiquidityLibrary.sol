// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LiquidityLibrary
/// @notice Core CPMM math for bin-based concentrated liquidity.
/// @dev Each bin is a mini x*y=k pool bounded by [sqrtPriceLower, sqrtPriceUpper].
///      Uses sqrtPriceX96 representation like Uniswap v3.
///      Distribution strategies (exponential, linear, constant, equal-token1)
///      are implemented as separate libraries that import this core.
library LiquidityLibrary {
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q192 = 2 ** 192;

    struct BinBounds {
        uint256 sqrtPriceLower;
        uint256 sqrtPriceUpper;
    }

    struct DepositAmounts {
        uint256 amount0;
        uint256 amount1;
    }

    // ──────────────────────────────────────────────
    //  Pure Math Helpers
    // ──────────────────────────────────────────────

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = x;
        uint256 y;
        if (x == type(uint256).max) {
            y = (x >> 1) + 1;
        } else {
            y = (x + 1) >> 1;
        }
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
        return z;
    }

    function priceToSqrtPriceX96(uint256 price, uint8 decimals0, uint8 decimals1) internal pure returns (uint256) {
        uint256 scaledPrice = price * (10 ** decimals0) / (10 ** decimals1);
        uint8 adj = 18 + decimals0 - decimals1;
        uint256 bigScaled = scaledPrice * 1e12;
        if (adj % 2 == 0) {
            return sqrt(bigScaled) * Q96 / (10 ** (adj / 2)) / 1e6;
        } else {
            return sqrt(bigScaled * 10) * Q96 / (10 ** (adj / 2 + 1)) / 1e6;
        }
    }

    function sqrtPriceX96ToPrice(uint256 sqrtPriceX96, uint8 /* decimals0 */, uint8 /* decimals1 */)
        internal
        pure
        returns (uint256)
    {
        uint256 a = sqrtPriceX96 >> 48;
        uint256 b = sqrtPriceX96 & ((1 << 48) - 1);
        uint256 price = a * a * 1e18 / Q96;
        price += (2 * a * b * 1e18) >> 144;
        return price;
    }

    // ──────────────────────────────────────────────
    //  CPMM Token Amounts
    // ──────────────────────────────────────────────

    function getTokenAmountsForBin(uint256 L, uint256 sqrtPriceCurrent, BinBounds memory bounds)
        internal
        pure
        returns (uint256 token0, uint256 token1)
    {
        if (L == 0) return (0, 0);
        if (sqrtPriceCurrent <= bounds.sqrtPriceLower) {
            token0 = L * (Q96 * Q96 / bounds.sqrtPriceLower - Q96 * Q96 / bounds.sqrtPriceUpper) / Q96;
        } else if (sqrtPriceCurrent >= bounds.sqrtPriceUpper) {
            token1 = L * (bounds.sqrtPriceUpper - bounds.sqrtPriceLower) / Q96;
        } else {
            token0 = L * (Q96 * Q96 / sqrtPriceCurrent - Q96 * Q96 / bounds.sqrtPriceUpper) / Q96;
            token1 = L * (sqrtPriceCurrent - bounds.sqrtPriceLower) / Q96;
        }
    }

    // ──────────────────────────────────────────────
    //  Bin Boundary Helpers
    // ──────────────────────────────────────────────

    function getBinBounds(uint256 binIndex, uint256 spacing, uint256 sqrtPriceBase)
        internal
        pure
        returns (BinBounds memory)
    {
        uint256 sqrtPriceLower = sqrtPriceBase + binIndex * spacing;
        uint256 sqrtPriceUpper = sqrtPriceLower + spacing;
        return BinBounds(sqrtPriceLower, sqrtPriceUpper);
    }

    // ──────────────────────────────────────────────
    //  LP Mint / Withdraw Amounts
    // ──────────────────────────────────────────────

    function getMintAmounts(
        uint256 totalLiquidity,
        uint256 totalToken0,
        uint256 totalToken1,
        uint256 sharesToMint,
        uint256 totalSupply
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sharesToMint == 0) return (0, 0);
        if (totalSupply == 0 || totalLiquidity == 0) {
            return (totalToken0, totalToken1);
        }
        amount0 = totalToken0 * sharesToMint / totalSupply;
        amount1 = totalToken1 * sharesToMint / totalSupply;
    }

    function getWithdrawAmounts(uint256 totalToken0, uint256 totalToken1, uint256 sharesToBurn, uint256 totalSupply)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sharesToBurn == 0 || totalSupply == 0) return (0, 0);
        amount0 = totalToken0 * sharesToBurn / totalSupply;
        amount1 = totalToken1 * sharesToBurn / totalSupply;
    }

    // ──────────────────────────────────────────────
    //  Internal Helpers
    // ──────────────────────────────────────────────

    function _powDecimal(uint256 base, uint256 exp) internal pure returns (uint256) {
        if (exp == 0) return 1e18;
        if (exp == 1) return base;
        uint256 result = 1e18;
        uint256 currentBase = base;
        uint256 e = exp;
        while (e > 0) {
            if (e & 1 == 1) {
                result = result * currentBase / 1e18;
            }
            currentBase = currentBase * currentBase / 1e18;
            e >>= 1;
        }
        return result;
    }
}
