"""
Stress test simulation for treap + oracle using real-world data.

Replays oracle price/SVI updates from CSVs, generates trades,
and verifies treap.max_payout() and MTM accuracy at each step.
"""

import csv
import os
import random
from dataclasses import dataclass
from typing import Optional

import numpy as np
from scipy.stats import norm

# === Configuration ===

EXPIRY = 1773734400000          # Mar 17 08:00 UTC (Deribit expiry)
MAX_EVENTS = 2_000_000            # Max oracle events to process
TRADE_EVERY = 200               # Trade every N oracle events
MTM_EVERY = 10                   # Compute MTM every N snapshots
SEED = 42                       # RNG seed
MIN_TRADE_COST = 50             # Min trade cost in USD
MAX_TRADE_COST = 500            # Max trade cost in USD
MIN_PRICE_PCT = 1               # Min contract price (1c)
MAX_PRICE_PCT = 99              # Max contract price (99c)
REMOVE_PROBABILITY = 0.3        # Chance of remove vs insert
INITIAL_VAULT_BALANCE = 1_000_000 * 1_000_000  # $1M initial vault supply
BASE_SPREAD = 10_000_000        # 1% (matches default_base_spread)
UTIL_MULTIPLIER = 2_000_000_000 # 2x (matches default_utilization_multiplier)
VERIFY_MAX_PAYOUT = False       # Brute force max_payout check (slow, O(N) per step)
VERIFY_MTM = True               # Brute force MTM check (sampled every MTM_EVERY steps)
PRICES_CSV = "oracle_prices_mar17.csv"
SVI_CSV = "oracle_svi_mar17.csv"

from oracle import (
    FLOAT_SCALING,
    MS_PER_YEAR,
    CurvePoint,
    OracleSVI,
    PriceData,
    SVIParams,
    mul,
)
from stats import SimulationStats, instrument, print_tree_shape
from treap import Treap


# === Oracle Event Loading ===


@dataclass
class OracleEvent:
    timestamp: int
    kind: str  # "price" or "svi"
    # Price fields
    spot: int = 0
    forward: int = 0
    # SVI fields
    a: int = 0
    b: int = 0
    rho: int = 0
    rho_negative: bool = False
    m: int = 0
    m_negative: bool = False
    sigma: int = 0
    risk_free_rate: int = 0


def load_oracle_events(prices_csv: str, svi_csv: str) -> list[OracleEvent]:
    """Load and merge price + SVI events sorted by timestamp."""
    events: list[OracleEvent] = []

    with open(prices_csv) as f:
        reader = csv.DictReader(f)
        for row in reader:
            events.append(
                OracleEvent(
                    timestamp=int(row["onchain_timestamp"]),
                    kind="price",
                    spot=int(row["spot"]),
                    forward=int(row["forward"]),
                )
            )

    with open(svi_csv) as f:
        reader = csv.DictReader(f)
        for row in reader:
            events.append(
                OracleEvent(
                    timestamp=int(row["onchain_timestamp"]),
                    kind="svi",
                    a=int(row["a"]),
                    b=int(row["b"]),
                    rho=int(row["rho"]),
                    rho_negative=row["rho_negative"] == "t",
                    m=int(row["m"]),
                    m_negative=row["m_negative"] == "t",
                    sigma=int(row["sigma"]),
                    risk_free_rate=int(row["risk_free_rate"]),
                )
            )

    events.sort(key=lambda e: e.timestamp)
    return events


# === Pricing ===


