// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinRatchet} from "../src/BinRatchet.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @dev Same three books as the MEV analysis: stable / mid / meme.
contract BinRatchetRegimesTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    struct Regime {
        string name;
        uint24 fee; // pips: 100=1bps, 500=5bps, 3000=30bps
        int24 tickSpacing;
        int24 binSize; // ticks; ~0.01% each
        uint256 typicalClip; // vs 200 ether notionally seeded
    }

    struct Live {
        BinRatchet hook;
        PoolKey key;
        PoolId id;
        Currency c0;
        Currency c1;
    }

    Regime internal stable;
    Regime internal mid;
    Regime internal meme;

    function setUp() public {
        deployArtifactsAndLabel();
        // USDC/USDT: 0.20% bins, 1 bps, 5% clip
        stable = Regime("stable", 100, 1, 20, 10 ether);
        // ETH/USDC: 1.00% bins, 5 bps, 1% clip
        mid = Regime("mid", 500, 10, 100, 2 ether);
        // MEME: 3.00% bins, 30 bps, 3% clip
        meme = Regime("meme", 3000, 60, 300, 6 ether);
    }

    function _deploy(Regime memory r, uint160 salt) internal returns (Live memory live) {
        address flags = address(uint160(HOOK_FLAGS) | (salt << 20));
        deployCodeTo("BinRatchet.sol:BinRatchet", abi.encode(poolManager), flags);
        live.hook = BinRatchet(flags);

        (live.c0, live.c1) = deployCurrencyPair();
        MockERC20(Currency.unwrap(live.c0)).approve(address(live.hook), type(uint256).max);
        MockERC20(Currency.unwrap(live.c1)).approve(address(live.hook), type(uint256).max);
        MockERC20(Currency.unwrap(live.c0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(live.c1)).approve(address(swapRouter), type(uint256).max);

        live.key = PoolKey(live.c0, live.c1, r.fee, r.tickSpacing, IHooks(address(live.hook)));
        live.id = live.key.toId();
        poolManager.initialize(live.key, Constants.SQRT_PRICE_1_1);
        live.hook.setBinSize(live.key, r.binSize);

        live.hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
    }

    function _priceMoveBps(Live memory live, uint256 amountIn, bool zeroForOne) internal returns (uint256) {
        uint256 p0 = uint256(live.hook.currentSqrtPriceX96());
        swapRouter.swapExactTokensForTokens(
            amountIn, 0, zeroForOne, live.key, "", address(this), block.timestamp
        );
        uint256 p1 = uint256(live.hook.currentSqrtPriceX96());
        uint256 hi = p0 > p1 ? p0 : p1;
        uint256 lo = p0 > p1 ? p1 : p0;
        // sqrtP move ≈ half of price move; report |Δsqrt|/sqrt * 10000
        return (hi - lo) * 10_000 / p0;
    }

    function test_stable_seedsLinearDecayAndSwaps() public {
        Live memory live = _deploy(stable, 1);
        _assertBook(live);
        uint160 p0 = live.hook.currentSqrtPriceX96();
        swapRouter.swapExactTokensForTokens(1 ether, 0, false, live.key, "", address(this), block.timestamp);
        assertGt(live.hook.currentSqrtPriceX96(), p0);
    }

    function test_mid_seedsLinearDecayAndSwaps() public {
        Live memory live = _deploy(mid, 2);
        _assertBook(live);
        uint160 p0 = live.hook.currentSqrtPriceX96();
        swapRouter.swapExactTokensForTokens(1 ether, 0, false, live.key, "", address(this), block.timestamp);
        assertGt(live.hook.currentSqrtPriceX96(), p0);
    }

    function test_meme_seedsLinearDecayAndSwaps() public {
        Live memory live = _deploy(meme, 3);
        _assertBook(live);
        uint160 p0 = live.hook.currentSqrtPriceX96();
        swapRouter.swapExactTokensForTokens(1 ether, 0, false, live.key, "", address(this), block.timestamp);
        assertGt(live.hook.currentSqrtPriceX96(), p0);
    }

    function test_allRegimes_sameBlockReverseWalksBack() public {
        _assertRoundTrip(_deploy(stable, 4), 1 ether);
        _assertRoundTrip(_deploy(mid, 5), 1 ether);
        _assertRoundTrip(_deploy(meme, 6), 1 ether);
    }

    function test_allRegimes_typicalClip_thenWalkBack() public {
        _assertRoundTrip(_deploy(stable, 7), stable.typicalClip);
        _assertRoundTrip(_deploy(mid, 8), mid.typicalClip);
        _assertRoundTrip(_deploy(meme, 9), meme.typicalClip);
    }

    function test_sameSizeClip_stableMovesLessThanMidLessThanMeme() public {
        Live memory s = _deploy(stable, 10);
        Live memory m = _deploy(mid, 11);
        Live memory h = _deploy(meme, 12);

        uint256 clip = 0.5 ether;
        uint256 ds = _priceMoveBps(s, clip, false);
        uint256 dm = _priceMoveBps(m, clip, false);
        uint256 dh = _priceMoveBps(h, clip, false);

        assertLt(ds, dm, "stable should move less than mid");
        assertLt(dm, dh, "mid should move less than meme");
    }

    function test_oppositeDirection_allRegimes() public {
        Live memory s = _deploy(stable, 13);
        Live memory m = _deploy(mid, 14);
        Live memory h = _deploy(meme, 15);

        uint160 ps = s.hook.currentSqrtPriceX96();
        uint160 pm = m.hook.currentSqrtPriceX96();
        uint160 ph = h.hook.currentSqrtPriceX96();

        swapRouter.swapExactTokensForTokens(1 ether, 0, true, s.key, "", address(this), block.timestamp);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, m.key, "", address(this), block.timestamp);
        swapRouter.swapExactTokensForTokens(1 ether, 0, true, h.key, "", address(this), block.timestamp);

        assertLt(s.hook.currentSqrtPriceX96(), ps);
        assertLt(m.hook.currentSqrtPriceX96(), pm);
        assertLt(h.hook.currentSqrtPriceX96(), ph);
    }

    function test_linearDecay_allRegimes_nearSpotDeeper() public {
        _assertDecay(_deploy(stable, 16));
        _assertDecay(_deploy(mid, 17));
        _assertDecay(_deploy(meme, 18));
    }

    function _assertBook(Live memory live) internal view {
        assertTrue(live.hook.isConfigured(live.id));
        assertGt(live.hook.getTotalShares(live.id), 0);
        assertGt(live.hook.liquidity(live.hook.currentBin()), 0);
        assertEq(live.hook.currentSqrtPriceX96(), Constants.SQRT_PRICE_1_1);
    }

    function _assertDecay(Live memory live) internal view {
        int24 cur = live.hook.currentBin();
        assertGt(live.hook.liquidity(cur), live.hook.liquidity(cur + 4));
        assertGt(live.hook.liquidity(cur + 4), live.hook.liquidity(cur + 8));
        assertEq(live.hook.liquidity(cur + 9), 0);
    }

    function _assertRoundTrip(Live memory live, uint256 clip) internal {
        uint160 p0 = live.hook.currentSqrtPriceX96();
        swapRouter.swapExactTokensForTokens(clip, 0, false, live.key, "", address(this), block.timestamp);
        uint160 p1 = live.hook.currentSqrtPriceX96();
        assertGt(p1, p0);
        swapRouter.swapExactTokensForTokens(clip, 0, true, live.key, "", address(this), block.timestamp);
        assertLt(live.hook.currentSqrtPriceX96(), p1);
    }
}
