"""
Chart generation for simulation results.

Produces PNG charts that are overwritten on each run.
"""

import os
from datetime import datetime, timezone

import matplotlib.pyplot as plt

FLOAT_SCALING = 1_000_000_000
USDC_SCALING = 1_000_000


def _to_usdc(values: list[int]) -> list[float]:
    return [v / USDC_SCALING for v in values]


def _to_pct(num: list[int], den: list[int]) -> list[float]:
    return [
        (n / d * 100) if d > 0 else 0.0
        for n, d in zip(num, den)
    ]


def _to_timestamps(snapshots) -> list[datetime]:
    return [
        datetime.fromtimestamp(s.timestamp / 1000, tz=timezone.utc)
        for s in snapshots
    ]


def generate_charts(snapshots, output_dir: str):
    if not snapshots:
        print("No snapshots to chart.")
        return

    times = _to_timestamps(snapshots)
    balances = [s.vault_balance for s in snapshots]
    mtms = [s.treap_mtm for s in snapshots]
    max_payouts = [s.treap_max_payout for s in snapshots]

    _chart_vault_balances(times, balances, mtms, max_payouts, output_dir)
    _chart_utilization(times, balances, mtms, max_payouts, output_dir)
    _chart_vault_value(times, balances, mtms, output_dir)


def _chart_vault_balances(times, balances, mtms, max_payouts, output_dir):
    """Chart A: Vault balance, MTM, and max payout over time."""
    fig, ax = plt.subplots(figsize=(14, 6))

    ax.plot(times, _to_usdc(balances), label="Balance", linewidth=1.5)
    ax.plot(times, _to_usdc(mtms), label="MTM", linewidth=1.2)
    ax.plot(times, _to_usdc(max_payouts), label="Max Payout", linewidth=1.2, linestyle="--")

    ax.set_title("Vault Balances Over Time")
    ax.set_xlabel("Time")
    ax.set_ylabel("USDC")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.autofmt_xdate()
    fig.tight_layout()

    path = os.path.join(output_dir, "chart_vault_balances.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  Saved {path}")


def _chart_utilization(times, balances, mtms, max_payouts, output_dir):
    """Chart B: MTM/balance and max_payout/balance as percentages."""
    fig, ax = plt.subplots(figsize=(14, 6))

    mtm_pct = _to_pct(mtms, balances)
    mp_pct = _to_pct(max_payouts, balances)

    ax.plot(times, mtm_pct, label="MTM / Balance", linewidth=1.2)
    ax.plot(times, mp_pct, label="Max Payout / Balance", linewidth=1.2, linestyle="--")
    ax.axhline(y=80, color="red", linestyle=":", linewidth=1, label="80% Exposure Limit")

    ax.set_title("Vault Utilization Over Time")
    ax.set_xlabel("Time")
    ax.set_ylabel("%")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.autofmt_xdate()
    fig.tight_layout()

    path = os.path.join(output_dir, "chart_vault_utilization.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  Saved {path}")


def _chart_vault_value(times, balances, mtms, output_dir):
    """Chart C: Vault value (balance - MTM) over time."""
    fig, ax = plt.subplots(figsize=(14, 6))

    vault_values = [b - m for b, m in zip(balances, mtms)]
    ax.plot(times, _to_usdc(vault_values), label="Vault Value (Balance - MTM)", linewidth=1.5, color="green")

    ax.set_title("Vault Value Over Time")
    ax.set_xlabel("Time")
    ax.set_ylabel("USDC")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.autofmt_xdate()
    fig.tight_layout()

    path = os.path.join(output_dir, "chart_vault_value.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  Saved {path}")


# === Mint Analysis ===

# Price buckets: (label, min_pct, max_pct) where pct is mid_price as % of FLOAT_SCALING
PRICE_BUCKETS = [
    ("1-10c", 1, 10),
    ("10-25c", 10, 25),
    ("25-50c", 25, 50),
    ("50-75c", 50, 75),
    ("75-90c", 75, 90),
    ("90-99c", 90, 99),
]


