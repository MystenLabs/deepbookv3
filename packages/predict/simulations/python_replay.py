#!/usr/bin/env python3
"""Python economic replay for Predict simulation scenarios."""

from __future__ import annotations

import argparse
import csv
import json
from functools import lru_cache
from io import StringIO
from pathlib import Path
from typing import Any

from python_indexes.strike_payout_tree import StrikePayoutTree
from sim_artifacts import load_local_trace, write_json

FLOAT_SCALING = 1_000_000_000
POSITION_LOT_SIZE = 10_000
ECONOMIC_SCHEMA_VERSION = "predict_economic_v4"
LOCAL_TRACE_SCHEMA_VERSION = "predict_local_trace_v5"
EXPECTED_ACTION_SEQUENCE = (
    "mint",
    "mint",
    "redeem_live",
    "request_supply",
    "flush",
    "request_withdraw",
    "flush",
    "mint",
    "redeem_live",
    "rebalance_expiry_cash",
    "mint",
    "mint",
    "settle",
    "redeem_settled",
    "redeem_settled",
    "redeem_settled",
    "redeem_settled",
    "flush",
    "request_supply",
    "flush",
)
DEFAULT_SCENARIO_CONFIG_PATH = Path(__file__).with_name("data") / "scenario_config.json"
SCENARIO_CONFIG_SCHEMA: dict[str, Any] = {
    "schema_version": int,
    "source": {"settlement_price": str},
    "capital": {"manager_seed": str, "vault_seed": str},
    "generation": {
        "rows": int,
        "min_mint_spend": str,
        "max_mint_spend": str,
        "supply_amount": str,
        "withdraw_shares": str,
    },
    "market": {
        "cadence_id": int,
        "cadence_period_ms": str,
        "cadence_window_size": str,
        "tick_size": str,
        "admission_tick_size": str,
        "max_expiry_allocation": str,
        "initial_expiry_cash": str,
    },
    "protocol": {
        "base_fee": str,
        "min_fee": str,
        "min_entry_probability": str,
        "max_entry_probability": str,
        "protocol_reserve_profit_share": str,
        "expiry_fee_window_ms": str,
        "expiry_fee_max_multiplier": str,
        "backing_buffer_lambda": str,
        "inventory_impact_max_rate": str,
        "plp_supply_fee_rate": str,
        "plp_withdraw_fee_rate": str,
        "lp_request_limit_flush_attempts": str,
        "max_lp_pool_value": str,
    },
}
ORACLE_REFRESH_FIELDS = (
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
)
SCENARIO_COLUMNS = (
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
    "replay_timestamp_ms",
    "source_timestamp_ms",
    "price_source_timestamp_ms",
)
# Lightweight mirror initialized from the complete scenario_config.json contract.
BASE_FEE = 20_000_000
MIN_FEE = 5_000_000
MIN_ENTRY_PROBABILITY = 10_000_000
MAX_ENTRY_PROBABILITY = 990_000_000
# Absolute-tick strike domain (range_codec / constants.move): `raw_strike =
# tick * tick_size`, no centered grid. Finite ticks occupy 1..POS_INF_TICK-1; tick
# 0 is the neg-inf sentinel (lower side) and POS_INF_TICK is the pos-inf sentinel
# (higher side). The on-chain pos-inf raw strike sentinel is u64::MAX.
ORACLE_TICK_SIZE = FLOAT_SCALING
ADMISSION_TICK_SIZE = ORACLE_TICK_SIZE
TICK_BITS = 30
POS_INF_TICK = (1 << TICK_BITS) - 1
NEG_INF_STRIKE = 0
POS_INF_STRIKE = (1 << 64) - 1  # constants::pos_inf!() == u64::MAX
# The raw-strike bounds of the finite tick domain, used only to construct the
# payout tree (which is keyed by raw strikes = tick*tick_size). These are fixed
# constants now — there is NO centered grid derived from the first spot, so they
# are known before any row runs.
ORACLE_MIN_STRIKE = 1 * ORACLE_TICK_SIZE
ORACLE_MAX_STRIKE = (POS_INF_TICK - 1) * ORACLE_TICK_SIZE
MIN_PREMIUM = 1_000_000
DUSDC_DECIMALS = 1_000_000
VAULT_SEED = 500_000 * DUSDC_DECIMALS
MANAGER_SEED = 500_000 * DUSDC_DECIMALS
MIN_BOOTSTRAP_LIQUIDITY = 10 * DUSDC_DECIMALS
INITIAL_ACCOUNT_PLP_BALANCE = VAULT_SEED
INITIAL_TOTAL_PLP_SUPPLY = INITIAL_ACCOUNT_PLP_BALANCE + MIN_BOOTSTRAP_LIQUIDITY
INITIAL_EXPIRY_CASH = 50_000 * DUSDC_DECIMALS
EXPIRY_REBALANCE_PCT = 100_000_000
MAX_EXPIRY_ALLOCATION = 250_000 * DUSDC_DECIMALS
BACKING_BUFFER_LAMBDA = 250_000_000
PROTOCOL_RESERVE_PROFIT_SHARE = 400_000_000
EXPIRY_FEE_WINDOW_MS = 24 * 60 * 60 * 1000
EXPIRY_FEE_MAX_MULTIPLIER = 2_000_000_000
INVENTORY_IMPACT_MAX_RATE = 50_000_000
PLP_SUPPLY_FEE_RATE = 1_000_000
PLP_WITHDRAW_FEE_RATE = 2_000_000
LP_REQUEST_LIMIT_FLUSH_ATTEMPTS = 1
MAX_LP_POOL_VALUE = (1 << 64) - 1

F = 1_000_000_000
PRICE_CACHE_SIZE = 1_000_000
LN2_U128 = 693_147_180
INV_SQRT_2PI = 398_942_280
SMALL_THRESHOLD = 662_910_000
A0 = 2_235_252_035
A1 = 161_028_231_069
A2 = 1_067_689_485_460
A3 = 18_154_981_253_344
A4 = 65_682_338
B0 = 47_202_581_905
B1 = 976_098_551_738
B2 = 10_260_932_208_619
B3 = 45_507_789_335_027
MEDIUM_THRESHOLD = 5_656_854_249
C0 = 398_941_512
C1 = 8_883_149_794
C2 = 93_506_656_132
C3 = 597_270_276_395
C4 = 2_494_537_585_290
C5 = 6_848_190_450_536
C6 = 11_602_651_437_647
C7 = 9_842_714_838_384
C8 = 11
D0 = 22_266_688_044
D1 = 235_387_901_782
D2 = 1_519_377_599_408
D3 = 6_485_558_298_267
D4 = 18_615_571_640_885
D5 = 34_900_952_721_146
D6 = 38_912_003_286_093
D7 = 19_685_429_676_860
INV_3_U128 = 333_333_333
INV_5_U128 = 200_000_000
INV_7_U128 = 142_857_143
INV_9_U128 = 111_111_111
INV_11_U128 = 90_909_091
INV_13_U128 = 76_923_077


def load_scenario_config(path: Path | None = None) -> dict[str, Any]:
    config_path = path if path is not None else DEFAULT_SCENARIO_CONFIG_PATH
    config = json.loads(config_path.read_text())
    validate_scenario_config(config)
    return config


def _validate_config_object(
    value: Any,
    schema: dict[str, Any],
    path: str,
) -> None:
    if not isinstance(value, dict):
        raise ValueError(f"{path} must be an object")
    missing = sorted(set(schema) - set(value))
    unknown = sorted(set(value) - set(schema))
    if missing or unknown:
        details = []
        if missing:
            details.append(f"missing={','.join(missing)}")
        if unknown:
            details.append(f"unknown={','.join(unknown)}")
        raise ValueError(f"{path} schema mismatch; {'; '.join(details)}")
    for key, nested in schema.items():
        child = value[key]
        child_path = f"{path}.{key}"
        if isinstance(nested, dict):
            _validate_config_object(child, nested, child_path)
        elif key == "schema_version":
            if child != 2:
                raise ValueError(f"unsupported scenario config schema_version: {child}")
        elif nested is int:
            if isinstance(child, bool) or not isinstance(child, int) or child < 0:
                raise ValueError(f"{child_path} must be a non-negative integer")
        elif nested is str and (not isinstance(child, str) or not child.isdecimal()):
            raise ValueError(f"{child_path} must be a non-negative integer string")


def validate_scenario_config(config: Any) -> None:
    _validate_config_object(config, SCENARIO_CONFIG_SCHEMA, "scenario config")


def _config_int(config: dict[str, Any], section: str, key: str) -> int:
    return int(config[section][key])


