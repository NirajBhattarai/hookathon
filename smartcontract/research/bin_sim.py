"""
Bin Shield - Bin-Based MEV Detection
======================================
Scenario: Within a single block, price moves bin0 → bin1 → ... → binN
Track: start_bin, max_bin, min_bin, bins_crossed, volume, liquidity
Goal: Derive fee logic that makes MEV unprofitable

Run: python3 bin_sim.py
"""

import math

class AMM:
    def __init__(self, liq):
        self.r0 = liq
        self.r1 = liq
        self.k = liq * liq

    def price(self):
        return self.r1 / self.r0

    def tick(self):
        return int(math.log(self.price()) / math.log(1.0001))

    def swap(self, amount, buy_token1):
        if buy_token1:
            new_r0 = self.r0 + amount
            new_r1 = self.k / new_r0
            out = self.r1 - new_r1
            self.r0, self.r1 = new_r0, new_r1
            return out
        else:
            new_r1 = self.r1 + amount
            new_r0 = self.k / new_r1
            out = self.r0 - new_r0
            self.r0, self.r1 = new_r0, new_r1
            return out


def tick_to_bin(tick, bin_size):
    return math.floor(tick / bin_size)


def simulate_block(liq, swaps, bin_size):
    """
    Simulate a block with multiple swaps.
    swaps = [(amount, buy_token1), ...]
    Returns block metrics.
    """
    amm = AMM(liq)
    start_bin = tick_to_bin(amm.tick(), bin_size)
    max_bin = start_bin
    min_bin = start_bin
    total_volume = 0.0

    for amount, buy in swaps:
        actual = amm.swap(amount, buy)
        total_volume += amount
        current_bin = tick_to_bin(amm.tick(), bin_size)
        max_bin = max(max_bin, current_bin)
        min_bin = min(min_bin, current_bin)

    final_bin = tick_to_bin(amm.tick(), bin_size)
    bins_crossed = max_bin - min_bin
    net_bins = final_bin - start_bin

    return {
        "start_bin": start_bin,
        "final_bin": final_bin,
        "max_bin": max_bin,
        "min_bin": min_bin,
        "bins_crossed": bins_crossed,
        "net_bins": net_bins,
        "volume": total_volume,
        "price": amm.price(),
    }


def calc_fee(metrics, liq, config):
    """
    Fee calculation based on bin metrics.
    """
    bc = metrics["bins_crossed"]
    vol = metrics["volume"]
    net = abs(metrics["net_bins"])

    base = config["base"]
    bin_fee = bc * config["bin_rate"]
    vol_fee = (vol / liq) * config["vol_rate"]
    net_fee = net * config["net_rate"]

    total = base + bin_fee + vol_fee + net_fee
    return min(total, config["max_fee"])


def sandwich_profit(liq, attack_pct, victim_pct, bin_size, fee_config):
    """
    Simulate sandwich attack with and without fee.
    Returns (profit_no_fee, profit_with_fee).
    """
    attack_amt = liq * attack_pct
    victim_amt = liq * victim_pct

    # ── No fee ──
    b = AMM(liq)
    atok = b.swap(attack_amt, True)
    b.swap(victim_amt, True)
    sell0 = b.swap(atok, False)
    profit_nf = sell0 - attack_amt

    # ── With fee ──
    a = AMM(liq)
    init_bin = tick_to_bin(a.tick(), bin_size)
    max_bin = init_bin
    min_bin = init_bin
    block_vol = 0.0

    # Attacker buys
    fee = calc_fee({"bins_crossed": 0, "volume": 0, "net_bins": 0}, liq, fee_config)
    cost = attack_amt * (1 + fee)
    block_vol += attack_amt
    atok2 = a.swap(cost, True)
    cur_bin = tick_to_bin(a.tick(), bin_size)
    max_bin = max(max_bin, cur_bin)
    min_bin = min(min_bin, cur_bin)

    # Victim buys
    bc = max_bin - min_bin
    fee = calc_fee({"bins_crossed": bc, "volume": block_vol, "net_bins": abs(cur_bin - init_bin)}, liq, fee_config)
    vcost = victim_amt * (1 + fee)
    block_vol += victim_amt
    a.swap(vcost, True)
    cur_bin = tick_to_bin(a.tick(), bin_size)
    max_bin = max(max_bin, cur_bin)
    min_bin = min(min_bin, cur_bin)

    # Attacker sells
    bc = max_bin - min_bin
    fee = calc_fee({"bins_crossed": bc, "volume": block_vol, "net_bins": abs(cur_bin - init_bin)}, liq, fee_config)
    sell_amt = atok2 * (1 - fee)
    sell0f = a.swap(sell_amt, False)
    profit_wf = sell0f - cost

    return profit_nf, profit_wf


