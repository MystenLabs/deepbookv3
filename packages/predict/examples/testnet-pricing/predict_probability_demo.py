#!/usr/bin/env python3
"""Replay real mints from an earlier Predict package on Sui Testnet.

This is deliberately a pricing-only proof of concept. It reads oracle inputs and
mint terms, derives a probability from the live forward and SVI smile, and turns
that probability into a fair contract value. It does not model inventory,
hedging, pool state, fees, liquidation, settlement, or transaction execution.
It implements the sampled package's raw-SVI N(d2) formula, not the current
Predict source's SVI roll-down and digital-skew adjustment.

Run:
    python3 predict_probability_demo.py
    python3 predict_probability_demo.py --mint 0
    python3 predict_probability_demo.py --data testnet_pricing_sample.json
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


PRICE_SCALE = 1_000_000_000
PROBABILITY_SCALE = 1_000_000_000
QUOTE_SCALE = 1_000_000


def normal_cdf(value: float) -> float:
    """Standard normal cumulative distribution function."""
    return 0.5 * (1.0 + math.erf(value / math.sqrt(2.0)))


def live_forward(snapshot: dict[str, Any]) -> float:
    """Re-anchor the provider forward to the high-frequency Pyth spot.

    The provider spot/forward ratio is the expiry basis. Predict applies that
    basis to the latest Pyth spot:

        live_forward = pyth_spot * (bs_forward / bs_spot)
    """
    pyth_spot = int(snapshot["pyth_spot_1e9"]) / PRICE_SCALE
    provider_spot = int(snapshot["bs_spot_1e9"]) / PRICE_SCALE
    provider_forward = int(snapshot["bs_forward_1e9"]) / PRICE_SCALE
    if pyth_spot <= 0 or provider_spot <= 0 or provider_forward <= 0:
        raise ValueError("spot and forward inputs must be positive")
    return pyth_spot * provider_forward / provider_spot


def svi_total_variance(strike: float, forward: float, svi: dict[str, Any]) -> float:
    """Evaluate SVI total variance w(k) at one strike."""
    if strike <= 0 or forward <= 0:
        raise ValueError("strike and forward must be positive")

    a = int(svi["a_1e9"]) / PRICE_SCALE
    b = int(svi["b_1e9"]) / PRICE_SCALE
    rho = int(svi["rho_1e9"]) / PRICE_SCALE
    m = int(svi["m_1e9"]) / PRICE_SCALE
    sigma = int(svi["sigma_1e9"]) / PRICE_SCALE

    # Formula invariant: valid provider data must produce positive total
    # variance. Without it, sqrt(w) and the probability are undefined.
    k = math.log(strike / forward)
    centered = k - m
    variance = a + b * (rho * centered + math.sqrt(centered * centered + sigma * sigma))
    if variance <= 0:
        raise ValueError(f"SVI produced non-positive total variance: {variance}")
    return variance


def over_probability(strike: float, forward: float, svi: dict[str, Any]) -> float:
    """Return P(settlement > strike) for a cash-or-nothing digital."""
    variance = svi_total_variance(strike, forward, svi)
    k = math.log(strike / forward)
    d2 = -((k + variance / 2.0) / math.sqrt(variance))
    return normal_cdf(d2)


def range_probability(
    lower_strike: float,
    higher_strike: float,
    forward: float,
    svi: dict[str, Any],
) -> float:
    """Return P(lower < settlement <= higher)."""
    if lower_strike >= higher_strike:
        raise ValueError("lower strike must be below higher strike")
    probability = over_probability(lower_strike, forward, svi) - over_probability(
        higher_strike,
        forward,
        svi,
    )
    # Floating-point evaluation can miss the mathematical [0, 1] range by a
    # negligible amount in deep tails, so clamp only that representation noise.
    return min(1.0, max(0.0, probability))


def latest_snapshot(
    stream: list[dict[str, Any]],
    expiry_ms: int,
    mint_timestamp_ms: int,
) -> dict[str, Any]:
    """Find the latest sampled oracle state strictly earlier than a mint."""
    candidates = [
        snapshot
        for snapshot in stream
        if int(snapshot["expiry_ms"]) == expiry_ms
        and int(snapshot["update_timestamp_ms"]) < mint_timestamp_ms
    ]
    if not candidates:
        raise ValueError(
            f"no oracle snapshot before {mint_timestamp_ms} for expiry {expiry_ms}"
        )
    return max(candidates, key=lambda snapshot: int(snapshot["update_timestamp_ms"]))


def price_mint(stream: list[dict[str, Any]], mint: dict[str, Any]) -> dict[str, Any]:
    """Derive probability and fair values for one sampled mint."""
    snapshot = latest_snapshot(
        stream,
        int(mint["expiry_ms"]),
        int(mint["timestamp_ms"]),
    )
    forward = live_forward(snapshot)
    lower = int(mint["lower_strike_1e9"]) / PRICE_SCALE
    higher = int(mint["higher_strike_1e9"]) / PRICE_SCALE
    probability = range_probability(lower, higher, forward, snapshot["svi"])

    payout_usd = int(mint["quantity_1e6"]) / QUOTE_SCALE
    leverage = int(mint["leverage_1e9"]) / PRICE_SCALE
    if payout_usd <= 0 or leverage < 1:
        raise ValueError("payout must be positive and leverage must be at least 1x")

    full_contract_value = probability * payout_usd
    model_net_premium = full_contract_value / leverage
    onchain_probability = int(mint["onchain_entry_probability_1e9"]) / PROBABILITY_SCALE
    onchain_net_premium = int(mint["onchain_net_premium_1e6"]) / QUOTE_SCALE

    return {
        "mint_timestamp": mint["timestamp"],
        "expiry_ms": int(mint["expiry_ms"]),
        "range_usd": [lower, higher],
        "payout_usd": payout_usd,
        "leverage": leverage,
        "oracle_source_timestamp_ms": int(snapshot["source_timestamp_ms"]),
        "oracle_transaction_url": snapshot["transaction_url"],
        "mint_transaction_url": mint["transaction_url"],
        "live_forward_usd": forward,
        "model_probability": probability,
        "onchain_entry_probability": onchain_probability,
        "probability_delta_bps": (probability - onchain_probability) * 10_000,
        "full_contract_value_usd": full_contract_value,
        "model_net_premium_usd": model_net_premium,
        "onchain_net_premium_usd": onchain_net_premium,
        "premium_delta_usd": model_net_premium - onchain_net_premium,
    }


def print_results(results: list[dict[str, Any]]) -> None:
    header = (
        "#  mint time (UTC)          range (USD)           forward     "
        "model p   chain p   delta    payout     model $    chain $"
    )
    print(header)
    print("-" * len(header))
    for index, result in enumerate(results):
        lower, higher = result["range_usd"]
        print(
            f"{index:>2} "
            f"{result['mint_timestamp']:<24} "
            f"({lower:>9,.2f}, {higher:>9,.2f}] "
            f"{result['live_forward_usd']:>10,.2f} "
            f"{result['model_probability']:>8.4%} "
            f"{result['onchain_entry_probability']:>8.4%} "
            f"{result['probability_delta_bps']:>+7.2f}bp "
            f"${result['payout_usd']:>8,.2f} "
            f"${result['model_net_premium_usd']:>9,.4f} "
            f"${result['onchain_net_premium_usd']:>9,.4f}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data",
        type=Path,
        default=Path(__file__).with_name("testnet_pricing_sample.json"),
        help="fixture path (default: testnet_pricing_sample.json next to this script)",
    )
    parser.add_argument(
        "--mint",
        type=int,
        help="replay only this zero-based mint index",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print calculated results as JSON",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    with args.data.open(encoding="utf-8") as source:
        fixture = json.load(source)

    stream = fixture["oracle_stream"]
    mints = fixture["mints"]
    if fixture.get("synthetic") is not False or fixture.get("network") != "sui-testnet":
        raise ValueError("fixture must contain real Sui Testnet data")
    pricing_model = fixture.get("pricing_model", {})
    if (
        pricing_model.get("family") != "raw_svi_nd2"
        or pricing_model.get("uses_svi_roll_down") is not False
        or pricing_model.get("uses_svi_digital_skew_adjustment") is not False
    ):
        raise ValueError("fixture must describe the historical raw-SVI N(d2) model")
    if len(stream) != 1_000 or len(mints) != 10:
        raise ValueError(
            f"expected 1,000 oracle snapshots and 10 mints, got {len(stream)} and {len(mints)}"
        )

    if args.mint is not None:
        if args.mint < 0 or args.mint >= len(mints):
            raise ValueError(f"--mint must be between 0 and {len(mints) - 1}")
        mints = [mints[args.mint]]

    results = [price_mint(stream, mint) for mint in mints]
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print_results(results)
        print()
        print(
            "Model price is probability × fixed payout; net premium divides that value by the "
            "mint's leverage. Fees and all position/pool behavior are intentionally excluded."
        )


if __name__ == "__main__":
    main()
