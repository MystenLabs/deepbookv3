#!/usr/bin/env python3
"""Visualize simulation results from a results.json file.

Usage:
    python visualize.py <path-to-results.json>
    python visualize.py runs/mar30-1137/artifacts/results.json
"""

import json
import os
import sys

import matplotlib.pyplot as plt
import numpy as np

MIST_PER_SUI = 1_000_000_000


def load_results(path: str) -> list[dict]:
    with open(path) as f:
        return json.load(f)


def to_sui(mist: int | float) -> float:
    return mist / MIST_PER_SUI


def print_gas_summary(txs: list[dict]):
    print("\n=== Gas Summary ===\n")
    fmt = "  {:<16s} {:>6s}  {:>12s}  {:>12s}  {:>12s}"
    print(fmt.format("Action", "Count", "Avg (SUI)", "Min (SUI)", "Max (SUI)"))
    print(fmt.format("------", "-----", "---------", "---------", "---------"))
    for action in ("update_prices", "update_svi", "mint"):
        rows = [t for t in txs if t["action"] == action]
        if not rows:
            continue
        gas = [t["gasTotal"] for t in rows]
        print(
            fmt.format(
                action,
                str(len(rows)),
                f"{to_sui(np.mean(gas)):.6f}",
                f"{to_sui(np.min(gas)):.6f}",
                f"{to_sui(np.max(gas)):.6f}",
            )
        )


def print_mint_gas_breakdown(mints: list[dict]):
    print("\n=== Mint Gas Breakdown ===\n")
    fmt = "  {:<18s} {:>12s}  {:>12s}  {:>12s}"
    print(fmt.format("Component", "Avg (SUI)", "Min (SUI)", "Max (SUI)"))
    print(fmt.format("---------", "---------", "---------", "---------"))
    for label, key in [
        ("Computation", "computationCost"),
        ("Storage", "storageCost"),
        ("Storage Rebate", "storageRebate"),
        ("Total", "gasTotal"),
    ]:
        values = [t[key] for t in mints]
        print(
            fmt.format(
                label,
                f"{to_sui(np.mean(values)):.6f}",
                f"{to_sui(np.min(values)):.6f}",
                f"{to_sui(np.max(values)):.6f}",
            )
        )


def print_latency_summary(txs: list[dict]):
    print("\n=== Latency ===\n")
    fmt = "  {:<16s} {:>6s}  {:>10s}  {:>10s}  {:>10s}"
    print(fmt.format("Action", "Count", "Avg (ms)", "Min (ms)", "Max (ms)"))
    print(fmt.format("------", "-----", "--------", "--------", "--------"))
    for action in ("update_prices", "update_svi", "mint"):
        rows = [t for t in txs if t["action"] == action]
        if not rows:
            continue
        wall = [t["wallMs"] for t in rows]
        print(
            fmt.format(
                action,
                str(len(rows)),
                f"{np.mean(wall):.0f}",
                f"{np.min(wall):.0f}",
                f"{np.max(wall):.0f}",
            )
        )


def plot_gas_over_time(mints: list[dict], out_dir: str):
    indices = list(range(1, len(mints) + 1))
    total_gas = [to_sui(m["gasTotal"]) for m in mints]
    comp_gas = [to_sui(m["computationCost"]) for m in mints]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), sharex=True)

    ax1.scatter(indices, total_gas, s=4, alpha=0.5, c="#2563eb")
    window = 50
    if len(total_gas) >= window:
        rolling = np.convolve(total_gas, np.ones(window) / window, mode="valid")
        ax1.plot(indices[window - 1 :], rolling, color="#dc2626", linewidth=1.5, label=f"{window}-mint avg")
        ax1.legend()
    ax1.set_ylabel("Total Gas (SUI)")
    ax1.set_title("Total Gas per Mint")
    ax1.grid(True, alpha=0.3)

    ax2.scatter(indices, comp_gas, s=4, alpha=0.5, c="#7c3aed")
    if len(comp_gas) >= window:
        rolling = np.convolve(comp_gas, np.ones(window) / window, mode="valid")
        ax2.plot(indices[window - 1 :], rolling, color="#dc2626", linewidth=1.5, label=f"{window}-mint avg")
        ax2.legend()
    ax2.set_xlabel("Mint #")
    ax2.set_ylabel("Computation Cost (SUI)")
    ax2.set_title("Computation Cost per Mint")
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    path = os.path.join(out_dir, "chart_gas_over_time.png")
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  Saved {path}")


