// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Test-only faucet over a fixed list of mock tokens. Anyone can mint.
contract TokenFaucet {
    address[] public tokens;
    uint256[] public amounts;

    constructor(address[] memory tokens_, uint256[] memory amounts_) {
        require(tokens_.length == amounts_.length, "length mismatch");
        tokens = tokens_;
        amounts = amounts_;
    }

    function count() external view returns (uint256) {
        return tokens.length;
    }

    function mint(uint256 index) external {
        MockERC20(tokens[index]).mint(msg.sender, amounts[index]);
    }

    function mintAll() external {
        uint256 n = tokens.length;
        for (uint256 i; i < n; ++i) {
            MockERC20(tokens[i]).mint(msg.sender, amounts[i]);
        }
    }
}
