#!/usr/bin/env python3
"""A/B LP PnL gate for inventory skew (decisions.md revisit condition).

Builds a piled-inventory synthetic scenario, replays with gamma=0 (baseline)
and gamma>0 (skew on, rebates off), and reports terminal LP profit.

Rate form (locality only): gamma · (delta / net_payout) · p(1 − p).
`gamma` is the per-unit rate at maximum crowding and maximum uncertainty
(p = 1/2), times four — the uncapped peak is gamma/4. Recalibrate after any
formula change; do not carry values from the old u_after form.
"""

from __future__ import annotations

import csv
import io
import json
import sys
from pathlib import Path
from typing import Any

SIM_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIM_DIR))

import python_replay as replay

FLOAT = replay.FLOAT_SCALING
DUSDC = replay.DUSDC_DECIMALS
LOT = 10_000

SPOT = 75_850_000_000_000
FORWARD = 75_800_000_000_000
A, B, RHO, M, SIGMA = 171_736, 7_449_196, 243_059_022, 1_133_202, 15_731_214
STRIKE = 75_000_000_000_000
EXPIRY_MS = 1_779_955_200_000
SETTLEMENT_TS = EXPIRY_MS + 1
SETTLEMENT_PRICE = STRIKE + replay.ORACLE_TICK_SIZE

COLUMNS = [
    "tx",
    "action",
    "spot",
    "forward",
    "a",
    "b",
    "rho",
    "rho_negative",
    "m",
    "m_negative",
    "sigma",
    "risk_free_rate",
    "strike",
    "is_up",
    "quantity",
    "leverage",
    "order_ref",
    "close_quantity",
    "replacement_order_ref",
    "amount",
    "lp_ref",
    "replay_timestamp_ms",
    "source_timestamp_ms",
    "price_source_timestamp_ms",
]


def _blank() -> dict[str, str]:
    return {c: "" for c in COLUMNS}


def _oracle(row: dict[str, str], ts: int) -> None:
    row["spot"] = str(SPOT)
    row["forward"] = str(FORWARD)
    row["a"] = str(A)
    row["b"] = str(B)
    row["rho"] = str(RHO)
    row["rho_negative"] = "true"
    row["m"] = str(M)
    row["m_negative"] = "false"
    row["sigma"] = str(SIGMA)
    row["risk_free_rate"] = "35000000"
    row["replay_timestamp_ms"] = str(ts)
    row["source_timestamp_ms"] = str(ts)
    row["price_source_timestamp_ms"] = str(ts)


def build_piled_csv(*, mints: int = 40, redeem_every: int = 5) -> str:
    rows: list[dict[str, str]] = []
    open_refs: list[str] = []
    ts0 = EXPIRY_MS - 7 * 24 * 60 * 60 * 1000
    qty = 500 * LOT
    tx = 0
    for i in range(mints):
        tx += 1
        ts = ts0 + i * 60_000
        ref = f"o_{i + 1:06d}"
        row = _blank()
        row["tx"] = str(tx)
        row["action"] = "oracle_mint_ptb"
        _oracle(row, ts)
        row["strike"] = str(STRIKE)
        row["is_up"] = "true"
        row["quantity"] = str(qty)
        row["leverage"] = str(replay.LEVERAGE_ONE_X)
        row["order_ref"] = ref
        rows.append(row)
        open_refs.append(ref)
        if (i + 1) % redeem_every == 0 and open_refs:
            tx += 1
            victim = open_refs.pop(0)
            rrow = _blank()
            rrow["tx"] = str(tx)
            rrow["action"] = "redeem"
            _oracle(rrow, ts + 1)
            rrow["order_ref"] = victim
            rrow["close_quantity"] = str(qty)
            rows.append(rrow)

    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=COLUMNS)
    writer.writeheader()
    writer.writerows(rows)
    return buf.getvalue()


