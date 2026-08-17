// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {BinRatchet} from "../src/BinRatchet.sol";

/// @notice Mines the address and deploys the BinRatchet.sol Hook contract
contract DeployHookScript is BaseScript {
    function run() public {
        // All hook permissions are disabled for now; no flags need to be mined.
        // Flags will be added back as BinRatchet features are implemented.
        uint160 flags = uint160(0);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(BinRatchet).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        BinRatchet binRatchet = new BinRatchet{salt: salt}(poolManager);
        vm.stopBroadcast();

        require(address(binRatchet) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