def apply_scenario_config(config: dict[str, Any]) -> None:
    global VAULT_SEED
    global MANAGER_SEED
    global INITIAL_ACCOUNT_PLP_BALANCE
    global INITIAL_TOTAL_PLP_SUPPLY
    global BASE_FEE
    global MIN_FEE
    global MIN_ENTRY_PROBABILITY
    global MAX_ENTRY_PROBABILITY
    global PROTOCOL_RESERVE_PROFIT_SHARE
    global MAX_EXPIRY_ALLOCATION
    global INITIAL_EXPIRY_CASH
    global EXPIRY_FEE_WINDOW_MS
    global EXPIRY_FEE_MAX_MULTIPLIER
    global BACKING_BUFFER_LAMBDA
    global INVENTORY_IMPACT_MAX_RATE
    global PLP_SUPPLY_FEE_RATE
    global PLP_WITHDRAW_FEE_RATE
    global LP_REQUEST_LIMIT_FLUSH_ATTEMPTS
    global MAX_LP_POOL_VALUE
    global ORACLE_TICK_SIZE
    global ADMISSION_TICK_SIZE
    global ORACLE_MIN_STRIKE
    global ORACLE_MAX_STRIKE

    VAULT_SEED = int(config["capital"]["vault_seed"])
    MANAGER_SEED = int(config["capital"]["manager_seed"])

    BASE_FEE = _config_int(config, "protocol", "base_fee")
    MIN_FEE = _config_int(config, "protocol", "min_fee")
    MIN_ENTRY_PROBABILITY = _config_int(
        config,
        "protocol",
        "min_entry_probability",
    )
    MAX_ENTRY_PROBABILITY = _config_int(
        config,
        "protocol",
        "max_entry_probability",
    )
    PROTOCOL_RESERVE_PROFIT_SHARE = _config_int(
        config,
        "protocol",
        "protocol_reserve_profit_share",
    )
    MAX_EXPIRY_ALLOCATION = _config_int(
        config,
        "market",
        "max_expiry_allocation",
    )
    INITIAL_EXPIRY_CASH = _config_int(
        config,
        "market",
        "initial_expiry_cash",
    )
    BACKING_BUFFER_LAMBDA = _config_int(
        config,
        "protocol",
        "backing_buffer_lambda",
    )
    EXPIRY_FEE_WINDOW_MS = _config_int(
        config,
        "protocol",
        "expiry_fee_window_ms",
    )
    EXPIRY_FEE_MAX_MULTIPLIER = _config_int(
        config,
        "protocol",
        "expiry_fee_max_multiplier",
    )
    INVENTORY_IMPACT_MAX_RATE = _config_int(config, "protocol", "inventory_impact_max_rate")
    PLP_SUPPLY_FEE_RATE = _config_int(config, "protocol", "plp_supply_fee_rate")
    PLP_WITHDRAW_FEE_RATE = _config_int(config, "protocol", "plp_withdraw_fee_rate")
    LP_REQUEST_LIMIT_FLUSH_ATTEMPTS = _config_int(
        config,
        "protocol",
        "lp_request_limit_flush_attempts",
    )
    MAX_LP_POOL_VALUE = _config_int(config, "protocol", "max_lp_pool_value")
    ORACLE_TICK_SIZE = _config_int(config, "market", "tick_size")
    ADMISSION_TICK_SIZE = _config_int(config, "market", "admission_tick_size")
    ORACLE_MIN_STRIKE = ORACLE_TICK_SIZE
    ORACLE_MAX_STRIKE = (POS_INF_TICK - 1) * ORACLE_TICK_SIZE
    bootstrap_fee = (
        PLP_SUPPLY_FEE_RATE * VAULT_SEED + FLOAT_SCALING - 1
    ) // FLOAT_SCALING
    INITIAL_ACCOUNT_PLP_BALANCE = VAULT_SEED - bootstrap_fee
    INITIAL_TOTAL_PLP_SUPPLY = INITIAL_ACCOUNT_PLP_BALANCE + MIN_BOOTSTRAP_LIQUIDITY


def config_source_value(config: dict[str, Any], key: str) -> int:
    return int(config["source"][key])


class I64:
    def __init__(self, magnitude: int, is_negative: bool = False):
        self.magnitude = magnitude
        self.is_negative = bool(is_negative) if magnitude != 0 else False

    def neg(self) -> "I64":
        return I64(self.magnitude, not self.is_negative)

    def add(self, other: "I64") -> "I64":
        if self.is_negative == other.is_negative:
            return I64(self.magnitude + other.magnitude, self.is_negative)
        if self.magnitude >= other.magnitude:
            return I64(self.magnitude - other.magnitude, self.is_negative)
        return I64(other.magnitude - self.magnitude, other.is_negative)

    def sub(self, other: "I64") -> "I64":
        return self.add(other.neg())

    def mul_scaled(self, other: "I64") -> "I64":
        product = self.magnitude * other.magnitude // FLOAT_SCALING
        return I64(product, self.is_negative != other.is_negative)

    def div_scaled(self, other: "I64") -> "I64":
        quotient = self.magnitude * FLOAT_SCALING // other.magnitude
        return I64(quotient, self.is_negative != other.is_negative)

    def square_scaled(self) -> int:
        return self.mul_scaled(self).magnitude


def scenario_quantity_scale() -> int:
    return 1


def signed_svi_value(magnitude: int, is_negative: bool) -> str:
    if magnitude == 0:
        return "0"
    return f"-{magnitude}" if is_negative else str(magnitude)


