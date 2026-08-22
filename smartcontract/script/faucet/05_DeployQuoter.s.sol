// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BinQuoter} from "./BinQuoter.sol";
import {BinBookBase} from "../binbook/BinBookBase.s.sol";

/// @notice Deploys the test-only BinQuoter against the official Sepolia PoolManager.
contract DeployQuoter is BinBookBase {
    function run() external {
        vm.startBroadcast();
        BinQuoter quoter = new BinQuoter(IPoolManager(POOL_MANAGER));
        vm.stopBroadcast();

        string memory obj = string.concat('{"quoter":"', vm.toString(address(quoter)), '"}');
        vm.writeJson(obj, string.concat("deployments/quoter-", vm.toString(block.chainid), ".json"));
        console2.log("quoter:", address(quoter));
    }
}
