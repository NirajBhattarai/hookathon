// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct QP {
    address c0;
    address c1;
    uint24 fee;
    int24 ts;
    address hooks;
    bool zfo;
    uint256 amt;
    address recv;
}

interface IBinQuoter {
    function quoteExactInput(QP calldata p) external;
}

contract QuoteProbe {
    event Inner(bytes reason);

    function probe(address quoter, QP calldata p) external {
        try IBinQuoter(quoter).quoteExactInput(p) {}
        catch (bytes memory reason) {
            emit Inner(reason);
        }
    }
}