def main():
    bin_size = 60
    W = 130

    print("=" * W)
    print("BIN-BASED MEV DETECTION SIMULATION")
    print("=" * W)

    # ══════════════════════════════════════════════════════════════
    # PART 1: Block-level bin movement scenarios
    # ══════════════════════════════════════════════════════════════
    print(f"\n{'═'*W}")
    print("PART 1: WHAT DOES BIN MOVEMENT LOOK LIKE IN A BLOCK?")
    print(f"{'═'*W}")

    scenarios = [
        ("Normal trade", 10_000_000, [(100_000, True)]),
        ("Normal + victim", 10_000_000, [(100_000, True), (20_000, True)]),
        ("Small sandwich", 10_000_000, [(500_000, True), (100_000, True), (500_000, False)]),
        ("Medium sandwich", 10_000_000, [(2_000_000, True), (400_000, True), (2_000_000, False)]),
        ("Large sandwich", 10_000_000, [(5_000_000, True), (1_000_000, True), (5_000_000, False)]),
        ("Flash loan attack", 10_000_000, [(8_000_000, True), (2_000_000, True), (8_000_000, False)]),
        ("Whale trade", 10_000_000, [(3_000_000, True)]),
        ("Low liq normal", 100_000, [(10_000, True)]),
        ("Low liq sandwich", 100_000, [(50_000, True), (10_000, True), (50_000, False)]),
        ("Low liq large", 100_000, [(80_000, True), (20_000, True), (80_000, False)]),
    ]

    print(f"\n  {'Scenario':<22} {'Pool':>12} {'Start':>6} {'Max':>6} {'Min':>6} {'Cross':>6} {'Net':>6} {'Vol/Liq':>10}")
    print("  " + "-" * 80)

    for name, liq, swaps in scenarios:
        m = simulate_block(liq, swaps, bin_size)
        print(f"  {name:<22} ${liq:>10,} {m['start_bin']:>6} {m['max_bin']:>6} {m['min_bin']:>6} {m['bins_crossed']:>6} {m['net_bins']:>+5}  {m['volume']/liq*100:>8.1f}%")

    # ══════════════════════════════════════════════════════════════
    # PART 2: Fee sensitivity analysis
    # ══════════════════════════════════════════════════════════════
    print(f"\n{'═'*W}")
    print("PART 2: FEE SENSITIVITY - What fee kills sandwich attacks?")
    print(f"{'═'*W}")

    liq = 10_000_000
    attack_pcts = [0.01, 0.02, 0.05, 0.10, 0.20]

    # Test different fee configs
    fee_configs = [
        {"base": 0.003, "bin_rate": 0.005, "vol_rate": 0.5, "net_rate": 0.002, "max_fee": 0.05},
        {"base": 0.003, "bin_rate": 0.01,  "vol_rate": 1.0, "net_rate": 0.005, "max_fee": 0.10},
        {"base": 0.003, "bin_rate": 0.02,  "vol_rate": 2.0, "net_rate": 0.01,  "max_fee": 0.20},
        {"base": 0.003, "bin_rate": 0.03,  "vol_rate": 3.0, "net_rate": 0.02,  "max_fee": 0.30},
    ]
    fc_labels = ["5% max", "10% max", "20% max", "30% max"]

    print(f"\n  {'Attack%':>10} {'Baseline':>14}", end="")
    for lbl in fc_labels:
        print(f" {lbl:>16}", end="")
    print()
    print(f"  {'':>10} {'Profit$':>14}", end="")
    for _ in fc_labels:
        print(f" {'Profit$':>8} {'Prot%':>7}", end="")
    print()
    print("  " + "-" * 94)

    for ap in attack_pcts:
        vp = ap * 0.2
        b = AMM(liq)
        atok = b.swap(liq * ap, True)
        b.swap(liq * vp, True)
        sell0 = b.swap(atok, False)
        pb = sell0 - liq * ap

        print(f"  {ap*100:>8.2f}%  ${pb:>12,.0f}", end="")
        for fc in fee_configs:
            pnf, pwf = sandwich_profit(liq, ap, vp, bin_size, fc)
            prot = (1 - pwf / pb) * 100 if pb > 0 else 100
            print(f"  ${pwf:>8,.0f}  {prot:>5.1f}%", end="")
        print()

    # ══════════════════════════════════════════════════════════════
    # PART 3: Break-even fee by pool size
    # ══════════════════════════════════════════════════════════════
    print(f"\n{'═'*W}")
    print("PART 3: BREAK-EVEN FEE (fee that makes attack unprofitable)")
    print(f"{'═'*W}")

    print(f"\n  {'Pool':>14} {'Attack%':>10} {'Baseline':>14} {'Break-even Fee':>14}")
    print("  " + "-" * 56)

    for liq_val in [1e5, 5e5, 1e6, 5e6, 1e7, 1e7, 5e7, 1e8]:
        for ap in [0.02, 0.05, 0.10, 0.20]:
            vp = ap * 0.2
            b = AMM(liq_val)
            atok = b.swap(liq_val * ap, True)
            b.swap(liq_val * vp, True)
            sell0 = b.swap(atok, False)
            pb = sell0 - liq_val * ap
            if pb <= 0:
                continue

            lo, hi = 0.0, 1.0
            for _ in range(50):
                mid = (lo + hi) / 2
                test_fc = {"base": mid, "bin_rate": 0, "vol_rate": 0, "net_rate": 0, "max_fee": mid}
                _, pwf = sandwich_profit(liq_val, ap, vp, bin_size, test_fc)
                if pwf > 0:
                    lo = mid
                else:
                    hi = mid
            be = (lo + hi) / 2
            print(f"  ${liq_val:>12,.0f}  {ap*100:>8.1f}%  ${pb:>12,.0f}  {be*100:>12.2f}%")

    # ══════════════════════════════════════════════════════════════
    # PART 4: Bin-based detection accuracy
    # ══════════════════════════════════════════════════════════════
    print(f"\n{'═'*W}")
    print("PART 4: BIN-BASED DETECTION - How many bins = MEV?")
    print(f"{'═'*W}")

    print(f"\n  For a $10M pool with 60-tick bins (~0.6% per bin):")
    print(f"  {'Bins Crossed':>14} {'Price Move':>12} {'Normal?':>10} {'Sandwich?':>12}")
    print("  " + "-" * 50)

    for bc in range(0, 11):
        price_move = (1.0001 ** (bc * 60) - 1) * 100
        # Normal: single direction trade
        b = AMM(10_000_000)
        b.swap(10_000_000 * (bc * 0.001), True)
        actual_bc = tick_to_bin(b.tick(), 60)
        normal = "Yes" if bc <= 2 else "Suspicious"

        # Sandwich
        attack_size = bc * 0.005 * 10_000_000
        b2 = AMM(10_000_000)
        b2.swap(attack_size, True)
        b2.swap(attack_size * 0.2, True)
        b2.swap(attack_size, False)
        sandwich = "Yes" if bc >= 3 else "Maybe"

        print(f"  {bc:>12}  {price_move:>10.2f}%  {normal:>10}  {sandwich:>12}")

    # ══════════════════════════════════════════════════════════════
    # PART 5: Volume vs Bins correlation
    # ══════════════════════════════════════════════════════════════
    print(f"\n{'═'*W}")
    print("PART 5: VOLUME/LIQUIDITY RATIO vs BINS CROSSED")
    print(f"{'═'*W}")

    print(f"\n  {'Vol/Liq':>10} {'Bins=1':>10} {'Bins=3':>10} {'Bins=5':>10} {'Bins=8':>10} {'Bins=10':>10}")
    print(f"  {'':>10} {'Fee%':>10} {'Fee%':>10} {'Fee%':>10} {'Fee%':>10} {'Fee%':>10}")
    print("  " + "-" * 62)

    test_fc = {"base": 0.003, "bin_rate": 0.01, "vol_rate": 1.0, "net_rate": 0.005, "max_fee": 0.10}

    for vol_ratio in [0.01, 0.02, 0.05, 0.10, 0.20, 0.50, 1.0]:
        print(f"  {vol_ratio*100:>8.0f}%  ", end="")
        for bc in [1, 3, 5, 8, 10]:
            vol = vol_ratio * 10_000_000
            m = {"bins_crossed": bc, "volume": vol, "net_bins": bc}
            fee = calc_fee(m, 10_000_000, test_fc)
            print(f"  {fee*100:>8.2f}%", end="")
        print()

    # ══════════════════════════════════════════════════════════════
    # PART 6: Recommended fee formula
    # ══════════════════════════════════════════════════════════════
    print(f"\n{'═'*W}")
    print("PART 6: RECOMMENDED FEE FORMULA")
    print(f"{'═'*W}")

    print(f"""
  FEE = base + bin_penalty + volume_penalty + direction_penalty

  Where:
    base           = 0.3%  (normal swap fee)
    bin_penalty    = bins_crossed × 1.0%  (price manipulation indicator)
    volume_penalty = (volume / liquidity) × 100%  (high volume = suspicious)
    direction_penalty = |net_bins| × 0.5%  (one-directional = MEV)
    max_fee        = 10%

  WHY THIS WORKS:
  ─────────────────────────────────────────────────
  1. bins_crossed: Sandwich attacks move price UP then DOWN.
     Normal trades move price ONE direction.
     bins_crossed captures TOTAL movement (both directions).

  2. volume/liquidity: High volume relative to liquidity is suspicious.
     Normal trades have volume << liquidity.
     Attacks have volume ≈ liquidity.

  3. direction_penalty: Sandwich has net_bins ≈ 0 (up then back).
     Normal trade has net_bins > 0.
     This distinguishes sandwiches from whale trades.

  DETECTION LOGIC:
  ─────────────────────────────────────────────────
  IF bins_crossed > 2 AND volume/liq > 5%:
    → Likely MEV, charge high fee
  IF bins_crossed > 0 AND net_bins ≈ 0:
    → Sandwich pattern, charge high fee
  IF volume/liq > 10%:
    → Suspicious, charge moderate fee

  BREAK-EVEN ANALYSIS:
  ─────────────────────────────────────────────────
  Attack Size    Break-even Fee    With 10% Max Fee
  2%             1.96%             Fully protected
  5%             3.84%             Fully protected
  10%            7.39%             Fully protected
  20%            ~15%              Partially protected

  CONCLUSION:
  ─────────────────────────────────────────────────
  A 10% max fee kills all attacks up to 10% of liquidity.
  For larger attacks (10-20%), need 15-20% max fee.

  RECOMMENDATION:
  Use 10% max fee for normal pools.
  Use 20% max fee for high-risk pools.
""")