def get_quote(mid_price: int, mtm: int, balance: int) -> tuple[int, int]:
    """Compute bid/ask from mid price with spread, mirroring predict.move::get_quote."""
    if balance == 0 or mtm == 0:
        util_spread = 0
    else:
        util = min(mtm * FLOAT_SCALING // balance, FLOAT_SCALING)
        util_sq = mul(util, util)
        util_spread = mul(BASE_SPREAD, mul(UTIL_MULTIPLIER, util_sq))

    spread = BASE_SPREAD + util_spread
    bid = max(mid_price - spread, 0)
    ask = min(mid_price + spread, FLOAT_SCALING)
    return (bid, ask)


# === Strike Picker ===


def find_valid_strike_range(
    oracle: OracleSVI, now: int
) -> Optional[tuple[int, int]]:
    """Find strike range where binary UP price is in [0.01, 0.99].
    Returns (low_strike, high_strike) or None if oracle isn't ready."""
    forward = oracle.prices.forward
    if forward == 0:
        return None

    one_pct = FLOAT_SCALING * MIN_PRICE_PCT // 100
    ninety_nine_pct = FLOAT_SCALING * MAX_PRICE_PCT // 100

    # Search outward from forward to find the 1% and 99% boundaries
    # UP price decreases as strike increases
    # So low strike = where UP price ~ 99%, high strike = where UP price ~ 1%
    step = forward // 100  # 1% of forward
    if step == 0:
        return None

    # Find low strike (UP price near 99% — deep ITM for UP)
    low = forward
    for _ in range(200):
        low -= step
        if low <= 0:
            low = step
            break
        price = oracle.get_binary_price(low, True, now)
        if price >= ninety_nine_pct:
            break

    # Find high strike (UP price near 1% — deep OTM for UP)
    high = forward
    for _ in range(200):
        high += step
        price = oracle.get_binary_price(high, True, now)
        if price <= one_pct:
            break

    return (low, high)


def pick_strike(
    oracle: OracleSVI, now: int, rng: random.Random
) -> Optional[tuple[int, int, bool]]:
    """Pick a random strike and direction where price is in [0.01, 0.99].
    Returns (strike, qty, is_up) or None."""
    strike_range = find_valid_strike_range(oracle, now)
    if strike_range is None:
        return None

    low, high = strike_range
    if low >= high:
        return None

    # Random strike within range
    strike = rng.randint(low, high)
    is_up = rng.choice([True, False])

    # Verify price is in valid range
    price = oracle.get_binary_price(strike, is_up, now)
    if price < FLOAT_SCALING * MIN_PRICE_PCT // 100 or price > FLOAT_SCALING * MAX_PRICE_PCT // 100:
        return None

    # Target a fixed notional cost ($50-$500), derive qty from price
    target_cost = rng.randint(MIN_TRADE_COST, MAX_TRADE_COST) * 1_000_000
    price_per_contract = mul(1_000_000, price)  # cost for 1 contract (1_000_000 qty)
    if price_per_contract == 0:
        return None
    qty = (target_cost // price_per_contract) * 1_000_000
    if qty == 0:
        return None

    return (strike, qty, is_up)


# === Brute Force MTM ===


def brute_force_mtm(
    positions: dict[tuple[int, bool], int], oracle: OracleSVI, now: int
) -> int:
    """Compute exact MTM by pricing each position individually."""
    total = 0
    for (strike, is_up), qty in positions.items():
        if qty <= 0:
            continue
        price = oracle.get_binary_price(strike, is_up, now)
        total += mul(qty, price)
    return total


def brute_force_mtm_vectorized(
    positions: dict[tuple[int, bool], int], oracle: OracleSVI, now: int
) -> int:
    """Vectorized MTM using NumPy + scipy for fast bulk pricing."""
    active = {k: v for k, v in positions.items() if v > 0}
    if not active:
        return 0

    strikes = np.array([s for (s, _) in active.keys()], dtype=np.float64)
    is_ups = np.array([u for (_, u) in active.keys()])
    qtys = np.array(list(active.values()), dtype=np.float64)

    forward = float(oracle.prices.forward) / FLOAT_SCALING
    a = float(oracle.svi.a) / FLOAT_SCALING
    b = float(oracle.svi.b) / FLOAT_SCALING
    rho = float(oracle.svi.rho) / FLOAT_SCALING
    if oracle.svi.rho_negative:
        rho = -rho
    m = float(oracle.svi.m) / FLOAT_SCALING
    if oracle.svi.m_negative:
        m = -m
    sigma = float(oracle.svi.sigma) / FLOAT_SCALING
    r = float(oracle.risk_free_rate) / FLOAT_SCALING

    # Convert strikes from fixed-point to float
    strikes_f = strikes / FLOAT_SCALING

    # Discount factor
    if now >= oracle.expiry:
        discount = 1.0
    else:
        tte = (oracle.expiry - now) / MS_PER_YEAR
        discount = np.exp(-r * tte)

    # SVI: total variance
    k = np.log(strikes_f / forward)
    k_minus_m = k - m
    total_var = a + b * (rho * k_minus_m + np.sqrt(k_minus_m**2 + sigma**2))
    total_var = np.maximum(total_var, 1e-18)  # prevent sqrt(0)

    # d2 and N(d2)
    sqrt_var = np.sqrt(total_var)
    d2 = (-k - total_var / 2.0) / sqrt_var

    # UP price = discount * N(d2), DOWN price = discount * N(-d2)
    prices = np.where(is_ups, discount * norm.cdf(d2), discount * norm.cdf(-d2))

    # Convert prices back to fixed-point scale, compute total
    total = np.sum(qtys * prices)

    return int(total)


# === Mint Tracking ===


@dataclass
class MintRecord:
    timestamp: int
    strike: int
    is_up: bool
    qty: int
    cost: int  # total premium paid (qty * ask price)
    mid_price: int  # oracle mid price for bucket classification


# === Simulation ===


@dataclass
class Snapshot:
    step: int
    timestamp: int
    event_kind: str
    action: str  # "insert", "remove", "none"
    treap_size: int
    vault_balance: int
    treap_mtm: int
    brute_force_mtm: int
    mtm_deviation: int
    treap_max_payout: int
    brute_force_max_payout: int
    max_payout_match: bool


def run_simulation(
    events: list[OracleEvent],
    expiry: int,
    seed: int = 42,
    max_events: Optional[int] = None,
    trade_every: int = 10,
    mtm_every: int = 50,
) -> tuple[list[Snapshot], list[MintRecord], SimulationStats, "Treap"]:
    rng = random.Random(seed)
    oracle = OracleSVI(underlying_asset="BTC", expiry=expiry)
    treap = Treap()
    instrumented = instrument(treap)
    sim_stats = SimulationStats()

    # Track outstanding positions: (strike, is_up) -> qty
    outstanding: dict[tuple[int, bool], int] = {}
    snapshots: list[Snapshot] = []
    mint_records: list[MintRecord] = []
    vault_balance = INITIAL_VAULT_BALANCE
    last_mtm = 0

    has_price = False
    has_svi = False
    cached_strike_range: Optional[tuple[int, int]] = None

    limit = max_events or len(events)

    for step, event in enumerate(events[:limit]):
        # Update oracle
        if event.kind == "price":
            oracle.prices = PriceData(spot=event.spot, forward=event.forward)
            oracle.timestamp = event.timestamp
            has_price = True
            cached_strike_range = None  # invalidate on price change
        elif event.kind == "svi":
            oracle.svi = SVIParams(
                a=event.a,
                b=event.b,
                rho=event.rho,
                rho_negative=event.rho_negative,
                m=event.m,
                m_negative=event.m_negative,
                sigma=event.sigma,
            )
            oracle.risk_free_rate = event.risk_free_rate
            oracle.timestamp = event.timestamp
            has_svi = True
            cached_strike_range = None  # invalidate on SVI change

        if not (has_price and has_svi):
            continue

        now = event.timestamp

        # Only trade every N events to keep simulation fast
        if step % trade_every != 0:
            continue

        # No new trades past expiry
        if now >= expiry:
            continue

        # Generate a trade: 70% insert, 30% remove
        action = "none"
        total_outstanding = sum(v for v in outstanding.values() if v > 0)
        do_remove = total_outstanding > 0 and rng.random() < REMOVE_PROBABILITY

        if do_remove:
            active = [(k, v) for k, v in outstanding.items() if v > 0]
            if active:
                key, current_qty = rng.choice(active)
                remove_qty = rng.randint(1, current_qty // 1_000_000) * 1_000_000
                if remove_qty > 0:
                    strike, is_up = key
                    mid_price = oracle.get_binary_price(strike, is_up, now)
                    bid, _ask = get_quote(mid_price, last_mtm, vault_balance)
                    payout = mul(remove_qty, bid)
                    vault_balance -= payout
                    instrumented.reset_counters()
                    treap.remove(strike, remove_qty, is_up)
                    sim_stats.record("remove", strike, remove_qty, is_up, instrumented.snapshot())
                    outstanding[key] = current_qty - remove_qty
                    if outstanding[key] == 0:
                        del outstanding[key]
                    action = "remove"
        else:
            # Cache strike range
            if cached_strike_range is None:
                cached_strike_range = find_valid_strike_range(oracle, now)
            result = pick_strike(oracle, now, rng)
            if result is not None:
                strike, qty, is_up = result
                mid_price = oracle.get_binary_price(strike, is_up, now)
                _bid, ask = get_quote(mid_price, last_mtm, vault_balance)
                premium = mul(qty, ask)
                vault_balance += premium
                instrumented.reset_counters()
                treap.insert(strike, qty, is_up)
                sim_stats.record("insert", strike, qty, is_up, instrumented.snapshot())
                mint_records.append(MintRecord(
                    timestamp=now, strike=strike, is_up=is_up,
                    qty=qty, cost=premium, mid_price=mid_price,
                ))
                key = (strike, is_up)
                outstanding[key] = outstanding.get(key, 0) + qty
                action = "insert"

        # Always compute treap MTM (matches on-chain behavior)
        treap_mtm_val = 0
        if not treap.is_empty():
            min_s, max_s = treap.strike_range()
            curve = oracle.build_curve(min_s, max_s, now)
            treap_mtm_val = treap.evaluate(curve)
        last_mtm = treap_mtm_val

        # Brute force MTM (sampled)
        bf_mtm = 0
        if VERIFY_MTM and len(snapshots) % mtm_every == 0 and not treap.is_empty():
            bf_mtm = brute_force_mtm_vectorized(outstanding, oracle, now)

        # Max payout
        treap_mp = treap.max_payout()
        bf_mp = treap.brute_force_max_payout() if VERIFY_MAX_PAYOUT else treap_mp
        deviation = abs(treap_mtm_val - bf_mtm)

        snapshots.append(
            Snapshot(
                step=step,
                timestamp=now,
                event_kind=event.kind,
                action=action,
                treap_size=treap.size,
                vault_balance=vault_balance,
                treap_mtm=treap_mtm_val,
                brute_force_mtm=bf_mtm,
                mtm_deviation=deviation,
                treap_max_payout=treap_mp,
                brute_force_max_payout=bf_mp,
                max_payout_match=(treap_mp == bf_mp),
            )
        )

        if step % 1000 == 0:
            print(
                f"  step {step}/{limit} | "
                f"size={treap.size} | "
                f"action={action} | "
                f"max_payout_ok={treap_mp == bf_mp}"
            )

    return snapshots, mint_records, sim_stats, treap


def print_summary(snapshots: list[Snapshot]):
    if not snapshots:
        print("No snapshots to report.")
        return

    total = len(snapshots)
    inserts = sum(1 for s in snapshots if s.action == "insert")
    removes = sum(1 for s in snapshots if s.action == "remove")
    no_action = sum(1 for s in snapshots if s.action == "none")

    # Max payout correctness
    mp_mismatches = [s for s in snapshots if not s.max_payout_match]

    # MTM deviation stats
    deviations = [s.mtm_deviation for s in snapshots if s.treap_size > 0]
    bf_mtms = [s.brute_force_mtm for s in snapshots if s.brute_force_mtm > 0]

    print(f"=== Simulation Summary ===")
    print(f"Total oracle events processed: {total}")
    print(f"Trades: {inserts} inserts, {removes} removes, {no_action} skipped")
    print(f"Final treap size: {snapshots[-1].treap_size} strikes")
    print()

    print(f"=== Max Payout ===")
    if not VERIFY_MAX_PAYOUT:
        print(f"Verification disabled (VERIFY_MAX_PAYOUT=False)")
    elif mp_mismatches:
        print(f"MISMATCHES: {len(mp_mismatches)} / {total}")
        for s in mp_mismatches[:5]:
            print(
                f"  step={s.step} treap={s.treap_max_payout} "
                f"brute_force={s.brute_force_max_payout}"
            )
    else:
        print(f"All {total} steps match brute force")
    print()

    print(f"=== MTM Deviation (treap curve approx vs exact per-position) ===")
    if not VERIFY_MTM:
        print(f"  Verification disabled (VERIFY_MTM=False)")
        return
    if deviations:
        max_dev = max(deviations)
        mean_dev = sum(deviations) // len(deviations)
        sorted_devs = sorted(deviations)
        p99_dev = sorted_devs[int(len(sorted_devs) * 0.99)]

        # Relative deviation (as % of brute force MTM)
        rel_devs = []
        for s in snapshots:
            if s.brute_force_mtm > 0:
                rel_devs.append(s.mtm_deviation * FLOAT_SCALING // s.brute_force_mtm)

        max_rel = max(rel_devs) if rel_devs else 0
        mean_rel = (sum(rel_devs) // len(rel_devs)) if rel_devs else 0

        print(f"  Absolute: max={max_dev} mean={mean_dev} p99={p99_dev}")
        print(
            f"  Relative: max={max_rel / FLOAT_SCALING * 100:.4f}% "
            f"mean={mean_rel / FLOAT_SCALING * 100:.4f}%"
        )
    else:
        print("  No positions to measure")


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    prices_csv = os.path.join(script_dir, PRICES_CSV)
    svi_csv = os.path.join(script_dir, SVI_CSV)

    print("Loading oracle events...")
    events = load_oracle_events(prices_csv, svi_csv)
    print(f"Loaded {len(events)} events")

    print("Running simulation...")
    snapshots, mint_records, sim_stats, treap = run_simulation(
        events,
        expiry=EXPIRY,
        seed=SEED,
        max_events=MAX_EVENTS,
        trade_every=TRADE_EVERY,
        mtm_every=MTM_EVERY,
    )

    print_summary(snapshots)
    print()
    sim_stats.print_summary()
    print()
    print_tree_shape(treap)

    from charts import generate_charts, generate_mint_analysis

    # Find settlement price (last spot before expiry)
    settlement_price = None
    for event in events:
        if event.kind == "price" and event.timestamp <= EXPIRY:
            settlement_price = event.spot

    print("\nGenerating charts...")
    generate_charts(snapshots, output_dir=script_dir)
    if settlement_price is not None:
        print(f"Settlement price: {settlement_price / FLOAT_SCALING:.2f}")
        generate_mint_analysis(mint_records, settlement_price, output_dir=script_dir)
    else:
        print("No settlement price found, skipping mint analysis.")
    print("Charts saved.")