def align_strike_to_tick(strike: int) -> int:
    # Snap a raw strike DOWN to its admission boundary. The absolute-tick domain has
    # no grid to center; admission alignment is just flooring to the configured
    # mint-entry multiple. The tick must land in the finite domain 1..POS_INF_TICK-1.
    if strike <= 0:
        raise ValueError("strike must be positive")
    aligned = (strike // ADMISSION_TICK_SIZE) * ADMISSION_TICK_SIZE
    tick = aligned // ORACLE_TICK_SIZE
    if tick <= 0 or tick >= POS_INF_TICK:
        raise ValueError(
            "strike tick outside the finite tick domain (1..POS_INF_TICK-1); "
            "raise the oracle tick size to cover a higher strike"
        )
    return aligned


def binary_range_bounds(strike: int, is_up: bool) -> tuple[int, int]:
    # Raw-strike binary range. UP -> (strike, +inf); DOWN -> (-inf, strike).
    if is_up:
        return strike, POS_INF_STRIKE
    return NEG_INF_STRIKE, strike


def binary_range_ticks(strike: int, is_up: bool) -> tuple[int, int]:
    # Tick range for a binary order. UP (strike, +inf) -> (strike/tick, POS_INF_TICK);
    # DOWN (-inf, strike) -> (0 = neg-inf, strike/tick). Mirrors range_codec.
    tick = strike // ORACLE_TICK_SIZE
    if is_up:
        return tick, POS_INF_TICK
    return 0, tick


def strikes_from_ticks(lower_tick: int, higher_tick: int) -> tuple[int, int]:
    # Tick -> raw strike with open-ended sentinels (mirrors range_codec::strike_from_tick per boundary):
    # lower_tick 0 -> NEG_INF_STRIKE; higher_tick POS_INF_TICK -> POS_INF_STRIKE.
    lower = NEG_INF_STRIKE if lower_tick == 0 else lower_tick * ORACLE_TICK_SIZE
    higher = POS_INF_STRIKE if higher_tick == POS_INF_TICK else higher_tick * ORACLE_TICK_SIZE
    return lower, higher


def parse_mint_quantity(quantity: int, line_number: int, field: str = "quantity") -> int:
    lots = quantity // POSITION_LOT_SIZE
    if lots <= 0:
        raise ValueError(f"Scenario line {line_number}: {field} must be at least one position lot")
    if quantity % POSITION_LOT_SIZE != 0:
        raise ValueError(f"Scenario line {line_number}: {field} must be a multiple of {POSITION_LOT_SIZE}")
    return quantity


def _required(row: dict[str, str], field: str, line_number: int) -> str:
    value = row.get(field, "")
    if value == "":
        raise ValueError(f"Scenario line {line_number}: missing {field}")
    return value


def _uint(row: dict[str, str], field: str, line_number: int) -> int:
    value = _required(row, field, line_number)
    if not value.isdigit():
        raise ValueError(
            f'Scenario line {line_number}: expected {field} to be an unsigned integer, got "{value}"'
        )
    return int(value)


def _optional_uint(row: dict[str, str], field: str, line_number: int, default: int) -> int:
    value = row.get(field, "")
    if value == "":
        return default
    if not value.isdigit():
        raise ValueError(
            f'Scenario line {line_number}: expected {field} to be an unsigned integer, got "{value}"'
        )
    return int(value)


def _optional_str(row: dict[str, str], field: str) -> str | None:
    value = row.get(field, "")
    return None if value == "" else value


def _timestamps(row: dict[str, str], line_number: int) -> dict[str, int]:
    return {
        "replayTimestampMs": _uint(row, "replay_timestamp_ms", line_number),
        "sourceTimestampMs": _uint(row, "source_timestamp_ms", line_number),
        "priceSourceTimestampMs": _uint(row, "price_source_timestamp_ms", line_number),
    }


def _ref(row: dict[str, str], field: str, line_number: int) -> str:
    value = _required(row, field, line_number)
    if not value[0].isalpha() or any(not (ch.isalnum() or ch in "_-") for ch in value):
        raise ValueError(f'Scenario line {line_number}: invalid {field} "{value}"')
    return value


def _bool(row: dict[str, str], field: str, line_number: int) -> bool:
    value = _required(row, field, line_number)
    if value not in ("true", "false"):
        raise ValueError(f'Scenario line {line_number}: expected {field} to be true/false, got "{value}"')
    return value == "true"


def _optional_bool(row: dict[str, str], field: str, line_number: int, default: bool = False) -> bool:
    value = row.get(field, "")
    if value == "":
        return default
    if value not in ("true", "false"):
        raise ValueError(f'Scenario line {line_number}: expected {field} to be true/false, got "{value}"')
    return value == "true"


def _oracle_values(row: dict[str, str], line_number: int) -> dict[str, Any]:
    present = [field for field in ORACLE_REFRESH_FIELDS if row.get(field, "") != ""]
    if len(present) != len(ORACLE_REFRESH_FIELDS):
        raise ValueError(f"Scenario line {line_number}: oracle refresh fields must all be present")
    return {
        "spot": _uint(row, "spot", line_number),
        "forward": _uint(row, "forward", line_number),
        "a": _uint(row, "a", line_number),
        "aNegative": _bool(row, "a_negative", line_number),
        "b": _uint(row, "b", line_number),
        "rho": _uint(row, "rho", line_number),
        "rhoNegative": _bool(row, "rho_negative", line_number),
        "m": _uint(row, "m", line_number),
        "mNegative": _bool(row, "m_negative", line_number),
        "sigma": _uint(row, "sigma", line_number),
        "riskFreeRate": _uint(row, "risk_free_rate", line_number),
    }


def _optional_oracle_values(row: dict[str, str], line_number: int) -> dict[str, Any] | None:
    present = [field for field in ORACLE_REFRESH_FIELDS if row.get(field, "") != ""]
    if not present:
        return None
    return _oracle_values(row, line_number)


def parse_scenario_text(text: str) -> list[dict[str, Any]]:
    reader = csv.DictReader(StringIO(text.replace("\r", "")))
    if tuple(reader.fieldnames or ()) != SCENARIO_COLUMNS:
        raise ValueError(f"scenario header does not match schema: expected {','.join(SCENARIO_COLUMNS)}")
    rows: list[dict[str, Any]] = []
    last_tx = 0
    for index, raw in enumerate(reader, start=2):
        row = {key: (value or "").strip() for key, value in raw.items() if key is not None}
        tx = _uint(row, "tx", index)
        if tx <= last_tx:
            raise ValueError(f"Scenario line {index}: tx values must be strictly increasing")
        last_tx = tx
        action = _required(row, "action", index)
        if action == "mint":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    **_timestamps(row, index),
                    **_oracle_values(row, index),
                    "strike": _uint(row, "strike", index),
                    "isUp": _bool(row, "is_up", index),
                    "quantity": parse_mint_quantity(_uint(row, "quantity", index), index),
                    "orderRef": _ref(row, "order_ref", index),
                }
            )
        elif action == "redeem_live":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    **_timestamps(row, index),
                    "oracleRefresh": _oracle_values(row, index),
                    "orderRef": _ref(row, "order_ref", index),
                    "closeQuantity": parse_mint_quantity(_uint(row, "close_quantity", index), index, "close_quantity"),
                    "replacementOrderRef": _optional_str(row, "replacement_order_ref"),
                }
            )
        elif action == "request_supply":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    "amount": _uint(row, "amount", index),
                    "minOutput": _uint(row, "min_output", index),
                    "lpRef": _ref(row, "lp_ref", index),
                }
            )
        elif action == "request_withdraw":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    "shares": _uint(row, "shares", index),
                    "minOutput": _uint(row, "min_output", index),
                    "lpRef": _ref(row, "lp_ref", index),
                }
            )
        elif action == "flush":
            oracle = _optional_oracle_values(row, index)
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    "oracleRefresh": oracle,
                    **(_timestamps(row, index) if oracle is not None else {}),
                }
            )
        elif action == "rebalance_expiry_cash":
            rows.append({"action": action, "lineNumber": index, "step": tx})
        elif action == "settle":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    "settlementPrice": _uint(row, "settlement_price", index),
                }
            )
        elif action == "redeem_settled":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    "orderRef": _ref(row, "order_ref", index),
                }
            )
        else:
            raise ValueError(f'Scenario line {index}: unsupported action "{action}"')
    return rows


def parse_scenario(path: Path) -> list[dict[str, Any]]:
    return parse_scenario_text(path.read_text())


def validate_complete_scenario(rows: list[dict[str, Any]]) -> None:
    if len(rows) != len(EXPECTED_ACTION_SEQUENCE):
        raise ValueError(
            f"scenario must contain exactly {len(EXPECTED_ACTION_SEQUENCE)} steps, got {len(rows)}"
        )
    for index, (row, expected_action) in enumerate(
        zip(rows, EXPECTED_ACTION_SEQUENCE, strict=True), start=1
    ):
        if row["step"] != index:
            raise ValueError(f"scenario step {index} must use tx {index}, got {row['step']}")
        if row["action"] != expected_action:
            raise ValueError(
                f"scenario step {index} must be {expected_action}, got {row['action']}"
            )


def deepbook_div(x: int, y: int) -> int:
    return x * FLOAT_SCALING // y


def deepbook_mul(x: int, y: int) -> int:
    return x * y // FLOAT_SCALING


def mul_div_round_down(a: int, b: int, c: int) -> int:
    return a * b // c


def mul_div_round_up(a: int, b: int, c: int) -> int:
    return (a * b + c - 1) // c


def live_forward(spot: int, forward: int) -> int:
    # Mirror pricing::load_live_pricer's single
    # mul_div_down(pyth_spot, bs_forward, bs_spot). The localnet parity flow
    # pushes identical Pyth and Block Scholes spots in the same PTB, so the spot
    # terms cancel exactly and the on-chain forward is the supplied BS forward.
    if spot <= 0:
        raise ValueError("live forward requires a positive spot")
    return forward


def mul_scaled_u128(x: int, y: int) -> int:
    return x * y // F


def normalize_ln(x: int) -> tuple[int, int]:
    y = x
    n = 0
    if y >> 32 >= FLOAT_SCALING:
        y >>= 32
        n += 32
    if y >> 16 >= FLOAT_SCALING:
        y >>= 16
        n += 16
    if y >> 8 >= FLOAT_SCALING:
        y >>= 8
        n += 8
    if y >> 4 >= FLOAT_SCALING:
        y >>= 4
        n += 4
    if y >> 2 >= FLOAT_SCALING:
        y >>= 2
        n += 2
    if y >> 1 >= FLOAT_SCALING:
        y >>= 1
        n += 1
    return y, n


def ln_u128(y: int, n: int) -> int:
    z = (y - F) * F // (y + F)
    w = mul_scaled_u128(z, z)
    h = mul_scaled_u128(w, INV_13_U128)
    h = mul_scaled_u128(INV_11_U128 + h, w)
    h = mul_scaled_u128(INV_9_U128 + h, w)
    h = mul_scaled_u128(INV_7_U128 + h, w)
    h = mul_scaled_u128(INV_5_U128 + h, w)
    h = mul_scaled_u128(INV_3_U128 + h, w)
    ln_y = mul_scaled_u128(mul_scaled_u128(2 * F, z), F + h)
    return n * LN2_U128 + ln_y


def ln_fixed(x: int) -> I64:
    if x == FLOAT_SCALING:
        return I64(0)
    if x < FLOAT_SCALING:
        inv = F * F // x
        return ln_fixed(inv).neg()
    y, n = normalize_ln(x)
    return I64(ln_u128(y, n))


def exp_series_u128(r: int) -> int:
    total = F
    term = F
    for k in range(1, 13):
        term = term * r // (k * F)
        if term == 0:
            break
        total += term
    return total


def exp_u128(r: int, n: int, x_negative: bool) -> int:
    exp_r = exp_series_u128(r)
    if x_negative:
        result = F * F // exp_r
        if n >= 32:
            result >>= 32
            if result == 0:
                return 0
            n -= 32
        if n >= 16:
            result >>= 16
            if result == 0:
                return 0
            n -= 16
        if n >= 8:
            result >>= 8
            if result == 0:
                return 0
            n -= 8
        if n >= 4:
            result >>= 4
            if result == 0:
                return 0
            n -= 4
        if n >= 2:
            result >>= 2
            if result == 0:
                return 0
            n -= 2
        if n >= 1:
            result >>= 1
        return result

    result = exp_r
    if n >= 32:
        result <<= 32
        n -= 32
    if n >= 16:
        result <<= 16
        n -= 16
    if n >= 8:
        result <<= 8
        n -= 8
    if n >= 4:
        result <<= 4
        n -= 4
    if n >= 2:
        result <<= 2
        n -= 2
    if n >= 1:
        result <<= 1
    return result


