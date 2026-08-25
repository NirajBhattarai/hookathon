// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library Constants {
    /// @dev All sqrtPrice calculations are calculated as
    /// sqrtPriceX96 = floor(sqrt(A / B) * 2 ** 96) where A and B are the currency reserves
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 public constant SQRT_PRICE_1_2 = 56022770974786139918731938227;
    uint160 public constant SQRT_PRICE_1_4 = 39614081257132168796771975168;
    uint160 public constant SQRT_PRICE_2_1 = 112045541949572279837463876454;
    uint160 public constant SQRT_PRICE_4_1 = 158456325028528675187087900672;
    uint160 public constant SQRT_PRICE_121_100 = 87150978765690771352898345369;
    uint160 public constant SQRT_PRICE_99_100 = 78831026366734652303669917531;
    uint160 public constant SQRT_PRICE_99_1000 = 24928559360766947368818086097;
    uint160 public constant SQRT_PRICE_101_100 = 79623317895830914510639640423;
    uint160 public constant SQRT_PRICE_1000_100 = 250541448375047931186413801569;
    uint160 public constant SQRT_PRICE_1010_100 = 251791039410471229173201122529;
    uint160 public constant SQRT_PRICE_10000_100 = 792281625142643375935439503360;

    // Meme coin prices (1 MEME = 1/N ETH → sqrtPriceX96 = sqrt(1/N) * 2^96)
    uint160 public constant SQRT_PRICE_1_100 = 7922816251426434199159046144; // 1 MEME = 0.01 ETH  (100 MEME/ETH)
    uint160 public constant SQRT_PRICE_1_1000 = 2505414483750479155158843392; // 1 MEME = 0.001 ETH (1K MEME/ETH)
    uint160 public constant SQRT_PRICE_1_10000 = 792281625142643392428113920; // 1 MEME = 0.0001 ETH (10K MEME/ETH)
    uint160 public constant SQRT_PRICE_1_100000 = 250541448375047936131727360; // 1 MEME = 0.00001 ETH (100K MEME/ETH)

    uint256 constant MAX_UINT256 = type(uint256).max;
    uint128 constant MAX_UINT128 = type(uint128).max;
    uint160 constant MAX_UINT160 = type(uint160).max;

    address constant ADDRESS_ZERO = address(0);
}
