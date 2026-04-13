#!/usr/bin/env python3
"""Toxic-flow simulation comparing baseline symmetric spread vs inventory-aware mid shift.

Scenario:
- 7 days, one toxic trade per minute (10080 ticks).
- Each tick: find the strike K where fair p_up(K) ≈ 0.20 and buy UP there.
- Assume every trade wins (PnL per unit notional = 1 - ask).
- Market state (forward, SVI params) is sampled from scenario_mar6_1000mints.csv.

Usage:
    packages/predict/simulations/.venv/bin/python \
        packages/predict/simulations/toxic_flow_sim.py
"""
from __future__ import annotations

import csv
import math
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from scipy.stats import norm

# === Paths / constants ===
SCRIPT_DIR = Path(__file__).parent
CSV_PATH = SCRIPT_DIR / "data" / "scenario_mar6_1000mints.csv"
OUT_DIR = SCRIPT_DIR / "runs"
OUT_DIR.mkdir(exist_ok=True)

FLOAT_SCALING = 1e9
SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000
ONE_DAY_MS = 24 * 60 * 60 * 1000

# Simulation config
N_MINUTES = 7 * 24 * 60  # 10080 ticks
TARGET_P = 0.20  # trader always buys UP at strike where p_up ≈ 0.20
TRADE_SIZE = 10_000.0  # $10k notional per trade

# Spread config (defaults from predict/constants.move)
BASE_SPREAD = 0.01
MIN_SPREAD = 0.0025

# Mid-shift config
BALANCE = 10_000_000.0
DEFAULT_DEPTH_MULTIPLIER = 1.0


# === CSV parsing ===

def parse_states(path: Path) -> list[tuple[float, tuple[float, float, float, float, float]]]:
    """Parse CSV into an ordered list of (forward, svi_params) snapshots.

    Each `update_prices`/`update_svi` pair yields one state. `mint` rows are ignored.
    """
    states: list[tuple[float, tuple[float, float, float, float, float]]] = []
    cur_forward: float | None = None
    cur_svi: tuple[float, float, float, float, float] | None = None
    with open(path) as f:
        for row in csv.DictReader(f):
            action = row["action"]
            if action == "update_prices":
                cur_forward = float(row["forward"]) / FLOAT_SCALING
            elif action == "update_svi":
                a = float(row["a"]) / FLOAT_SCALING
                b = float(row["b"]) / FLOAT_SCALING
                rho = float(row["rho"]) / FLOAT_SCALING
                if row["rho_negative"].strip().lower() == "true":
                    rho = -rho
                m = float(row["m"]) / FLOAT_SCALING
                if row["m_negative"].strip().lower() == "true":
                    m = -m
                sigma = float(row["sigma"]) / FLOAT_SCALING
                cur_svi = (a, b, rho, m, sigma)
                if cur_forward is not None and cur_svi is not None:
                    states.append((cur_forward, cur_svi))
    return states


# === SVI → binary UP price (port of oracle::compute_nd2) ===

def svi_up_price(strike: float, forward: float, svi) -> float | None:
    a, b, rho, m, sigma = svi
    if strike <= 0 or forward <= 0:
        return None
    k = math.log(strike / forward)
    km = k - m
    inner = rho * km + math.sqrt(km * km + sigma * sigma)
    if inner < 0:
        return None
    w = a + b * inner
    if w <= 0:
        return None
    d2 = -(k + w / 2) / math.sqrt(w)
    return float(norm.cdf(d2))


def find_strike_for_target_p(forward: float, svi, target_p: float) -> float | None:
    """Binary search for strike K where p_up(K) ≈ target_p. p_up decreases in K."""
    lo, hi = forward * 0.2, forward * 5.0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        p = svi_up_price(mid, forward, svi)
        if p is None:
            return None
        if p > target_p:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


# === Pricing ===

def spread_at(p: float) -> float:
    return max(BASE_SPREAD * math.sqrt(p * (1 - p)), MIN_SPREAD)


def baseline_up_ask(p: float) -> float:
    return min(p + spread_at(p), 1.0)


def shifted_up_ask(p: float, raw_ratio: float) -> float:
    ratio = max(-1.0, min(1.0, raw_ratio))
    mid_shift = ratio * (1 - p) if ratio > 0 else ratio * p
    shifted_mid = p + mid_shift
    ask = shifted_mid + spread_at(p)
    # zero-edge floor: never sell UP below fair
    ask = max(ask, p)
    return min(ask, 1.0)


# === Simulation ===