def sqrt_initial_guess_u128(x: int) -> int:
    bits = 0
    val = x
    if val >= 1 << 64:
        val >>= 64
        bits += 64
    if val >= 1 << 32:
        val >>= 32
        bits += 32
    if val >= 1 << 16:
        val >>= 16
        bits += 16
    if val >= 1 << 8:
        val >>= 8
        bits += 8
    if val >= 1 << 4:
        val >>= 4
        bits += 4
    if val >= 1 << 2:
        val >>= 2
        bits += 2
    if val >= 1 << 1:
        bits += 1
    return 1 << ((bits + 1) // 2)


def sqrt_u128(x: int) -> int:
    if x == 0:
        return 0
    if x < 4:
        return 1
    g = sqrt_initial_guess_u128(x)
    for _ in range(7):
        g = (g + x // g) // 2
    if g * g > x:
        g -= 1
    return g


def sqrt_down(x: int) -> int:
    return sqrt_u128(x * F)


def normal_cdf_u128(x: int, x_negative: bool) -> int:
    if x < SMALL_THRESHOLD:
        xsq = x * x // F
        xnum = A4 * xsq // F
        xden = xsq
        xnum = (xnum + A0) * xsq // F
        xden = (xden + B0) * xsq // F
        xnum = (xnum + A1) * xsq // F
        xden = (xden + B1) * xsq // F
        xnum = (xnum + A2) * xsq // F
        xden = (xden + B2) * xsq // F
        ratio = (xnum + A3) * F // (xden + B3)
        term = x * ratio // F
        return F // 2 - term if x_negative else F // 2 + term
    if x < MEDIUM_THRESHOLD:
        xnum = C8 * x // F
        xden = x
        xnum = (xnum + C0) * x // F
        xden = (xden + D0) * x // F
        xnum = (xnum + C1) * x // F
        xden = (xden + D1) * x // F
        xnum = (xnum + C2) * x // F
        xden = (xden + D2) * x // F
        xnum = (xnum + C3) * x // F
        xden = (xden + D3) * x // F
        xnum = (xnum + C4) * x // F
        xden = (xden + D4) * x // F
        xnum = (xnum + C5) * x // F
        xden = (xden + D5) * x // F
        xnum = (xnum + C6) * x // F
        xden = (xden + D6) * x // F
        rational = (xnum + C7) * F // (xden + D7)
        x_sq_half = x * x // (F * 2)
        n = x_sq_half // LN2_U128
        r = x_sq_half - n * LN2_U128
        exp_val = exp_u128(r, n, True)
        complement = exp_val * rational // F
        return complement if x_negative else F - complement
    return 0 if x_negative else F


def normal_cdf(value: I64) -> int:
    if value.magnitude > 8 * FLOAT_SCALING:
        return 0 if value.is_negative else FLOAT_SCALING
    return normal_cdf_u128(value.magnitude, value.is_negative)


def normal_pdf(value: I64) -> int:
    x = value.magnitude
    if x > 8 * FLOAT_SCALING:
        return 0
    x_sq_half = x * x // (2 * FLOAT_SCALING)
    n = x_sq_half // LN2_U128
    r = x_sq_half - n * LN2_U128
    return deepbook_mul(exp_u128(r, n, True), INV_SQRT_2PI)


def variance_sqrt_and_d2(a: I64, b: int, inner: int, k: I64) -> tuple[int, I64]:
    """Total variance, sqrt(w) and d2 at u128/1e18, mirroring pricing.move.

    `a` and `b` arrive already rolled down and 1e18-scaled. `inner` is 1e9, so
    the product comes back down by 1e9 to remain at 1e18. The integer square
    root of a 1e18-scaled value is its 1e9-scaled root. Returns
    (sqrt(w) @1e9, d2 @1e9).
    """
    increment = b * inner // F
    if a.is_negative:
        if increment <= a.magnitude:
            raise ValueError("SVI total variance must be positive")
        total_var = increment - a.magnitude
    else:
        if increment + a.magnitude == 0:
            raise ValueError("SVI total variance must be positive")
        total_var = increment + a.magnitude
    sqrt_var = sqrt_u128(total_var)

    # d2 = -(k + w/2) / sqrt(w): the numerator stays at 1e18 and the divisor is the
    # 1e9-scaled root, so the quotient lands at 1e9 with the sign tracked by hand.
    k_scaled = k.magnitude * F
    half_var = total_var // 2
    if not k.is_negative:
        numerator, numerator_negative = k_scaled + half_var, False
    elif half_var >= k_scaled:
        numerator, numerator_negative = half_var - k_scaled, False
    else:
        numerator, numerator_negative = k_scaled - half_var, True
    # normal_cdf/normal_pdf saturate beyond |x| > 8; cap there so the magnitude
    # stays inside u64 as w -> 0.
    saturation = 8 * F + 1
    d2_magnitude = min(numerator // sqrt_var, saturation)
    return sqrt_var, I64(d2_magnitude, not numerator_negative)


def compute_nd2(svi: dict[str, Any], forward: int, strike: int) -> int:
    # Mirror pricing.move exactly: log-moneyness is a DIFFERENCE of logarithms,
    # never `ln` of a fixed-point ratio. Forming `strike * 1e9 / forward` first
    # floors the quotient to zero below a ratio of 1e-9 and past u64 above 1.8e10,
    # which is why the contract used to short-circuit to the digital limits 1e9
    # and 0 there. Both the quotient and those shortcuts are gone; this model is
    # bit-compared against the chain, so it must not reintroduce either. The
    # difference is well-conditioned over every representable pair (|k| <= 44.4),
    # and the tails now reach their limits through the d2 clamp instead.
    k = ln_fixed(strike).sub(ln_fixed(forward))
    m = I64(svi["m"], svi["mNegative"])
    k_minus_m = k.sub(m)
    k_minus_m_squared = k_minus_m.square_scaled()
    sigma = svi["sigma"]
    sigma_squared = deepbook_mul(sigma, sigma)
    sq = sqrt_down(k_minus_m_squared + sigma_squared)
    rho = I64(svi["rho"], svi["rhoNegative"])
    rho_km = rho.mul_scaled(k_minus_m)
    inner = rho_km.add(I64(sq))
    if inner.is_negative:
        raise ValueError("SVI inner term cannot be negative")
    a = I64(svi["a"], svi.get("aNegative", False))
    sqrt_var, d2 = variance_sqrt_and_d2(a, svi["b"], inner.magnitude, k)
    nd2 = normal_cdf(d2)

    slope_ratio = k_minus_m.div_scaled(I64(sq))
    slope = rho.add(slope_ratio)
    w_prime = I64(svi["b"] * slope.magnitude // (F * F), slope.is_negative)
    if w_prime.magnitude == 0:
        return nd2

    correction = mul_div_round_down(normal_pdf(d2), w_prime.magnitude, 2 * sqrt_var)
    if w_prime.is_negative:
        return min(FLOAT_SCALING, nd2 + correction)
    return nd2 - correction if nd2 > correction else 0


def svi_cache_key(svi: dict[str, Any]) -> tuple[int, bool, int, int, bool, int, bool, int]:
    scale = 1 if svi.get("at1e18") else F
    return (
        svi["a"] * scale,
        svi.get("aNegative", False),
        svi["b"] * scale,
        svi["rho"],
        svi["rhoNegative"],
        svi["m"],
        svi["mNegative"],
        svi["sigma"],
    )


@lru_cache(maxsize=PRICE_CACHE_SIZE)
def compute_up_price_cached(
    forward: int,
    a: int,
    a_negative: bool,
    b: int,
    rho: int,
    rho_negative: bool,
    m: int,
    m_negative: bool,
    sigma: int,
    strike: int,
) -> int:
    if strike == NEG_INF_STRIKE:
        return FLOAT_SCALING
    if strike == POS_INF_STRIKE:
        return 0
    return compute_nd2(
        {
            "a": a,
            "aNegative": a_negative,
            "b": b,
            "rho": rho,
            "rhoNegative": rho_negative,
            "m": m,
            "mNegative": m_negative,
            "sigma": sigma,
            "at1e18": True,
        },
        forward,
        strike,
    )


def compute_up_price(svi: dict[str, Any], forward: int, strike: int) -> int:
    return compute_up_price_cached(forward, *svi_cache_key(svi), strike)


@lru_cache(maxsize=PRICE_CACHE_SIZE)
def compute_range_price_cached(
    forward: int,
    a: int,
    a_negative: bool,
    b: int,
    rho: int,
    rho_negative: bool,
    m: int,
    m_negative: bool,
    sigma: int,
    lower: int,
    higher: int,
) -> int:
    lower_up = compute_up_price_cached(
        forward,
        a,
        a_negative,
        b,
        rho,
        rho_negative,
        m,
        m_negative,
        sigma,
        lower,
    )
    higher_up = compute_up_price_cached(
        forward,
        a,
        a_negative,
        b,
        rho,
        rho_negative,
        m,
        m_negative,
        sigma,
        higher,
    )
    return max(0, lower_up - higher_up)


def compute_range_price(svi: dict[str, Any], forward: int, lower: int, higher: int) -> int:
    return compute_range_price_cached(forward, *svi_cache_key(svi), lower, higher)


REQUIRED_ACTIONS = [
    "mint",
    "redeem_live",
    "request_supply",
    "request_withdraw",
    "flush",
    "rebalance_expiry_cash",
    "settle",
    "redeem_settled",
]


def order_id_for_terms(lower_tick: int, higher_tick: int, quantity: int, sequence: int) -> int:
    lots = quantity // POSITION_LOT_SIZE
    return (lots << 100) | (lower_tick << 70) | (higher_tick << 40) | sequence


def model_fee_time_to_expiry_ms(model: dict[str, Any], timestamp_ms: int) -> int:
    return max(0, model["expiry_ms"] - timestamp_ms)


def expiry_fee_multiplier(time_to_expiry_ms: int) -> int:
    if time_to_expiry_ms >= EXPIRY_FEE_WINDOW_MS:
        return FLOAT_SCALING
    ramp = mul_div_round_down(
        EXPIRY_FEE_MAX_MULTIPLIER - FLOAT_SCALING,
        EXPIRY_FEE_WINDOW_MS - time_to_expiry_ms,
        EXPIRY_FEE_WINDOW_MS,
    )
    return FLOAT_SCALING + ramp


def fee_rate(probability: int, time_to_expiry_ms: int | None = None) -> int:
    if probability < 0 or probability > FLOAT_SCALING:
        raise ValueError("invalid fee probability")
    if probability in (0, FLOAT_SCALING):
        raw = 0
    else:
        variance = deepbook_mul(probability, FLOAT_SCALING - probability)
        raw = deepbook_mul(BASE_FEE, sqrt_down(variance))
    rate = max(raw, MIN_FEE)
    if time_to_expiry_ms is not None:
        rate = deepbook_mul(rate, expiry_fee_multiplier(time_to_expiry_ms))
    return rate


def assert_entry_probability_bounds(probability: int) -> None:
    if probability < MIN_ENTRY_PROBABILITY or probability > MAX_ENTRY_PROBABILITY:
        raise ValueError("entry probability out of bounds")


def oracle_for_row(row: dict[str, Any]) -> dict[str, Any] | None:
    if row["action"] == "mint":
        return {key: row[key] for key in (
            "spot",
            "forward",
            "a",
            "aNegative",
            "b",
            "rho",
            "rhoNegative",
            "m",
            "mNegative",
            "sigma",
            "riskFreeRate",
        )}
    return row.get("oracleRefresh")


def svi_input(oracle: dict[str, Any]) -> dict[str, str]:
    return {
        "a": signed_svi_value(oracle["a"], oracle["aNegative"]),
        "b": str(oracle["b"]),
        "rho": signed_svi_value(oracle["rho"], oracle["rhoNegative"]),
        "m": signed_svi_value(oracle["m"], oracle["mNegative"]),
        "sigma": str(oracle["sigma"]),
    }


def row_input(row: dict[str, Any]) -> dict[str, Any]:
    action = row["action"]
    oracle = oracle_for_row(row)
    oracle_input = (
        {
            "spot": str(oracle["spot"]),
            "forward": str(oracle["forward"]),
            "a": str(oracle["a"]),
            "a_negative": oracle["aNegative"],
            "b": str(oracle["b"]),
            "rho": str(oracle["rho"]),
            "rho_negative": oracle["rhoNegative"],
            "m": str(oracle["m"]),
            "m_negative": oracle["mNegative"],
            "sigma": str(oracle["sigma"]),
            "risk_free_rate": str(oracle["riskFreeRate"]),
        }
        if oracle is not None
        else {}
    )
    if action == "mint":
        lower_tick, higher_tick = binary_range_ticks(align_strike_to_tick(row["strike"]), row["isUp"])
        return {
            **oracle_input,
            "order_ref": row["orderRef"],
            "lower_tick": str(lower_tick),
            "higher_tick": str(higher_tick),
            "quantity": str(row["quantity"]),
        }
    if action == "redeem_live":
        return {
            **oracle_input,
            "order_ref": row["orderRef"],
            "close_quantity": str(row["closeQuantity"]),
            "replacement_order_ref": row["replacementOrderRef"],
        }
    if action == "request_supply":
        return {
            "amount": str(row["amount"]),
            "min_output": str(row["minOutput"]),
            "lp_ref": row["lpRef"],
        }
    if action == "request_withdraw":
        return {
            "shares": str(row["shares"]),
            "min_output": str(row["minOutput"]),
            "lp_ref": row["lpRef"],
        }
    if action == "settle":
        return {"settlement_price": str(row["settlementPrice"])}
    if action == "redeem_settled":
        return {
            "order_ref": row["orderRef"],
        }
    return oracle_input


def initial_state() -> dict[str, int]:
    return {
        "account_dusdc_balance": MANAGER_SEED,
        "account_plp_balance": INITIAL_ACCOUNT_PLP_BALANCE,
        "expiry_cash_balance": INITIAL_EXPIRY_CASH,
        "inventory_impact_reserve": 0,
        "payout_liability": 0,
        "required_cash": 0,
        "fee_incentive_balance": 0,
        "vault_idle_balance": VAULT_SEED + MIN_BOOTSTRAP_LIQUIDITY - INITIAL_EXPIRY_CASH,
        "vault_protocol_reserve_balance": 0,
        "vault_pending_protocol_profit": 0,
        "profit_basis_debits": INITIAL_EXPIRY_CASH,
        "profit_basis_credits": 0,
        "vault_total_plp_supply": INITIAL_TOTAL_PLP_SUPPLY,
        "supply_requests_pending": 0,
        "withdraw_requests_pending": 0,
        "is_settled": 0,
        "active_market_count": 1,
        "sent_to_expiry": INITIAL_EXPIRY_CASH,
        "received_from_expiry": 0,
    }


def state_snapshot(state: dict[str, int]) -> dict[str, str]:
    visible = (
        "account_dusdc_balance",
        "account_plp_balance",
        "expiry_cash_balance",
        "inventory_impact_reserve",
        "payout_liability",
        "required_cash",
        "fee_incentive_balance",
        "vault_idle_balance",
        "vault_protocol_reserve_balance",
        "vault_pending_protocol_profit",
        "profit_basis_debits",
        "profit_basis_credits",
        "vault_total_plp_supply",
        "supply_requests_pending",
        "withdraw_requests_pending",
        "is_settled",
        "active_market_count",
    )
    return {key: str(state[key]) for key in visible}


def initial_model(expiry_ms: int) -> dict[str, Any]:
    return {
        "expiry_ms": expiry_ms,
        "tree": StrikePayoutTree(tick_size=ORACLE_TICK_SIZE, pos_inf_tick=POS_INF_TICK),
        "orders": {},
        "next_order_sequence": 0,
        "last_oracle": None,
        "settlement_price": None,
        "settled_liability": 0,
        "supply_queue": [],
        "withdraw_queue": [],
        "next_supply_index": 1,
        "next_withdraw_index": 0,
    }


def live_payout_liability(model: dict[str, Any]) -> int:
    maximum, total = model["tree"].payout_reserve_terms()
    return maximum + deepbook_mul(BACKING_BUFFER_LAMBDA, total - maximum)


def update_required_cash(model: dict[str, Any], state: dict[str, int]) -> None:
    liability = (
        model["settled_liability"]
        if model["settlement_price"] is not None
        else live_payout_liability(model)
    )
    state["payout_liability"] = liability
    state["required_cash"] = liability + state["inventory_impact_reserve"]


def inventory_impact_potential(liability: int) -> int:
    if INVENTORY_IMPACT_MAX_RATE == 0 or liability == 0:
        return 0
    capped = min(liability, MAX_EXPIRY_ALLOCATION)
    utilization = mul_div_round_down(capped, FLOAT_SCALING, MAX_EXPIRY_ALLOCATION)
    marginal_rate = deepbook_mul(INVENTORY_IMPACT_MAX_RATE, utilization)
    potential = deepbook_mul(marginal_rate, capped) // 2
    if liability > MAX_EXPIRY_ALLOCATION:
        potential += deepbook_mul(INVENTORY_IMPACT_MAX_RATE, liability - MAX_EXPIRY_ALLOCATION)
    return potential


def apply_oracle(
    model: dict[str, Any],
    row: dict[str, Any],
    timing: dict[str, int] | None,
) -> None:
    oracle = oracle_for_row(row)
    if oracle is not None:
        snapshot = dict(oracle)
        snapshot["expiryMs"] = model["expiry_ms"]
        snapshot["pricingTimestampMs"] = (
            timing["pricing_timestamp_ms"] if timing else row.get("replayTimestampMs", 0)
        )
        snapshot["sviSourceTimestampMs"] = (
            timing.get("svi_source_timestamp_ms", snapshot["pricingTimestampMs"])
            if timing
            else row.get("sourceTimestampMs", snapshot["pricingTimestampMs"])
        )
        model["last_oracle"] = snapshot


def live_marked_liability(model: dict[str, Any]) -> int:
    oracle = model["last_oracle"]
    if oracle is None:
        raise ValueError("live valuation requires an oracle snapshot")
    svi = pricing_svi(oracle)
    forward = live_forward(oracle["spot"], oracle["forward"])
    return model["tree"].walk_linear(
        lambda strike: compute_up_price(svi, forward, strike),
        FLOAT_SCALING,
    )


def current_nav(model: dict[str, Any], state: dict[str, int]) -> int:
    if model["settlement_price"] is not None:
        return 0
    free_cash = max(0, state["expiry_cash_balance"] - state["inventory_impact_reserve"])
    return max(0, free_cash - live_marked_liability(model))


def pool_value(state: dict[str, int], active_nav: int) -> int:
    gross = state["vault_idle_balance"] + active_nav
    aggregate_credits = state["profit_basis_credits"] + active_nav
    exclusion = deepbook_mul(
        max(0, aggregate_credits - state["profit_basis_debits"]),
        PROTOCOL_RESERVE_PROFIT_SHARE,
    )
    return max(0, gross - exclusion - state["vault_pending_protocol_profit"])


def pricing_svi(oracle: dict[str, Any]) -> dict[str, Any]:
    remaining_ms = oracle["expiryMs"] - oracle["pricingTimestampMs"]
    anchor_tte_ms = oracle["expiryMs"] - oracle["sviSourceTimestampMs"]
    if remaining_ms <= 0 or anchor_tte_ms <= 0:
        raise ValueError("SVI roll-down requires pre-expiry timestamps")
    rolled_a = oracle["a"] * FLOAT_SCALING * remaining_ms // anchor_tte_ms
    rolled_b = oracle["b"] * FLOAT_SCALING * remaining_ms // anchor_tte_ms
    return {
        "a": rolled_a,
        "aNegative": oracle["aNegative"],
        "b": rolled_b,
        "rho": oracle["rho"],
        "rhoNegative": oracle["rhoNegative"],
        "m": oracle["m"],
        "mNegative": oracle["mNegative"],
        "sigma": oracle["sigma"],
        "riskFreeRate": oracle["riskFreeRate"],
        "at1e18": True,
    }


def price_range(row_or_order: dict[str, Any], oracle: dict[str, Any]) -> int:
    if "lower_tick" in row_or_order:
        lower, higher = strikes_from_ticks(
            row_or_order["lower_tick"],
            row_or_order["higher_tick"],
        )
    else:
        strike = align_strike_to_tick(row_or_order["strike"])
        lower, higher = binary_range_bounds(strike, row_or_order["isUp"])
    return compute_range_price(
        pricing_svi(oracle),
        live_forward(oracle["spot"], oracle["forward"]),
        lower,
        higher,
    )


def mint_order(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
    timestamp_ms: int,
) -> list[dict[str, Any]]:
    oracle = model["last_oracle"]
    if oracle is None:
        raise ValueError("mint requires an oracle snapshot")
    probability = price_range(row, oracle)
    assert_entry_probability_bounds(probability)
    quantity = row["quantity"]
    premium = deepbook_mul(probability, quantity)
    if premium < MIN_PREMIUM:
        raise ValueError("premium below minimum")
    fee = deepbook_mul(
        fee_rate(probability, model_fee_time_to_expiry_ms(model, timestamp_ms)),
        quantity,
    )
    lower_tick, higher_tick = binary_range_ticks(align_strike_to_tick(row["strike"]), row["isUp"])
    before = live_payout_liability(model)
    model["tree"].insert_range(lower_tick, higher_tick, quantity)
    after = live_payout_liability(model)
    impact_charge = inventory_impact_potential(after) - inventory_impact_potential(before)
    total_cost = premium + fee + impact_charge
    if total_cost > state["account_dusdc_balance"]:
        raise ValueError("insufficient account balance for mint")

    sequence = model["next_order_sequence"]
    model["next_order_sequence"] += 1
    model["orders"][row["orderRef"]] = {
        "lower_tick": lower_tick,
        "higher_tick": higher_tick,
        "quantity": quantity,
        "sequence": sequence,
        "position_root_sequence": sequence,
    }
    state["account_dusdc_balance"] -= total_cost
    state["expiry_cash_balance"] += total_cost
    state["inventory_impact_reserve"] += impact_charge
    update_required_cash(model, state)
    return [
        {
            "type": "order_minted",
            "order_ref": row["orderRef"],
            "order_sequence": str(sequence),
            "lower_tick": str(lower_tick),
            "higher_tick": str(higher_tick),
            "entry_probability": str(probability),
            "quantity": str(quantity),
            "premium": str(premium),
            "trading_fee": str(fee),
            "fee_incentive_subsidy": "0",
            "builder_fee": "0",
            "penalty_fee": "0",
            "referral_fee": "0",
            "inventory_impact_charge": str(impact_charge),
            "onchain_timestamp_ms": str(timestamp_ms),
            "pyth_spot_source_timestamp_ms": str(row["priceSourceTimestampMs"]),
            "block_scholes_spot_source_timestamp_ms": str(row["priceSourceTimestampMs"]),
            "block_scholes_forward_source_timestamp_ms": str(row["priceSourceTimestampMs"]),
            "block_scholes_svi_source_timestamp_ms": str(row["sourceTimestampMs"]),
        }
    ]


def redeem_live(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
    timestamp_ms: int,
) -> list[dict[str, Any]]:
    order = model["orders"].pop(row["orderRef"], None)
    if order is None:
        raise ValueError(f"unknown order_ref {row['orderRef']}")
    close_quantity = row["closeQuantity"]
    if close_quantity > order["quantity"]:
        raise ValueError("close quantity exceeds order")
    oracle = model["last_oracle"]
    if oracle is None:
        raise ValueError("live redeem requires an oracle snapshot")
    probability = price_range(order, oracle)
    redeem_amount = deepbook_mul(probability, close_quantity)
    fee = min(
        redeem_amount,
        deepbook_mul(
            fee_rate(probability, model_fee_time_to_expiry_ms(model, timestamp_ms)),
            close_quantity,
        ),
    )
    before = live_payout_liability(model)
    model["tree"].remove_range(order["lower_tick"], order["higher_tick"], close_quantity)
    after = live_payout_liability(model)
    impact_rebate = inventory_impact_potential(before) - inventory_impact_potential(after)
    remaining = order["quantity"] - close_quantity
    replacement_ref = None
    replacement_sequence = None
    if remaining > 0:
        replacement_ref = row["replacementOrderRef"] or row["orderRef"]
        replacement_sequence = model["next_order_sequence"]
        model["next_order_sequence"] += 1
        model["orders"][replacement_ref] = {
            **order,
            "quantity": remaining,
            "sequence": replacement_sequence,
        }

    state["account_dusdc_balance"] += redeem_amount + impact_rebate - fee
    state["expiry_cash_balance"] += fee - redeem_amount - impact_rebate
    state["inventory_impact_reserve"] -= impact_rebate
    update_required_cash(model, state)
    return [
        {
            "type": "live_order_redeemed",
            "order_ref": row["orderRef"],
            "order_sequence": str(order["sequence"]),
            "quantity_closed": str(close_quantity),
            "remaining_quantity": str(remaining),
            "replacement_order_ref": replacement_ref,
            "replacement_order_sequence": (
                None if replacement_sequence is None else str(replacement_sequence)
            ),
            "redeem_amount": str(redeem_amount),
            "trading_fee": str(fee),
            "builder_fee": "0",
            "penalty_fee": "0",
            "inventory_impact_rebate": str(impact_rebate),
            "onchain_timestamp_ms": str(timestamp_ms),
            "pyth_spot_source_timestamp_ms": str(row["priceSourceTimestampMs"]),
            "block_scholes_spot_source_timestamp_ms": str(row["priceSourceTimestampMs"]),
            "block_scholes_forward_source_timestamp_ms": str(row["priceSourceTimestampMs"]),
            "block_scholes_svi_source_timestamp_ms": str(row["sourceTimestampMs"]),
        }
    ]


def request_supply(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
) -> list[dict[str, Any]]:
    index = model["next_supply_index"]
    model["next_supply_index"] += 1
    model["supply_queue"].append(
        {
            "index": index,
            "amount": row["amount"],
            "min_output": row["minOutput"],
            "misses": 0,
        }
    )
    state["supply_requests_pending"] += 1
    return [
        {
            "type": "supply_requested",
            "lp_ref": row["lpRef"],
            "index": str(index),
            "amount": str(row["amount"]),
            "min_output": str(row["minOutput"]),
            "requests_pending_after": str(state["supply_requests_pending"]),
        }
    ]


def request_withdraw(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
) -> list[dict[str, Any]]:
    shares = row["shares"]
    if shares > state["account_plp_balance"]:
        raise ValueError("insufficient account PLP")
    state["account_plp_balance"] -= shares
    index = model["next_withdraw_index"]
    model["next_withdraw_index"] += 1
    model["withdraw_queue"].append(
        {
            "index": index,
            "amount": shares,
            "min_output": row["minOutput"],
            "misses": 0,
        }
    )
    state["withdraw_requests_pending"] += 1
    return [
        {
            "type": "withdraw_requested",
            "lp_ref": row["lpRef"],
            "index": str(index),
            "amount": str(shares),
            "min_output": str(row["minOutput"]),
            "requests_pending_after": str(state["withdraw_requests_pending"]),
        }
    ]


def realize_pending_protocol_profit(state: dict[str, int]) -> int:
    amount = min(
        state["vault_pending_protocol_profit"],
        state["vault_idle_balance"],
    )
    state["vault_pending_protocol_profit"] -= amount
    state["vault_idle_balance"] -= amount
    state["vault_protocol_reserve_balance"] += amount
    return amount


def rebalance_expiry(
    model: dict[str, Any],
    state: dict[str, int],
) -> list[dict[str, Any]]:
    if state["active_market_count"] == 0 or model["settlement_price"] is not None:
        return []
    update_required_cash(model, state)
    required = state["required_cash"]
    target_buffer = deepbook_mul(required, EXPIRY_REBALANCE_PCT)
    target = max(INITIAL_EXPIRY_CASH, required + target_buffer)
    threshold = max(INITIAL_EXPIRY_CASH, required + target_buffer + target_buffer)
    cash = state["expiry_cash_balance"]
    if cash < target:
        funding_room = max(
            0,
            MAX_EXPIRY_ALLOCATION
            - max(0, state["sent_to_expiry"] - state["received_from_expiry"]),
        )
        amount = min(target - cash, state["vault_idle_balance"], funding_room)
        if amount == 0:
            return []
        state["vault_idle_balance"] -= amount
        state["expiry_cash_balance"] += amount
        state["sent_to_expiry"] += amount
        state["profit_basis_debits"] += amount
        return [
            {
                "type": "expiry_cash_rebalanced",
                "amount": str(amount),
                "to_expiry": True,
                "target_cash": str(target),
                "protocol_profit_realized": "0",
            }
        ]
    if cash > threshold:
        amount = cash - target
        state["expiry_cash_balance"] -= amount
        state["vault_idle_balance"] += amount
        state["received_from_expiry"] += amount
        state["profit_basis_credits"] += amount
        realized = realize_pending_protocol_profit(state)
        return [
            {
                "type": "expiry_cash_rebalanced",
                "amount": str(amount),
                "to_expiry": False,
                "target_cash": str(target),
                "protocol_profit_realized": str(realized),
            }
        ]
    return []


def drain_supply_queue(
    model: dict[str, Any],
    state: dict[str, int],
    frozen_pool_value: int,
    frozen_total_supply: int,
) -> tuple[list[dict[str, Any]], int]:
    updates = []
    processed = 0
    while model["supply_queue"]:
        request = model["supply_queue"][0]
        if frozen_pool_value == 0 or frozen_total_supply == 0:
            model["supply_queue"].pop(0)
            state["supply_requests_pending"] -= 1
            state["account_dusdc_balance"] += request["amount"]
            updates.append(
                {
                    "type": "request_cancelled",
                    "index": str(request["index"]),
                    "amount": str(request["amount"]),
                    "is_supply": True,
                    "reason": "1",
                    "requests_pending_after": str(state["supply_requests_pending"]),
                }
            )
            processed += 1
            continue
        fee = mul_div_round_up(
            request["amount"], PLP_SUPPLY_FEE_RATE, FLOAT_SCALING
        )
        shares = mul_div_round_down(
            request["amount"] - fee,
            frozen_total_supply,
            frozen_pool_value,
        )
        if shares < request["min_output"]:
            model["supply_queue"].pop(0)
            state["supply_requests_pending"] -= 1
            state["account_dusdc_balance"] += request["amount"]
            updates.append(
                {
                    "type": "request_cancelled",
                    "index": str(request["index"]),
                    "amount": str(request["amount"]),
                    "is_supply": True,
                    "reason": "2",
                    "requests_pending_after": str(state["supply_requests_pending"]),
                }
            )
            processed += 1
            continue
        capacity = max(0, MAX_LP_POOL_VALUE - frozen_pool_value)
        fill = min(request["amount"], capacity)
        if fill == 0:
            break
        fee = mul_div_round_up(fill, PLP_SUPPLY_FEE_RATE, FLOAT_SCALING)
        shares = mul_div_round_down(fill - fee, frozen_total_supply, frozen_pool_value)
        remaining = request["amount"] - fill
        state["vault_idle_balance"] += fill
        state["vault_total_plp_supply"] += shares
        state["account_plp_balance"] += shares
        if remaining == 0:
            model["supply_queue"].pop(0)
            state["supply_requests_pending"] -= 1
        else:
            request["amount"] = remaining
            request["min_output"] = mul_div_round_up(
                request["min_output"],
                remaining,
                fill + remaining,
            )
        updates.append(
            {
                "type": "supply_filled",
                "index": str(request["index"]),
                "dusdc_amount": str(fill),
                "shares_minted": str(shares),
                "fee_dusdc": str(fee),
                "dusdc_remaining": str(remaining),
                "requests_pending_after": str(state["supply_requests_pending"]),
            }
        )
        processed += 1
        if remaining:
            break
    return updates, processed


def drain_withdraw_queue(
    model: dict[str, Any],
    state: dict[str, int],
    frozen_pool_value: int,
    frozen_total_supply: int,
) -> tuple[list[dict[str, Any]], int]:
    updates = []
    processed = 0
    while model["withdraw_queue"]:
        request = model["withdraw_queue"][0]
        if frozen_pool_value == 0 or frozen_total_supply == 0:
            model["withdraw_queue"].pop(0)
            state["withdraw_requests_pending"] -= 1
            state["account_plp_balance"] += request["amount"]
            updates.append(
                {
                    "type": "request_cancelled",
                    "index": str(request["index"]),
                    "amount": str(request["amount"]),
                    "is_supply": False,
                    "reason": "1",
                    "requests_pending_after": str(state["withdraw_requests_pending"]),
                }
            )
            processed += 1
            continue
        gross = mul_div_round_down(request["amount"], frozen_pool_value, frozen_total_supply)
        fee = mul_div_round_up(gross, PLP_WITHDRAW_FEE_RATE, FLOAT_SCALING)
        payout = gross - fee
        if payout < request["min_output"]:
            model["withdraw_queue"].pop(0)
            state["withdraw_requests_pending"] -= 1
            state["account_plp_balance"] += request["amount"]
            updates.append(
                {
                    "type": "request_cancelled",
                    "index": str(request["index"]),
                    "amount": str(request["amount"]),
                    "is_supply": False,
                    "reason": "2",
                    "requests_pending_after": str(state["withdraw_requests_pending"]),
                }
            )
            processed += 1
            continue
        if state["vault_idle_balance"] < payout:
            affordable = mul_div_round_down(
                state["vault_idle_balance"],
                frozen_total_supply,
                frozen_pool_value,
            )
            if affordable == 0:
                break
            burn = min(request["amount"], affordable)
            gross = mul_div_round_down(burn, frozen_pool_value, frozen_total_supply)
            fee = mul_div_round_up(gross, PLP_WITHDRAW_FEE_RATE, FLOAT_SCALING)
            payout = gross - fee
        else:
            burn = request["amount"]
        remaining = request["amount"] - burn
        state["vault_idle_balance"] -= payout
        state["vault_total_plp_supply"] -= burn
        state["account_dusdc_balance"] += payout
        if remaining == 0:
            model["withdraw_queue"].pop(0)
            state["withdraw_requests_pending"] -= 1
        else:
            request["amount"] = remaining
            request["min_output"] = mul_div_round_up(
                request["min_output"],
                remaining,
                burn + remaining,
            )
        updates.append(
            {
                "type": "withdraw_filled",
                "index": str(request["index"]),
                "shares_burned": str(burn),
                "dusdc_amount": str(payout),
                "fee_dusdc": str(fee),
                "shares_remaining": str(remaining),
                "requests_pending_after": str(state["withdraw_requests_pending"]),
            }
        )
        processed += 1
        if remaining:
            break
    return updates, processed


def flush(
    model: dict[str, Any],
    state: dict[str, int],
) -> list[dict[str, Any]]:
    updates = rebalance_expiry(model, state)
    active_nav = current_nav(model, state) if state["active_market_count"] else 0
    idle_before = state["vault_idle_balance"]
    frozen_pool_value = pool_value(state, active_nav)
    frozen_total_supply = state["vault_total_plp_supply"]
    supply_updates, supply_processed = drain_supply_queue(
        model,
        state,
        frozen_pool_value,
        frozen_total_supply,
    )
    withdraw_updates, withdraw_processed = drain_withdraw_queue(
        model,
        state,
        frozen_pool_value,
        frozen_total_supply,
    )
    updates.extend(supply_updates)
    updates.extend(withdraw_updates)
    updates.append(
        {
            "type": "flush_executed",
            "pool_value": str(frozen_pool_value),
            "total_supply": str(frozen_total_supply),
            "supply_fee_rate": str(PLP_SUPPLY_FEE_RATE),
            "withdraw_fee_rate": str(PLP_WITHDRAW_FEE_RATE),
            "active_market_nav": str(active_nav),
            "market_count": str(state["active_market_count"]),
            "idle_balance_before": str(idle_before),
            "supplies_filled": str(sum(u["type"] == "supply_filled" for u in supply_updates)),
            "withdrawals_filled": str(
                sum(u["type"] == "withdraw_filled" for u in withdraw_updates)
            ),
            "requests_processed": str(supply_processed + withdraw_processed),
            "idle_balance_after": str(state["vault_idle_balance"]),
            "total_supply_after": str(state["vault_total_plp_supply"]),
        }
    )
    return updates


def settle_market(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
    timestamp_ms: int,
) -> list[dict[str, Any]]:
    if model["settlement_price"] is not None:
        raise ValueError("market already settled")
    settlement_price = row["settlementPrice"]
    model["settlement_price"] = settlement_price
    model["settled_liability"] = model["tree"].settled_payout_liability(settlement_price)
    state["inventory_impact_reserve"] = 0
    state["is_settled"] = 1
    update_required_cash(model, state)
    updates = [
        {
            "type": "market_settled",
            "settlement_price": str(settlement_price),
            "settlement_source": "0",
            "onchain_timestamp_ms": str(timestamp_ms),
        }
    ]

    state["active_market_count"] = 0
    returned = state["expiry_cash_balance"] - model["settled_liability"]
    state["expiry_cash_balance"] = model["settled_liability"]
    state["vault_idle_balance"] += returned
    state["received_from_expiry"] += returned
    state["profit_basis_credits"] += returned
    updates.append(
        {
            "type": "expiry_cash_received",
            "settlement_price": str(settlement_price),
            "amount": str(returned),
        }
    )

    profit = max(0, state["received_from_expiry"] - state["sent_to_expiry"])
    if profit:
        state["profit_basis_debits"] += profit
        protocol_profit = deepbook_mul(profit, PROTOCOL_RESERVE_PROFIT_SHARE)
        lp_profit = profit - protocol_profit
        state["vault_pending_protocol_profit"] += protocol_profit
        realize_pending_protocol_profit(state)
        updates.append(
            {
                "type": "expiry_profit_materialized",
                "lp_profit": str(lp_profit),
                "protocol_profit": str(protocol_profit),
                "protocol_reserve_balance_after": str(
                    state["vault_protocol_reserve_balance"]
                ),
                "profit_basis_after": str(state["profit_basis_debits"]),
                "pending_protocol_profit_after": str(
                    state["vault_pending_protocol_profit"]
                ),
            }
        )
    update_required_cash(model, state)
    return updates


def settlement_in_range(order: dict[str, Any], settlement_price: int) -> bool:
    lower_tick = order["lower_tick"]
    higher_tick = order["higher_tick"]
    lower_ok = lower_tick == 0 or settlement_price > lower_tick * ORACLE_TICK_SIZE
    higher_ok = (
        higher_tick == POS_INF_TICK
        or settlement_price <= higher_tick * ORACLE_TICK_SIZE
    )
    return lower_ok and higher_ok


def redeem_settled(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
    timestamp_ms: int,
) -> list[dict[str, Any]]:
    if model["settlement_price"] is None:
        raise ValueError("market is not settled")
    order = model["orders"].pop(row["orderRef"], None)
    if order is None:
        raise ValueError(f"unknown order_ref {row['orderRef']}")
    payout = (
        order["quantity"]
        if settlement_in_range(order, model["settlement_price"])
        else 0
    )
    model["settled_liability"] -= payout
    state["expiry_cash_balance"] -= payout
    state["account_dusdc_balance"] += payout
    update_required_cash(model, state)
    return [
        {
            "type": "settled_order_redeemed",
            "order_ref": row["orderRef"],
            "order_sequence": str(order["sequence"]),
            "payout_amount": str(payout),
            "onchain_timestamp_ms": str(timestamp_ms),
        }
    ]


def load_pricing_timings(path: Path) -> dict[tuple[int, str], dict[str, int]]:
    payload = load_local_trace(path)
    if payload["schema_version"] != LOCAL_TRACE_SCHEMA_VERSION:
        raise ValueError(
            f"unsupported local trace schema_version: {payload['schema_version']}"
        )
    timings: dict[tuple[int, str], dict[str, int]] = {}
    for step in payload["steps"]:
        timing = {
            "pricing_timestamp_ms": step["pricingTimestampMs"],
        }
        for event in step["events"]:
            parsed = event["parsedJson"]
            if parsed.get("series_kind") != 2:
                continue
            observation = parsed.get("observation", {})
            source_timestamp_ms = observation.get("source_timestamp_ms")
            if isinstance(source_timestamp_ms, str) and source_timestamp_ms.isdecimal():
                timing["svi_source_timestamp_ms"] = int(source_timestamp_ms)
                break
        timings[(step["step"], step["action"])] = timing
    return timings


def timestamp_for_row(
    row: dict[str, Any],
    timings: dict[tuple[int, str], dict[str, int]],
) -> int:
    timing = timings.get((row["step"], row["action"]))
    if timing is not None:
        return timing["pricing_timestamp_ms"]
    return row.get("replayTimestampMs", 0)


def replay(
    rows: list[dict[str, Any]],
    expiry_ms: int,
    pricing_timings: dict[tuple[int, str], dict[str, int]],
) -> dict[str, Any]:
    validate_complete_scenario(rows)
    model = initial_model(expiry_ms)
    state = initial_state()
    records: list[dict[str, Any]] = []
    observed_actions: list[str] = []

    for row in rows:
        action = row["action"]
        if action not in observed_actions:
            observed_actions.append(action)
        timing = pricing_timings.get((row["step"], row["action"]))
        timestamp_ms = timestamp_for_row(row, pricing_timings)
        apply_oracle(model, row, timing)
        updates: list[dict[str, Any]] = []
        if action == "mint":
            updates.extend(mint_order(model, state, row, timestamp_ms))
        elif action == "redeem_live":
            updates.extend(redeem_live(model, state, row, timestamp_ms))
        elif action == "request_supply":
            updates.extend(request_supply(model, state, row))
        elif action == "request_withdraw":
            updates.extend(request_withdraw(model, state, row))
        elif action == "flush":
            updates.extend(flush(model, state))
        elif action == "rebalance_expiry_cash":
            updates.extend(rebalance_expiry(model, state))
        elif action == "settle":
            updates.extend(settle_market(model, state, row, timestamp_ms))
        elif action == "redeem_settled":
            updates.extend(redeem_settled(model, state, row, timestamp_ms))
        else:
            raise ValueError(f"unsupported action {action}")
        update_required_cash(model, state)
        records.append(
            {
                "step": row["step"],
                "action": action,
                "input": row_input(row),
                "updates": updates,
                "state": state_snapshot(state),
            }
        )

    missing = [action for action in REQUIRED_ACTIONS if action not in observed_actions]
    if missing:
        raise ValueError(f"scenario did not execute required actions: {','.join(missing)}")
    return {
        "schema_version": ECONOMIC_SCHEMA_VERSION,
        "scenario": {
            "quantity_scale": str(scenario_quantity_scale()),
            "required_actions": REQUIRED_ACTIONS,
            "observed_actions": observed_actions,
        },
        "records": records,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--pricing-trace", type=Path, required=True)
    parser.add_argument("--expiry-ms", type=int, required=True)
    parser.add_argument("--max-rows", type=int)
    parser.add_argument("--config", type=Path, default=DEFAULT_SCENARIO_CONFIG_PATH)
    args = parser.parse_args()

    config = load_scenario_config(args.config)
    apply_scenario_config(config)
    rows = parse_scenario(args.scenario)
    if args.max_rows is not None:
        rows = rows[: args.max_rows]
    output = replay(
        rows,
        args.expiry_ms,
        load_pricing_timings(args.pricing_trace),
    )
    write_json(args.out, output)
    print(f"wrote {args.out} records={len(output['records'])}")


if __name__ == "__main__":
    main()
