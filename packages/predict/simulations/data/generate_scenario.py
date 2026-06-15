#!/usr/bin/env python3
"""Generate executable Predict simulation scenarios from oracle snapshots."""

from __future__ import annotations

import argparse
import csv
import secrets
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SIM_DIR = Path(__file__).resolve().parents[1]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

import python_replay as replay  # noqa: E402

SCENARIO_COLUMNS = [
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

SOURCE_DATASET = Path(__file__).with_name("scenario_dataset.csv")
SCENARIO_CONFIG = Path(__file__).with_name("scenario_config.json")
GENERATED_DIR = Path(__file__).with_name("generated")
DEFAULT_RISK_FREE_RATE = 35_000_000
MAX_ROW_ATTEMPTS = 100
DUSDC = 1_000_000
MANAGER_CASH_FLOOR = 50_000 * DUSDC


@dataclass(frozen=True)
class FlowConfig:
    rows: int
    mint_count: int
    redeem_count: int
    supply_count: int
    withdraw_count: int
    exact_time_ltv: bool
    min_quantity_lots: int
    max_quantity_lots: int
    min_mint_spend: int
    max_mint_spend: int
    min_supply: int
    max_supply: int


class GenerationError(RuntimeError):
    pass


class Generator:
    def __init__(self, snapshots: list[dict[str, Any]], config: FlowConfig, source_config: dict[str, Any]):
        self.snapshots = snapshots
        self.config = config
        if config.min_mint_spend <= 0 or config.max_mint_spend < config.min_mint_spend:
            raise GenerationError("mint spend range must be positive and ordered")
        self.expiry_ms = replay.config_source_value(source_config, "expiry_ms") if config.exact_time_ltv else None
        self.rng = secrets.SystemRandom()
        self.remaining = {
            "oracle_mint_ptb": config.mint_count,
            "redeem": config.redeem_count,
            "supply": config.supply_count,
            "withdraw": config.withdraw_count,
        }
        self.rows: list[dict[str, str]] = []
        self.order_quantities: dict[str, int] = {}
        self.redeemable_refs: list[str] = []
        self.lp_amounts: dict[str, int] = {}
        self.withdrawable_lp_refs: list[str] = []
        self.manager_balance = replay.MANAGER_SEED
        self.vault_idle_balance = replay.VAULT_SEED
        self.next_order = 1
        self.next_lp = 1

    def generate(self) -> list[dict[str, str]]:
        for index in range(self.config.rows):
            snapshot = self.snapshot_for_index(index)
            self.rows.append(self.generate_row(index + 1, snapshot))
        if any(value != 0 for value in self.remaining.values()):
            raise GenerationError(f"remaining action counts after generation: {self.remaining}")
        return self.rows

    def snapshot_for_index(self, index: int) -> dict[str, Any]:
        if self.config.rows == 1:
            return self.snapshots[0]
        source_index = round(index * (len(self.snapshots) - 1) / (self.config.rows - 1))
        return self.snapshots[source_index]

    def generate_row(self, tx: int, snapshot: dict[str, Any]) -> dict[str, str]:
        reasons: list[str] = []
        for _ in range(MAX_ROW_ATTEMPTS):
            action = self.choose_action(tx)
            try:
                if action == "oracle_mint_ptb":
                    return self.build_mint_row(tx, snapshot)
                if action == "redeem":
                    return with_oracle_fields(self.build_redeem_row(tx), snapshot)
                if action == "supply":
                    return with_oracle_fields(self.build_supply_row(tx), snapshot)
                return with_oracle_fields(self.build_withdraw_row(tx), snapshot)
            except GenerationError as error:
                reasons.append(str(error))
        raise GenerationError(
            "unable to generate legal row "
            f"tx={tx} remaining={self.remaining} "
            f"open_orders={len(self.redeemable_refs)} lp_refs={len(self.withdrawable_lp_refs)} "
            f"last_errors={reasons[-5:]}"
        )

    def choose_action(self, tx: int) -> str:
        if tx == 1:
            return "oracle_mint_ptb"

        weighted: list[tuple[str, int]] = []
        if self.remaining["oracle_mint_ptb"] > 0 and self.manager_balance > MANAGER_CASH_FLOOR:
            weighted.append(("oracle_mint_ptb", self.remaining["oracle_mint_ptb"]))
        if self.remaining["redeem"] > 0 and self.redeemable_refs:
            weighted.append(("redeem", self.remaining["redeem"]))
        if self.remaining["supply"] > 0:
            weighted.append(("supply", self.remaining["supply"]))
        if self.remaining["withdraw"] > 0 and self.withdrawable_lp_refs:
            weighted.append(("withdraw", self.remaining["withdraw"]))

        if not weighted:
            raise GenerationError(f"no eligible actions at tx={tx} remaining={self.remaining}")

        cursor = self.rng.randrange(sum(weight for _, weight in weighted))
        for action, weight in weighted:
            if cursor < weight:
                return action
            cursor -= weight
        raise AssertionError("unreachable weighted action selection")

    def build_mint_row(self, tx: int, snapshot: dict[str, Any]) -> dict[str, str]:
        if self.remaining["oracle_mint_ptb"] <= 0:
            raise GenerationError("mint count exhausted")

        svi = svi_for_replay(snapshot)
        forward = snapshot["forward"]
        # The raw `forward` is written to the CSV (localnet pushes it to
        # update_block_scholes_prices), but pricing must use the value the
        # contracts actually quote with: forward re-derived from the live Pyth
        # spot via pricing::load_live_pricer. Mirror that here so admission decisions
        # (tier, LTV, min principal) match localnet and the replay.
        pricing_forward = replay.live_forward(snapshot["spot"], forward)
        for _ in range(MAX_ROW_ATTEMPTS):
            strike = self.random_strike(forward)
            is_up = bool(self.rng.randrange(2))
            lower, higher = replay.binary_range_bounds(replay.align_strike_to_tick(strike), is_up)
            try:
                entry_probability = replay.compute_range_price(svi, pricing_forward, lower, higher)
                fee_rate = replay.assert_mint_fee_rate(entry_probability, self.fee_time_to_expiry(snapshot))
                leverage = self.random_leverage(entry_probability)
                quantity = self.quantity_for_spend(
                    self.random_mint_spend(),
                    entry_probability,
                    fee_rate,
                    leverage,
                )
                terms = replay.compute_mint_terms(entry_probability, quantity, leverage)
                replay.assert_mint_principal_above_min(terms["contribution"])
                open_floor_index = self.open_floor_index(snapshot)
                replay.assert_terminal_ltv_mint_allowed(
                    quantity,
                    leverage,
                    terms["floor_seed_amount"],
                    open_floor_index,
                )
                replay.assert_mint_above_liquidation_threshold(
                    entry_probability,
                    quantity,
                    leverage,
                    terms["floor_seed_amount"],
                    open_floor_index,
                )
            except ValueError:
                continue

            fee_amount = replay.deepbook_mul(fee_rate, quantity)
            cash_required = terms["contribution"] + fee_amount
            if self.manager_balance - cash_required < MANAGER_CASH_FLOOR:
                continue

            order_ref = f"o_{self.next_order:06d}"
            self.next_order += 1
            self.manager_balance -= cash_required
            self.remaining["oracle_mint_ptb"] -= 1
            self.order_quantities[order_ref] = quantity
            self.redeemable_refs.append(order_ref)

            return scenario_row(
                tx=tx,
                action="oracle_mint_ptb",
                spot=snapshot["spot"],
                forward=forward,
                a=snapshot["a"],
                b=snapshot["b"],
                rho=snapshot["rho"],
                rho_negative=snapshot["rho_negative"],
                m=snapshot["m"],
                m_negative=snapshot["m_negative"],
                sigma=snapshot["sigma"],
                risk_free_rate=DEFAULT_RISK_FREE_RATE,
                strike=strike,
                is_up=is_up,
                quantity=quantity,
                leverage=leverage,
                order_ref=order_ref,
                replay_timestamp_ms=snapshot["price_checkpoint_timestamp_ms"],
                source_timestamp_ms=snapshot["svi_checkpoint_timestamp_ms"],
                price_source_timestamp_ms=snapshot["price_checkpoint_timestamp_ms"],
            )

        raise GenerationError("could not find legal mint parameters")

    def open_floor_index(self, snapshot: dict[str, Any]) -> int:
        if self.expiry_ms is None:
            return replay.FLOAT_SCALING
        return replay.floor_index_at_ms(
            snapshot["price_checkpoint_timestamp_ms"],
            self.expiry_ms,
            replay.LEVERAGE_FLOOR_WINDOW_MS,
            replay.MAX_EXPIRY_FLOOR_PREMIUM,
        )

    def fee_time_to_expiry(self, snapshot: dict[str, Any]) -> int | None:
        if self.expiry_ms is None:
            return None
        return max(0, self.expiry_ms - snapshot["price_checkpoint_timestamp_ms"])

    def random_strike(self, forward: int) -> int:
        offset_bps = self.rng.randint(-2_500, 2_500)
        strike = forward * (10_000 + offset_bps) // 10_000
        strike = max(replay.ORACLE_MIN_STRIKE, min(replay.ORACLE_MAX_STRIKE, strike))
        return replay.align_strike_to_tick(strike)

    def max_leverage_for_probability(self, entry_probability: int) -> int:
        if entry_probability < replay.LEVERAGE_ONE_X_ONLY_PRICE_THRESHOLD:
            return replay.LEVERAGE_ONE_X
        if entry_probability < replay.LEVERAGE_TWO_X_MAX_PRICE_THRESHOLD:
            return replay.LEVERAGE_TWO_X
        return replay.LEVERAGE_THREE_X

    def random_leverage(self, entry_probability: int) -> int:
        max_leverage = self.max_leverage_for_probability(entry_probability)
        weighted = [
            (replay.LEVERAGE_ONE_X, 45),
            (replay.LEVERAGE_ONE_AND_HALF_X, 15),
            (replay.LEVERAGE_TWO_X, 15),
            (replay.LEVERAGE_TWO_AND_HALF_X, 12),
            (replay.LEVERAGE_THREE_X, 13),
        ]
        legal_weighted = [(leverage, weight) for leverage, weight in weighted if leverage <= max_leverage]
        cursor = self.rng.randrange(sum(weight for _, weight in legal_weighted))
        for leverage, weight in legal_weighted:
            if cursor < weight:
                return leverage
            cursor -= weight
        raise AssertionError("unreachable leverage selection")

    def random_mint_spend(self) -> int:
        return self.rng.randint(self.config.min_mint_spend, self.config.max_mint_spend)

    def quantity_for_spend(
        self,
        target_spend: int,
        entry_probability: int,
        fee_rate: int,
        leverage: int,
    ) -> int:
        lot_terms = replay.compute_mint_terms(entry_probability, replay.POSITION_LOT_SIZE, leverage)
        lot_fee = replay.deepbook_mul(fee_rate, replay.POSITION_LOT_SIZE)
        lot_cost = lot_terms["contribution"] + lot_fee
        if lot_cost <= 0:
            raise GenerationError("mint lot cost must be positive")
        lots = max(1, (target_spend + lot_cost // 2) // lot_cost)
        lots = max(self.config.min_quantity_lots, min(self.config.max_quantity_lots, lots))
        return lots * replay.POSITION_LOT_SIZE

    def build_redeem_row(self, tx: int) -> dict[str, str]:
        if self.remaining["redeem"] <= 0 or not self.redeemable_refs:
            raise GenerationError("redeem unavailable")

        idx = self.rng.randrange(len(self.redeemable_refs))
        order_ref = self.redeemable_refs.pop(idx)
        quantity = self.order_quantities.pop(order_ref)
        self.remaining["redeem"] -= 1
        return scenario_row(
            tx=tx,
            action="redeem",
            order_ref=order_ref,
            close_quantity=quantity,
        )

    def build_supply_row(self, tx: int) -> dict[str, str]:
        if self.remaining["supply"] <= 0:
            raise GenerationError("supply count exhausted")
        amount = self.rng.randint(self.config.min_supply // DUSDC, self.config.max_supply // DUSDC) * DUSDC
        lp_ref = f"lp_{self.next_lp:06d}"
        self.next_lp += 1
        self.lp_amounts[lp_ref] = amount
        self.withdrawable_lp_refs.append(lp_ref)
        self.vault_idle_balance += amount
        self.remaining["supply"] -= 1
        return scenario_row(tx=tx, action="supply", amount=amount, lp_ref=lp_ref)

    def build_withdraw_row(self, tx: int) -> dict[str, str]:
        if self.remaining["withdraw"] <= 0 or not self.withdrawable_lp_refs:
            raise GenerationError("withdraw unavailable")
        idx = self.rng.randrange(len(self.withdrawable_lp_refs))
        lp_ref = self.withdrawable_lp_refs[idx]
        amount = self.lp_amounts[lp_ref]
        if self.vault_idle_balance < amount:
            raise GenerationError("withdraw would exceed generated idle estimate")
        self.withdrawable_lp_refs.pop(idx)
        self.lp_amounts.pop(lp_ref)
        self.vault_idle_balance -= amount
        self.remaining["withdraw"] -= 1
        return scenario_row(tx=tx, action="withdraw", lp_ref=lp_ref)

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


def with_oracle_fields(row: dict[str, str], snapshot: dict[str, Any]) -> dict[str, str]:
    row.update(
        {
            "spot": str(snapshot["spot"]),
            "forward": str(snapshot["forward"]),
            "a": str(snapshot["a"]),
            "b": str(snapshot["b"]),
            "rho": str(snapshot["rho"]),
            "rho_negative": "true" if snapshot["rho_negative"] else "false",
            "m": str(snapshot["m"]),
            "m_negative": "true" if snapshot["m_negative"] else "false",
            "sigma": str(snapshot["sigma"]),
            "risk_free_rate": str(DEFAULT_RISK_FREE_RATE),
            "replay_timestamp_ms": str(snapshot["price_checkpoint_timestamp_ms"]),
            "source_timestamp_ms": str(snapshot["svi_checkpoint_timestamp_ms"]),
            "price_source_timestamp_ms": str(snapshot["price_checkpoint_timestamp_ms"]),
        }
    )
    return row


def svi_for_replay(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        "a": snapshot["a"],
        "b": snapshot["b"],
        "rho": snapshot["rho"],
        "rhoNegative": snapshot["rho_negative"],
        "m": snapshot["m"],
        "mNegative": snapshot["m_negative"],
        "sigma": snapshot["sigma"],
        "riskFreeRate": DEFAULT_RISK_FREE_RATE,
    }


def read_snapshots(path: Path) -> list[dict[str, Any]]:
    with path.open(newline="") as file:
        rows = []
        for raw in csv.DictReader(file):
            rows.append(
                {
                    "spot": int(raw["spot"]),
                    "forward": int(raw["forward"]),
                    "a": int(raw["a"]),
                    "b": int(raw["b"]),
                    "rho": int(raw["rho"]),
                    "rho_negative": raw["rho_negative"] == "true",
                    "m": int(raw["m"]),
                    "m_negative": raw["m_negative"] == "true",
                    "sigma": int(raw["sigma"]),
                    "svi_checkpoint_timestamp_ms": int(raw["svi_checkpoint_timestamp_ms"]),
                    "price_checkpoint_timestamp_ms": int(raw["price_checkpoint_timestamp_ms"]),
                }
            )
    if not rows:
        raise GenerationError(f"source dataset is empty: {path}")
    if rows[0]["price_checkpoint_timestamp_ms"] < rows[0]["svi_checkpoint_timestamp_ms"]:
        raise GenerationError(
            "source dataset has stale price at data row 1: "
            f"{rows[0]['price_checkpoint_timestamp_ms']} < {rows[0]['svi_checkpoint_timestamp_ms']}"
        )
    previous_timestamp = rows[0]["svi_checkpoint_timestamp_ms"]
    previous_replay_timestamp = rows[0]["price_checkpoint_timestamp_ms"]
    for index, row in enumerate(rows[1:], start=2):
        timestamp = row["svi_checkpoint_timestamp_ms"]
        replay_timestamp = row["price_checkpoint_timestamp_ms"]
        if row["price_checkpoint_timestamp_ms"] < timestamp:
            raise GenerationError(
                f"source dataset has stale price at data row {index}: "
                f"{row['price_checkpoint_timestamp_ms']} < {timestamp}"
            )
        if timestamp < previous_timestamp:
            raise GenerationError(
                f"source dataset is not chronological at data row {index}: "
                f"{timestamp} < {previous_timestamp}"
            )
        if replay_timestamp < previous_replay_timestamp:
            raise GenerationError(
                f"source dataset replay timestamps are not chronological at data row {index}: "
                f"{replay_timestamp} < {previous_replay_timestamp}"
            )
        previous_timestamp = timestamp
        previous_replay_timestamp = replay_timestamp
    return rows


def flow_counts(total_rows: int) -> tuple[int, int, int, int]:
    mint_count = total_rows * 60 // 100
    redeem_count = total_rows * 30 // 100
    withdraw_count = total_rows * 5 // 100
    supply_count = total_rows - mint_count - redeem_count - withdraw_count
    return mint_count, redeem_count, supply_count, withdraw_count


def generation_config_int(
    source_config: dict[str, Any],
    mode: str,
    key: str,
    default: int,
) -> int:
    value = source_config.get("generation", {}).get(mode, {}).get(key, default)
    return int(value)


def config_for_mode(mode: str, source_rows: int, source_config: dict[str, Any]) -> FlowConfig:
    if mode == "normal":
        mint_count, redeem_count, supply_count, withdraw_count = flow_counts(1_000)
        return FlowConfig(
            rows=1_000,
            mint_count=mint_count,
            redeem_count=redeem_count,
            supply_count=supply_count,
            withdraw_count=withdraw_count,
            exact_time_ltv=False,
            min_quantity_lots=100,
            max_quantity_lots=100_000,
            min_mint_spend=generation_config_int(source_config, mode, "min_mint_spend", 2 * DUSDC),
            max_mint_spend=generation_config_int(source_config, mode, "max_mint_spend", 20 * DUSDC),
            min_supply=500 * DUSDC,
            max_supply=5_000 * DUSDC,
        )
    if mode == "long":
        mint_count, redeem_count, supply_count, withdraw_count = flow_counts(source_rows)
        return FlowConfig(
            rows=source_rows,
            mint_count=mint_count,
            redeem_count=redeem_count,
            supply_count=supply_count,
            withdraw_count=withdraw_count,
            exact_time_ltv=True,
            min_quantity_lots=10,
            max_quantity_lots=250_000,
            min_mint_spend=generation_config_int(source_config, mode, "min_mint_spend", 5 * DUSDC),
            max_mint_spend=generation_config_int(source_config, mode, "max_mint_spend", 50 * DUSDC),
            min_supply=10 * DUSDC,
            max_supply=100 * DUSDC,
        )
    raise GenerationError(f"unsupported mode {mode}")


def output_path_for_mode(mode: str) -> Path:
    return GENERATED_DIR / f"{mode}_scenario.csv"


def write_scenario(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=SCENARIO_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)


def generate_mode(mode: str, source: Path, out: Path | None, source_config: dict[str, Any]) -> Path:
    snapshots = read_snapshots(source)
    # No grid to configure: the strike domain is absolute ticks (raw = tick*tick_size)
    # over a fixed domain known before any row runs, so there is nothing to center on
    # the first spot. Strikes are selected near the live forward in random_strike.
    generator = Generator(snapshots, config_for_mode(mode, len(snapshots), source_config), source_config)
    rows = generator.generate()
    out_path = out if out is not None else output_path_for_mode(mode)
    write_scenario(out_path, rows)
    print(f"wrote {out_path} rows={len(rows)}")
    return out_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("normal", "long"), default="normal")
    parser.add_argument("--source", type=Path, default=SOURCE_DATASET)
    parser.add_argument("--config", type=Path, default=SCENARIO_CONFIG)
    parser.add_argument("--out", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source_config = replay.load_scenario_config(args.config)
    replay.apply_scenario_config(source_config, long_run=args.mode == "long")
    generate_mode(args.mode, args.source, args.out, source_config)


if __name__ == "__main__":
    main()