def plot_gas_histogram(mints: list[dict], out_dir: str):
    total_gas = [to_sui(m["gasTotal"]) for m in mints]

    fig, ax = plt.subplots(figsize=(10, 5))
    ax.hist(total_gas, bins=50, color="#2563eb", edgecolor="white", linewidth=0.5)
    ax.set_xlabel("Total Gas (SUI)")
    ax.set_ylabel("Count")
    ax.set_title("Distribution of Mint Gas Cost")
    ax.axvline(np.mean(total_gas), color="#dc2626", linestyle="--", linewidth=1.5, label=f"Mean: {np.mean(total_gas):.4f}")
    ax.legend()
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    path = os.path.join(out_dir, "chart_gas_histogram.png")
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  Saved {path}")


def plot_gas_components_stacked(mints: list[dict], out_dir: str):
    indices = list(range(1, len(mints) + 1))
    comp = [to_sui(m["computationCost"]) for m in mints]
    net_storage = [to_sui(m["storageCost"] - m["storageRebate"]) for m in mints]

    fig, ax = plt.subplots(figsize=(12, 5))
    ax.stackplot(
        indices,
        comp,
        net_storage,
        labels=["Computation", "Net Storage"],
        colors=["#7c3aed", "#2563eb"],
        alpha=0.7,
    )
    ax.set_xlabel("Mint #")
    ax.set_ylabel("Gas (SUI)")
    ax.set_title("Gas Components per Mint (Stacked)")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    path = os.path.join(out_dir, "chart_gas_components.png")
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  Saved {path}")


def plot_latency_over_time(mints: list[dict], out_dir: str):
    indices = list(range(1, len(mints) + 1))
    wall = [m["wallMs"] for m in mints]

    fig, ax = plt.subplots(figsize=(12, 4))
    ax.scatter(indices, wall, s=4, alpha=0.5, c="#2563eb")
    window = 50
    if len(wall) >= window:
        rolling = np.convolve(wall, np.ones(window) / window, mode="valid")
        ax.plot(indices[window - 1 :], rolling, color="#dc2626", linewidth=1.5, label=f"{window}-mint avg")
        ax.legend()
    ax.set_xlabel("Mint #")
    ax.set_ylabel("Latency (ms)")
    ax.set_title("Mint Latency Over Time")
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    path = os.path.join(out_dir, "chart_latency.png")
    plt.savefig(path, dpi=150)
    plt.close()
    print(f"  Saved {path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python visualize.py <path-to-results.json>")
        sys.exit(1)

    results_path = sys.argv[1]
    if not os.path.isfile(results_path):
        print(f"ERROR: File not found: {results_path}")
        sys.exit(1)

    out_dir = os.path.dirname(os.path.abspath(results_path))
    txs = load_results(results_path)
    mints = [t for t in txs if t["action"] == "mint"]

    print_gas_summary(txs)
    print_mint_gas_breakdown(mints)
    print_latency_summary(txs)

    print("\n=== Charts ===\n")
    plot_gas_over_time(mints, out_dir)
    plot_gas_histogram(mints, out_dir)
    plot_gas_components_stacked(mints, out_dir)
    plot_latency_over_time(mints, out_dir)

    print(f"\nDone. {len(txs)} txs ({len(mints)} mints) analyzed.")


if __name__ == "__main__":
    main()