def simulate(states, depth_multiplier: float):
    n_states = len(states)
    state_idx = np.linspace(0, n_states - 1, N_MINUTES).astype(int)

    baseline_pnl = np.zeros(N_MINUTES)
    shifted_pnl = np.zeros(N_MINUTES)
    raw_ratio_series = np.zeros(N_MINUTES)
    ask_baseline_series = np.zeros(N_MINUTES)
    ask_shifted_series = np.zeros(N_MINUTES)

    aggregate = 0.0
    b_pnl = 0.0
    s_pnl = 0.0

    for i, si in enumerate(state_idx):
        forward, svi = states[int(si)]
        strike = find_strike_for_target_p(forward, svi, TARGET_P)
        if strike is None:
            baseline_pnl[i] = b_pnl
            shifted_pnl[i] = s_pnl
            continue
        p = svi_up_price(strike, forward, svi)
        if p is None or p <= 0 or p >= 1:
            baseline_pnl[i] = b_pnl
            shifted_pnl[i] = s_pnl
            continue

        tte_ms = SEVEN_DAYS_MS * (N_MINUTES - i) / N_MINUTES
        tte_factor = math.sqrt(SEVEN_DAYS_MS / max(tte_ms, ONE_DAY_MS))
        raw_ratio = (aggregate * tte_factor) / (BALANCE * depth_multiplier)

        b_ask = baseline_up_ask(p)
        s_ask = shifted_up_ask(p, raw_ratio)

        # Toxic trader knows the trade wins. PnL per unit = 1 - ask. Skip if ask ≥ 1.
        if b_ask < 1.0:
            b_pnl += TRADE_SIZE * (1.0 - b_ask)
        if s_ask < 1.0:
            s_pnl += TRADE_SIZE * (1.0 - s_ask)
            aggregate += TRADE_SIZE * math.sqrt(p * (1 - p))

        baseline_pnl[i] = b_pnl
        shifted_pnl[i] = s_pnl
        raw_ratio_series[i] = raw_ratio
        ask_baseline_series[i] = b_ask
        ask_shifted_series[i] = s_ask

    return {
        "baseline_pnl": baseline_pnl,
        "shifted_pnl": shifted_pnl,
        "raw_ratio": raw_ratio_series,
        "ask_baseline": ask_baseline_series,
        "ask_shifted": ask_shifted_series,
    }


# === Main ===

def main() -> None:
    states = parse_states(CSV_PATH)
    print(f"Parsed {len(states)} (forward, svi) snapshots from {CSV_PATH.name}")
    print(f"Running {N_MINUTES} ticks, trade size ${TRADE_SIZE:,.0f}, balance ${BALANCE:,.0f}")

    result = simulate(states, DEFAULT_DEPTH_MULTIPLIER)

    baseline_final = result["baseline_pnl"][-1]
    shifted_final = result["shifted_pnl"][-1]
    print(f"Baseline final toxic PnL: ${baseline_final:,.0f}")
    print(f"Shifted  final toxic PnL: ${shifted_final:,.0f}  "
          f"(depth_multiplier={DEFAULT_DEPTH_MULTIPLIER})")
    if baseline_final > 0:
        print(f"Reduction: {1 - shifted_final / baseline_final:.1%}")

    ticks = np.arange(N_MINUTES)

    # Chart 1: baseline vs shifted cumulative PnL
    fig, ax = plt.subplots(figsize=(11, 6))
    ax.plot(
        ticks,
        result["baseline_pnl"] / 1_000,
        label="Baseline (symmetric spread only)",
        color="#d62728",
        lw=2,
    )
    ax.plot(
        ticks,
        result["shifted_pnl"] / 1_000,
        label=f"With mid shift (depth_multiplier={DEFAULT_DEPTH_MULTIPLIER})",
        color="#2ca02c",
        lw=2,
    )
    ax.set_xlabel("Minute since start of 7d window")
    ax.set_ylabel("Cumulative toxic trader PnL ($ thousands)")
    ax.set_title(
        f"Toxic flow: buy strike at p_up≈{TARGET_P}, ${int(TRADE_SIZE):,}/trade, "
        f"${int(BALANCE / 1e6)}M vault"
    )
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out1 = OUT_DIR / "toxic_flow_pnl.png"
    fig.savefig(out1, dpi=150)
    plt.close(fig)
    print(f"Wrote {out1.relative_to(SCRIPT_DIR)}")

    # Chart 2: depth_multiplier sensitivity
    fig, ax = plt.subplots(figsize=(11, 6))
    ax.plot(ticks, result["baseline_pnl"] / 1_000, label="Baseline", color="#d62728", lw=2.2)
    colors = ["#1f77b4", "#2ca02c", "#9467bd", "#ff7f0e"]
    for dm, color in zip([0.25, 0.5, 1.0, 2.0], colors):
        sweep = simulate(states, dm)
        ax.plot(
            ticks,
            sweep["shifted_pnl"] / 1_000,
            label=f"depth_multiplier={dm}",
            color=color,
            lw=1.6,
        )
    ax.set_xlabel("Minute since start of 7d window")
    ax.set_ylabel("Cumulative toxic trader PnL ($ thousands)")
    ax.set_title("Toxic flow PnL — depth_multiplier sensitivity")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out2 = OUT_DIR / "toxic_flow_depth_sweep.png"
    fig.savefig(out2, dpi=150)
    plt.close(fig)
    print(f"Wrote {out2.relative_to(SCRIPT_DIR)}")

    # Chart 3: diagnostic — how the ask evolves under the shift vs baseline
    fig, ax = plt.subplots(figsize=(11, 6))
    ax.plot(ticks, result["ask_baseline"], label="Baseline ask", color="#d62728", lw=1.5)
    ax.plot(ticks, result["ask_shifted"], label="Shifted ask", color="#2ca02c", lw=1.5)
    ax.axhline(1.0, color="grey", lw=0.8, ls="--", alpha=0.6)
    ax.set_xlabel("Minute since start of 7d window")
    ax.set_ylabel("Ask price (UP at target strike)")
    ax.set_title("UP ask over time — baseline vs. mid-shift defense")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out3 = OUT_DIR / "toxic_flow_ask_trace.png"
    fig.savefig(out3, dpi=150)
    plt.close(fig)
    print(f"Wrote {out3.relative_to(SCRIPT_DIR)}")


if __name__ == "__main__":
    main()
