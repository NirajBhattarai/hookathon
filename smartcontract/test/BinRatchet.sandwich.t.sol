// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinRatchet} from "../src/BinRatchet.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @dev Sandwich ROI: LinearDecay bin book (ratchet OFF) vs flat x*y=k with the same capital and fee.
contract BinRatchetSandwichTest is BaseTest {
    using CurrencyLibrary for Currency;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    struct Live {
        BinRatchet hook;
        PoolKey key;
        Currency c0;
        Currency c1;
        uint24 fee;
        uint256 reserve0;
        uint256 reserve1;
    }

    function setUp() public {
        deployArtifactsAndLabel();
    }

    function _deploy(uint24 fee, int24 tickSpacing, int24 binSize, uint160 salt) internal returns (Live memory live) {
        address flags = address(uint160(HOOK_FLAGS) | (salt << 20));
        deployCodeTo("BinRatchet.sol:BinRatchet", abi.encode(poolManager), flags);
        live.hook = BinRatchet(flags);
        live.fee = fee;

        (live.c0, live.c1) = deployCurrencyPair();
        MockERC20 t0 = MockERC20(Currency.unwrap(live.c0));
        MockERC20 t1 = MockERC20(Currency.unwrap(live.c1));
        t0.approve(address(live.hook), type(uint256).max);
        t1.approve(address(live.hook), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        live.key = PoolKey(live.c0, live.c1, fee, tickSpacing, IHooks(address(live.hook)));
        poolManager.initialize(live.key, Constants.SQRT_PRICE_1_1);
        live.hook.setBinSize(live.key, binSize);

        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));
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
        live.reserve0 = b0 - t0.balanceOf(address(this));
        live.reserve1 = b1 - t1.balanceOf(address(this));
    }

    function _xykSwap(uint256 r0, uint256 r1, uint256 amountIn, bool zeroForOne, uint24 fee)
        internal
        pure
        returns (uint256 amountOut, uint256 nr0, uint256 nr1)
    {
        uint256 net = amountIn * (1_000_000 - fee) / 1_000_000;
        uint256 k = r0 * r1;
        if (zeroForOne) {
            nr0 = r0 + net;
            nr1 = k / nr0;
            amountOut = r1 - nr1;
        } else {
            nr1 = r1 + net;
            nr0 = k / nr1;
            amountOut = r0 - nr0;
        }
    }

    function _xykSandwichRoiWad(uint256 r0, uint256 r1, uint256 victimIn, uint24 fee)
        internal
        pure
        returns (int256 roiWad)
    {
        uint256 attackerIn = victimIn * 2;
        (uint256 frontOut, uint256 r0a, uint256 r1a) = _xykSwap(r0, r1, attackerIn, false, fee);
        (, uint256 r0b, uint256 r1b) = _xykSwap(r0a, r1a, victimIn, false, fee);
        (uint256 backOut,,) = _xykSwap(r0b, r1b, frontOut, true, fee);
        roiWad = (int256(backOut) - int256(attackerIn)) * 1e18 / int256(attackerIn);
    }

    function _hookSandwichRoiWad(Live memory live, uint256 victimIn) internal returns (int256 roiWad) {
        uint256 attackerIn = victimIn * 2;
        MockERC20 t0 = MockERC20(Currency.unwrap(live.c0));
        MockERC20 t1 = MockERC20(Currency.unwrap(live.c1));

        address victim = address(0xB0B);
        t0.mint(victim, 1_000 ether);
        t1.mint(victim, 1_000 ether);
        vm.startPrank(victim);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        uint256 t0Before = t0.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(attackerIn, 0, false, live.key, "", address(this), block.timestamp);
        uint256 frontOut = t0.balanceOf(address(this)) - t0Before;

        vm.prank(victim);
        swapRouter.swapExactTokensForTokens(victimIn, 0, false, live.key, "", victim, block.timestamp);

        uint256 t1Mid = t1.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens(frontOut, 0, true, live.key, "", address(this), block.timestamp);
        uint256 backOut = t1.balanceOf(address(this)) - t1Mid;

        roiWad = (int256(backOut) - int256(attackerIn)) * 1e18 / int256(attackerIn);
    }

    function _run(string memory name, uint24 fee, int24 spacing, int24 binSize, uint256 victimIn, uint160 salt)
        internal
        returns (int256 hookRoi, int256 xykRoi)
    {
        Live memory live = _deploy(fee, spacing, binSize, salt);
        xykRoi = _xykSandwichRoiWad(live.reserve0, live.reserve1, victimIn, fee);
        hookRoi = _hookSandwichRoiWad(live, victimIn);

        console2.log(name);
        console2.log("  TVL token0/token1", live.reserve0, live.reserve1);
        console2.log("  victimIn", victimIn);
        console2.log("  x*y=k ROI (wad, 1e18=100%)", xykRoi);
        console2.log("  bin+LinearDecay ROI (ratchet OFF)", hookRoi);
    }

    function test_sandwich_stable_binsBeatXykWithoutRatchet() public {
        (int256 hookRoi, int256 xykRoi) = _run("STABLE  1bps  0.20% bins  5% clip", 100, 1, 20, 10 ether, 1);
        assertLt(hookRoi, xykRoi, "bins should be less profitable to sandwich than x*y=k");
    }

    function test_sandwich_mid_binsBeatXykWithoutRatchet() public {
        (int256 hookRoi, int256 xykRoi) = _run("MID     5bps  1.00% bins  1% clip", 500, 10, 100, 2 ether, 2);
        assertLt(hookRoi, xykRoi, "bins should be less profitable to sandwich than x*y=k");
    }

    function test_sandwich_meme_binsBeatXykWithoutRatchet() public {
        (int256 hookRoi, int256 xykRoi) = _run("MEME   30bps  3.00% bins  3% clip", 3000, 60, 300, 6 ether, 3);
        assertLt(hookRoi, xykRoi, "bins should be less profitable to sandwich than x*y=k");
    }
}
