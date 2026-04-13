#!/usr/bin/env python3
"""Toxic-flow simulation comparing baseline symmetric spread vs inventory-aware mid shift.

Scenario:
- 7 days, one toxic trade per minute (10080 ticks).
- Each tick: find the strike K where fair p_up(K) ≈ 0.20 and buy UP there.
- Trader's realized win rate on the 20c strike is WIN_RATE (default 40%).
- Trader only takes the trade when EV is positive: ask < WIN_RATE.
- Expected PnL per unit = WIN_RATE − ask.
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

plt.rcParams["text.parse_math"] = False  # allow literal "$" in labels/titles

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
TRADE_SIZE = 2_000.0  # $2k notional per trade
WIN_RATE = 0.40  # realized win rate on 20c strikes (toxic but not omniscient)

# Spread config (defaults from predict/constants.move)
BASE_SPREAD = 0.01
MIN_SPREAD = 0.0025

# Mid-shift config
BALANCE = 10_000_000.0
DEFAULT_DEPTH_MULTIPLIER = 1.0
BALANCE_VARIANTS = [100_000_000.0, 400_000_000.0]  # runs main() once per balance


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
    max_payout_baseline = np.zeros(N_MINUTES)
    max_payout_shifted = np.zeros(N_MINUTES)

    aggregate = 0.0
    b_pnl = 0.0
    s_pnl = 0.0
    b_payout = 0.0  # max possible vault liability (= contracts sold × $1 payout)
    s_payout = 0.0

    for i, si in enumerate(state_idx):
        forward, svi = states[int(si)]
        strike = find_strike_for_target_p(forward, svi, TARGET_P)
        if strike is None:
            baseline_pnl[i] = b_pnl
            shifted_pnl[i] = s_pnl
            max_payout_baseline[i] = b_payout
            max_payout_shifted[i] = s_payout
            continue
        p = svi_up_price(strike, forward, svi)
        if p is None or p <= 0 or p >= 1:
            baseline_pnl[i] = b_pnl
            shifted_pnl[i] = s_pnl
            max_payout_baseline[i] = b_payout
            max_payout_shifted[i] = s_payout
            continue

        tte_ms = SEVEN_DAYS_MS * (N_MINUTES - i) / N_MINUTES
        tte_factor = math.sqrt(SEVEN_DAYS_MS / max(tte_ms, ONE_DAY_MS))
        raw_ratio = (aggregate * tte_factor) / (BALANCE * depth_multiplier)

        b_ask = baseline_up_ask(p)
        s_ask = shifted_up_ask(p, raw_ratio)

        # Trader takes the trade only if expected value is positive: WIN_RATE > ask.
        # Expected PnL per unit = WIN_RATE · (1 − ask) + (1 − WIN_RATE) · (−ask) = WIN_RATE − ask.
        # Contracts bought for a $TRADE_SIZE spend = TRADE_SIZE / ask. Max payout = 1 per contract.
        # Vault exposure gate: refuse the trade if cumulative max payout would
        # exceed the vault balance (vault cannot pay out more than it holds).
        b_new_contracts = TRADE_SIZE / b_ask
        if b_ask < WIN_RATE and b_payout + b_new_contracts <= BALANCE:
            b_pnl += TRADE_SIZE * (WIN_RATE - b_ask)
            b_payout += b_new_contracts
        s_new_contracts = TRADE_SIZE / s_ask
        if s_ask < WIN_RATE and s_payout + s_new_contracts <= BALANCE:
            s_pnl += TRADE_SIZE * (WIN_RATE - s_ask)
            s_payout += s_new_contracts
            aggregate += TRADE_SIZE * math.sqrt(p * (1 - p))

        baseline_pnl[i] = b_pnl
        shifted_pnl[i] = s_pnl
        raw_ratio_series[i] = raw_ratio
        ask_baseline_series[i] = b_ask
        ask_shifted_series[i] = s_ask
        max_payout_baseline[i] = b_payout
        max_payout_shifted[i] = s_payout

    return {
        "baseline_pnl": baseline_pnl,
        "shifted_pnl": shifted_pnl,
        "raw_ratio": raw_ratio_series,
        "ask_baseline": ask_baseline_series,
        "ask_shifted": ask_shifted_series,
        "max_payout_baseline": max_payout_baseline,
        "max_payout_shifted": max_payout_shifted,
    }


# === Charting ===

DAYS = np.arange(N_MINUTES) / (24 * 60)
DAY_TICKS = list(range(8))
DAY_LABELS = [f"Day {d}" for d in DAY_TICKS]


def _style_day_axis(ax) -> None:
    ax.set_xticks(DAY_TICKS)
    ax.set_xticklabels(DAY_LABELS)
    ax.set_xlim(0, 7)


def _suffix(balance: float) -> str:
    return f"_{int(balance / 1e6)}m"


def render_charts(states, balance: float) -> None:
    global BALANCE
    BALANCE = balance

    sweep_multipliers = [0.25, 0.5, 1.0, 2.0]
    sweep_colors = ["#1f77b4", "#2ca02c", "#9467bd", "#ff7f0e"]
    sweep_results = {dm: simulate(states, dm) for dm in sweep_multipliers}
    result = sweep_results[DEFAULT_DEPTH_MULTIPLIER]

    baseline_final = result["baseline_pnl"][-1]
    print(f"\n=== Balance ${balance:,.0f} ===")
    print(f"  baseline final toxic PnL: ${baseline_final:,.0f}")
    for dm in sweep_multipliers:
        shifted_final = sweep_results[dm]["shifted_pnl"][-1]
        reduction = (1 - shifted_final / baseline_final) if baseline_final > 0 else 0.0
        print(f"  shifted final (dm={dm}): ${shifted_final:,.0f}  "
              f"(reduction {reduction:.1%})")

    label = f"${int(balance / 1e6)}M vault"
    suffix = _suffix(balance)

    # Chart 1: baseline vs shifted cumulative PnL across depth_multipliers
    fig, ax = plt.subplots(figsize=(11, 6))
    ax.plot(DAYS, result["baseline_pnl"] / 1_000,
            label="Baseline (symmetric spread only)", color="#d62728", lw=2.2)
    for dm, color in zip(sweep_multipliers, sweep_colors):
        ax.plot(DAYS, sweep_results[dm]["shifted_pnl"] / 1_000,
                label=f"Mid shift (depth_multiplier={dm})",
                color=color, lw=1.8)
    ax.set_xlabel("Time elapsed (days)")
    ax.set_ylabel("Cumulative toxic trader PnL ($ thousands)")
    _style_day_axis(ax)
    ax.set_title(
        f"Toxic flow PnL — {label}, buy strike at p_up≈{TARGET_P}, "
        f"win rate {int(WIN_RATE * 100)}%, ${int(TRADE_SIZE):,}/trade"
    )
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out1 = OUT_DIR / f"toxic_flow_pnl{suffix}.png"
    fig.savefig(out1, dpi=150)
    plt.close(fig)
    print(f"  wrote {out1.relative_to(SCRIPT_DIR)}")

    # Chart 3: diagnostic — ask evolves vs. trader reservation, with max payout
    fig, ax = plt.subplots(figsize=(11, 6))
    ax.plot(DAYS, result["ask_baseline"], label="Baseline ask",
            color="#d62728", lw=1.5)
    ax.plot(DAYS, result["ask_shifted"], label="Shifted ask",
            color="#2ca02c", lw=1.5)
    ax.axhline(WIN_RATE, color="grey", lw=0.9, ls="--", alpha=0.7,
               label=f"Trader reservation = {WIN_RATE}")
    ax.set_xlabel("Time elapsed (days)")
    ax.set_ylabel("Ask price (UP at target strike)")
    _style_day_axis(ax)
    ax.set_ylim(0.1, 1.02)
    ax.set_title(f"UP ask over time — {label} — baseline vs. mid-shift defense")

    ax2 = ax.twinx()
    ax2.plot(DAYS, result["max_payout_baseline"] / 1e6,
             label="Baseline max payout (right axis)",
             color="#d62728", lw=1.2, ls=":")
    ax2.plot(DAYS, result["max_payout_shifted"] / 1e6,
             label="Shifted max payout (right axis)",
             color="#2ca02c", lw=1.2, ls=":")
    ax2.set_ylabel("Cumulative max vault payout ($M)")
    ax2.set_ylim(bottom=0)

    lines1, labels1 = ax.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax.legend(lines1 + lines2, labels1 + labels2, loc="upper left", fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out3 = OUT_DIR / f"toxic_flow_ask_trace{suffix}.png"
    fig.savefig(out3, dpi=150)
    plt.close(fig)
    print(f"  wrote {out3.relative_to(SCRIPT_DIR)}")

    # Chart 4: standalone max payout chart
    fig, ax = plt.subplots(figsize=(11, 6))
    ax.plot(DAYS, result["max_payout_baseline"] / 1e6,
            label="Baseline max payout", color="#d62728", lw=2)
    ax.plot(DAYS, result["max_payout_shifted"] / 1e6,
            label="Shifted max payout", color="#2ca02c", lw=2)
    ax.axhline(balance / 1e6, color="black", lw=1.0, ls="--", alpha=0.6,
               label=f"Vault balance = ${int(balance / 1e6)}M")
    ax.set_xlabel("Time elapsed (days)")
    ax.set_ylabel("Cumulative max vault payout ($M)")
    _style_day_axis(ax)
    ax.set_title(
        f"Max possible vault liability — {label}, "
        f"buy strike at p_up≈{TARGET_P}, win rate {int(WIN_RATE * 100)}%"
    )
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    out4 = OUT_DIR / f"toxic_flow_max_payout{suffix}.png"
    fig.savefig(out4, dpi=150)
    plt.close(fig)
    print(f"  wrote {out4.relative_to(SCRIPT_DIR)}")

    print(f"  baseline max payout: ${result['max_payout_baseline'][-1]:,.0f}")
    print(f"  shifted  max payout: ${result['max_payout_shifted'][-1]:,.0f}")


def main() -> None:
    states = parse_states(CSV_PATH)
    print(f"Parsed {len(states)} (forward, svi) snapshots from {CSV_PATH.name}")
    print(f"Running {N_MINUTES} ticks, trade size ${TRADE_SIZE:,.0f}, "
          f"win rate {int(WIN_RATE * 100)}%")

    for balance in BALANCE_VARIANTS:
        render_charts(states, balance)


if __name__ == "__main__":
    main()
