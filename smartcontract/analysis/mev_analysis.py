#!/usr/bin/env python3
"""
MEV / market-quality analysis: concentrated bins vs flat x*y=k.

Fixes vs v3:
  - x*y=k sandwich now updates reserves between legs (was 3 independent swaps)
  - L normalization scales by actual TVL, not sum(value/L)
  - Empty bins are skipped so LinearDecay tails do not trap the swap
  - EqualToken1 uses L_i = 1 / (√p_hi - √p_lo)
  - Optional bin-ratchet: after price leaves a bin, reverse flow cannot re-enter it
  - Pair fees applied to amount-in so sandwich ROI is realistic
  - Volatility coverage: how much TVL/depth survives a ±1σ / ±2σ move
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Optional, Tuple


# ═══════════════════════════════════════════════════════════════
#  BIN CPMM
# ═══════════════════════════════════════════════════════════════

def sqrt_p(p: float) -> float:
    return math.sqrt(p) if p > 0 else 0.0


@dataclass
class Bin:
    L: float
    p_lo: float
    p_hi: float

    def reserves(self, p: float) -> Tuple[float, float]:
        s = sqrt_p(p)
        slo = sqrt_p(self.p_lo)
        shi = sqrt_p(self.p_hi)
        if s <= slo:
            return (0.0, self.L * (shi - slo))
        if s >= shi:
            return (self.L * (1 / slo - 1 / shi), 0.0)
        return (self.L * (1 / slo - 1 / s), self.L * (s - slo))


def swap_single_bin(
    L: float, p_lo: float, p_hi: float,
    p_start: float, amount_in: float, zero_for_one: bool,
) -> Tuple[float, float, float]:
    """Returns (amount_out, p_end, amount_in_consumed)."""
    if L <= 0 or amount_in <= 0:
        return (0.0, p_start, 0.0)

    slo = sqrt_p(p_lo)
    shi = sqrt_p(p_hi)
    s = sqrt_p(p_start)

    if zero_for_one:
        s_in = min(max(s, slo), shi)
        max_in = L * (1 / slo - 1 / s_in) if s_in > slo else 0.0
        if max_in <= 0:
            return (0.0, p_start, 0.0)
        if amount_in >= max_in:
            return (L * (s_in - slo), p_lo, max_in)
        inv_s_new = 1 / s_in + amount_in / L
        s_new = max(1 / inv_s_new, slo)
        return (L * (s_in - s_new), s_new * s_new, amount_in)

    s_in = min(max(s, slo), shi)
    max_in = L * (shi - s_in) if s_in < shi else 0.0
    if max_in <= 0:
        return (0.0, p_start, 0.0)
    if amount_in >= max_in:
        return (L * (1 / s_in - 1 / shi), p_hi, max_in)
    s_new = min(s_in + amount_in / L, shi)
    return (L * (1 / s_in - 1 / s_new), s_new * s_new, amount_in)


def find_active_bin(bins: List[Bin], p: float) -> int:
    for i, b in enumerate(bins):
        if b.p_lo <= p <= b.p_hi and b.L > 0:
            return i
    if p < bins[0].p_lo:
        return 0
    if p > bins[-1].p_hi:
        return len(bins) - 1
    # Price sits in a gap / empty bin — snap to nearest live bin in-range
    best, best_d = 0, float("inf")
    for i, b in enumerate(bins):
        if b.L <= 0:
            continue
        mid = 0.5 * (b.p_lo + b.p_hi)
        d = abs(mid - p)
        if d < best_d:
            best, best_d = i, d
    return best


def swap_pool(
    bins: List[Bin],
    p_start: float,
    amount_in: float,
    zero_for_one: bool,
    fee: float = 0.0,
    ratchet_lo: Optional[int] = None,
    ratchet_hi: Optional[int] = None,
) -> Tuple[float, float, int]:
    """
    Swap through bins (ascending p_lo).
    ratchet_lo / ratchet_hi clamp the walk so a reverse cannot re-enter
    bins already left — this is the BinRatchet lock.
    Returns (amount_out, p_end, end_bin_index).
    """
    remaining = amount_in * (1.0 - fee)
    total_out = 0.0
    p_current = p_start
    active = find_active_bin(bins, p_start)
    end_bin = active

    if zero_for_one:
        stop = -1 if ratchet_lo is None else ratchet_lo - 1
        for i in range(active, stop, -1):
            if remaining < 1e-18:
                break
            if ratchet_lo is not None and i < ratchet_lo:
                break
            b = bins[i]
            if b.L <= 0:
                p_current = b.p_lo
                end_bin = i
                continue
            p_entry = min(max(p_current, b.p_lo), b.p_hi)
            out, p_end, consumed = swap_single_bin(
                b.L, b.p_lo, b.p_hi, p_entry, remaining, True
            )
            if consumed <= 0:
                p_current = b.p_lo
                end_bin = i
                continue
            total_out += out
            remaining -= consumed
            p_current = p_end
            end_bin = i
    else:
        stop = len(bins) if ratchet_hi is None else ratchet_hi + 1
        for i in range(active, stop):
            if remaining < 1e-18:
                break
            if ratchet_hi is not None and i > ratchet_hi:
                break
            b = bins[i]
            if b.L <= 0:
                p_current = b.p_hi
                end_bin = i
                continue
            p_entry = min(max(p_current, b.p_lo), b.p_hi)
            out, p_end, consumed = swap_single_bin(
                b.L, b.p_lo, b.p_hi, p_entry, remaining, False
            )
            if consumed <= 0:
                p_current = b.p_hi
                end_bin = i
                continue
            total_out += out
            remaining -= consumed
            p_current = p_end
            end_bin = i

    return total_out, p_current, end_bin


def build_bins(
    price: float,
    num_bins_per_side: int,
    bin_width: float,
    L_raw: List[float],
) -> List[Bin]:
    n = num_bins_per_side
    bins: List[Bin] = []
    for i in range(n - 1, -1, -1):
        p_hi = price * (1 - i * bin_width)
        p_lo = price * (1 - (i + 1) * bin_width)
        if p_lo <= 0:
            p_lo = p_hi * 0.5
        bins.append(Bin(L_raw[n - 1 - i], p_lo, p_hi))
    for i in range(n):
        p_lo = price * (1 + i * bin_width)
        p_hi = price * (1 + (i + 1) * bin_width)
        bins.append(Bin(L_raw[n + i], p_lo, p_hi))
    return bins


def compute_total_value(bins: List[Bin], price: float) -> float:
    total = 0.0
    for b in bins:
        t0, t1 = b.reserves(price)
        total += t0 * price + t1
    return total


def make_L_values_raw(
    strategy: str,
    num_bins_per_side: int,
    param: float,
    price: float,
    bin_width: float,
) -> List[float]:
    n = num_bins_per_side
    total = 2 * n
    Ls: List[float] = []

    def bounds_for_raw_index(idx: int) -> Tuple[float, float]:
        if idx < n:
            i = n - 1 - idx  # matches build_bins below-side walk
            p_hi = price * (1 - i * bin_width)
            p_lo = price * (1 - (i + 1) * bin_width)
            if p_lo <= 0:
                p_lo = p_hi * 0.5
            return p_lo, p_hi
        i = idx - n
        return price * (1 + i * bin_width), price * (1 + (i + 1) * bin_width)

    for i in range(total):
        distance = (n - i) if i < n else (i - n + 1)
        if strategy == "exp":
            Ls.append(param ** distance)
        elif strategy == "linear":
            ramp = int(param)
            Ls.append(0.0 if distance >= ramp else (ramp - distance) / ramp)
        elif strategy == "equal_t1":
            p_lo, p_hi = bounds_for_raw_index(i)
            width = sqrt_p(p_hi) - sqrt_p(p_lo)
            Ls.append(1.0 / width if width > 0 else 0.0)
        else:  # constant
            Ls.append(1.0)
    return Ls


def normalize_L_values(
    L_raw: List[float],
    price: float,
    num_bins_per_side: int,
    bin_width: float,
    target_TVL: float,
) -> List[float]:
    bins_test = build_bins(price, num_bins_per_side, bin_width, L_raw)
    total = compute_total_value(bins_test, price)
    if total <= 0:
        return L_raw
    scale = target_TVL / total
    return [L * scale for L in L_raw]


# ═══════════════════════════════════════════════════════════════
#  x*y=k
# ═══════════════════════════════════════════════════════════════

@dataclass
class XYkPool:
    reserve0: float
    reserve1: float

    @property
    def price(self) -> float:
        return self.reserve1 / self.reserve0 if self.reserve0 > 0 else 0.0

    @property
    def k(self) -> float:
        return self.reserve0 * self.reserve1

    @property
    def TVL(self) -> float:
        return self.reserve0 * self.price + self.reserve1

    def copy(self) -> "XYkPool":
        return XYkPool(self.reserve0, self.reserve1)


def xyk_swap(pool: XYkPool, amount_in: float, zero_for_one: bool, fee: float = 0.0) -> float:
    """Mutates pool. Returns amount_out."""
    net = amount_in * (1.0 - fee)
    if net <= 0:
        return 0.0
    if zero_for_one:
        new_r0 = pool.reserve0 + net
        new_r1 = pool.k / new_r0
        out = pool.reserve1 - new_r1
        pool.reserve0, pool.reserve1 = new_r0, new_r1
        return max(out, 0.0)
    new_r1 = pool.reserve1 + net
    new_r0 = pool.k / new_r1
    out = pool.reserve0 - new_r0
    pool.reserve0, pool.reserve1 = new_r0, new_r1
    return max(out, 0.0)


# ═══════════════════════════════════════════════════════════════
#  METRICS
# ═══════════════════════════════════════════════════════════════

@dataclass
class SandwichResult:
    attacker_profit_pct: float
    victim_slippage_pct: float
    price_move_pct: float
    attacker_capital_pct: float
    crossed_bin: bool


@dataclass
class ImpactResult:
    imp_01: float
    imp_1: float
    imp_5: float
    imp_10: float
    spread_bps: float
    depth_to_1pct: float


@dataclass
class VolCoverage:
    tvl_within_1s: float
    tvl_within_2s: float
    depth_after_1s: float
    in_range_after_1s: bool
    in_range_after_2s: bool
    bins_needed_for_1s: float


def sandwich_bins(
    bins: List[Bin],
    price: float,
    TVL: float,
    victim_pct: float,
    fee: float,
    attacker_mult: float = 2.0,
    ratchet: bool = False,
) -> SandwichResult:
    victim_amt = TVL * victim_pct
    attacker_amt = victim_amt * attacker_mult

    front_out, p1, bin1 = swap_pool(bins, price, attacker_amt, False, fee=fee)
    hi = bin1 if ratchet else None
    victim_out, p2, bin2 = swap_pool(
        bins, p1, victim_amt, False, fee=fee, ratchet_hi=hi if ratchet else None
    )
    if ratchet:
        hi = bin2
    fair_out, _, _ = swap_pool(bins, price, victim_amt, False, fee=fee)
    back_out, p3, _ = swap_pool(
        bins, p2, front_out, True, fee=fee, ratchet_lo=hi if ratchet else None
    )

    profit_pct = (back_out - attacker_amt) / attacker_amt * 100 if attacker_amt else 0.0
    slip = (fair_out - victim_out) / fair_out * 100 if fair_out > 0 else 0.0
    return SandwichResult(
        attacker_profit_pct=profit_pct,
        victim_slippage_pct=slip,
        price_move_pct=abs(p1 - price) / price * 100,
        attacker_capital_pct=attacker_amt / TVL * 100,
        crossed_bin=bin2 != find_active_bin(bins, price),
    )


def sandwich_xyk(
    pool: XYkPool, TVL: float, victim_pct: float, fee: float, attacker_mult: float = 2.0
) -> SandwichResult:
    victim_amt = TVL * victim_pct
    attacker_amt = victim_amt * attacker_mult
    p0 = pool.price

    live = pool.copy()
    front_out = xyk_swap(live, attacker_amt, False, fee)
    p1 = live.price
    victim_out = xyk_swap(live, victim_amt, False, fee)
    fair = pool.copy()
    fair_out = xyk_swap(fair, victim_amt, False, fee)
    back_out = xyk_swap(live, front_out, True, fee)

    profit_pct = (back_out - attacker_amt) / attacker_amt * 100 if attacker_amt else 0.0
    slip = (fair_out - victim_out) / fair_out * 100 if fair_out > 0 else 0.0
    return SandwichResult(
        attacker_profit_pct=profit_pct,
        victim_slippage_pct=slip,
        price_move_pct=abs(p1 - p0) / p0 * 100 if p0 else 0.0,
        attacker_capital_pct=attacker_amt / TVL * 100,
        crossed_bin=False,
    )


def impact_bins(bins: List[Bin], price: float, TVL: float, fee: float) -> ImpactResult:
    imps = []
    for pct in (0.001, 0.01, 0.05, 0.10):
        _, p_end, _ = swap_pool(bins, price, TVL * pct, False, fee=fee)
        imps.append(abs(p_end - price) / price * 100)

    tiny = TVL * 1e-4
    out_up, p_up, _ = swap_pool(bins, price, tiny, False, fee=fee)
    _, p_back, _ = swap_pool(bins, p_up, out_up, True, fee=fee)
    spread = abs(price - p_back) / price * 10000

    lo, hi = 0.0, TVL * 2.0
    for _ in range(60):
        mid = (lo + hi) / 2
        _, p_mid, _ = swap_pool(bins, price, mid, False, fee=0.0)
        if price > 0 and abs(p_mid - price) / price < 0.01:
            lo = mid
        else:
            hi = mid
    return ImpactResult(*imps, spread_bps=spread, depth_to_1pct=lo)


def impact_xyk(pool: XYkPool, TVL: float, fee: float) -> ImpactResult:
    imps = []
    for pct in (0.001, 0.01, 0.05, 0.10):
        tmp = pool.copy()
        xyk_swap(tmp, TVL * pct, False, fee)
        imps.append(abs(tmp.price - pool.price) / pool.price * 100)

    tmp = pool.copy()
    tiny = TVL * 1e-4
    out = xyk_swap(tmp, tiny, False, fee)
    xyk_swap(tmp, out, True, fee)
    spread = abs(pool.price - tmp.price) / pool.price * 10000

    lo, hi = 0.0, TVL * 2.0
    for _ in range(60):
        mid = (lo + hi) / 2
        tmp = pool.copy()
        xyk_swap(tmp, mid, False, fee=0.0)
        if abs(tmp.price - pool.price) / pool.price < 0.01:
            lo = mid
        else:
            hi = mid
    return ImpactResult(*imps, spread_bps=spread, depth_to_1pct=lo)


def tvl_inside_band(bins: List[Bin], price: float, lo: float, hi: float) -> float:
    """Value of reserves whose bin overlaps [lo, hi]."""
    total = 0.0
    for b in bins:
        if b.p_hi < lo or b.p_lo > hi:
            continue
        t0, t1 = b.reserves(price)
        total += t0 * price + t1
    return total


def vol_coverage_bins(bins: List[Bin], price: float, TVL: float, vol: float) -> VolCoverage:
    band1 = (price * (1 - vol), price * (1 + vol))
    band2 = (price * (1 - 2 * vol), price * (1 + 2 * vol))
    v1 = tvl_inside_band(bins, price, *band1) / TVL * 100 if TVL else 0.0
    v2 = tvl_inside_band(bins, price, *band2) / TVL * 100 if TVL else 0.0

    p_1s = price * (1 + vol)
    in1 = any(b.L > 0 and b.p_lo <= p_1s <= b.p_hi for b in bins)
    p_2s = price * (1 + 2 * vol)
    in2 = any(b.L > 0 and b.p_lo <= p_2s <= b.p_hi for b in bins)

    depth = 0.0
    if in1:
        lo, hi = 0.0, TVL * 2.0
        for _ in range(50):
            mid = (lo + hi) / 2
            _, p_mid, _ = swap_pool(bins, p_1s, mid, False, fee=0.0)
            if p_1s > 0 and abs(p_mid - p_1s) / p_1s < 0.01:
                lo = mid
            else:
                hi = mid
        depth = lo

    # bins of `bin_width` needed to cover 1σ (set later by caller if wanted)
    return VolCoverage(v1, v2, depth, in1, in2, 0.0)


def vol_coverage_xyk(pool: XYkPool, TVL: float, vol: float) -> VolCoverage:
    # x*y=k has liquidity on (0, ∞). Depth after a 1σ arb-to-new-price:
    # skip the arb and just measure depth at the post-move reserves.
    # Approximate: after price * (1+vol), r1/r0 = p*(1+vol), r0*r1 = k
    p1 = pool.price * (1 + vol)
    r0 = math.sqrt(pool.k / p1)
    r1 = pool.k / r0
    moved = XYkPool(r0, r1)
    imp = impact_xyk(moved, moved.TVL, fee=0.0)
    return VolCoverage(100.0, 100.0, imp.depth_to_1pct, True, True, 0.0)


def worst_sandwich(run_fn, sizes=None, mults=None) -> Tuple[SandwichResult, float, float]:
    """Return (best_for_attacker, victim_pct, attacker_mult)."""
    sizes = sizes or (0.001, 0.005, 0.01, 0.02, 0.05, 0.10, 0.20)
    mults = mults or (1.0, 2.0, 3.0, 5.0)
    best: Optional[SandwichResult] = None
    best_sz = 0.0
    best_m = 0.0
    for sz in sizes:
        for m in mults:
            s = run_fn(sz, m)
            if best is None or s.attacker_profit_pct > best.attacker_profit_pct:
                best, best_sz, best_m = s, sz, m
    assert best is not None
    return best, best_sz, best_m


# ═══════════════════════════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════════════════════════

@dataclass
class TokenPair:
    name: str
    regime: str
    price: float
    vol: float          # 1-day σ
    TVL: float
    n_bins: int
    bin_w: float
    trade_pct: float    # typical victim size as fraction of TVL
    fee: float          # swap fee (amount-in)


PAIRS = {
    "USDC/USDT": TokenPair(
        "USDC/USDT  (stable)", "stable",
        price=1.0, vol=0.001, TVL=50e6, n_bins=10, bin_w=0.002,
        trade_pct=0.05, fee=0.0001,
    ),
    "ETH/USDC": TokenPair(
        "ETH/USDC  (mid-vol)", "mid",
        price=2000.0, vol=0.02, TVL=10e6, n_bins=20, bin_w=0.01,
        trade_pct=0.01, fee=0.0005,
    ),
    "MEME/ETH": TokenPair(
        "MEME/ETH  (high-vol)", "high",
        price=0.0001, vol=0.10, TVL=500e3, n_bins=25, bin_w=0.03,
        trade_pct=0.03, fee=0.003,
    ),
}

STRATEGIES = {
    "x*y=k (V2)":        ("xyk", 0.0),
    "ConstantL":         ("constant", 0.0),
    "EqualToken1":       ("equal_t1", 0.0),
    "LinearDecay(r=10)": ("linear", 10.0),
    "LinearDecay(r=5)":  ("linear", 5.0),
    "ExpoDecay(0.8)":    ("exp", 0.8),
    "ExpoDecay(0.5)":    ("exp", 0.5),
}


def make_book(pair: TokenPair, stype: str, sparam: float):
    if stype == "xyk":
        r1 = pair.TVL / 2
        r0 = r1 / pair.price
        return XYkPool(r0, r1), None
    L_raw = make_L_values_raw(stype, pair.n_bins, sparam, pair.price, pair.bin_w)
    L_norm = normalize_L_values(L_raw, pair.price, pair.n_bins, pair.bin_w, pair.TVL)
    bins = build_bins(pair.price, pair.n_bins, pair.bin_w, L_norm)
    return None, bins


# ═══════════════════════════════════════════════════════════════
#  REPORT
# ═══════════════════════════════════════════════════════════════

def fmt_pct(x: float, signed: bool = True, digits: int = 2) -> str:
    if signed:
        return f"{x:+.{digits}f}%"
    return f"{x:.{digits}f}%"


def run() -> None:
    print("=" * 118)
    print("  BINS vs FLAT x*y=k   ·   stable / mid-vol / high-vol")
    print("  Sandwich uses pair fee. Depth is fee-free (shape only).")
    print("  Ratchet = reverse cannot re-enter a bin the forward swap already left.")
    print("=" * 118)

    all_data = {}

    for key, pair in PAIRS.items():
        print(f"\n{'━' * 118}")
        print(
            f"  {pair.name}   price={pair.price:g}   σ={pair.vol*100:.2f}%/day"
            f"   TVL=${pair.TVL:,.0f}   {pair.n_bins} bins/side × {pair.bin_w*100:.2f}%"
            f"   fee={pair.fee*10000:.1f}bps   typical trade={pair.trade_pct*100:.1f}% TVL"
        )
        print(
            f"  1σ range = ±{pair.vol/pair.bin_w:.1f} bins"
            f"   2σ = ±{2*pair.vol/pair.bin_w:.1f} bins"
            f"   book half-width = {pair.n_bins * pair.bin_w * 100:.1f}%"
        )
        print(f"{'━' * 118}")

        pair_data = {}
        for sname, (stype, sparam) in STRATEGIES.items():
            pool, bins = make_book(pair, stype, sparam)
            if stype == "xyk":
                s_typ = sandwich_xyk(pool, pair.TVL, pair.trade_pct, pair.fee, 2.0)
                s_typ_nf = sandwich_xyk(pool, pair.TVL, pair.trade_pct, 0.0, 2.0)
                def _run(sz, m, _p=pool):
                    return sandwich_xyk(_p, pair.TVL, sz, pair.fee, m)
                worst, wsz, wm = worst_sandwich(_run)
                imp = impact_xyk(pool, pair.TVL, pair.fee)
                cov = vol_coverage_xyk(pool, pair.TVL, pair.vol)
                s_ratchet = s_typ  # no ratchet on V2
            else:
                s_typ = sandwich_bins(bins, pair.price, pair.TVL, pair.trade_pct, pair.fee, 2.0, False)
                s_typ_nf = sandwich_bins(bins, pair.price, pair.TVL, pair.trade_pct, 0.0, 2.0, False)
                s_ratchet = sandwich_bins(bins, pair.price, pair.TVL, pair.trade_pct, pair.fee, 2.0, True)
                def _run(sz, m, _b=bins):
                    return sandwich_bins(_b, pair.price, pair.TVL, sz, pair.fee, m, False)
                worst, wsz, wm = worst_sandwich(_run)
                imp = impact_bins(bins, pair.price, pair.TVL, pair.fee)
                cov = vol_coverage_bins(bins, pair.price, pair.TVL, pair.vol)
                cov.bins_needed_for_1s = pair.vol / pair.bin_w

            pair_data[sname] = dict(
                typ=s_typ, typ_nf=s_typ_nf, ratchet=s_ratchet,
                worst=worst, wsz=wsz, wm=wm, imp=imp, cov=cov,
            )
        all_data[key] = pair_data

        # ── typical sandwich ──
        print(f"\n  TYPICAL SANDWICH  (victim={pair.trade_pct*100:.1f}% TVL, attacker=2×, fee on)")
        print(f"  {'Strategy':<22} │ {'Att ROI':>9} │ {'no-fee ROI':>10} │ {'Victim slip':>11} │ {'Front ΔP':>9} │ {'Ratchet ROI':>11} │ {'Crossed?':>8}")
        print(f"  {'─'*22}─┼─{'─'*9}─┼─{'─'*10}─┼─{'─'*11}─┼─{'─'*9}─┼─{'─'*11}─┼─{'─'*8}")
        for i, sn in enumerate(STRATEGIES):
            d = pair_data[sn]
            s, nf, r = d["typ"], d["typ_nf"], d["ratchet"]
            cross = "—" if sn.startswith("x*y") else ("yes" if s.crossed_bin else "no")
            line = (
                f"  {sn:<22} │ {s.attacker_profit_pct:>+8.2f}% │ {nf.attacker_profit_pct:>+9.2f}%"
                f" │ {s.victim_slippage_pct:>+10.2f}% │ {s.price_move_pct:>+8.2f}%"
                f" │ {r.attacker_profit_pct:>+10.2f}% │ {cross:>8}"
            )
            print(line)
            if i == 0:
                print(f"  {'─'*22}─┼─{'─'*9}─┼─{'─'*10}─┼─{'─'*11}─┼─{'─'*9}─┼─{'─'*11}─┼─{'─'*8}")

        # ── depth ──
        print(f"\n  PRICE IMPACT / DEPTH  (sell token1, fee on impact columns)")
        print(f"  {'Strategy':<22} │ {'0.1%TVL':>8} │ {'1%TVL':>8} │ {'5%TVL':>8} │ {'10%TVL':>8} │ {'Spread':>8} │ {'Depth→1%':>12}")
        print(f"  {'─'*22}─┼─{'─'*8}─┼─{'─'*8}─┼─{'─'*8}─┼─{'─'*8}─┼─{'─'*8}─┼─{'─'*12}")
        for i, sn in enumerate(STRATEGIES):
            ip = pair_data[sn]["imp"]
            print(
                f"  {sn:<22} │ {ip.imp_01:>7.3f}% │ {ip.imp_1:>7.3f}% │ {ip.imp_5:>7.3f}%"
                f" │ {ip.imp_10:>7.3f}% │ {ip.spread_bps:>6.1f}bp │ ${ip.depth_to_1pct:>10,.0f}"
            )
            if i == 0:
                print(f"  {'─'*22}─┼─{'─'*8}─┼─{'─'*8}─┼─{'─'*8}─┼─{'─'*8}─┼─{'─'*8}─┼─{'─'*12}")

        # ── vol coverage ──
        print(f"\n  VOLATILITY COVERAGE  (1σ = {pair.vol*100:.2f}%, 2σ = {2*pair.vol*100:.2f}%)")
        print(f"  {'Strategy':<22} │ {'TVL in ±1σ':>11} │ {'TVL in ±2σ':>11} │ {'In-range@1σ':>11} │ {'In-range@2σ':>11} │ {'Depth@1σ':>12}")
        print(f"  {'─'*22}─┼─{'─'*11}─┼─{'─'*11}─┼─{'─'*11}─┼─{'─'*11}─┼─{'─'*12}")
        for i, sn in enumerate(STRATEGIES):
            c = pair_data[sn]["cov"]
            print(
                f"  {sn:<22} │ {c.tvl_within_1s:>10.1f}% │ {c.tvl_within_2s:>10.1f}%"
                f" │ {('yes' if c.in_range_after_1s else 'NO'):>11}"
                f" │ {('yes' if c.in_range_after_2s else 'NO'):>11}"
                f" │ ${c.depth_after_1s:>10,.0f}"
            )
            if i == 0:
                print(f"  {'─'*22}─┼─{'─'*11}─┼─{'─'*11}─┼─{'─'*11}─┼─{'─'*11}─┼─{'─'*12}")

        # ── worst sandwich ──
        print(f"\n  WORST-CASE SANDWICH  (attacker picks size × multiple, fee on, no ratchet)")
        print(f"  {'Strategy':<22} │ {'Best ROI':>9} │ {'Vic %TVL':>9} │ {'Atk mult':>8} │ {'Vic slip':>9}")
        print(f"  {'─'*22}─┼─{'─'*9}─┼─{'─'*9}─┼─{'─'*8}─┼─{'─'*9}")
        for i, sn in enumerate(STRATEGIES):
            d = pair_data[sn]
            w = d["worst"]
            print(
                f"  {sn:<22} │ {w.attacker_profit_pct:>+8.2f}% │ {d['wsz']*100:>8.1f}%"
                f" │ {d['wm']:>7.1f}x │ {w.victim_slippage_pct:>+8.2f}%"
            )
            if i == 0:
                print(f"  {'─'*22}─┼─{'─'*9}─┼─{'─'*9}─┼─{'─'*8}─┼─{'─'*9}")

    # ═══════════════════════════════════════════════════════════════
    print(f"\n{'═' * 118}")
    print("  HEAD-TO-HEAD vs x*y=k   (typical sandwich + depth + 1σ survival)")
    print(f"{'═' * 118}")

    for key, pair in PAIRS.items():
        print(f"\n  {pair.name}")
        xyk = all_data[key]["x*y=k (V2)"]
        print(
            f"  {'Strategy':<22} │ {'ROI vs V2':>10} │ {'Slip vs V2':>10} │ {'Depth vs V2':>11} │ {'1σ TVL':>8} │ {'1σ depth vs V2':>14}"
        )
        print(f"  {'─'*22}─┼─{'─'*10}─┼─{'─'*10}─┼─{'─'*11}─┼─{'─'*8}─┼─{'─'*14}")
        for sn in STRATEGIES:
            if sn.startswith("x*y"):
                continue
            d = all_data[key][sn]
            roi_d = d["typ"].attacker_profit_pct - xyk["typ"].attacker_profit_pct
            slip_d = d["typ"].victim_slippage_pct - xyk["typ"].victim_slippage_pct
            depth_pct = (
                (d["imp"].depth_to_1pct / xyk["imp"].depth_to_1pct - 1) * 100
                if xyk["imp"].depth_to_1pct > 0 else 0.0
            )
            d1 = (
                (d["cov"].depth_after_1s / xyk["cov"].depth_after_1s - 1) * 100
                if xyk["cov"].depth_after_1s > 0 else 0.0
            )
            print(
                f"  {sn:<22} │ {roi_d:>+9.2f}pp │ {slip_d:>+9.2f}pp │ {depth_pct:>+10.0f}%"
                f" │ {d['cov'].tvl_within_1s:>7.1f}% │ {d1:>+13.0f}%"
            )

    print(f"\n{'═' * 118}")
    print("  HOW TO READ THIS")
    print(f"{'═' * 118}")
    print("""
  Two separate effects are stacked in a bin book. Do not mix them up.

  1. CONCENTRATION  (bins vs flat x*y=k, ratchet off)
     x*y=k spreads inventory from price 0 to ∞. Only a thin slice sits near spot.
     Bins put the same TVL inside a finite band around spot, so local L is higher.
     Higher local L → smaller price move for a given trade → sandwich is harder.
     Cost: once price walks out of the book, depth goes to zero. x*y=k never does that.

  2. RATCHET  (one-way bin lock)
     After a swap leaves a bin, the reverse cannot re-enter it.
     A sandwich that crosses a bin boundary cannot fully unwind.
     In-bin sandwiches still look like a local x*y=k.

  Stable  (σ ≪ bin width, e.g. USDC/USDT 0.1%/day vs 0.20% bins)
     Almost all flow dies inside the active bin. Ratchet rarely fires.
     The whole win vs V2 is concentration: a 5% TVL clip hits a deep local book
     instead of a 50/50 unbounded curve. Tail risk is negligible (2σ is 0.2%).

  High-vol  (σ spans several bins, e.g. MEME 10%/day vs 3% bins)
     Typical flow already walks multiple bins. Concentration still helps at spot,
     but Linear/Expo tails go thin exactly where a 1σ move lands.
     Ratchet starts to matter: the unwind leg is trapped in the last bin.
     x*y=k keeps quoting after a 20% move; a tight LinearDecay(r=5) may not.

  Mid-vol  (ETH, σ ≈ 2 bins)
     Sits between the two. LinearDecay(r=10) usually covers 2σ and still
     beats V2 on depth. ExpoDecay(0.5) wins at spot and loses after a trend day.
""")
    print("=" * 118 + "\n")


if __name__ == "__main__":
    run()