def _bucket_for_price(mid_price: int) -> str | None:
    pct = mid_price * 100 // FLOAT_SCALING
    for label, lo, hi in PRICE_BUCKETS:
        if lo <= pct < hi:
            return label
    return None


def _mint_settled_itm(mint, settlement_price: int) -> bool:
    if mint.is_up:
        return settlement_price > mint.strike
    else:
        return settlement_price <= mint.strike


def generate_mint_analysis(mint_records, settlement_price: int, output_dir: str):
    if not mint_records:
        print("No mint records to analyze.")
        return

    _chart_pnl_by_bucket(mint_records, settlement_price, output_dir)
    _chart_pnl_by_direction(mint_records, settlement_price, output_dir)


def _chart_pnl_by_bucket(mint_records, settlement_price: int, output_dir: str):
    """Cumulative trader PnL over time, one line per price bucket."""
    fig, ax = plt.subplots(figsize=(14, 6))

    bucket_labels = [label for label, _, _ in PRICE_BUCKETS]
    cumulative_pnl = {label: 0 for label in bucket_labels}
    series = {label: [] for label in bucket_labels}
    totals = {label: 0 for label in bucket_labels}
    times = []

    for mint in mint_records:
        bucket = _bucket_for_price(mint.mid_price)
        if bucket is None:
            continue
        totals[bucket] += 1
        settlement = mint.qty if _mint_settled_itm(mint, settlement_price) else 0
        pnl = settlement - mint.cost
        cumulative_pnl[bucket] += pnl
        times.append(datetime.fromtimestamp(mint.timestamp / 1000, tz=timezone.utc))
        for label in bucket_labels:
            series[label].append(cumulative_pnl[label] / USDC_SCALING)

    for label, _, _ in PRICE_BUCKETS:
        if totals[label] > 0:
            ax.plot(times, series[label], label=f"{label} (n={totals[label]})", linewidth=1.2)

    ax.axhline(y=0, color="black", linestyle="-", linewidth=0.5)
    ax.set_title("Cumulative Trader PnL Over Time (by Price Bucket)")
    ax.set_xlabel("Mint Time")
    ax.set_ylabel("PnL (USDC)")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.autofmt_xdate()
    fig.tight_layout()

    path = os.path.join(output_dir, "chart_mint_pnl_by_bucket.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  Saved {path}")


def _chart_pnl_by_direction(mint_records, settlement_price: int, output_dir: str):
    """Cumulative trader PnL over time, UP vs DOWN."""
    fig, ax = plt.subplots(figsize=(14, 6))

    up_pnl = 0
    dn_pnl = 0
    up_total = 0
    dn_total = 0
    times = []
    up_series = []
    dn_series = []

    for mint in mint_records:
        settlement = mint.qty if _mint_settled_itm(mint, settlement_price) else 0
        pnl = settlement - mint.cost
        if mint.is_up:
            up_pnl += pnl
            up_total += 1
        else:
            dn_pnl += pnl
            dn_total += 1

        times.append(datetime.fromtimestamp(mint.timestamp / 1000, tz=timezone.utc))
        up_series.append(up_pnl / USDC_SCALING)
        dn_series.append(dn_pnl / USDC_SCALING)

    ax.plot(times, up_series, label=f"UP (n={up_total})", linewidth=1.2)
    ax.plot(times, dn_series, label=f"DOWN (n={dn_total})", linewidth=1.2)
    ax.axhline(y=0, color="black", linestyle="-", linewidth=0.5)

    ax.set_title("Cumulative Trader PnL Over Time (UP vs DOWN)")
    ax.set_xlabel("Mint Time")
    ax.set_ylabel("PnL (USDC)")
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.autofmt_xdate()
    fig.tight_layout()

    path = os.path.join(output_dir, "chart_mint_pnl_by_direction.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  Saved {path}")
