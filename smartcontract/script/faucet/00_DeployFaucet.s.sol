// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {TokenFaucet} from "./TokenFaucet.sol";
import {BinBookBase} from "../binbook/BinBookBase.s.sol";

/// @notice Deploys 20 mock "top tokens" with realistic decimals and a public faucet.
contract DeployFaucet is BinBookBase {
    struct Spec {
        string name;
        string symbol;
        uint8 decimals;
        uint256 faucetAmount;
    }

    function run() external {
        Spec[20] memory specs = [
            Spec("Tether USD", "USDT", 6, 100_000e6),
            Spec("USD Coin", "USDC", 6, 100_000e6),
            Spec("Dai Stablecoin", "DAI", 18, 100_000e18),
            Spec("Wrapped BTC", "WBTC", 8, 10e8),
            Spec("Wrapped Ether", "WETH", 18, 50e18),
            Spec("BNB", "BNB", 18, 200e18),
            Spec("XRP", "XRP", 6, 200_000e6),
            Spec("Solana", "SOL", 9, 5_000e9),
            Spec("Cardano", "ADA", 6, 500_000e6),
            Spec("Dogecoin", "DOGE", 8, 5_000_000e8),
            Spec("Toncoin", "TON", 9, 10_000e9),
            Spec("TRON", "TRX", 6, 1_000_000e6),
            Spec("Avalanche", "AVAX", 18, 2_000e18),
            Spec("Chainlink", "LINK", 18, 10_000e18),
            Spec("Polkadot", "DOT", 10, 20_000e10),
            Spec("Polygon", "MATIC", 18, 100_000e18),
            Spec("Shiba Inu", "SHIB", 18, 5_000_000_000e18),
            Spec("Pepe", "PEPE", 18, 10_000_000_000e18),
            Spec("Uniswap", "UNI", 18, 5_000e18),
            Spec("Cosmos", "ATOM", 6, 10_000e6)
        ];

        vm.startBroadcast();

        uint256 n = specs.length;
        address[] memory toks = new address[](n);
        uint256[] memory amts = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            MockERC20 t = new MockERC20(specs[i].name, specs[i].symbol, specs[i].decimals);
            toks[i] = address(t);
            amts[i] = specs[i].faucetAmount;
            console2.log(specs[i].symbol, toks[i]);
        }

        TokenFaucet faucet = new TokenFaucet(toks, amts);

        vm.stopBroadcast();

        // record for the frontend (gitignored)
        string memory obj = string.concat('{"faucet":"', vm.toString(address(faucet)), '"}');
        vm.writeJson(obj, string.concat("deployments/faucet-", vm.toString(block.chainid), ".json"));

        console2.log("faucet:", address(faucet));
    }
}
