// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {BinBook} from "../src/BinBook.sol";
import {Constants} from "./utils/Constants.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @dev A standalone unlock-callback contract, unrelated to BinBook, used to prove that anyone can
///      mint the hook's PoolManager claim balance directly (Issue A from the "manually send and
///      break things" question) without ever calling BinBook.addLiquidity.
contract Donor is IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _pm) {
        poolManager = _pm;
    }

    /// @notice Settles `amount` of `currency` from this contract's own balance, then mints the
    ///         resulting ERC6909 claim directly to `to` — the exact "manual send" the question
    ///         asked about.
    function donate(Currency currency, address to, uint256 amount) external {
        poolManager.unlock(abi.encode(currency, to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.sync(currency);
        MockERC20(Currency.unwrap(currency)).transfer(address(poolManager), amount);
        poolManager.settle();
        poolManager.mint(to, currency.toId(), amount);
        return "";
    }
}

/// @notice Regression coverage for the fix to Issue A: `_getAmountIn`/`_getAmountOut` used to read
///         `poolManager.balanceOf(address(this), currency.toId())` — a claim balance anyone can
///         inflate via `PoolManager.mint(hook, id, amount)` without ever calling `addLiquidity`.
///         They now read `poolReserve0/1[id]`, tracked internally and moved only by this pool's
///         own mint/burn/swap/collectFees. This proves a raw donation to the hook's claim balance
///         no longer changes how many shares a deposit mints.
contract BinBookDonationTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    address flags;
    BinBook hook;
    PoolKey key;
    PoolId id;
    MockERC20 token0;
    MockERC20 token1;
    Donor donor;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        deployArtifactsAndLabel();
        flags = address(uint160(HOOK_FLAGS));
        deployCodeTo("BinBook.sol:BinBook", abi.encode(poolManager), flags);
        hook = BinBook(flags);

        (Currency c0, Currency c1) = deployCurrencyPair();
        key = PoolKey(c0, c1, 3000, 1, IHooks(address(hook)));
        id = key.toId();
        hook.createPool(key, Constants.SQRT_PRICE_1_1, 60);

        token0 = MockERC20(Currency.unwrap(c0));
        token1 = MockERC20(Currency.unwrap(c1));

        donor = new Donor(poolManager);
        token0.mint(address(donor), 10_000_000 ether);
        token1.mint(address(donor), 10_000_000 ether);

        token0.mint(alice, 10_000 ether);
        token1.mint(alice, 10_000 ether);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        token0.mint(bob, 10_000 ether);
        token1.mint(bob, 10_000 ether);
        vm.startPrank(bob);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Alice seeds the pool. Bob then deposits identical params along two branches from the
    ///      same snapshot: with, and without, a huge outside donation of ERC6909 claims straight to
    ///      the hook's PoolManager balance in between. If poolReserve0/1 are truly isolated from
    ///      that donation, Bob mints the exact same shares either way.
    function test_donationToClaimBalance_doesNotChangeMintedShares() public {
        vm.prank(alice);
        hook.addLiquidity(
            key,
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

        uint256 snapshot = vm.snapshotState();

        // Branch A: Bob deposits with no donation in between.
        vm.prank(bob);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );
        uint256 sharesWithoutDonation = hook.getShares(id, bob);

        vm.revertToState(snapshot);

        // Branch B: a totally unrelated contract donates 500,000 token0 directly into the hook's
        // PoolManager claim balance for currency0 — no call to BinBook at all.
        donor.donate(key.currency0, address(hook), 500_000 ether);

        vm.prank(bob);
        hook.addLiquidity(
            key,
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp,
                tickLower: -600,
                tickUpper: 600,
                userInputSalt: bytes32(0)
            })
        );
        uint256 sharesWithDonation = hook.getShares(id, bob);

        assertEq(
            sharesWithDonation,
            sharesWithoutDonation,
            "a raw donation to the hook's claim balance changed how many shares an unrelated deposit minted"
        );

        // The donated tokens really did leave the donor and really did land in the PoolManager
        // claim ledger under the hook's address — this isn't a no-op donate, it's a real one that
        // BinBook's own accounting simply never looks at.
        assertEq(
            poolManager.balanceOf(address(hook), key.currency0.toId()) - hook.poolReserve0(id),
            500_000 ether,
            "donation should still be sitting in the raw claim balance, invisible to poolReserve0"
        );
    }
}
