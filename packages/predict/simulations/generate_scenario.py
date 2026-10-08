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
    "higher_strike",
    "quantity",
    "max_probability",
    "order_ref",
    "close_quantity",
    "replacement_order_ref",
    "commit_spot",
    "amount",
    "shares",
    "min_output",
    "lp_ref",
    "settlement_price",
    "replay_timestamp_ms",
    "source_timestamp_ms",
    "price_source_timestamp_ms",
]

DATA_DIR = Path(__file__).with_name("data")
SCENARIO_CONFIG = DATA_DIR / "scenario_config.json"
GENERATED_DIR = DATA_DIR / "generated"
DEFAULT_RISK_FREE_RATE = 35_000_000
# The limit-refund probe: an UP order quoted near the money at placement, capped this far above
# its placement probability, and committed at a spot that lifts its probability at τ at least
# this far above the cap, but not past `LIMIT_REFUND_MAX_TICK_PROBABILITY`, so it misses its own
# cap (reason 1) rather than the entry band. The margins absorb the SVI roll-down between
# generation, placement, and τ.
LIMIT_REFUND_PLACEMENT_BAND = (300_000_000, 600_000_000)
# A sampled strike's probability stays this far inside the entry band. A queued order is priced
# at its τ, after the SVI rolls down from its source time, which moves a tail probability by
# several percent of itself, so a strike sampled at the band's edge can be refunded on
# admission instead of filling.
SAMPLED_PROBABILITY_MARGIN = 40_000_000
STRIKE_SAMPLE_ATTEMPTS = 128
LIMIT_REFUND_CAP_MARGIN = 100_000_000
LIMIT_REFUND_MAX_TICK_PROBABILITY = 850_000_000
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
        "a_negative": snapshot["a_negative"],
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
        "aNegative": snapshot["a_negative"],
        "b": snapshot["b"],
        "rho": snapshot["rho"],
        "rhoNegative": snapshot["rho_negative"],
        "m": snapshot["m"],
        "mNegative": snapshot["m_negative"],
        "sigma": snapshot["sigma"],
        "riskFreeRate": DEFAULT_RISK_FREE_RATE,
    }


