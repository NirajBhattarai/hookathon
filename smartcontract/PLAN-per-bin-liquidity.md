# Per-Bin Liquidity Distribution — Research Plan

## Overview

BinRatchet hook follows the **hook-owned liquidity** pattern (`BaseCustomAccounting` style).
The hook is the owner of all positions in the pool. Users deposit tokens → hook distributes
across bins → hook manages positions.

```
User → hook.addLiquidity(tickLower, tickUpper, amount0, amount1, deadline)
  ↓
Hook stores tokens, calls poolManager.unlock()
  ↓
unlockCallback → loops over bins:
  for (tick = tickLower; tick < tickUpper; tick += binSize) {
      1. getTickLiquidity() → existing liquidity at tick
      2. proportional share = totalLiquidity / numBins
      3. getLiquidityForAmounts() → convert tokens to liquidity
      4. cap at available capacity
      5. poolManager.modifyLiquidity(tick, tick+binSize, liqDelta)
      6. settle tokens
  }
  ↓
Return unused tokens to user
```

## Files to Modify

### 1. `src/BinRatchet.sol` — Major Changes

**New imports:**

```solidity
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
```

**New structs:**

```solidity
struct AddLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

struct CallbackData {
    address sender;
    AddLiquidityParams params;
}
```

**New errors:**

```solidity
error TicksNotAlignedToBins();
error SlippageTooHigh();
error DeadlineExpired();
error LiquidityOnlyViaHook();
```

**New external function — `addLiquidity`:**

- User-facing entry point
- Validates: deadline, tick alignment (both % binSize == 0), pool configured
- Stores tokens from user
- Calls `poolManager.unlock()` → triggers `unlockCallback`

**`unlockCallback` implementation:**

```
for tick = params.tickLower; tick < params.tickUpper; tick += binSize:
  1. sqrtPriceLower = TickMath.getSqrtPriceAtTick(tick)
     sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tick + binSize)

  2. liqAtTick = StateLibrary.getTickLiquidity(poolManager, poolId, tick)

  3. proportion = 1 / numBins
     binAmount0 = params.amount0Desired * proportion
     binAmount1 = params.amount1Desired * proportion

  4. binLiq = LiquidityAmounts.getLiquidityForAmounts(
         currentSqrtPrice, sqrtPriceLower, sqrtPriceUpper,
         binAmount0, binAmount1
     )

  5. Cap: if binLiq + existingLiq > maxLiqPerTick, reduce binLiq

  6. poolManager.modifyLiquidity(key, {
         tickLower: tick,
         tickUpper: tick + binSize,
         liquidityDelta: binLiq,
         salt: keccak256(abi.encode(sender, tick))
     }, "")

  7. Settle tokens for this bin's share
```

**Updated `getHookPermissions`:**

```solidity
beforeInitialize: false,
afterInitialize: true,
beforeAddLiquidity: true,    // enforce alignment
beforeRemoveLiquidity: false,
afterAddLiquidity: false,
...
```

**`_beforeAddLiquidity` — validation only:**

```solidity
function _beforeAddLiquidity(..., ModifyLiquidityParams calldata params, ...) {
    int24 binSize = binStates[key.toId()].config.binSize;
    if (params.tickLower % binSize != 0 || params.tickUpper % binSize != 0)
        revert TicksNotAlignedToBins();
    return IHooks.beforeAddLiquidity.selector;
}
```

### 2. `test/fuzz/BinRatchetFuzz.t.sol` — New Fuzz Tests

```solidity
// Fuzz test for tick alignment
function test_fuzz_addLiquidity_alignment(int24 tickLower, int24 tickUpper, int24 binSize) public {
    // align ticks, verify addLiquidity succeeds
    // misaligned ticks → revert
}

// Fuzz test for cap-and-redistribute
function test_fuzz_perBin_capRedistribute(uint256 amount0, uint256 amount1) public {
    // Add liquidity, verify all tokens distributed or returned
}
```

### 3. `test/BinRatchet.t.sol` — Unit Tests

- `test_addLiquidity_succeeds` — basic flow
- `test_addLiquidity_reverts_misalignedTicks` — alignment check
- `test_addLiquidity_reverts_poolNotConfigured` — no binSize set
- `test_addLiquidity_reverts_slippage` — amount below min
- `test_addLiquidity_reverts_deadline` — expired
- `test_addLiquidity_perBin_distribution` — verify each bin gets position
- `test_addLiquidity_returnsUnusedTokens` — cap + redistribute works

## Key Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| Hook owns liquidity | Yes | Per-bin control requires hook to be position owner |
| `beforeAddLiquidity` | Validation only | Real logic in `unlockCallback` loop |
| Token distribution | Proportional split | User provides totals, hook divides by numBins |
| Capping | Per-bin | If bin can't take full share, cap and redistribute excess |
| Position identity | `keccak256(sender, tick)` salt | Each user x bin is a unique position |

## Math Summary

For each bin `[tick, tick + binSize)`:

```
numBins = (tickUpper - tickLower) / binSize
proportion = 1 / numBins
binAmount0 = totalAmount0 * proportion
binAmount1 = totalAmount1 * proportion

sqrtPriceLower = TickMath.getSqrtPriceAtTick(tick)
sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tick + binSize)

liq = LiquidityAmounts.getLiquidityForAmounts(
    currentSqrtPrice, sqrtPriceLower, sqrtPriceUpper,
    binAmount0, binAmount1
)
```

## Uniswap v4 Flow Reference

```
User calls:  positionManager.mint(poolKey, tickLower, tickUpper, liquidity, ...)
                          ↓
        PoolManager.modifyLiquidity(key, params, hookData)
                          ↓
        1. key.hooks.beforeModifyLiquidity(key, params, hookData)
           ↳ if liquidityDelta > 0 → calls beforeAddLiquidity
           ↳ if liquidityDelta ≤ 0 → calls beforeRemoveLiquidity
        2. pool.modifyLiquidity(params)   ← actual state change
        3. key.hooks.afterModifyLiquidity(...)
```

## Reference Files

- `BaseCustomAccounting.sol` — hook-owned liquidity pattern
- `BaseCustomCurve.sol` — custom token distribution
- `LiquidityAmounts.sol` — token ↔ liquidity math
- `StateLibrary.sol` — reading pool state (getSlot0, getTickLiquidity, getPositionInfo)
- `Pool.sol:146` — pool's modifyLiquidity implementation
- `Hooks.sol:195` — beforeModifyLiquidity dispatch (calls beforeAddLiquidity when liquidityDelta > 0)
