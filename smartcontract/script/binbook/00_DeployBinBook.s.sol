// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BinBook} from "../../src/BinBook.sol";
import {BinBookBase} from "./BinBookBase.s.sol";

/// @notice Deploys the BinBook hook (mined flags via canonical CREATE2 factory) and creates its
///         first pool against the official Sepolia PoolManager, then saves the deployment to
///         deployments/<chainid>.json for downstream scripts.
///         Env: TOKEN0/TOKEN1 (optional) — reuse existing tokens (e.g. a live faucet pair) instead
///         of minting a fresh throwaway Token A/Token B, so a hook redeploy keeps working with the
///         same tokens users already hold balances of.
///         Env: HOOK_SALT (optional) — pre-mined CREATE2 salt (bytes32 hex). When set, skips
///         HookMiner.find and deploys with this salt instead.
contract DeployBinBook is BinBookBase {
    function run() external {
        address[] memory wallets = vm.getWallets();
        address broadcaster = wallets.length > 0 ? wallets[0] : msg.sender;

        vm.startBroadcast();

        address existingToken0 = vm.envOr("TOKEN0", address(0));
        address existingToken1 = vm.envOr("TOKEN1", address(0));

        Currency c0;
        Currency c1;
        if (existingToken0 != address(0) && existingToken1 != address(0)) {
            (c0, c1) = existingToken0 < existingToken1
                ? (Currency.wrap(existingToken0), Currency.wrap(existingToken1))
                : (Currency.wrap(existingToken1), Currency.wrap(existingToken0));
        } else {
            MockERC20 tA = new MockERC20("Token A", "TKA", 18);
            MockERC20 tB = new MockERC20("Token B", "TKB", 18);
            (c0, c1) = address(tA) < address(tB)
                ? (Currency.wrap(address(tA)), Currency.wrap(address(tB)))
                : (Currency.wrap(address(tB)), Currency.wrap(address(tA)));
            tA.mint(broadcaster, 1_000_000e18);
            tB.mint(broadcaster, 1_000_000e18);
        }

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory hookInit = abi.encodePacked(type(BinBook).creationCode, abi.encode(POOL_MANAGER));
        bytes32 fixedSalt = vm.envOr("HOOK_SALT", bytes32(0));
        address hookAddr;
        bytes32 salt;
        if (fixedSalt != bytes32(0)) {
            salt = fixedSalt;
            hookAddr = HookMiner.computeAddress(CREATE2_FACTORY, uint256(salt), hookInit);
            require(uint160(hookAddr) & uint160(Hooks.ALL_HOOK_MASK) == flags, "HOOK_SALT: bad flags");
            require(hookAddr.code.length == 0, "HOOK_SALT: address has code");
        } else {
            (hookAddr, salt) =
                HookMiner.find(CREATE2_FACTORY, flags, type(BinBook).creationCode, abi.encode(POOL_MANAGER));
        }
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, hookInit));
        require(ok, "hook deploy failed");
        BinBook binBook = BinBook(hookAddr);

        bool skipPool = vm.envOr("SKIP_CREATE_POOL", false);
        if (!skipPool) {
            PoolKey memory key = PoolKey({
                currency0: c0,
                currency1: c1,
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hookAddr)
            });
            // Pools can only be born via createPool now (BinBook self-initializes and locks bin size
            // atomically) — a direct PoolManager.initialize() call reverts with InitializeViaCreatePool.
            binBook.createPool(key, 2 ** 96, TICK_SPACING);
        }

        vm.stopBroadcast();

        saveDeployment(
            Deployment({
                binBook: hookAddr,
                token0: Currency.unwrap(c0),
                token1: Currency.unwrap(c1),
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING
            })
        );

        console2.log("chainId      :", block.chainid);
        console2.log("broadcaster  :", broadcaster);
        console2.log("poolManager  :", address(POOL_MANAGER));
        console2.log("swapRouter   :", SWAP_ROUTER);
        console2.log("token0       :", Currency.unwrap(c0));
        console2.log("token1       :", Currency.unwrap(c1));
        console2.log("binBook      :", hookAddr);
        console2.logBytes32(salt);
        console2.log("^^ hook salt");
        if (!skipPool) {
            PoolKey memory key = PoolKey({
                currency0: c0,
                currency1: c1,
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hookAddr)
            });
            console2.logBytes32(keccak256(abi.encode(key)));
            console2.log("^^ poolId");
        }
    }
}
