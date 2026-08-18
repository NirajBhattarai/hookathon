---
name: solidity-conventions
description: Use when writing or editing Solidity contracts in this project. Covers contract layout order, section headers using headers-rs, struct packing, named mappings, NatSpec, error/event conventions, and Uniswap v4 hook patterns.
---

# Solidity Conventions

Follow these conventions for ALL Solidity files in this project.

## Section Headers

Use `headers-rs` to generate section headers (solmate/solady style):

```bash
headers-rs "SECTION NAME"
```

Output format:
```
/*//////////////////////////////////////////////////////////////
                        SECTION NAME
//////////////////////////////////////////////////////////////*/
```

Install if missing: `cargo install headers-rs`

## Contract Layout Order

Every contract MUST follow this element order:

```
1. TYPE DECLARATIONS   ->  structs, enums
2. STATE VARIABLES     ->  mappings with named params
3. EVENTS              ->  with NatSpec
4. ERRORS              ->  custom errors
5. CONSTRUCTOR
6. HOOK PERMISSIONS    ->  (Uniswap v4 specific)
7. HOOK CALLBACKS      ->  _beforeSwap, _afterSwap, etc.
8. CONFIGURATION       ->  admin/config functions
9. VIEW HELPERS        ->  read-only getters
10. INTERNAL HELPERS   ->  _ prefixed internal functions
```

## Mappings

Use named parameters (Solidity >=0.8.18):

```solidity
// CORRECT
mapping(PoolId poolId => BinState) public binStates;
mapping(PoolId poolId => address creator) public poolCreator;

// WRONG
mapping(PoolId => BinState) public binStates;
```

## Struct Packing

Pack structs to fit in minimal storage slots. Add packing comments:

```solidity
struct BinState {
    int24 currentBin; // --------- 3 bytes
    BinConfig config; // --------- 3 bytes  (packed into 1 slot)
}
```

## Errors

Use custom errors, not require strings:

```solidity
// CORRECT
error NotPoolCreator();
error BinSizeAlreadySet();

// WRONG
require(msg.sender == poolCreator[id], "Not pool creator");
```

## NatSpec

Every public/external function and state variable MUST have NatSpec:

```solidity
/// @notice Set bin size for a pool (called once by pool creator after creation)
/// @param key The pool key
/// @param _binSize Number of ticks per bin (must be > 0)
function setBinSize(PoolKey calldata key, int24 _binSize) external {
```

## Events

Emit events for state changes. Use indexed where appropriate:

```solidity
event BinSizeSet(PoolId indexed poolId, address indexed creator, int24 binSize);
```

## Uniswap v4 Hook Patterns

### Import Order
```solidity
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
```

### Using Clause
```solidity
contract MyHook is BaseHook {
    using PoolIdLibrary for PoolKey;
```

### Internal Hook Overrides
Hook callbacks are `internal override`, NOT `external`:

```solidity
// CORRECT
function _afterInitialize(address sender, PoolKey calldata key, uint160, int24)
    internal
    override
    returns (bytes4)
{
    return IHooks.afterInitialize.selector;
}

// WRONG - do not use external or onlyPoolManager (BaseHook handles it)
function _afterInitialize(...) external override returns (bytes4) { }
```

### Pool Creator Detection
Use `afterInitialize` to capture pool creator (no hookData - removed due to frontrunning):

```solidity
function _afterInitialize(address sender, PoolKey calldata key, uint160, int24)
    internal
    override
    returns (bytes4)
{
    PoolId id = key.toId();
    poolCreator[id] = sender;  // sender = pool creator
    return IHooks.afterInitialize.selector;
}
```

### Per-Pool Configuration
Single hook contract serves multiple pools via mappings:

```solidity
mapping(PoolId poolId => BinState) public binStates;
mapping(PoolId poolId => address creator) public poolCreator;
mapping(PoolId poolId => bool) public binSizeSet;
```

## File Header

Start every .sol file with:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
```

## General Rules

- 4 spaces indentation (no tabs)
- Max 120 characters per line
- Single blank line between functions
- No comments unless asked (NatSpec is required, inline comments are not)
- Use `calldata` for external function parameters, `memory` for internal
- Prefer `revert` with custom errors over `require`
