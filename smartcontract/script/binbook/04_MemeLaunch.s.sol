// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BinBook} from "../../src/BinBook.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {BinBookBase} from "./BinBookBase.s.sol";

/// @notice pump.fun-style launch on the BinBook hook:
///         deploy $BINU (1B supply), pair vs WETH, creator seeds 0.5 WETH,
///         then snipers / retail / a whale dump trade against the book.
///         Env: SEED_WETH (default 0.5e18), BUY_WETH_TOTAL (default 0.6e18)
contract MemeLaunch is BinBookBase {
    using PoolIdLibrary for PoolKey;

    WETH internal weth;
    MockERC20 internal binu;
    PoolKey internal key;
    BinBook internal book;
    address internal trader;

    function run() external {
        address broadcaster = vm.getWallets()[0];
        trader = broadcaster;
        uint256 seedWeth = vm.envOr("SEED_WETH", uint256(0.5e18));
        uint256 buyTotal = vm.envOr("BUY_WETH_TOTAL", uint256(0.6e18));

        vm.startBroadcast();

        // --- Token launch ---
        weth = new WETH();
        weth.deposit{value: seedWeth + buyTotal}();
        binu = new MockERC20("BinBook Inu", "BINU", 18);
        binu.mint(broadcaster, 1_000_000_000e18); // fixed supply, all to creator

        // --- Pool @ ~2e-9 WETH per BINU (same hook as the main deployment) ---
        book = BinBook(loadDeployment().binBook);
        key = PoolKey({
            currency0: Currency.wrap(address(weth)) < Currency.wrap(address(binu))
                ? Currency.wrap(address(weth))
                : Currency.wrap(address(binu)),
            currency1: Currency.wrap(address(weth)) < Currency.wrap(address(binu))
                ? Currency.wrap(address(binu))
                : Currency.wrap(address(weth)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(book))
        });
        int24 startTick = -200320; // ≈ 2e-9
        book.createPool(key, TickMath.getSqrtPriceAtTick(startTick), TICK_SPACING);

        // --- Approvals ---
        IERC20(address(weth)).approve(address(book), type(uint256).max);
        IERC20(address(binu)).approve(address(book), type(uint256).max);
        IERC20(address(weth)).approve(SWAP_ROUTER, type(uint256).max);
        IERC20(address(binu)).approve(SWAP_ROUTER, type(uint256).max);
        IERC20(address(weth)).approve(address(PERMIT2), type(uint256).max);
        IERC20(address(binu)).approve(address(PERMIT2), type(uint256).max);

        // --- Creator seeds the book: seedWeth + half the supply ---
        book.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: _isWeth0() ? seedWeth : 0,
                amount1Desired: _isWeth0() ? 0 : seedWeth,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        book.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: _isWeth0() ? 0 : 500_000_000e18,
                amount1Desired: _isWeth0() ? 500_000_000e18 : 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );
        _log("creator seed", seedWeth);

        // --- Launch sequence ---
        _buy(0.08e18, "sniper1");
        _buy(0.12e18, "sniper2");
        _buy(0.03e18, "retail1");
        _buy(0.02e18, "retail2");
        _buy(0.05e18, "retail3");
        _buy(0.04e18, "retail4");
        _buy(0.06e18, "retail5");
        _sell(40_000_000e18, "whale_dump");
        _buy(0.05e18, "dip_buyer");
        _buy(0.07e18, "moon_chaser");
        _sell(15_000_000e18, "profit_taker");

        vm.stopBroadcast();

        // --- Save deployment (separate file so the main pool config is untouched) ---
        string memory obj = string.concat(
            '{"binBook":"',
            vm.toString(address(book)),
            '","token0":"',
            vm.toString(_isWeth0() ? address(weth) : address(binu)),
            '","token1":"',
            vm.toString(_isWeth0() ? address(binu) : address(weth)),
            '","fee":',
            vm.toString(POOL_FEE),
            ',"tickSpacing":',
            vm.toString(int256(TICK_SPACING)),
            "}"
        );
        vm.writeJson(obj, string.concat("deployments/", vm.toString(block.chainid), "-meme.json"));
        PoolId id = key.toId();
        console2.log("=== LAUNCH SUMMARY ===");
        console2.log("weth          :", address(weth));
        console2.log("binu          :", address(binu));
        console2.log("binBook       :", address(book));
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("^^ poolId");
        console2.log("final sqrtP   :", book.currentSqrtPriceX96(id));
        console2.log("currentBin    :", book.currentBin(id));
        (uint256 f0, uint256 f1) = book.pendingFees(id, broadcaster);
        console2.log("pendingFee weth:", _isWeth0() ? f0 : f1);
        console2.log("pendingFee binu:", _isWeth0() ? f1 : f0);
    }

    function _isWeth0() internal view returns (bool) {
        return address(weth) < address(binu);
    }

    function _buy(uint256 wethIn, string memory tag) internal {
        IUniswapV4Router04(payable(SWAP_ROUTER))
            .swapExactTokensForTokens({
                amountIn: wethIn,
                amountOutMin: 0,
                zeroForOne: _isWeth0(),
                poolKey: key,
                hookData: "",
                receiver: trader,
                deadline: block.timestamp + 600
            });
        _log(tag, wethIn);
    }

    function _sell(uint256 binuIn, string memory tag) internal {
        IUniswapV4Router04(payable(SWAP_ROUTER))
            .swapExactTokensForTokens({
                amountIn: binuIn,
                amountOutMin: 0,
                zeroForOne: !_isWeth0(),
                poolKey: key,
                hookData: "",
                receiver: trader,
                deadline: block.timestamp + 600
            });
        _log(tag, binuIn);
    }

    function _log(string memory tag, uint256 amt) internal view {
        PoolId id = key.toId();
        uint160 sp = book.currentSqrtPriceX96(id);
        // price of 1 BINU in WETH (1e18 precision): (sp/2^96)^2 adjusted by direction
        uint256 px96 = FullMath.mulDiv(sp, sp, 2 ** 96); // token1 per token0, 2^96 scale
        bool wethIs0 = _isWeth0();
        uint256 priceE18 = wethIs0
            ? FullMath.mulDiv(2 ** 96, 1e18, px96)  // BINU is token1 -> weth per binu = 1/px
            : FullMath.mulDiv(px96, 1e18, 2 ** 96);
        console2.log(tag, amt);
        console2.log("  ethPerBinu(1e18):", priceE18);
        console2.log("  bin:", book.currentBin(id));
    }
}
