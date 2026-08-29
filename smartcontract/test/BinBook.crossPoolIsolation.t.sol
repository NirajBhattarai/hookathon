// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {Constants} from "./utils/Constants.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Regression coverage for Issue B: `PoolManager` ERC6909 claim balances are keyed only by
///         currency (`Currency.toId() == uint160(tokenAddress)`), with no PoolId component — so
///         `poolManager.balanceOf(hook, currency.toId())` used to return this hook's *entire*
///         holding of that token, summed across every pool it backs. Two pools sharing a currency
///         under the same hook deployment would have silently repriced each other's shares with no
///         attacker involved. `poolReserve0/1` are now keyed by `PoolId`, so this proves a deposit
///         into one pool leaves a sibling pool's own tracked reserve, and its share pricing,
///         untouched — even though the two pools really do share the same underlying token and the
///         same (contaminated) PoolManager claim balance under the hood.
contract BinBookCrossPoolIsolationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    address flags;
    BinBook hook;

    PoolKey keyA; // shared <-> other1
    PoolKey keyB; // shared <-> other2
    PoolId idA;
    PoolId idB;
    Currency shared;

    function setUp() public {
        deployArtifactsAndLabel();
        flags = address(uint160(HOOK_FLAGS));
        deployCodeTo("BinBook.sol:BinBook", abi.encode(poolManager), flags);
        hook = BinBook(flags);

        Currency other1 = deployCurrency();
        Currency other2 = deployCurrency();
        shared = deployCurrency();

        keyA = PoolKey(_sortLow(shared, other1), _sortHigh(shared, other1), 3000, 1, IHooks(address(hook)));
        keyB = PoolKey(_sortLow(shared, other2), _sortHigh(shared, other2), 3000, 1, IHooks(address(hook)));
        idA = keyA.toId();
        idB = keyB.toId();

        hook.createPool(keyA, Constants.SQRT_PRICE_1_1, 60);
        hook.createPool(keyB, Constants.SQRT_PRICE_1_1, 60);

        MockERC20(Currency.unwrap(keyA.currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(keyA.currency1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(keyB.currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(keyB.currency1)).approve(address(hook), type(uint256).max);
    }

    function _sortLow(Currency a, Currency b) internal pure returns (Currency) {
        return Currency.unwrap(a) < Currency.unwrap(b) ? a : b;
    }

    function _sortHigh(Currency a, Currency b) internal pure returns (Currency) {
        return Currency.unwrap(a) < Currency.unwrap(b) ? b : a;
    }

    function test_depositInPoolA_doesNotMovePoolB_sharedReserve() public {
        // Deposit into pool A only. This genuinely grows the hook's PoolManager claim balance for
        // `shared` (proving the two pools really do sit on the same global claim ledger).
        hook.addLiquidity(
            keyA,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 1000 ether,
                amount1Desired: 1000 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );

        assertGt(
            poolManager.balanceOf(address(hook), shared.toId()),
            0,
            "sanity: the hook's global claim balance for the shared currency should have grown"
        );

        // Pool B's own tracked reserves must be completely untouched by pool A's deposit.
        assertEq(hook.poolReserve0(idB), 0, "pool B's poolReserve0 moved from an unrelated pool A deposit");
        assertEq(hook.poolReserve1(idB), 0, "pool B's poolReserve1 moved from an unrelated pool A deposit");
        assertEq(hook.totalShares(idB), 0, "pool B minted shares from an unrelated pool A deposit");

        // A fresh bootstrap deposit into pool B must price purely off pool B's own (empty) state —
        // shares == depositValue exactly, with zero influence from pool A's now-nonzero holdings of
        // the same underlying token.
        hook.addLiquidity(
            keyB,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 50 ether,
                amount1Desired: 50 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );

        // Exact equality isn't expected here — depositLBase's per-bin proportional split can drift
        // by a few wei from the ideal amount0Desired+amount1Desired sum under floor rounding (same
        // cross-path drift documented on `_getAmountOut`) — that's unrelated to pool isolation.
        assertApproxEqAbs(
            hook.totalShares(idB), 100 ether, 1000, "pool B's bootstrap mint should equal its own deposit value"
        );
    }
}