def sampled_probability_admissible(probability: int) -> bool:
    return (
        replay.MIN_ENTRY_PROBABILITY + SAMPLED_PROBABILITY_MARGIN
        <= probability
        <= replay.MAX_ENTRY_PROBABILITY - SAMPLED_PROBABILITY_MARGIN
    )


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

    def snapshot_index(self, step: int) -> int:
        last_step = self.config["generation"]["rows"] - 1
        return round((step - 1) * (len(self.snapshots) - 1) / last_step)

    def snapshot(self, step: int) -> dict[str, Any]:
        return self.snapshots[self.snapshot_index(step)]

    def commit_spot(self, step: int) -> int:
        # A queued order fills at the price for its τ, about a second after placement: the
        # source's next observation, or the same one at the end of the source.
        index = min(self.snapshot_index(step) + 1, len(self.snapshots) - 1)
        return self.snapshots[index]["spot"]

    def mint_row(
        self,
        step: int,
        order_ref: str,
        is_up: bool,
        *,
        strike: int | None = None,
        higher_strike: int | None = None,
        commit: bool = True,
        max_probability: int | None = None,
        commit_spot: int | None = None,
    ) -> dict[str, str]:
        snapshot = self.snapshot(step)
        forward = replay.live_forward(snapshot["spot"], snapshot["forward"])
        if strike is None:
            for _ in range(STRIKE_SAMPLE_ATTEMPTS):
                offset_bps = self.rng.randint(-1_500, 1_500)
                candidate = replay.align_strike_to_tick(
                    forward * (10_000 + offset_bps) // 10_000
                )
                lower, higher = replay.binary_range_bounds(candidate, is_up)
                probability = replay.compute_range_price(
                    svi_for_replay(snapshot), forward, lower, higher
                )
                if sampled_probability_admissible(probability):
                    strike = candidate
                    break
            else:
                raise GenerationError(f"could not sample an admissible strike for step {step}")
        else:
            strike = replay.align_strike_to_tick(strike)
            lower, higher = replay.binary_range_bounds(strike, is_up)
            if higher_strike is not None:
                higher = replay.align_strike_to_tick(higher_strike)
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
        if commit and commit_spot is None:
            commit_spot = self.commit_spot(step)
        return scenario_row(
            step,
            "mint",
            **oracle_fields(snapshot),
            strike=strike,
            is_up=is_up,
            higher_strike=higher_strike,
            quantity=quantity,
            max_probability=max_probability,
            order_ref=order_ref,
            commit_spot=commit_spot if commit else None,
        )

    def limit_refund_mint_row(self, step: int, order_ref: str) -> dict[str, str]:
        """An UP mint that passes its `max_probability` at placement and misses it at τ.

        The cap sits `LIMIT_REFUND_CAP_MARGIN` above the placement probability, and the
        committed spot is the smallest upward move that lifts the probability at least that far
        again above the cap while keeping it inside the entry band.
        """
        snapshot = self.snapshot(step)
        forward = replay.live_forward(snapshot["spot"], snapshot["forward"])
        svi = svi_for_replay(snapshot)
        low, high = LIMIT_REFUND_PLACEMENT_BAND
        for offset_bps in range(0, 1_001):
            strike = replay.align_strike_to_tick(forward * (10_000 + offset_bps) // 10_000)
            lower, higher = replay.binary_range_bounds(strike, True)
            placement = replay.compute_range_price(svi, forward, lower, higher)
            if low <= placement <= high:
                break
        else:
            raise GenerationError(f"could not place a near-the-money limit probe at step {step}")
        max_probability = placement + LIMIT_REFUND_CAP_MARGIN
        for move_bps in range(1, 2_001):
            commit_spot = snapshot["spot"] * (10_000 + move_bps) // 10_000
            tick_forward = replay.mul_div_round_down(commit_spot, snapshot["forward"], snapshot["spot"])
            at_tick = replay.compute_range_price(svi, tick_forward, lower, higher)
            if at_tick >= max_probability + LIMIT_REFUND_CAP_MARGIN:
                if at_tick > LIMIT_REFUND_MAX_TICK_PROBABILITY:
                    break
                return self.mint_row(
                    step,
                    order_ref,
                    True,
                    strike=strike,
                    max_probability=max_probability,
                    commit_spot=commit_spot,
                )
        raise GenerationError(f"could not price a limit refund at τ for step {step}")

    def finite_range_mint_row(self, step: int, order_ref: str) -> dict[str, str]:
        snapshot = self.snapshot(step)
        forward = replay.live_forward(snapshot["spot"], snapshot["forward"])
        svi = svi_for_replay(snapshot)
        for width_bps in (5, 10, 20, 50, 100, 200, 500, 1_000):
            lower = replay.align_strike_to_tick(forward * (10_000 - width_bps) // 10_000)
            higher = replay.align_strike_to_tick(forward * (10_000 + width_bps) // 10_000)
            if lower >= higher:
                continue
            prices = (
                replay.compute_up_price(svi, forward, lower),
                replay.compute_up_price(svi, forward, higher),
            )
            try:
                replay.assert_range_entry_bounds(prices)
            except ValueError:
                continue
            return self.mint_row(step, order_ref, True, strike=lower, higher_strike=higher)
        raise GenerationError(f"could not find an admissible finite range for step {step}")

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
        for _ in range(STRIKE_SAMPLE_ATTEMPTS):
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
            if sampled_probability_admissible(probability):
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
                    "redeem_open",
                    **oracle_fields(self.snapshot(3)),
                    order_ref="o_up_partial",
                    close_quantity=partial_quantity,
                    commit_spot=self.commit_spot(3),
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
                self.finite_range_mint_row(8, "o_round_trip"),
                scenario_row(
                    9,
                    "redeem_open",
                    **oracle_fields(self.snapshot(9)),
                    order_ref="o_round_trip",
                    close_quantity=self.order_quantities["o_round_trip"],
                    commit_spot=self.commit_spot(9),
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
                self.limit_refund_mint_row(13, "o_limit_refund"),
                # Never committed: it waits until settlement refunds it at its deadline.
                self.mint_row(14, "o_deadline_refund", False, commit=False),
                scenario_row(15, "settle", settlement_price=settlement_price),
                scenario_row(16, "settle_payout"),
                scenario_row(17, "rebalance_expiry_cash"),
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


def source_bool(
    raw: dict[str, str],
    column: str,
    row_number: int,
    *,
    default: bool | None = None,
) -> bool:
    value = raw.get(column)
    if value is None and default is not None:
        return default
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
                    "a_negative": source_bool(
                        raw,
                        "a_negative",
                        row_number,
                        default=False,
                    ),
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
