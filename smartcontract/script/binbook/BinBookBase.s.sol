// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/// @notice Shared config for BinBook deployment scripts.
abstract contract BinBookBase is Script {
    struct Deployment {
        address binBook;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    // Official Uniswap v4 deployments (see lib/hookmate/src/constants/AddressConstants.sol)
    IPoolManager constant POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543); // Sepolia
    address constant SWAP_ROUTER = 0xf13D190e9117920c703d79B5F33732e10049b115; // hookmate V4SwapRouter, Sepolia
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    function deployPath() internal view returns (string memory) {
        string memory custom = vm.envOr("DEPLOY_FILE", string(""));
        if (bytes(custom).length > 0) return custom;
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function saveDeployment(Deployment memory d) internal {
        string memory obj = string.concat(
            '{"binBook":"',
            vm.toString(d.binBook),
            '","token0":"',
            vm.toString(d.token0),
            '","token1":"',
            vm.toString(d.token1),
            '","fee":',
            vm.toString(d.fee),
            ',"tickSpacing":',
            vm.toString(int256(d.tickSpacing)),
            '}'
        );
        vm.writeJson(obj, deployPath());
    }

    function loadDeployment() internal view returns (Deployment memory d) {
        string memory json = vm.readFile(deployPath());
        d.binBook = vm.parseJsonAddress(json, ".binBook");
        d.token0 = vm.parseJsonAddress(json, ".token0");
        d.token1 = vm.parseJsonAddress(json, ".token1");
        d.fee = uint24(vm.parseJsonUint(json, ".fee"));
        d.tickSpacing = int24(vm.parseJsonInt(json, ".tickSpacing"));
    }

    function poolKeyOf(Deployment memory d) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(d.token0),
            currency1: Currency.wrap(d.token1),
            fee: d.fee,
            tickSpacing: d.tickSpacing,
            hooks: IHooks(d.binBook)
        });
    }
}