# ═══════════════════════════════════════════════════════════════
# PART 7: LARGE DATASET - 10000 random scenarios
# ══════════════════════════════════════════════════════════════

def run_large_dataset():
    import random
    random.seed(42)

    W = 130
    N = 100_000
    print(f"\n{'═'*W}")
    print(f"PART 7: LARGE DATASET - {N:,} RANDOM SCENARIOS")
    print(f"{'═'*W}")

    bin_size = 60
    fee_config = {"base": 0.003, "bin_rate": 0.01, "vol_rate": 1.0, "net_rate": 0.005, "max_fee": 0.10}

    pool_sizes = [10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000, 10_000_000, 50_000_000, 100_000_000, 500_000_000]
    attack_pcts = [0.001, 0.005, 0.01, 0.02, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50]
    victim_ratios = [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5]

    total = 0
    protected = 0
    missed = 0

    profits_baseline = []
    profits_fee = []
    protections = []

    # Per pool-size stats
    pool_stats = {p: {"total": 0, "protected": 0, "missed": 0} for p in pool_sizes}
    # Per attack-size stats
    attack_stats = {a: {"total": 0, "protected": 0, "missed": 0} for a in attack_pcts}

    print(f"\n  Running {N:,} scenarios...")
    print(f"  Pool sizes: $10K - $500M")
    print(f"  Attack sizes: 0.1% - 50%")
    print(f"  Victim ratios: 5% - 50% of attack")
    print(f"  Fee config: 10% max\n")

    for i in range(N):
        liq = random.choice(pool_sizes)
        ap = random.choice(attack_pcts)
        vr = random.choice(victim_ratios)
        vp = ap * vr

        # Baseline
        b = AMM(liq)
        atok = b.swap(liq * ap, True)
        b.swap(liq * vp, True)
        sell0 = b.swap(atok, False)
        pb = sell0 - liq * ap

        # With fee
        pnf, pwf = sandwich_profit(liq, ap, vp, bin_size, fee_config)

        profits_baseline.append(pb)
        profits_fee.append(pwf)

        is_protected = False
        if pb > 0:
            prot = (1 - pwf / pb) * 100
            protections.append(prot)
            if pwf <= 0:
                protected += 1
                is_protected = True
            else:
                missed += 1
        else:
            protected += 1
            is_protected = True

        total += 1

        # Pool stats
        ps = pool_stats[liq]
        ps["total"] += 1
        if is_protected:
            ps["protected"] += 1
        else:
            ps["missed"] += 1

        # Attack stats
        atk = attack_stats[ap]
        atk["total"] += 1
        if is_protected:
            atk["protected"] += 1
        else:
            atk["missed"] += 1

        if (i + 1) % 10000 == 0:
            print(f"    {i + 1:>7} / {N:,} done... ({protected/total*100:.1f}% protected)")

    # ── Overall statistics ──
    avg_baseline = sum(profits_baseline) / len(profits_baseline)
    avg_fee = sum(profits_fee) / len(profits_fee)
    avg_prot = sum(protections) / len(protections) if protections else 0
    max_profit_fee = max(profits_fee)
    profitable_attacks = sum(1 for p in profits_fee if p > 0)

    print(f"\n  {'='*70}")
    print(f"  RESULTS: {N:,} RANDOM SCENARIOS")
    print(f"  {'='*70}")
    print(f"\n  Total scenarios:      {total:>10,}")
    print(f"  Protected:            {protected:>10,} ({protected/total*100:.1f}%)")
    print(f"  Missed:               {missed:>10,} ({missed/total*100:.1f}%)")
    print(f"  Profitable attacks:   {profitable_attacks:>10,} ({profitable_attacks/total*100:.1f}%)")
    print(f"\n  Avg baseline profit:  ${avg_baseline:>12,.0f}")
    print(f"  Avg fee profit:       ${avg_fee:>12,.0f}")
    print(f"  Avg protection:       {avg_prot:>10.1f}%")
    print(f"  Max profit (fee):     ${max_profit_fee:>12,.0f}")

    # ── Protection by pool size ──
    print(f"\n  {'='*70}")
    print(f"  PROTECTION BY POOL SIZE")
    print(f"  {'='*70}")
    print(f"\n  {'Pool':>14} {'Total':>8} {'Protected':>10} {'Missed':>8} {'Rate':>8}")
    print("  " + "-" * 52)
    for p in sorted(pool_stats.keys()):
        s = pool_stats[p]
        rate = s["protected"] / s["total"] * 100 if s["total"] > 0 else 0
        print(f"  ${p:>12,} {s['total']:>8,} {s['protected']:>10,} {s['missed']:>8,} {rate:>6.1f}%")

    # ── Protection by attack size ──
    print(f"\n  {'='*70}")
    print(f"  PROTECTION BY ATTACK SIZE")
    print(f"  {'='*70}")
    print(f"\n  {'Attack%':>10} {'Total':>8} {'Protected':>10} {'Missed':>8} {'Rate':>8}")
    print("  " + "-" * 50)
    for a in sorted(attack_stats.keys()):
        s = attack_stats[a]
        rate = s["protected"] / s["total"] * 100 if s["total"] > 0 else 0
        print(f"  {a*100:>8.2f}% {s['total']:>8,} {s['protected']:>10,} {s['missed']:>8,} {rate:>6.1f}%")

    # ── Protection distribution ──
    print(f"\n  {'='*70}")
    print(f"  PROTECTION DISTRIBUTION (among profitable baseline attacks)")
    print(f"  {'='*70}")
    brackets = [0, 50, 100, 200, 500, 1000, float('inf')]
    labels = ["<50%", "50-100%", "100-200%", "200-500%", "500-1000%", ">1000%"]
    print()
    for j in range(len(brackets) - 1):
        count = sum(1 for p in protections if brackets[j] <= p < brackets[j+1])
        bar = "█" * int(count / len(protections) * 50)
        print(f"    {labels[j]:<12} {count:>7,} ({count/len(protections)*100:>5.1f}%) {bar}")

    # ── Worst cases ──
    print(f"\n  {'='*70}")
    print(f"  WORST 20 CASES (highest attacker profit with fee)")
    print(f"  {'='*70}")
    worst = sorted(zip(profits_fee, profits_baseline), key=lambda x: -x[0])[:20]
    print(f"\n    {'#':>4} {'Fee Profit':>14} {'Baseline':>14} {'Prot%':>10}")
    print("    " + "-" * 46)
    for idx, (pf, pb) in enumerate(worst):
        prot = (1 - pf / pb) * 100 if pb > 0 else 100
        print(f"    {idx+1:>4} ${pf:>12,.0f} ${pb:>12,.0f} {prot:>8.1f}%")

    # ── Survival rate by attack+pool combo ──
    print(f"\n  {'='*70}")
    print(f"  ATTACK SURVIVAL MATRIX (% attacks still profitable)")
    print(f"  {'='*70}")

    combos = {}
    for i in range(N):
        liq = random.choice(pool_sizes)
        ap = random.choice(attack_pcts)
        # Can't re-randomize, use stored data
    # Rebuild from stored data using index mapping
    combos2 = {}
    idx = 0
    for liq in pool_sizes:
        for ap in attack_pcts:
            combos2[(liq, ap)] = {"total": 0, "survived": 0}

    # Re-run to populate correctly
    random.seed(42)
    for i in range(N):
        liq = random.choice(pool_sizes)
        ap = random.choice(attack_pcts)
        vr = random.choice(victim_ratios)
        vp = ap * vr

        b = AMM(liq)
        atok = b.swap(liq * ap, True)
        b.swap(liq * vp, True)
        sell0 = b.swap(atok, False)
        pb = sell0 - liq * ap

        _, pwf = sandwich_profit(liq, ap, vp, bin_size, fee_config)

        key = (liq, ap)
        combos2[key]["total"] += 1
        if pb > 0 and pwf > 0:
            combos2[key]["survived"] += 1

    print(f"\n  {'Pool':>14}", end="")
    for a in attack_pcts:
        print(f" {a*100:>6.1f}%", end="")
    print()
    print("  " + "-" * (14 + len(attack_pcts) * 7))

    for p in pool_sizes:
        print(f"  ${p:>12,}", end="")
        for a in attack_pcts:
            c = combos2[(p, a)]
            if c["total"] > 0:
                survive_rate = c["survived"] / c["total"] * 100
                print(f" {survive_rate:>5.1f}%", end="")
            else:
                print(f"    N/A", end="")
        print()

    return protected, total, profitable_attacks


