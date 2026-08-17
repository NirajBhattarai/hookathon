# Bin Shield Research

## Files
- `bin_sim.py` — Bin-based fee simulation (100K scenarios)
- `combined_sim.py` — Detection + Worst Price + Fee (100K scenarios)

## Problem
Sandwich MEV attacks on Uniswap v4: attacker buys before victim, pushes price up, victim buys at worse price, attacker sells for profit.

## Key Findings

### 1. Bin-Based Fee (bin_sim.py)
- **10% max fee**: Protects attacks ≤10% of liquidity (100%)
- **20% max fee**: Protects attacks ≤20% of liquidity
- Break-even fees: 0.79% (2% attack), 1.96% (5%), 3.84% (10%), 7.39% (20%)

### 2. Worst Price Override (combined_sim.py)
- Force attacker to buy at VICTIM's price (highest)
- Force attacker to sell at START price (lowest)
- **100% protection** when combined with fee

### 3. Detection Timing
```
Tx#1: Attacker BUY  → suspicious (not yet detected)
Tx#2: Victim BUY    → MEV DETECTED (pattern: BUY→BUY)
Tx#3: Attacker SELL → FORCE worst price
```

### 4. Combined Results (100K scenarios)
| Method | Protected | Rate |
|---|---|---|
| Fee only (20% max) | 100,000 | 100.0% |
| Worst price only | 69,892 | 69.9% |
| **Worst + Fee** | **100,000** | **100.0%** |

### 5. Protection by Attack Size
```
Atk%    Fee   Worst   Combined
1%      YES   NO      YES
5%      YES   NO      YES
10%     YES   YES     YES
20%     YES   YES     YES
30%     YES   YES     YES
50%     YES   YES     YES
```

### 6. Gas Cost
```
Detection:   ~18,000 gas/swap (+12%)
Protection:  ~12,000 gas (when triggered)
Combined:    ~30,000 gas/swap (+20%)
```

## Detection Logic
```
Signal 1: Swap size > 5% of liquidity
Signal 2: Volume/liquidity > 10%
Signal 3: Bins crossed > 5
Signal 4: Direction changed

Score >= 2 → MEV detected → force worst price
```

## Comparison with Existing Work

| Project | Mechanism | Our Innovation |
|---|---|---|
| Brokkr Finance | Volume-based fee | Bin-based measurement |
| OpenZeppelin | Block-level checkpoint | Dynamic fee formula |
| CodesenSys | EWMA price returns | bins_crossed/net_bins ratio |

## Implementation Plan
1. Track block state (swap_count, volume, direction, price)
2. Detect MEV using score-based signals
3. Apply worst price override when detected
4. Apply dynamic fee as backup protection

## Next Steps
1. Implement in Solidity
2. Write fork tests
3. Deploy to testnet