def run_once(*, gamma: int, rebate_enabled: bool) -> dict[str, Any]:
    replay.INVENTORY_SKEW_GAMMA = gamma
    replay.INVENTORY_SKEW_CAP = FLOAT
    replay.INVENTORY_SKEW_REBATE_ENABLED = rebate_enabled

    rows = replay.parse_scenario_text(build_piled_csv())
    canonical, _ = replay.replay(
        rows,
        collect_derived=False,
        exact_time=True,
        expiry_ms=EXPIRY_MS,
        settlement_price=SETTLEMENT_PRICE,
        settlement_timestamp_ms=SETTLEMENT_TS,
        terminal_closeout=True,
    )
    closeout = next(
        u
        for r in canonical["records"]
        for u in r["updates"]
        if u["type"] == "terminal_closeout"
    )
    skew_charged = sum(
        int(u.get("inventory_skew_charge", 0))
        for r in canonical["records"]
        for u in r["updates"]
        if u["type"] == "order_minted"
    )
    skew_rebated = sum(
        int(u.get("inventory_skew_rebate", 0))
        for r in canonical["records"]
        for u in r["updates"]
        if u["type"] == "live_order_redeemed"
    )
    return {
        "gamma": gamma,
        "rebate_enabled": rebate_enabled,
        "terminal_lp_profit": int(closeout["lp_profit"]),
        "terminal_protocol_profit": int(closeout["protocol_profit"]),
        "returned_pool_cash": int(closeout["returned_pool_cash"]),
        "skew_charged": skew_charged,
        "skew_rebated": skew_rebated,
        "net_skew_retained": skew_charged - skew_rebated,
        "mint_count": sum(
            1 for r in canonical["records"] for u in r["updates"] if u["type"] == "order_minted"
        ),
        "live_redeem_count": sum(
            1
            for r in canonical["records"]
            for u in r["updates"]
            if u["type"] == "live_order_redeemed"
        ),
    }


def main() -> None:
    baseline = run_once(gamma=0, rebate_enabled=False)
    # Sweep locality-only gammas. Peak uncapped rate is gamma/4, so 0.10 → 2.5%
    # of notional at coin-flip full crowding; 0.20 → 5%; 0.40 → 10%.
    candidates = [
        50_000_000,  # 0.05
        100_000_000,  # 0.10
        200_000_000,  # 0.20
        400_000_000,  # 0.40
    ]
    sweeps = [run_once(gamma=g, rebate_enabled=False) for g in candidates]
    # Prefer the smallest gamma that still lifts returned pool cash — keep the
    # armed intensity modest once load is no longer in the product.
    chosen = next(
        (
            s
            for s in sweeps
            if s["returned_pool_cash"] > baseline["returned_pool_cash"]
            or s["terminal_lp_profit"] > baseline["terminal_lp_profit"]
        ),
        sweeps[-1],
    )
    skewed = chosen
    # While net_losses_to_fill > 0, materialize_expiry_profit reports lp_profit=0
    # even as returned expiry cash replenishes the vault. Compare the cash that
    # actually returns to the pool — that is the LP-owned residual.
    delta_returned = skewed["returned_pool_cash"] - baseline["returned_pool_cash"]
    delta_lp_profit = skewed["terminal_lp_profit"] - baseline["terminal_lp_profit"]
    report = {
        "formula": "gamma * (delta / net_payout) * p * (1 - p)",
        "gamma_meaning": (
            "per-unit rate at maximum crowding and maximum uncertainty (p=1/2), "
            "times four; uncapped peak rate = gamma/4"
        ),
        "baseline": baseline,
        "sweep": sweeps,
        "skewed": skewed,
        "calibrated_gamma": skewed["gamma"],
        "delta_returned_pool_cash": delta_returned,
        "delta_returned_pool_cash_dusdc": delta_returned / DUSDC,
        "delta_lp_profit": delta_lp_profit,
        "helps_lps": delta_returned > 0 or delta_lp_profit > 0,
        "notes": (
            "Piled up-binary inventory on one strike; skew escrow residual returns "
            "to LPs at terminal closeout. Rebates disabled (ship default). "
            "Gate uses returned_pool_cash because terminal_lp_profit stays 0 while "
            "net_losses_to_fill absorbs recoveries. Gamma recalibrated for the "
            "locality-only rate (no u_after / capital-basis factor)."
        ),
    }
    out = SIM_DIR / "artifacts" / "inventory_skew_lp_pnl.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not report["helps_lps"]:
        print(
            "\nGATE FAILED: inventory skew did not improve LP vault recovery "
            "vs no-skew baseline. Per decisions.md, do not proceed to Move.",
            file=sys.stderr,
        )
        sys.exit(2)
    print(
        "\nGATE PASSED: skew increases returned pool cash "
        f"(+{delta_returned} raw) at gamma={skewed['gamma']}; "
        "locality-only calibration ok."
    )


if __name__ == "__main__":
    main()