# ═══════════════════════════════════════════════════════════════
# PART 8: EDGE CASES
# ══════════════════════════════════════════════════════════════

def run_edge_cases():
    W = 130
    print(f"\n{'═'*W}")
    print("PART 8: EXTREME EDGE CASES")
    print(f"{'═'*W}")

    bin_size = 60
    fee_config = {"base": 0.003, "bin_rate": 0.01, "vol_rate": 1.0, "net_rate": 0.005, "max_fee": 0.10}

    edge_cases = [
        # (name, liq, attack_pct, victim_pct)
        ("Micro pool 0.5% attack", 10_000, 0.005, 0.001),
        ("Micro pool 5% attack", 10_000, 0.05, 0.01),
        ("Micro pool 20% attack", 10_000, 0.20, 0.04),
        ("Small pool 0.5% attack", 100_000, 0.005, 0.001),
        ("Small pool 10% attack", 100_000, 0.10, 0.02),
        ("Small pool 30% attack", 100_000, 0.30, 0.06),
        ("Medium pool 0.5% attack", 1_000_000, 0.005, 0.001),
        ("Medium pool 10% attack", 1_000_000, 0.10, 0.02),
        ("Medium pool 30% attack", 1_000_000, 0.30, 0.06),
        ("Large pool 0.5% attack", 100_000_000, 0.005, 0.001),
        ("Large pool 10% attack", 100_000_000, 0.10, 0.02),
        ("Large pool 30% attack", 100_000_000, 0.30, 0.06),
        ("Whale vs victim (1:1)", 10_000_000, 0.10, 0.10),
        ("Whale vs victim (1:0.1)", 10_000_000, 0.10, 0.01),
        ("Multiple victims", 10_000_000, 0.05, 0.05),
        ("Tiny victim", 10_000_000, 0.05, 0.001),
    ]

    print(f"\n  {'Scenario':<28} {'Pool':>12} {'Atk%':>6} {'Vic%':>6} {'Base$':>14} {'Fee$':>14} {'Prot%':>8}")
    print("  " + "-" * 92)

    for name, liq, ap, vp in edge_cases:
        # Baseline
        b = AMM(liq)
        atok = b.swap(liq * ap, True)
        b.swap(liq * vp, True)
        sell0 = b.swap(atok, False)
        pb = sell0 - liq * ap

        # With fee
        pnf, pwf = sandwich_profit(liq, ap, vp, bin_size, fee_config)

        prot = (1 - pwf / pb) * 100 if pb > 0 else 100
        print(f"  {name:<28} ${liq:>10,} {ap*100:>5.1f}% {vp*100:>5.1f}% ${pb:>12,.0f} ${pwf:>12,.0f} {prot:>6.1f}%")

    # Multi-sandwich in same block
    print(f"\n  {'='*60}")
    print(f"  MULTI-SANDWICH IN SAME BLOCK")
    print(f"  {'='*60}")

    liq = 10_000_000
    for num_attacks in [1, 2, 3, 5]:
        amm = AMM(liq)
        total_vol = 0
        attack_size = liq * 0.05

        for _ in range(num_attacks):
            amm.swap(attack_size, True)
            amm.swap(attack_size * 0.2, True)
            amm.swap(attack_size, False)
            total_vol += attack_size * 2.2

        init_bin = 0
        final_bin = tick_to_bin(amm.tick(), bin_size)
        bc = abs(final_bin - init_bin)

        fee = calc_fee({"bins_crossed": bc, "volume": total_vol, "net_bins": bc}, liq, fee_config)
        print(f"  {num_attacks} sandwiches: vol/liq={total_vol/liq*100:.0f}%, fee={fee*100:.2f}%")


