#!/usr/bin/env python3
"""Generate the bounded current-contract Predict parity scenario."""

from __future__ import annotations

import argparse
import csv
import random
from pathlib import Path
from typing import Any

import python_replay as replay

SCENARIO_COLUMNS = [
    "tx",
    "action",
    "spot",
    "forward",
    "a",
    "a_negative",
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
    "order_ref",
    "close_quantity",
    "replacement_order_ref",
    "amount",
    "shares",
    "min_output",
    "lp_ref",
    "settlement_price",
    "permissionless",
    "replay_timestamp_ms",
    "source_timestamp_ms",
    "price_source_timestamp_ms",
]

DATA_DIR = Path(__file__).with_name("data")
SCENARIO_CONFIG = DATA_DIR / "scenario_config.json"
GENERATED_DIR = DATA_DIR / "generated"
DEFAULT_RISK_FREE_RATE = 35_000_000
REQUIRED_SOURCE_COLUMNS = [
    "spot",
    "forward",
    "a",
    "b",
    "rho",
    "rho_negative",
    "m",
    "m_negative",
    "sigma",
    "svi_checkpoint_timestamp_ms",
    "price_checkpoint_timestamp_ms",
]


class GenerationError(RuntimeError):
    pass


def scenario_row(tx: int, action: str, **values: Any) -> dict[str, str]:
    row = {column: "" for column in SCENARIO_COLUMNS}
    row["tx"] = str(tx)
    row["action"] = action
    for key, value in values.items():
        if value is None:
            continue
        if isinstance(value, bool):
            row[key] = "true" if value else "false"
        else:
            row[key] = str(value)
    return row


def oracle_fields(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        "spot": snapshot["spot"],
        "forward": snapshot["forward"],
        "a": snapshot["a"],
        "a_negative": False,
        "b": snapshot["b"],
        "rho": snapshot["rho"],
        "rho_negative": snapshot["rho_negative"],
        "m": snapshot["m"],
        "m_negative": snapshot["m_negative"],
        "sigma": snapshot["sigma"],
        "risk_free_rate": DEFAULT_RISK_FREE_RATE,
        "replay_timestamp_ms": snapshot["price_checkpoint_timestamp_ms"],
        "source_timestamp_ms": snapshot["svi_checkpoint_timestamp_ms"],
        "price_source_timestamp_ms": snapshot["price_checkpoint_timestamp_ms"],
    }


def svi_for_replay(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        "a": snapshot["a"],
        "aNegative": False,
        "b": snapshot["b"],
        "rho": snapshot["rho"],
        "rhoNegative": snapshot["rho_negative"],
        "m": snapshot["m"],
        "mNegative": snapshot["m_negative"],
        "sigma": snapshot["sigma"],
        "riskFreeRate": DEFAULT_RISK_FREE_RATE,
    }