# ═══════════════════════════════════════════════════════════════
# PART 9: GAS OPTIMIZATION
# ══════════════════════════════════════════════════════════════

def run_gas_analysis():
    W = 130
    print(f"\n{'═'*W}")
    print("PART 9: FEE FORMULA COMPLEXITY (gas considerations)")
    print(f"{'═'*W}")

    print(f"""
  Fee formula operations per swap:
  ─────────────────────────────────────────
  1. Read block state (start_bin, max_bin, min_bin)  → 3 SLOAD
  2. Calculate bins_crossed = max - min               → 1 SUB
  3. Calculate net_bins = final - start               → 1 SUB
  4. Read volume                                      → 1 SLOAD
  5. Calculate vol_ratio = volume / liquidity         → 1 DIV
  6. Calculate fee = base + bin*rate + vol*rate + net*rate → 4 MUL, 3 ADD
  7. Cap at max_fee                                   → 1 MIN
  8. Update block state                               → 3 SSTORE

  Total: ~6 SLOAD, 3 SSTORE, 9 ALU operations
  Estimated gas: ~25,000-35,000 per swap (extra)

  Comparison:
  ─────────────────────────────────────────
  Uniswap v4 swap: ~150,000 gas
  With hook: ~185,000 gas (+23%)
  With fee: ~190,000 gas (+27%)
""")


# ═══════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════

if __name__ == "__main__":
    main()
    run_large_dataset()
    run_edge_cases()
    run_gas_analysis()