class Generator:
    def __init__(
        self,
        snapshots: list[dict[str, Any]],
        config: dict[str, Any],
        seed: int,
    ) -> None:
        self.snapshots = snapshots
        self.config = config
        self.rng = random.Random(seed)
        self.order_quantities: dict[str, int] = {}

    def snapshot(self, step: int) -> dict[str, Any]:
        index = round((step - 1) * (len(self.snapshots) - 1) / 19)
        return self.snapshots[index]

    def mint_row(
        self,
        step: int,
        order_ref: str,
        is_up: bool,
        *,
        strike: int | None = None,
    ) -> dict[str, str]:
        snapshot = self.snapshot(step)
        forward = replay.live_forward(snapshot["spot"], snapshot["forward"])
        if strike is None:
            for _ in range(32):
                offset_bps = self.rng.randint(-1_500, 1_500)
                candidate = replay.align_strike_to_tick(
                    forward * (10_000 + offset_bps) // 10_000
                )
                lower, higher = replay.binary_range_bounds(candidate, is_up)
                probability = replay.compute_range_price(
                    svi_for_replay(snapshot), forward, lower, higher
                )
                if replay.MIN_ENTRY_PROBABILITY <= probability <= replay.MAX_ENTRY_PROBABILITY:
                    strike = candidate
                    break
            else:
                raise GenerationError(f"could not sample an admissible strike for step {step}")
        else:
            strike = replay.align_strike_to_tick(strike)
            lower, higher = replay.binary_range_bounds(strike, is_up)
            probability = replay.compute_range_price(
                svi_for_replay(snapshot), forward, lower, higher
            )
            replay.assert_entry_probability_bounds(probability)

        generation = self.config["generation"]
        target_spend = self.rng.randint(
            int(generation["min_mint_spend"]),
            int(generation["max_mint_spend"]),
        )
        lots = max(1, target_spend * replay.FLOAT_SCALING // probability // replay.POSITION_LOT_SIZE)
        quantity = lots * replay.POSITION_LOT_SIZE
        # Several orders remain open concurrently before the first flush can
        # rebalance cash. Bound each position by one eighth of the configured
        # initial cash so scenario validity does not depend on sampled probability.
        cash_bound = int(self.config["market"]["initial_expiry_cash"]) // 8
        cash_bound = cash_bound // replay.POSITION_LOT_SIZE * replay.POSITION_LOT_SIZE
        quantity = min(quantity, cash_bound)
        if replay.deepbook_mul(probability, quantity) < replay.MIN_PREMIUM:
            quantity = replay.mul_div_round_up(
                replay.MIN_PREMIUM,
                replay.FLOAT_SCALING,
                probability,
            )
            quantity = (
                (quantity + replay.POSITION_LOT_SIZE - 1)
                // replay.POSITION_LOT_SIZE
                * replay.POSITION_LOT_SIZE
            )
        self.order_quantities[order_ref] = quantity
        return scenario_row(
            step,
            "mint",
            **oracle_fields(snapshot),
            strike=strike,
            is_up=is_up,
            quantity=quantity,
            order_ref=order_ref,
        )

    def settlement_mint_row(
        self,
        step: int,
        order_ref: str,
        *,
        winner: bool,
        settlement_price: int,
    ) -> dict[str, str]:
        snapshot = self.snapshot(step)
        forward = replay.live_forward(snapshot["spot"], snapshot["forward"])
        for _ in range(32):
            offset_bps = self.rng.randint(-1_500, 1_500)
            strike = replay.align_strike_to_tick(
                forward * (10_000 + offset_bps) // 10_000
            )
            settlement_above_strike = settlement_price > strike
            is_up = winner == settlement_above_strike
            lower, higher = replay.binary_range_bounds(strike, is_up)
            probability = replay.compute_range_price(
                svi_for_replay(snapshot), forward, lower, higher
            )
            if replay.MIN_ENTRY_PROBABILITY <= probability <= replay.MAX_ENTRY_PROBABILITY:
                return self.mint_row(
                    step,
                    order_ref,
                    is_up,
                    strike=strike,
                )
        outcome = "winner" if winner else "loser"
        raise GenerationError(
            f"could not sample an admissible settlement {outcome} for step {step}"
        )

    def generate(self) -> list[dict[str, str]]:
        generation = self.config["generation"]
        if generation["rows"] != 20:
            raise GenerationError("current parity scenario requires generation.rows=20")
        settlement_price = int(self.config["source"]["settlement_price"])

        rows = [
            self.mint_row(1, "o_up_partial", True),
            self.mint_row(2, "o_down", False),
        ]
        partial_quantity = self.order_quantities["o_up_partial"] // 2
        partial_quantity = max(
            replay.POSITION_LOT_SIZE,
            partial_quantity // replay.POSITION_LOT_SIZE * replay.POSITION_LOT_SIZE,
        )
        if partial_quantity >= self.order_quantities["o_up_partial"]:
            partial_quantity = self.order_quantities["o_up_partial"] - replay.POSITION_LOT_SIZE
        rows.extend(
            [
                scenario_row(
                    3,
                    "redeem_live",
                    **oracle_fields(self.snapshot(3)),
                    order_ref="o_up_partial",
                    close_quantity=partial_quantity,
                ),
                scenario_row(
                    4,
                    "request_supply",
                    amount=generation["supply_amount"],
                    min_output=0,
                    lp_ref="lp_supply_1",
                ),
                scenario_row(5, "flush", **oracle_fields(self.snapshot(5))),
                scenario_row(
                    6,
                    "request_withdraw",
                    shares=generation["withdraw_shares"],
                    min_output=0,
                    lp_ref="lp_withdraw_1",
                ),
                scenario_row(7, "flush", **oracle_fields(self.snapshot(7))),
                self.mint_row(8, "o_round_trip", bool(self.rng.randrange(2))),
                scenario_row(
                    9,
                    "redeem_live",
                    **oracle_fields(self.snapshot(9)),
                    order_ref="o_round_trip",
                    close_quantity=self.order_quantities["o_round_trip"],
                ),
                scenario_row(10, "rebalance_expiry_cash"),
                self.settlement_mint_row(
                    11,
                    "o_settle_winner",
                    winner=True,
                    settlement_price=settlement_price,
                ),
                self.settlement_mint_row(
                    12,
                    "o_settle_loser",
                    winner=False,
                    settlement_price=settlement_price,
                ),
                scenario_row(13, "settle", settlement_price=settlement_price),
                scenario_row(
                    14,
                    "redeem_settled",
                    order_ref="o_up_partial",
                    permissionless=False,
                ),
                scenario_row(
                    15,
                    "redeem_settled",
                    order_ref="o_down",
                    permissionless=True,
                ),
                scenario_row(
                    16,
                    "redeem_settled",
                    order_ref="o_settle_winner",
                    permissionless=False,
                ),
                scenario_row(
                    17,
                    "redeem_settled",
                    order_ref="o_settle_loser",
                    permissionless=True,
                ),
                scenario_row(18, "flush"),
                scenario_row(
                    19,
                    "request_supply",
                    amount=generation["supply_amount"],
                    min_output=0,
                    lp_ref="lp_supply_2",
                ),
                scenario_row(20, "flush"),
            ]
        )
        return rows


def source_bool(raw: dict[str, str], column: str, row_number: int) -> bool:
    value = raw[column]
    if value not in {"true", "false"}:
        raise GenerationError(
            f"source dataset row {row_number} has invalid {column}: {value!r}"
        )
    return value == "true"


def read_snapshots(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(newline="") as file:
        reader = csv.DictReader(file)
        fieldnames = reader.fieldnames or []
        if len(fieldnames) != len(set(fieldnames)):
            raise GenerationError("source dataset header has duplicate columns")
        missing = [column for column in REQUIRED_SOURCE_COLUMNS if column not in fieldnames]
        if missing:
            raise GenerationError(
                f"source dataset is missing required columns: {','.join(missing)}"
            )
        for row_number, raw in enumerate(reader, start=1):
            if None in raw or any(value is None for value in raw.values()):
                raise GenerationError(
                    f"source dataset row {row_number} does not match the source schema"
                )
            rows.append(
                {
                    "spot": int(raw["spot"]),
                    "forward": int(raw["forward"]),
                    "a": int(raw["a"]),
                    "b": int(raw["b"]),
                    "rho": int(raw["rho"]),
                    "rho_negative": source_bool(raw, "rho_negative", row_number),
                    "m": int(raw["m"]),
                    "m_negative": source_bool(raw, "m_negative", row_number),
                    "sigma": int(raw["sigma"]),
                    "svi_checkpoint_timestamp_ms": int(
                        raw["svi_checkpoint_timestamp_ms"]
                    ),
                    "price_checkpoint_timestamp_ms": int(
                        raw["price_checkpoint_timestamp_ms"]
                    ),
                }
            )
    if not rows:
        raise GenerationError(f"source dataset is empty: {path}")
    previous_svi = rows[0]["svi_checkpoint_timestamp_ms"]
    previous_price = rows[0]["price_checkpoint_timestamp_ms"]
    for index, row in enumerate(rows, start=1):
        svi_timestamp = row["svi_checkpoint_timestamp_ms"]
        price_timestamp = row["price_checkpoint_timestamp_ms"]
        if price_timestamp < svi_timestamp:
            raise GenerationError(
                f"source dataset has stale price at data row {index}: "
                f"{price_timestamp} < {svi_timestamp}"
            )
        if svi_timestamp < previous_svi or price_timestamp < previous_price:
            raise GenerationError(f"source dataset is not chronological at data row {index}")
        previous_svi = svi_timestamp
        previous_price = price_timestamp
    return rows


def write_scenario(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=SCENARIO_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)


def generate_scenario(
    source: Path,
    out: Path | None,
    source_config: dict[str, Any],
    seed: int,
) -> Path:
    rows = Generator(read_snapshots(source), source_config, seed).generate()
    out_path = out if out is not None else GENERATED_DIR / "parity_scenario.csv"
    write_scenario(out_path, rows)
    print(f"wrote {out_path} rows={len(rows)} seed={seed}")
    return out_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--config", type=Path, default=SCENARIO_CONFIG)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--seed", type=int, default=0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source_config = replay.load_scenario_config(args.config)
    replay.apply_scenario_config(source_config)
    generate_scenario(args.source, args.out, source_config, args.seed)


if __name__ == "__main__":
    main()
