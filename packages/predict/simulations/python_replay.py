#!/usr/bin/env python3
"""Python economic replay for Predict simulation scenarios."""

from __future__ import annotations

import argparse
import csv
import json
import os
from functools import lru_cache
from io import StringIO
from pathlib import Path
from typing import Any

from python_indexes.liquidation_book import (
    LiquidationBook,
    encode_order_id,
)
from python_indexes.strike_payout_tree import StrikePayoutTree

FLOAT_SCALING = 1_000_000_000
POSITION_LOT_SIZE = 10_000
ECONOMIC_SCHEMA_VERSION = "predict_economic_v3"
DERIVED_SCHEMA_VERSION = "predict_derived_v2"
DEFAULT_SCENARIO_CONFIG_PATH = Path(__file__).with_name("data") / "scenario_config.json"
ORACLE_REFRESH_FIELDS = (
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
)
# Lightweight mirror of Move config defaults. scenario_config.json may override
# these only when the corresponding localnet setup is intentionally extended.
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
MIN_NET_PREMIUM = 1_000_000
DUSDC_DECIMALS = 1_000_000
VAULT_SEED = 500_000 * DUSDC_DECIMALS
MANAGER_SEED = 500_000 * DUSDC_DECIMALS
MIN_BOOTSTRAP_LIQUIDITY = 10 * DUSDC_DECIMALS
INITIAL_TOTAL_PLP_SUPPLY = VAULT_SEED + MIN_BOOTSTRAP_LIQUIDITY
INITIAL_EXPIRY_CASH = 50_000 * DUSDC_DECIMALS
EXPIRY_REBALANCE_PCT = 100_000_000
MAX_EXPIRY_ALLOCATION = 250_000 * DUSDC_DECIMALS
BACKING_BUFFER_LAMBDA = 250_000_000
TRADE_LIQUIDATION_BUDGET = 24
VALUATION_LIQUIDATION_BUDGET = 192
LIQUIDATION_HEAD_SCAN_DIVISOR = 3
CURVE_SAMPLES = 50
PROTOCOL_RESERVE_PROFIT_SHARE = 400_000_000
# WITHDRAW_FEE_ALPHA removed: the withdraw band fee died with the approximate-NAV
# world. The async flush pays withdrawals exactly pro-rata (plp::withdraw_dusdc).
TRADING_LOSS_REBATE_RATE = 500_000_000
TERMINAL_REBATE_FRACTION = 0
# Admin-tunable per-feed default, mirrored from config_constants::default_expiry_fee_window_ms!().
EXPIRY_FEE_WINDOW_MS = 24 * 60 * 60 * 1000
EXPIRY_FEE_MAX_MULTIPLIER = FLOAT_SCALING

# Dynamic mint-admission cap. Actual liquidation still uses LIQUIDATION_LTV.
MAX_ADMISSION_LEVERAGE = 3_000_000_000  # 3x, default_max_admission_leverage
ADMISSION_LEVERAGE_CURVE_K = 200_000_000  # 0.20, admission_leverage_curve_k
LIQUIDATION_LTV = 850_000_000  # 0.85, default_liquidation_ltv
GLOBAL_OBSERVABILITY_INTERVAL = 10
LEVERAGE_ONE_X = 1_000_000_000
LEVERAGE_ONE_AND_HALF_X = 1_500_000_000
LEVERAGE_TWO_X = 2_000_000_000
LEVERAGE_TWO_AND_HALF_X = 2_500_000_000
LEVERAGE_THREE_X = 3_000_000_000

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
    return json.loads(config_path.read_text())


def _config_int(config: dict[str, Any], section: str, key: str, default: int) -> int:
    value = config.get(section, {}).get(key, default)
    return int(value)


def _capital_int(config: dict[str, Any], mode: str, key: str, default: int) -> int:
    value = config.get("capital", {}).get(mode, {}).get(key, default)
    return int(value)


def apply_scenario_config(config: dict[str, Any], long_run: bool = False) -> None:
    global VAULT_SEED
    global MANAGER_SEED
    global INITIAL_TOTAL_PLP_SUPPLY
    global BASE_FEE
    global MIN_FEE
    global MIN_ENTRY_PROBABILITY
    global MAX_ENTRY_PROBABILITY
    global TRADE_LIQUIDATION_BUDGET
    global VALUATION_LIQUIDATION_BUDGET
    global LIQUIDATION_HEAD_SCAN_DIVISOR
    global CURVE_SAMPLES
    global PROTOCOL_RESERVE_PROFIT_SHARE
    global TRADING_LOSS_REBATE_RATE
    global MAX_EXPIRY_ALLOCATION
    global INITIAL_EXPIRY_CASH
    global TERMINAL_REBATE_FRACTION
    global EXPIRY_FEE_WINDOW_MS
    global EXPIRY_FEE_MAX_MULTIPLIER
    global BACKING_BUFFER_LAMBDA
    global MAX_ADMISSION_LEVERAGE
    global LIQUIDATION_LTV

    capital_mode = "long" if long_run else "normal"
    VAULT_SEED = _capital_int(config, capital_mode, "vault_seed", VAULT_SEED)
    MANAGER_SEED = _capital_int(config, capital_mode, "manager_seed", MANAGER_SEED)
    INITIAL_TOTAL_PLP_SUPPLY = VAULT_SEED + MIN_BOOTSTRAP_LIQUIDITY

    BASE_FEE = _config_int(config, "protocol", "base_fee", BASE_FEE)
    MIN_FEE = _config_int(config, "protocol", "min_fee", MIN_FEE)
    MIN_ENTRY_PROBABILITY = _config_int(
        config,
        "protocol",
        "min_entry_probability",
        MIN_ENTRY_PROBABILITY,
    )
    MAX_ENTRY_PROBABILITY = _config_int(
        config,
        "protocol",
        "max_entry_probability",
        MAX_ENTRY_PROBABILITY,
    )
    TRADE_LIQUIDATION_BUDGET = _config_int(config, "protocol", "trade_liquidation_budget", TRADE_LIQUIDATION_BUDGET)
    VALUATION_LIQUIDATION_BUDGET = _config_int(
        config,
        "protocol",
        "valuation_liquidation_budget",
        VALUATION_LIQUIDATION_BUDGET,
    )
    LIQUIDATION_HEAD_SCAN_DIVISOR = _config_int(
        config,
        "protocol",
        "liquidation_head_scan_divisor",
        LIQUIDATION_HEAD_SCAN_DIVISOR,
    )
    CURVE_SAMPLES = _config_int(config, "protocol", "curve_samples", CURVE_SAMPLES)
    PROTOCOL_RESERVE_PROFIT_SHARE = _config_int(
        config,
        "protocol",
        "protocol_reserve_profit_share",
        PROTOCOL_RESERVE_PROFIT_SHARE,
    )
    TRADING_LOSS_REBATE_RATE = _config_int(
        config,
        "protocol",
        "trading_loss_rebate_rate",
        TRADING_LOSS_REBATE_RATE,
    )
    MAX_EXPIRY_ALLOCATION = _config_int(
        config,
        "protocol",
        "max_expiry_allocation",
        MAX_EXPIRY_ALLOCATION,
    )
    INITIAL_EXPIRY_CASH = _config_int(
        config,
        "protocol",
        "initial_expiry_cash",
        INITIAL_EXPIRY_CASH,
    )
    BACKING_BUFFER_LAMBDA = _config_int(
        config,
        "protocol",
        "backing_buffer_lambda",
        BACKING_BUFFER_LAMBDA,
    )
    TERMINAL_REBATE_FRACTION = FLOAT_SCALING if long_run else 0
    EXPIRY_FEE_WINDOW_MS = _config_int(
        config,
        "protocol",
        "expiry_fee_window_ms",
        EXPIRY_FEE_WINDOW_MS,
    )
    EXPIRY_FEE_MAX_MULTIPLIER = _config_int(
        config,
        "protocol",
        "expiry_fee_max_multiplier",
        EXPIRY_FEE_MAX_MULTIPLIER,
    )
    MAX_ADMISSION_LEVERAGE = _config_int(
        config,
        "protocol",
        "max_admission_leverage",
        MAX_ADMISSION_LEVERAGE,
    )
    LIQUIDATION_LTV = _config_int(config, "protocol", "liquidation_ltv", LIQUIDATION_LTV)


def config_source_value(config: dict[str, Any], key: str) -> int | None:
    source = config.get("source", {})
    if key not in source:
        return None
    return int(source[key])


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


def _oracle_refresh(row: dict[str, str], line_number: int) -> dict[str, Any]:
    present = [field for field in ORACLE_REFRESH_FIELDS if row.get(field, "") != ""]
    if len(present) != len(ORACLE_REFRESH_FIELDS):
        raise ValueError(f"Scenario line {line_number}: oracle refresh fields must all be present")
    return {
        "oracleRefresh": {
            "spot": _uint(row, "spot", line_number),
            "forward": _uint(row, "forward", line_number),
            "a": _uint(row, "a", line_number),
            "aNegative": _optional_bool(row, "a_negative", line_number),
            "b": _uint(row, "b", line_number),
            "rho": _uint(row, "rho", line_number),
            "rhoNegative": _bool(row, "rho_negative", line_number),
            "m": _uint(row, "m", line_number),
            "mNegative": _bool(row, "m_negative", line_number),
            "sigma": _uint(row, "sigma", line_number),
            "riskFreeRate": _uint(row, "risk_free_rate", line_number),
        },
    }


def parse_scenario_text(text: str) -> list[dict[str, Any]]:
    reader = csv.DictReader(StringIO(text.replace("\r", "")))
    rows: list[dict[str, Any]] = []
    last_tx = 0
    for index, raw in enumerate(reader, start=2):
        row = {key: (value or "").strip() for key, value in raw.items() if key is not None}
        tx = _uint(row, "tx", index)
        if tx <= last_tx:
            raise ValueError(f"Scenario line {index}: tx values must be strictly increasing")
        last_tx = tx
        action = _required(row, "action", index)
        if action == "oracle_mint_ptb":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    **_timestamps(row, index),
                    "spot": _uint(row, "spot", index),
                    "forward": _uint(row, "forward", index),
                    "a": _uint(row, "a", index),
                    "aNegative": _optional_bool(row, "a_negative", index),
                    "b": _uint(row, "b", index),
                    "rho": _uint(row, "rho", index),
                    "rhoNegative": _bool(row, "rho_negative", index),
                    "m": _uint(row, "m", index),
                    "mNegative": _bool(row, "m_negative", index),
                    "sigma": _uint(row, "sigma", index),
                    "riskFreeRate": _uint(row, "risk_free_rate", index),
                    "strike": _uint(row, "strike", index),
                    "isUp": _bool(row, "is_up", index),
                    "quantity": parse_mint_quantity(_uint(row, "quantity", index), index),
                    "leverage": _optional_uint(row, "leverage", index, LEVERAGE_ONE_X),
                    "orderRef": _ref(row, "order_ref", index),
                }
            )
        elif action == "redeem":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    **_timestamps(row, index),
                    **_oracle_refresh(row, index),
                    "orderRef": _ref(row, "order_ref", index),
                    "closeQuantity": parse_mint_quantity(_uint(row, "close_quantity", index), index, "close_quantity"),
                    "replacementOrderRef": _optional_str(row, "replacement_order_ref"),
                }
            )
        elif action == "supply":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    **_timestamps(row, index),
                    **_oracle_refresh(row, index),
                    "amount": _uint(row, "amount", index),
                    "lpRef": _ref(row, "lp_ref", index),
                }
            )
        elif action == "withdraw":
            rows.append(
                {
                    "action": action,
                    "lineNumber": index,
                    "step": tx,
                    **_timestamps(row, index),
                    **_oracle_refresh(row, index),
                    "lpRef": _ref(row, "lp_ref", index),
                }
            )
        else:
            raise ValueError(f'Scenario line {index}: unsupported action "{action}"')
    return rows


def parse_scenario(path: Path) -> list[dict[str, Any]]:
    return parse_scenario_text(path.read_text())


def deepbook_div(x: int, y: int) -> int:
    return x * FLOAT_SCALING // y


def deepbook_div_up(x: int, y: int) -> int:
    return (x * FLOAT_SCALING + y - 1) // y


def deepbook_mul(x: int, y: int) -> int:
    return x * y // FLOAT_SCALING


def deepbook_mul_up(x: int, y: int) -> int:
    return (x * y + FLOAT_SCALING - 1) // FLOAT_SCALING


def mul_div_round_down(a: int, b: int, c: int) -> int:
    return a * b // c


def mul_div_round_up(a: int, b: int, c: int) -> int:
    return (a * b + c - 1) // c


def live_forward(
    pyth_spot: int,
    block_scholes_forward: int,
    block_scholes_spot: int,
) -> int:
    # Mirror pricing::resolve_live_pricer's fresh-Pyth branch.
    return mul_div_round_down(
        pyth_spot,
        block_scholes_forward,
        block_scholes_spot,
    )


def assert_valid_leverage(leverage: int) -> None:
    if leverage < LEVERAGE_ONE_X:
        raise ValueError("invalid leverage multiplier")


def leverage_multiplier(leverage: int) -> int:
    assert_valid_leverage(leverage)
    return leverage


def admission_leverage_cap(entry_probability: int) -> int:
    risk_curve = mul_div_round_down(
        entry_probability,
        FLOAT_SCALING + ADMISSION_LEVERAGE_CURVE_K,
        entry_probability + ADMISSION_LEVERAGE_CURVE_K,
    )
    return FLOAT_SCALING + deepbook_mul(MAX_ADMISSION_LEVERAGE - FLOAT_SCALING, risk_curve)


def assert_admission_leverage_cap(entry_probability: int, leverage: int) -> None:
    assert_valid_leverage(leverage)
    if leverage > admission_leverage_cap(entry_probability):
        raise ValueError("leverage above admission cap")


def net_premium_from_entry_value(entry_value: int, leverage: int) -> int:
    return deepbook_div_up(entry_value, leverage_multiplier(leverage))


def assert_net_premium_above_min(net_premium: int) -> None:
    # Mirror strike_exposure_config.move: net_premium >= min_net_premium!(), so a
    # net premium exactly equal to the minimum is allowed.
    if net_premium < MIN_NET_PREMIUM:
        raise ValueError("net premium below minimum")


def compute_mint_terms(entry_probability: int, quantity: int, leverage: int) -> dict[str, int]:
    assert_admission_leverage_cap(entry_probability, leverage)
    entry_exposure_value = deepbook_mul(entry_probability, quantity)
    contribution = net_premium_from_entry_value(entry_exposure_value, leverage)
    return {
        "entry_exposure_value": entry_exposure_value,
        "contribution": contribution,
        "floor_shares": entry_exposure_value - contribution,
        "leverage_multiplier": leverage_multiplier(leverage),
    }


def split_partial_close_floor(
    old_quantity: int,
    old_floor_shares: int,
    close_quantity: int,
) -> tuple[int, int, int]:
    if close_quantity > old_quantity:
        raise ValueError("close quantity exceeds order quantity")
    remaining_quantity = old_quantity - close_quantity
    remaining_floor_shares = mul_div_round_down(
        old_floor_shares,
        remaining_quantity,
        old_quantity,
    )
    remove_floor_shares = old_floor_shares - remaining_floor_shares
    return remaining_quantity, remaining_floor_shares, remove_floor_shares


def compute_live_close_terms(
    range_probability: int,
    old_quantity: int,
    old_floor_shares: int,
    close_quantity: int,
) -> dict[str, int]:
    (
        remaining_quantity,
        remaining_floor_shares,
        remove_floor_shares,
    ) = split_partial_close_floor(
        old_quantity,
        old_floor_shares,
        close_quantity,
    )
    gross_redeem_amount = deepbook_mul(range_probability, close_quantity)
    return {
        "remaining_quantity": remaining_quantity,
        "remaining_floor_shares": remaining_floor_shares,
        "remove_floor_shares": remove_floor_shares,
        "gross_redeem_amount": gross_redeem_amount,
        "redeem_amount": max(0, gross_redeem_amount - remove_floor_shares),
    }


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


def ln_ratio_fixed(numerator: int, denominator: int) -> I64:
    ratio = numerator * FLOAT_SCALING // denominator
    if 1 < ratio <= POS_INF_STRIKE:
        return ln_fixed(ratio)
    return ln_fixed(numerator).sub(ln_fixed(denominator))


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


def sqrt_fixed(x: int, precision: int) -> int:
    multiplier = FLOAT_SCALING // precision
    scaled = x * multiplier * F
    return sqrt_u128(scaled) // multiplier


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


def compute_nd2(svi: dict[str, Any], forward: int, strike: int) -> int:
    k = ln_ratio_fixed(strike, forward)
    m = I64(svi["m"], svi["mNegative"])
    k_minus_m = k.sub(m)
    k_minus_m_squared = k_minus_m.square_scaled()
    sigma = svi["sigma"]
    sigma_squared = deepbook_mul(sigma, sigma)
    sq = sqrt_fixed(k_minus_m_squared + sigma_squared, FLOAT_SCALING)
    rho = I64(svi["rho"], svi["rhoNegative"])
    rho_km = rho.mul_scaled(k_minus_m)
    inner = rho_km.add(I64(sq))
    if inner.is_negative:
        raise ValueError("SVI inner term cannot be negative")
    a = I64(svi["a"], svi.get("aNegative", False))
    wide_increment = svi["b"] * inner.magnitude
    wide_a = a.magnitude * FLOAT_SCALING
    if a.is_negative:
        if wide_increment < wide_a:
            raise ValueError("SVI total variance must be positive")
        wide_total_var = wide_increment - wide_a
    else:
        wide_total_var = wide_increment + wide_a
    total_var = wide_total_var // FLOAT_SCALING
    if total_var == 0:
        raise ValueError("SVI total variance must be positive")
    sqrt_var = sqrt_u128(wide_total_var)
    d2_numerator = k.add(I64(total_var // 2))
    d2 = d2_numerator.div_scaled(I64(sqrt_var)).neg()
    nd2 = normal_cdf(d2)

    slope_ratio = k_minus_m.div_scaled(I64(sq))
    slope = rho.add(slope_ratio)
    w_prime = I64(svi["b"]).mul_scaled(slope)
    if w_prime.magnitude == 0:
        return nd2

    correction = mul_div_round_down(normal_pdf(d2), w_prime.magnitude, 2 * sqrt_var)
    if w_prime.is_negative:
        return min(FLOAT_SCALING, nd2 + correction)
    return nd2 - correction if nd2 > correction else 0


def svi_cache_key(svi: dict[str, Any]) -> tuple[int, bool, int, int, bool, int, bool, int]:
    return (
        svi["a"],
        svi.get("aNegative", False),
        svi["b"],
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


def directional_probability_bounds(curve: list[dict[str, int]], lower: int, higher: int) -> tuple[int, int]:
    if lower >= higher or ((lower == NEG_INF_STRIKE) == (higher == POS_INF_STRIKE)):
        raise ValueError("invalid liquidation range")
    if not curve:
        raise ValueError("empty liquidation curve")
    is_up = higher == POS_INF_STRIKE
    strike = lower if is_up else higher
    if strike < curve[0]["strike"] or strike > curve[-1]["strike"]:
        raise ValueError("strike outside liquidation curve")

    lo = 0
    hi = len(curve)
    while lo < hi:
        mid = (lo + hi) // 2
        if curve[mid]["strike"] < strike:
            lo = mid + 1
        else:
            hi = mid

    point = curve[lo]
    if point["strike"] == strike:
        price = point["up_price"] if is_up else FLOAT_SCALING - point["up_price"]
        return price, price

    lo_point = curve[lo - 1]
    if lo_point["up_price"] < point["up_price"]:
        raise ValueError("curve price underflow")
    if is_up:
        return point["up_price"], lo_point["up_price"]
    return FLOAT_SCALING - lo_point["up_price"], FLOAT_SCALING - point["up_price"]


def build_curve(svi: dict[str, Any], forward: int, min_strike: int, max_strike: int) -> list[dict[str, int]]:
    if min_strike > max_strike:
        raise ValueError("invalid curve range")
    if min_strike == max_strike:
        return [{"strike": min_strike, "up_price": compute_up_price(svi, forward, min_strike)}]

    points = [
        {"strike": min_strike, "up_price": compute_up_price(svi, forward, min_strike)},
        {"strike": max_strike, "up_price": compute_up_price(svi, forward, max_strike)},
    ]
    while len(points) < CURVE_SAMPLES:
        best_idx = None
        best_diff = 0
        for i in range(len(points) - 1):
            lo = points[i]
            hi = points[i + 1]
            if hi["strike"] - lo["strike"] <= ORACLE_TICK_SIZE:
                continue
            if lo["up_price"] < hi["up_price"]:
                raise ValueError("curve price underflow")
            diff = lo["up_price"] - hi["up_price"]
            if diff > best_diff:
                best_idx = i
                best_diff = diff
        if best_idx is None:
            break
        lo = points[best_idx]
        hi = points[best_idx + 1]
        mid = align_strike_to_tick((lo["strike"] + hi["strike"]) // 2)
        points.insert(best_idx + 1, {"strike": mid, "up_price": compute_up_price(svi, forward, mid)})
    return points


def order_id_for_terms(order: dict[str, Any]) -> int:
    return encode_order_id(
        lower_tick=order["lower_tick"],
        higher_tick=order["higher_tick"],
        pos_inf_tick=POS_INF_TICK,
        floor_shares=order_floor_shares(order),
        quantity=order["quantity"],
        sequence=order["sequence"],
        position_lot_size=POSITION_LOT_SIZE,
    )


def floor_amount(floor_shares: int) -> int:
    return floor_shares


def liquidation_threshold_value(floor_amount: int) -> int:
    return deepbook_div(floor_amount, LIQUIDATION_LTV)


def assert_mint_above_liquidation_threshold(
    entry_probability: int,
    quantity: int,
    leverage: int,
    floor_shares: int,
) -> None:
    if leverage == LEVERAGE_ONE_X:
        return
    threshold_value = liquidation_threshold_value(floor_amount(floor_shares))
    gross_value = deepbook_mul(entry_probability, quantity)
    if gross_value <= threshold_value:
        raise ValueError("order below liquidation threshold at entry")


def order_floor_shares(order: dict[str, Any]) -> int:
    return order["floor_shares"]


def current_order_floor_amount(model: dict[str, Any], order: dict[str, Any]) -> int:
    return floor_amount(order_floor_shares(order))


def model_fee_time_to_expiry_ms(model: dict[str, Any], timestamp_ms: int | None = None) -> int | None:
    if not model.get("exact_time"):
        return None
    now_ms = model.get("now_ms") if timestamp_ms is None else timestamp_ms
    expiry_ms = model.get("expiry_ms")
    if now_ms is None or expiry_ms is None:
        raise ValueError("exact-time fee ramp requires now_ms and expiry_ms")
    return max(0, expiry_ms - now_ms)


def order_index_update_terms(order: dict[str, Any]) -> tuple[int, int]:
    floor_shares = order_floor_shares(order)
    return (order["quantity"], floor_shares)


def invalidate_valuation_cache(model: dict[str, Any]) -> None:
    model["valuation_cache"]["liability_key"] = None
    model["valuation_cache"]["liability"] = None


def insert_live_order(model: dict[str, Any], order: dict[str, Any]) -> None:
    quantity, floor_shares = order_index_update_terms(order)
    assert_mint_above_liquidation_threshold(
        order["entry_probability"],
        order["quantity"],
        order["leverage"],
        floor_shares,
    )
    # The payout tree owns both the linear quantity walk and max-point net payout
    # reserve reads. The replay mirrors NAV from model["orders"] directly after
    # checking the same active-book monotonicity precondition as the on-chain
    # price memo, so it needs no per-order NAV index.
    model["payout"].insert_range(order["lower"], order["higher"], quantity, floor_shares)
    invalidate_valuation_cache(model)
    track_minted_boundaries(model, order["lower"], order["higher"])
    insert_active_order(model, order["ref"])


def remove_closed_live_order(
    model: dict[str, Any],
    order: dict[str, Any],
    resulting_order: dict[str, Any] | None,
) -> None:
    old_quantity, old_floor_shares = order_index_update_terms(order)
    if resulting_order is None:
        remaining_floor_shares = 0
        remaining_quantity = 0
    else:
        remaining_quantity, remaining_floor_shares = order_index_update_terms(resulting_order)

    model["payout"].remove_range(order["lower"], order["higher"], old_quantity, old_floor_shares)
    if resulting_order is not None:
        model["payout"].insert_range(
            resulting_order["lower"],
            resulting_order["higher"],
            remaining_quantity,
            remaining_floor_shares,
        )
    invalidate_valuation_cache(model)


def remove_live_order(model: dict[str, Any], order: dict[str, Any]) -> None:
    remove_closed_live_order(model, order, None)


def valuation_curve_key(
    model: dict[str, Any],
) -> tuple[int, int, bool, int, int, bool, int, bool, int, int, int] | None:
    if model["current_svi"] is None or model["current_forward"] == 0:
        raise ValueError("pool valuation requires prior price and SVI updates")
    if model["minted_min_strike"] is None or model["minted_max_strike"] is None:
        return None
    return (
        model["current_forward"],
        *svi_cache_key(model["current_svi"]),
        model["minted_min_strike"],
        model["minted_max_strike"],
    )


def build_valuation_curve(model: dict[str, Any]) -> list[dict[str, int]] | None:
    key = valuation_curve_key(model)
    if key is None:
        return None
    cache = model["valuation_cache"]
    if cache["curve_key"] == key:
        return cache["curve"]
    curve = build_curve(
        model["current_svi"],
        model["current_forward"],
        model["minted_min_strike"],
        model["minted_max_strike"],
    )
    cache["curve_key"] = key
    cache["curve"] = curve
    cache["liability_key"] = None
    cache["liability"] = None
    return curve


# --- Exact NAV liability (replaces the deleted dense StrikeNavMatrix + curve). ---
# The contract's `strike_exposure::exact_live_liability` is `linear - correction`.
# The payout-tree `walk_linear` and leveraged-book `correction_value` are efficient
# on-chain aggregations of per-order sums when the active boundary UP prices are
# monotone. The contract rejects non-monotone active boundary sets during the price
# memo walk; mirror that precondition, then sum order-by-order here (the simulation
# has one book, so the O(n) walk is fine and exact):
#   linear     = Σ_active           quantity · range_price(lower, higher)
#   correction = Σ_active_leveraged min(quantity · range_price(lower, higher),
#                                       floor_shares)
#   exact_live_liability = max(0, linear - correction)
# There is NO conservative band anymore (deleted with the approximate-NAV world):
# the flush prices one exact mark for both supply and withdraw.
def assert_active_book_monotone(model: dict[str, Any]) -> None:
    boundaries = sorted(
        {
            strike
            for order in model["orders"].values()
            if order["status"] == "active"
            for strike in (order["lower"], order["higher"])
            if strike not in (NEG_INF_STRIKE, POS_INF_STRIKE)
        },
    )
    previous: int | None = None
    for strike in boundaries:
        price = compute_up_price(model["current_svi"], model["current_forward"], strike)
        if previous is not None and price > previous:
            raise ValueError("non-monotone active-book SVI surface")
        previous = price


def exact_live_liability(model: dict[str, Any]) -> int:
    if model["current_svi"] is None or model["current_forward"] == 0:
        raise ValueError("pool valuation requires prior price and SVI updates")
    assert_active_book_monotone(model)
    linear = 0
    correction = 0
    for order in model["orders"].values():
        if order["status"] != "active":
            continue
        range_value = deepbook_mul(
            compute_range_price(model["current_svi"], model["current_forward"], order["lower"], order["higher"]),
            order["quantity"],
        )
        linear += range_value
        if order["leverage"] != LEVERAGE_ONE_X:
            floor_value = floor_amount(order_floor_shares(order))
            correction += min(range_value, floor_value)
    return max(0, linear - correction)


def live_position_liability(model: dict[str, Any], curve: list[dict[str, int]] | None = None) -> int:
    # `curve` is accepted for call-site compatibility but ignored: the exact walk
    # needs no curve. (Kept positional so the Python-only derived sampler, which
    # passes a curve, still type-checks.)
    return exact_live_liability(model)


# Scalar replay of the `current_nav_approx` center for one ExpiryMarket: free cash
# minus the per-order live-liability center, floored at zero. free_cash =
# expiry_cash - rebate_reserve. This helper does not reproduce the Approx radius.
def current_nav(model: dict[str, Any], state: dict[str, int]) -> int:
    rebate_reserve = deepbook_mul(state["expiry_unresolved_trading_fees"], TRADING_LOSS_REBATE_RATE)
    free_cash = max(0, state["expiry_cash_balance"] - rebate_reserve)
    return max(0, free_cash - exact_live_liability(model))


def compute_pool_value(
    model: dict[str, Any],
    state: dict[str, int],
    curve: list[dict[str, int]] | None = None,
    position_liability: int | None = None,
) -> int:
    # Scalar-center analogue of `plp::lp_pool_value_approx`, where the single
    # active market contributes the `current_nav` center above (settled markets
    # contribute 0 — not modelled here, settlement is stubbed). This mirrors the
    # saturating exclusion of unmaterialized and carried protocol profit, but does
    # not compute the on-chain certificate or its directional flush marks.
    if model["current_svi"] is None or model["current_forward"] == 0:
        raise ValueError("pool valuation requires prior price and SVI updates")
    active_expiry_value = current_nav(model, state)
    exclusion = unmaterialized_protocol_profit_exclusion(state, active_expiry_value)
    return max(0, state["vault_idle_balance"] + active_expiry_value - exclusion - state["pending_protocol_profit"])


def expiry_net_funding(state: dict[str, int]) -> int:
    return max(0, state["expiry_sent_to_expiry"] - state["expiry_received_from_expiry"])


def available_expiry_funding(state: dict[str, int]) -> int:
    return max(0, MAX_EXPIRY_ALLOCATION - expiry_net_funding(state))


def payout_reserve(model: dict[str, Any]) -> int:
    max_net_payout, total_net_payout = model["payout"].net_payout_reserve_terms()
    gap = total_net_payout - max_net_payout
    if gap < 0:
        raise ValueError("net payout sum below payout-tree max")
    return max_net_payout + deepbook_mul(BACKING_BUFFER_LAMBDA, gap)


def record_sent_to_expiry(state: dict[str, int], amount: int) -> None:
    if amount == 0:
        return
    if state["terminal_accounting_started"]:
        raise ValueError("cannot send cash after terminal accounting starts")
    state["expiry_sent_to_expiry"] += amount
    state["profit_basis_debits"] += amount


def record_received_from_expiry(state: dict[str, int], amount: int) -> None:
    if amount == 0:
        return
    state["expiry_received_from_expiry"] += amount
    state["profit_basis_credits"] += amount


def realize_pending_protocol_profit(state: dict[str, int]) -> int:
    draw = min(state["pending_protocol_profit"], state["vault_idle_balance"])
    state["pending_protocol_profit"] -= draw
    state["vault_idle_balance"] -= draw
    state["vault_protocol_reserve_balance"] += draw
    return draw


def realize_protocol_profit(state: dict[str, int], amount: int) -> int:
    state["pending_protocol_profit"] += amount
    return realize_pending_protocol_profit(state)


def materialize_expiry_profit(state: dict[str, int]) -> tuple[int, int, int]:
    initial_loss = 0
    if not state["terminal_accounting_started"]:
        state["terminal_accounting_started"] = 1
        if state["expiry_sent_to_expiry"] > state["expiry_received_from_expiry"]:
            state["terminal_received_watermark"] = state["expiry_received_from_expiry"]
            initial_loss = state["expiry_sent_to_expiry"] - state["expiry_received_from_expiry"]
        else:
            state["terminal_received_watermark"] = state["expiry_sent_to_expiry"]

    received = state["expiry_received_from_expiry"]
    if received > state["terminal_received_watermark"]:
        profit = received - state["terminal_received_watermark"]
        state["terminal_received_watermark"] = received
    else:
        profit = 0

    state["net_losses_to_fill"] += initial_loss
    if profit == 0:
        return (0, 0, 0)
    if profit <= state["net_losses_to_fill"]:
        state["net_losses_to_fill"] -= profit
        return (0, 0, 0)

    materialized_profit = profit - state["net_losses_to_fill"]
    state["net_losses_to_fill"] = 0
    state["profit_basis_debits"] += materialized_profit
    protocol_profit = deepbook_mul(materialized_profit, PROTOCOL_RESERVE_PROFIT_SHARE)
    lp_profit = materialized_profit - protocol_profit
    realize_protocol_profit(state, protocol_profit)
    return (materialized_profit, lp_profit, protocol_profit)


def expiry_rebalance_cash_terms(model: dict[str, Any], state: dict[str, int]) -> tuple[int, int, int]:
    required_cash = payout_reserve(model) + deepbook_mul(
        state["expiry_unresolved_trading_fees"],
        TRADING_LOSS_REBATE_RATE,
    )
    target_buffer = deepbook_mul(required_cash, EXPIRY_REBALANCE_PCT)
    target_cash = max(required_cash + target_buffer, INITIAL_EXPIRY_CASH)
    sweep_threshold_cash = max(required_cash + target_buffer + target_buffer, INITIAL_EXPIRY_CASH)
    return state["expiry_cash_balance"], target_cash, sweep_threshold_cash


def sync_active_expiry_cash_updates(model: dict[str, Any], state: dict[str, int]) -> list[dict[str, Any]]:
    cash_balance, target_cash, sweep_threshold_cash = expiry_rebalance_cash_terms(model, state)
    if cash_balance < target_cash:
        top_up = min(target_cash - cash_balance, state["vault_idle_balance"], available_expiry_funding(state))
        if top_up <= 0:
            return []
        state["vault_idle_balance"] -= top_up
        state["expiry_cash_balance"] += top_up
        record_sent_to_expiry(state, top_up)
        return [
            {
                "type": "expiry_cash_rebalanced",
                "amount": str(top_up),
                "to_expiry": True,
                "target_cash": str(target_cash),
                "protocol_profit_realized": "0",
            }
        ]
    if cash_balance <= sweep_threshold_cash:
        return []

    returned_cash = cash_balance - target_cash
    state["expiry_cash_balance"] -= returned_cash
    state["vault_idle_balance"] += returned_cash
    record_received_from_expiry(state, returned_cash)
    protocol_profit_realized = realize_pending_protocol_profit(state)
    return [
        {
            "type": "expiry_cash_rebalanced",
            "amount": str(returned_cash),
            "to_expiry": False,
            "target_cash": str(target_cash),
            "protocol_profit_realized": str(protocol_profit_realized),
        }
    ]


# The flush valuation: rebalance the (single) active expiry, then price the pool
# NAV at the EXACT mark. The deleted approximate-NAV world's verified-vs-unscanned
# floor scan, supply_liability band, and aggregate_band are GONE — the flush uses
# one exact `current_nav` for both supply and withdraw (DOCS_CONSOLIDATED_FACTS §3,
# move.md NAV-mark invariant). Returns (cash-rebalance updates, pool_value,
# synced_state).
# The parity replay calls this once per synthetic flush, then uses the frozen pool
# value and pre-drain total supply for both FIFO queues.
def flush_valuation(
    model: dict[str, Any],
    state: dict[str, int],
) -> tuple[list[dict[str, Any]], int, dict[str, int]]:
    synced_state = dict(state)
    updates = sync_active_expiry_cash_updates(model, synced_state)
    pool_value = compute_pool_value(model, synced_state)
    return updates, pool_value, synced_state


def unmaterialized_protocol_profit_exclusion(state: dict[str, int], active_expiry_value: int) -> int:
    aggregate_credits = state["profit_basis_credits"] + active_expiry_value
    aggregate_debits = state["profit_basis_debits"]
    if aggregate_credits <= aggregate_debits:
        return 0
    return deepbook_mul(aggregate_credits - aggregate_debits, PROTOCOL_RESERVE_PROFIT_SHARE)


def expiry_fee_multiplier(time_to_expiry_ms: int | None) -> int:
    if time_to_expiry_ms is None or time_to_expiry_ms >= EXPIRY_FEE_WINDOW_MS:
        return FLOAT_SCALING
    ramp = mul_div_round_down(
        EXPIRY_FEE_MAX_MULTIPLIER - FLOAT_SCALING,
        EXPIRY_FEE_WINDOW_MS - time_to_expiry_ms,
        EXPIRY_FEE_WINDOW_MS,
    )
    return FLOAT_SCALING + ramp


def fee_rate(probability: int, time_to_expiry_ms: int | None = None) -> int:
    if probability == 0 or probability == FLOAT_SCALING:
        raw_fee = 0
    else:
        complement = FLOAT_SCALING - probability
        variance = deepbook_mul(probability, complement)
        bernoulli_factor = sqrt_fixed(variance, FLOAT_SCALING)
        raw_fee = deepbook_mul(BASE_FEE, bernoulli_factor)
    base = raw_fee if raw_fee > MIN_FEE else MIN_FEE
    return deepbook_mul(base, expiry_fee_multiplier(time_to_expiry_ms))


def assert_entry_probability_bounds(probability: int) -> None:
    if probability < MIN_ENTRY_PROBABILITY or probability > MAX_ENTRY_PROBABILITY:
        raise ValueError("entry probability out of bounds")


def assert_mint_fee_rate(probability: int, time_to_expiry_ms: int | None = None) -> int:
    return fee_rate(probability, time_to_expiry_ms)


def initial_state() -> dict[str, int]:
    if VAULT_SEED < INITIAL_EXPIRY_CASH:
        raise ValueError("vault seed is below the setup expiry cash floor")

    return {
        "manager_balance": MANAGER_SEED,
        "expiry_cash_balance": INITIAL_EXPIRY_CASH,
        "expiry_unresolved_trading_fees": 0,
        "vault_idle_balance": VAULT_SEED + MIN_BOOTSTRAP_LIQUIDITY - INITIAL_EXPIRY_CASH,
        "vault_protocol_reserve_balance": 0,
        "pending_protocol_profit": 0,
        "expiry_sent_to_expiry": INITIAL_EXPIRY_CASH,
        "expiry_received_from_expiry": 0,
        "terminal_accounting_started": 0,
        "terminal_received_watermark": 0,
        "net_losses_to_fill": 0,
        "profit_basis_debits": INITIAL_EXPIRY_CASH,
        "profit_basis_credits": 0,
        "vault_total_plp_supply": INITIAL_TOTAL_PLP_SUPPLY,
        "supply_requests_pending": 0,
        "withdraw_requests_pending": 0,
        "open_order_count": 0,
        "open_order_quantity": 0,
        "liquidated_order_count": 0,
    }


CANONICAL_STATE_KEYS = (
    "manager_balance",
    "expiry_cash_balance",
    "expiry_unresolved_trading_fees",
    "vault_idle_balance",
    "vault_protocol_reserve_balance",
    "pending_protocol_profit",
    "profit_basis_debits",
    "profit_basis_credits",
    "vault_total_plp_supply",
    "supply_requests_pending",
    "withdraw_requests_pending",
    "open_order_count",
    "open_order_quantity",
    "liquidated_order_count",
)


def state_snapshot(state: dict[str, int]) -> dict[str, str]:
    return {key: str(state[key]) for key in CANONICAL_STATE_KEYS}


def svi_input(row: dict[str, Any]) -> dict[str, str]:
    return {
        "a": signed_svi_value(row["a"], row.get("aNegative", False)),
        "b": str(row["b"]),
        "rho": signed_svi_value(row["rho"], row["rhoNegative"]),
        "m": signed_svi_value(row["m"], row["mNegative"]),
        "sigma": str(row["sigma"]),
    }


def mint_input(row: dict[str, Any]) -> dict[str, str]:
    # Mirror sim.ts mintInput: the canonical mint input is the (lower_tick,
    # higher_tick) pair the entrypoint takes directly (no standalone range key).
    strike = align_strike_to_tick(row["strike"])
    lower_tick, higher_tick = binary_range_ticks(strike, row["isUp"])
    return {
        "order_ref": row["orderRef"],
        "lower_tick": str(lower_tick),
        "higher_tick": str(higher_tick),
        "quantity": str(row["quantity"]),
        "leverage": str(row["leverage"]),
    }


def row_input(row: dict[str, Any]) -> dict[str, Any]:
    action = row["action"]
    if action == "oracle_mint_ptb":
        return {
            "spot": str(row["spot"]),
            "forward": str(row["forward"]),
            "svi": svi_input(row),
            **mint_input(row),
        }
    if action == "redeem":
        return {
            **oracle_refresh_input(row),
            "order_ref": row["orderRef"],
            "close_quantity": str(row["closeQuantity"]),
            "replacement_order_ref": row["replacementOrderRef"],
        }
    if action == "supply":
        return {**oracle_refresh_input(row), "amount": str(row["amount"]), "lp_ref": row["lpRef"]}
    return {**oracle_refresh_input(row), "lp_ref": row["lpRef"]}


def oracle_refresh_input(row: dict[str, Any]) -> dict[str, Any]:
    oracle = row["oracleRefresh"]
    return {
        "spot": str(oracle["spot"]),
        "forward": str(oracle["forward"]),
        "svi": svi_input(oracle),
    }


# Propbook Pyth oracle_lane::ObservationRecorded normalized view: the global Pyth
# spot tick. Mirrors the TS normalizer; timestamps are localnet-clock-derived and
# excluded from the parity diff.
def pyth_feed_update(price: dict[str, Any]) -> dict[str, str]:
    return {
        "type": "pyth_feed_updated",
        "spot": str(price["spot"]),
    }


# Synthetic normalized view collapsed from Propbook's split Block Scholes spot,
# forward, and SVI feed events. `basis` is no longer an event field (derived as
# forward/spot).
def block_scholes_surface_update(oracle: dict[str, Any]) -> dict[str, str]:
    return {
        "type": "block_scholes_surface_updated",
        "spot": str(oracle["spot"]),
        "forward": str(oracle["forward"]),
        **svi_input(oracle),
    }


def apply_inline_oracle_refresh(model: dict[str, Any], row: dict[str, Any], updates: list[dict[str, Any]]) -> None:
    oracle = row if row["action"] == "oracle_mint_ptb" else row["oracleRefresh"]
    model["current_forward"] = live_forward(
        oracle["spot"],
        oracle["forward"],
        oracle["spot"],
    )
    model["current_svi"] = oracle
    updates.append(pyth_feed_update(oracle))
    updates.append(block_scholes_surface_update(oracle))


def order_minted_update(
    mint: dict[str, Any],
    svi: dict[str, Any],
    forward: int,
    sequence: int,
    time_to_expiry_ms: int | None = None,
) -> dict[str, str]:
    strike = align_strike_to_tick(mint["strike"])
    lower, higher = binary_range_bounds(strike, mint["isUp"])
    lower_tick, higher_tick = binary_range_ticks(strike, mint["isUp"])
    entry_probability = compute_range_price(svi, forward, lower, higher)
    assert_entry_probability_bounds(entry_probability)
    fee_amount = deepbook_mul_up(assert_mint_fee_rate(entry_probability, time_to_expiry_ms), mint["quantity"])
    terms = compute_mint_terms(entry_probability, mint["quantity"], mint["leverage"])
    assert_net_premium_above_min(terms["contribution"])
    return {
        "type": "order_minted",
        "order_ref": mint["orderRef"],
        "order_sequence": str(sequence),
        # Canonical strike range as absolute ticks, matching the OrderMinted event
        # (raw `lower`/`higher` are kept locally only for pricing, not emitted).
        "lower_tick": str(lower_tick),
        "higher_tick": str(higher_tick),
        "leverage": str(mint["leverage"]),
        "entry_probability": str(entry_probability),
        "quantity": str(mint["quantity"]),
        "contribution": str(terms["contribution"]),
        "trading_fee": str(fee_amount),
        "fee_incentive_subsidy": "0",
        "builder_fee": "0",
        "penalty_fee": "0",
    }


def apply_update(state: dict[str, int], update: dict[str, Any]) -> None:
    if update["type"] == "order_minted":
        contribution = int(update["contribution"])
        trading_fee = int(update["trading_fee"])
        fee_incentive_subsidy = int(update.get("fee_incentive_subsidy", 0))
        builder_fee = int(update["builder_fee"])
        penalty_fee = int(update["penalty_fee"])
        quantity = int(update["quantity"])
        state["manager_balance"] -= (
            contribution + (trading_fee - fee_incentive_subsidy) + builder_fee + penalty_fee
        )
        state["expiry_cash_balance"] += contribution + trading_fee + penalty_fee
        state["expiry_unresolved_trading_fees"] += trading_fee
        state["open_order_count"] += 1
        state["open_order_quantity"] += quantity
    elif update["type"] == "order_liquidated":
        quantity = int(update["quantity"])
        state["open_order_count"] -= 1
        state["open_order_quantity"] -= quantity
        state["liquidated_order_count"] += 1
    elif update["type"] == "live_order_redeemed":
        redeem_amount = int(update["redeem_amount"])
        trading_fee = int(update["trading_fee"])
        builder_fee = int(update["builder_fee"])
        penalty_fee = int(update["penalty_fee"])
        quantity_closed = int(update["quantity_closed"])
        remaining_quantity = int(update["remaining_quantity"])
        state["manager_balance"] += redeem_amount - trading_fee - builder_fee - penalty_fee
        state["expiry_cash_balance"] -= redeem_amount
        state["expiry_cash_balance"] += trading_fee + penalty_fee
        state["expiry_unresolved_trading_fees"] += trading_fee
        state["open_order_quantity"] -= quantity_closed
        if remaining_quantity == 0:
            state["open_order_count"] -= 1
    elif update["type"] == "liquidated_order_redeemed":
        state["liquidated_order_count"] -= 1
    elif update["type"] == "settled_order_redeemed":
        payout = int(update["payout_amount"])
        quantity_closed = int(update["quantity_closed"])
        state["manager_balance"] += payout
        state["expiry_cash_balance"] -= payout
        state["open_order_count"] -= 1
        state["open_order_quantity"] -= quantity_closed
    elif update["type"] == "expiry_cash_rebalanced":
        amount = int(update["amount"])
        if update["to_expiry"]:
            state["expiry_cash_balance"] += amount
            state["vault_idle_balance"] -= amount
            record_sent_to_expiry(state, amount)
        else:
            protocol_profit_realized = int(update.get("protocol_profit_realized", 0))
            state["expiry_cash_balance"] -= amount
            state["vault_idle_balance"] += amount - protocol_profit_realized
            state["vault_protocol_reserve_balance"] += protocol_profit_realized
            state["pending_protocol_profit"] -= protocol_profit_realized
            record_received_from_expiry(state, amount)
    elif update["type"] == "expiry_cash_received":
        amount = int(update["amount"])
        state["expiry_cash_balance"] -= amount
        state["vault_idle_balance"] += amount
        record_received_from_expiry(state, amount)
    elif update["type"] == "expiry_profit_materialized":
        profit_basis_after = int(update["profit_basis_after"])
        reserve_after = int(update["protocol_reserve_balance_after"])
        pending_after = int(update["pending_protocol_profit_after"])
        protocol_profit_realized = reserve_after - state["vault_protocol_reserve_balance"]
        state["vault_idle_balance"] -= protocol_profit_realized
        state["vault_protocol_reserve_balance"] = reserve_after
        state["pending_protocol_profit"] = pending_after
        state["profit_basis_debits"] = profit_basis_after
    elif update["type"] == "supply_requested":
        state["supply_requests_pending"] = int(update["requests_pending_after"])
    elif update["type"] == "withdraw_requested":
        state["withdraw_requests_pending"] = int(update["requests_pending_after"])
    elif update["type"] == "request_cancelled":
        key = "supply_requests_pending" if update["is_supply"] else "withdraw_requests_pending"
        state[key] = int(update["requests_pending_after"])
    elif update["type"] == "supply_filled":
        if "requests_pending_after" in update:
            state["vault_total_plp_supply"] += int(update["shares_minted"])
            state["supply_requests_pending"] = int(update["requests_pending_after"])
        else:
            state["vault_idle_balance"] = int(update["idle_balance_after"])
            state["vault_total_plp_supply"] = int(update["total_supply_after"])
    elif update["type"] == "withdraw_filled":
        if "requests_pending_after" in update:
            state["vault_total_plp_supply"] -= int(update["shares_burned"])
            state["withdraw_requests_pending"] = int(update["requests_pending_after"])
        else:
            state["vault_idle_balance"] = int(update["idle_balance_after"])
            state["vault_total_plp_supply"] = int(update["total_supply_after"])
    elif update["type"] == "flush_executed":
        state["vault_idle_balance"] = int(update["idle_balance_after"])
        total_supply_after = int(update["total_supply_after"])
        if state["vault_total_plp_supply"] != total_supply_after:
            raise ValueError(
                "flush total supply mismatch: "
                f"deltas={state['vault_total_plp_supply']} event={total_supply_after}"
            )


def active_refs(model: dict[str, Any]) -> list[str]:
    return model["liquidation"].active_refs()


def active_order_count(model: dict[str, Any]) -> int:
    return model["liquidation"].active_order_count


def insert_active_order(model: dict[str, Any], ref: str) -> None:
    order = model["orders"][ref]
    if order["leverage"] == LEVERAGE_ONE_X:
        return
    model["liquidation"].insert_order(order["order_id"], ref)


def remove_active_order(model: dict[str, Any], ref: str) -> None:
    order = model["orders"][ref]
    if order["leverage"] == LEVERAGE_ONE_X:
        return
    model["liquidation"].remove_ref(ref)


def mark_order_liquidated(model: dict[str, Any], ref: str) -> None:
    order = model["orders"][ref]
    if order["leverage"] == LEVERAGE_ONE_X:
        return
    model["liquidation"].mark_ref_liquidated(ref)


def select_liquidation_candidates(model: dict[str, Any], budget: int) -> list[str]:
    candidate_ids = model["liquidation"].select_liquidation_candidates(
        budget,
        LIQUIDATION_HEAD_SCAN_DIVISOR,
    )
    return [model["liquidation"].ref_for(order_id) for order_id in candidate_ids]


def assert_liquidation_inputs(model: dict[str, Any]) -> None:
    if model["current_svi"] is None or model["current_forward"] == 0:
        raise ValueError("liquidation requires prior price and SVI updates")


def run_liquidation_pass_with_verification(
    model: dict[str, Any],
    budget: int,
) -> tuple[list[dict[str, str]], int, int]:
    candidates = select_liquidation_candidates(model, budget)
    if not candidates:
        return ([], 0, 0)
    assert_liquidation_inputs(model)
    updates = []
    verified_floor_amount = 0
    verified_range = 0
    for ref in candidates:
        order = model["orders"][ref]
        if order["status"] != "active":
            continue
        probability = compute_range_price(
            model["current_svi"],
            model["current_forward"],
            order["lower"],
            order["higher"],
        )
        gross_value = deepbook_mul(probability, order["quantity"])
        floor_amount = current_order_floor_amount(model, order)
        threshold_value = liquidation_threshold_value(floor_amount)
        if gross_value > threshold_value:
            verified_floor_amount += floor_amount
            verified_range += gross_value
            continue
        remove_live_order(model, order)
        mark_order_liquidated(model, ref)
        order["status"] = "liquidated"
        updates.append(
            {
                "type": "order_liquidated",
                "order_ref": ref,
                "order_sequence": str(order["sequence"]),
                "quantity": str(order["quantity"]),
                "gross_value": str(gross_value),
                "floor_amount": str(floor_amount),
                "liquidation_ltv": str(LIQUIDATION_LTV),
            }
        )
    return updates, verified_floor_amount, verified_range


def run_liquidation_pass(
    model: dict[str, Any],
    budget: int,
) -> list[dict[str, str]]:
    updates, _, _ = run_liquidation_pass_with_verification(model, budget)
    return updates


def append_pool_sync_phase(
    model: dict[str, Any],
    state: dict[str, int],
    updates: list[dict[str, Any]],
) -> tuple[int, dict[str, int]]:
    # The flush still runs a passive liquidation pass, but NAV no longer needs its
    # verified-floor/range output (the exact per-order floor-capped liability makes
    # an underwater order net to zero with no scan — see exact_live_liability), so
    # the verification plumbing and the band it fed are dropped.
    updates.extend(run_liquidation_pass(model, VALUATION_LIQUIDATION_BUDGET))
    sync_updates, pool_value, synced_state = flush_valuation(model, state)
    updates.extend(sync_updates)
    return pool_value, synced_state


def track_minted_boundaries(model: dict[str, Any], lower: int, higher: int) -> None:
    for strike in (lower, higher):
        if strike in (NEG_INF_STRIKE, POS_INF_STRIKE):
            continue
        if model["minted_min_strike"] is None or strike < model["minted_min_strike"]:
            model["minted_min_strike"] = strike
        if model["minted_max_strike"] is None or strike > model["minted_max_strike"]:
            model["minted_max_strike"] = strike


def mint_order(model: dict[str, Any], row: dict[str, Any], timestamp_ms: int) -> dict[str, str]:
    if model["current_svi"] is None or model["current_forward"] == 0:
        raise ValueError("mint requires prior price and SVI updates")
    if row["orderRef"] in model["orders"]:
        raise ValueError(f"duplicate order_ref {row['orderRef']}")
    update = order_minted_update(
        row,
        model["current_svi"],
        model["current_forward"],
        model["next_sequence"],
        model_fee_time_to_expiry_ms(model, timestamp_ms),
    )
    terms = compute_mint_terms(int(update["entry_probability"]), row["quantity"], row["leverage"])
    lower_tick = int(update["lower_tick"])
    higher_tick = int(update["higher_tick"])
    lower, higher = strikes_from_ticks(lower_tick, higher_tick)
    order = {
        "ref": row["orderRef"],
        "sequence": model["next_sequence"],
        "lower": lower,
        "higher": higher,
        "lower_tick": lower_tick,
        "higher_tick": higher_tick,
        "leverage": row["leverage"],
        "entry_probability": int(update["entry_probability"]),
        "quantity": row["quantity"],
        "contribution": int(update["contribution"]),
        "floor_shares": terms["floor_shares"],
        "status": "active",
    }
    order["order_id"] = order_id_for_terms(order)
    model["orders"][row["orderRef"]] = order
    model["next_sequence"] += 1
    insert_live_order(model, order)
    return update


def redeem_order(model: dict[str, Any], row: dict[str, Any]) -> dict[str, str]:
    ref = row["orderRef"]
    if ref not in model["orders"]:
        raise ValueError(f"unknown order_ref {ref}")
    order = model["orders"][ref]
    close_quantity = row["closeQuantity"]
    if close_quantity > order["quantity"]:
        raise ValueError(f"redeem close_quantity exceeds order quantity for {ref}")

    if order["status"] == "liquidated":
        if close_quantity != order["quantity"]:
            raise ValueError("liquidated redeem requires full close")
        if order["leverage"] != LEVERAGE_ONE_X:
            model["liquidation"].clear_liquidated(order["order_id"])
        del model["orders"][ref]
        return {
            "type": "liquidated_order_redeemed",
            "order_ref": ref,
            "order_sequence": str(order["sequence"]),
            "quantity_closed": str(close_quantity),
        }
    if order["status"] != "active":
        raise ValueError(f"order_ref {ref} is not redeemable")

    probability = compute_range_price(model["current_svi"], model["current_forward"], order["lower"], order["higher"])
    fee = deepbook_mul_up(fee_rate(probability, model_fee_time_to_expiry_ms(model)), close_quantity)
    close_terms = compute_live_close_terms(
        probability,
        order["quantity"],
        order_floor_shares(order),
        close_quantity,
    )
    remaining_quantity = close_terms["remaining_quantity"]
    if remaining_quantity == 0:
        replacement_ref = None
        replacement_sequence = None
        remove_active_order(model, ref)
        remove_live_order(model, order)
        del model["orders"][ref]
    else:
        replacement_ref = row["replacementOrderRef"] or ref
        replacement_terms = compute_mint_terms(order["entry_probability"], remaining_quantity, order["leverage"])
        replacement = {
            **order,
            "ref": replacement_ref,
            "sequence": model["next_sequence"],
            "quantity": remaining_quantity,
            "contribution": replacement_terms["contribution"],
            "floor_shares": close_terms["remaining_floor_shares"],
            "status": "active",
        }
        replacement["order_id"] = order_id_for_terms(replacement)
        remove_active_order(model, ref)
        remove_closed_live_order(model, order, replacement)
        del model["orders"][ref]
        model["next_sequence"] += 1
        model["orders"][replacement_ref] = replacement
        insert_active_order(model, replacement_ref)
        replacement_sequence = replacement["sequence"]

    redeem_amount = close_terms["redeem_amount"]
    fee = min(fee, redeem_amount)
    return {
        "type": "live_order_redeemed",
        "order_ref": ref,
        "order_sequence": str(order["sequence"]),
        "quantity_closed": str(close_quantity),
        "remaining_quantity": str(remaining_quantity),
        "replacement_order_ref": replacement_ref,
        "replacement_order_sequence": None if replacement_sequence is None else str(replacement_sequence),
        "redeem_amount": str(redeem_amount),
        "trading_fee": str(fee),
        "builder_fee": "0",
        "penalty_fee": "0",
    }


# === Async LP supply/withdraw (replaces the deleted synchronous SupplyExecuted /
# WithdrawExecuted). A supply/withdraw is now: a request that escrows funds, then a
# later privileged flush. These long-replay helpers intentionally use the scalar
# pool-value center for both directions; they do not reproduce the contract's
# `center + error` supply mark or `center - error` withdrawal mark. Both helpers
# round down, and a dust request that prices to 0 is refunded.
#
# These synchronous helpers are for the long Python-only replay. Normal parity
# queues requests and drains them later in `parity_flush_updates`.
def supply_update(
    model: dict[str, Any],
    row: dict[str, Any],
    pool_value: int,
    synced_state: dict[str, int],
) -> dict[str, str]:
    if row["lpRef"] in model["lp_refs"]:
        raise ValueError(f"duplicate lp_ref {row['lpRef']}")
    total_supply = synced_state["vault_total_plp_supply"]
    # Scalar replay supply calculation: bootstrap 1:1 requires an empty pool NAV.
    if total_supply == 0:
        if pool_value != 0:
            raise ValueError("bootstrap supply requires empty pool NAV")
        shares = row["amount"]
    elif pool_value == 0:
        shares = 0  # wiped pool — caller refunds the escrowed DUSDC
    else:
        shares = mul_div_round_down(row["amount"], total_supply, pool_value)
    if shares <= 0:
        raise ValueError("supply priced to zero shares (would be refunded)")
    model["lp_refs"][row["lpRef"]] = shares
    return {
        "type": "supply_filled",
        "lp_ref": row["lpRef"],
        "dusdc_amount": str(row["amount"]),
        "shares_minted": str(shares),
        "pool_value": str(pool_value),
        "total_supply_after": str(total_supply + shares),
        "idle_balance_after": str(synced_state["vault_idle_balance"] + row["amount"]),
    }


def withdraw_update(
    model: dict[str, Any],
    row: dict[str, Any],
    pool_value: int,
    synced_state: dict[str, int],
) -> dict[str, str]:
    shares = model["lp_refs"].get(row["lpRef"])
    if shares is None:
        raise ValueError(f"unknown lp_ref {row['lpRef']}")
    total_supply = synced_state["vault_total_plp_supply"]
    # Scalar replay withdrawal calculation: pro-rata and rounded down.
    payout = mul_div_round_down(shares, pool_value, total_supply) if total_supply else 0
    if payout <= 0:
        raise ValueError("withdraw priced to zero DUSDC (would be refunded)")
    if synced_state["vault_idle_balance"] < payout:
        raise ValueError("insufficient idle balance for withdraw")
    del model["lp_refs"][row["lpRef"]]
    return {
        "type": "withdraw_filled",
        "lp_ref": row["lpRef"],
        "shares_burned": str(shares),
        "dusdc_amount": str(payout),
        "pool_value": str(pool_value),
        "total_supply_after": str(total_supply - shares),
        "idle_balance_after": str(synced_state["vault_idle_balance"] - payout),
    }


def initial_manager_summary() -> dict[str, int]:
    return {
        "gross_paid_to_expiry": 0,
        "gross_received_from_expiry": 0,
        "trading_fees_paid": 0,
    }


def apply_manager_summary_update(summary: dict[str, int], update: dict[str, Any]) -> None:
    update_type = update["type"]
    if update_type == "order_minted":
        summary["gross_paid_to_expiry"] += int(update["contribution"])
        summary["trading_fees_paid"] += int(update["trading_fee"]) - int(
            update.get("fee_incentive_subsidy", 0)
        )
    elif update_type == "live_order_redeemed":
        summary["gross_received_from_expiry"] += int(update["redeem_amount"])
        summary["trading_fees_paid"] += int(update["trading_fee"])
    elif update_type == "settled_order_redeemed":
        summary["gross_received_from_expiry"] += int(update["payout_amount"])


def settled_order_payout(order: dict[str, Any], settlement_price: int) -> int:
    # Half-open (lower, higher] winner test on raw strikes. Bit-equivalent to the
    # contract's tick-domain predicate (range_codec::settlement_in_range, the single
    # owner both settlement surfaces derive from): for integer boundaries at exact
    # tick multiples, settlement > l*ts <=> l < ceil(settlement/ts) and
    # settlement <= h*ts <=> ceil(settlement/ts) <= h, with sentinel ends mapping to
    # 0 / u64::MAX — so the raw and tick thresholds agree for EVERY settlement,
    # whole-tick multiple or not.
    if settlement_price > order["lower"] and settlement_price <= order["higher"]:
        return order["quantity"] - order_floor_shares(order)
    return 0


def reset_terminal_model(model: dict[str, Any]) -> None:
    model["orders"].clear()
    model["liquidation"] = LiquidationBook()
    model["minted_min_strike"] = None
    model["minted_max_strike"] = None
    model["payout"] = StrikePayoutTree(
        min_strike=ORACLE_MIN_STRIKE,
        tick_size=ORACLE_TICK_SIZE,
        max_strike=ORACLE_MAX_STRIKE,
        neg_inf=NEG_INF_STRIKE,
        pos_inf=POS_INF_STRIKE,
    )
    invalidate_valuation_cache(model)


def assert_terminal_state_closed(state: dict[str, int]) -> None:
    expected_zero = (
        "expiry_cash_balance",
        "expiry_unresolved_trading_fees",
        "open_order_count",
        "open_order_quantity",
        "liquidated_order_count",
    )
    for key in expected_zero:
        if state[key] != 0:
            raise ValueError(f"terminal closeout left {key}={state[key]}")


def terminal_closeout_update(
    model: dict[str, Any],
    state: dict[str, int],
    manager_summary: dict[str, int],
    *,
    expiry_ms: int,
    settlement_timestamp_ms: int,
    settlement_price: int,
) -> dict[str, str]:
    active_orders = [order for order in model["orders"].values() if order["status"] == "active"]
    liquidated_orders = [order for order in model["orders"].values() if order["status"] == "liquidated"]

    settled_payout = 0
    winning_order_count = 0
    winning_quantity = 0
    active_quantity = 0
    for order in active_orders:
        active_quantity += order["quantity"]
        payout = settled_order_payout(order, settlement_price)
        settled_payout += payout
        if payout > 0:
            winning_order_count += 1
            winning_quantity += order["quantity"]

    indexed_payout = model["payout"].settled_payout_liability(settlement_price)
    if indexed_payout != settled_payout:
        raise ValueError(f"terminal payout index drifted: indexed={indexed_payout} scanned={settled_payout}")
    if settled_payout > state["expiry_cash_balance"]:
        raise ValueError("terminal payout exceeds expiry cash")

    state["manager_balance"] += settled_payout
    state["expiry_cash_balance"] -= settled_payout
    manager_summary["gross_received_from_expiry"] += settled_payout

    gross_profit = max(
        0,
        manager_summary["gross_received_from_expiry"] - manager_summary["gross_paid_to_expiry"],
    )
    trading_fees_paid = manager_summary["trading_fees_paid"]
    if trading_fees_paid > state["expiry_unresolved_trading_fees"]:
        raise ValueError("terminal trading fee basis exceeds unresolved trading fees")
    resolved_rebate_reserve = deepbook_mul(trading_fees_paid, TRADING_LOSS_REBATE_RATE)
    eligible_rebate = max(0, resolved_rebate_reserve - gross_profit)
    rebate_amount = deepbook_mul(eligible_rebate, TERMINAL_REBATE_FRACTION)
    if rebate_amount > state["expiry_cash_balance"]:
        raise ValueError("terminal rebate exceeds expiry cash")
    residual_rebate_reserve = resolved_rebate_reserve - rebate_amount
    state["manager_balance"] += rebate_amount
    state["expiry_cash_balance"] -= rebate_amount
    state["expiry_unresolved_trading_fees"] -= trading_fees_paid
    if residual_rebate_reserve > state["expiry_cash_balance"]:
        raise ValueError("terminal residual rebate reserve exceeds expiry cash")

    materialized_profit = 0
    protocol_profit = 0
    lp_profit = 0

    def materialize_terminal_return(amount: int) -> None:
        nonlocal materialized_profit, protocol_profit, lp_profit
        record_received_from_expiry(state, amount)
        update_materialized_profit, update_lp_profit, update_protocol_profit = materialize_expiry_profit(state)
        materialized_profit += update_materialized_profit
        lp_profit += update_lp_profit
        protocol_profit += update_protocol_profit

    returned_rebate_reserve = residual_rebate_reserve
    state["expiry_cash_balance"] -= returned_rebate_reserve
    state["vault_idle_balance"] += returned_rebate_reserve
    materialize_terminal_return(returned_rebate_reserve)

    returned_pool_cash = state["expiry_cash_balance"]
    state["expiry_cash_balance"] = 0
    state["vault_idle_balance"] += returned_pool_cash
    materialize_terminal_return(returned_pool_cash)
    returned_cash = returned_rebate_reserve + returned_pool_cash

    state["open_order_count"] = 0
    state["open_order_quantity"] = 0
    state["liquidated_order_count"] = 0
    reset_terminal_model(model)
    assert_terminal_state_closed(state)

    return {
        "type": "terminal_closeout",
        "expiry_ms": str(expiry_ms),
        "settlement_timestamp_ms": str(settlement_timestamp_ms),
        "settlement_price": str(settlement_price),
        "active_orders_redeemed": str(len(active_orders)),
        "active_quantity_redeemed": str(active_quantity),
        "winning_order_count": str(winning_order_count),
        "winning_quantity": str(winning_quantity),
        "settled_payout_amount": str(settled_payout),
        "liquidated_orders_cleared": str(len(liquidated_orders)),
        "gross_paid_to_expiry": str(manager_summary["gross_paid_to_expiry"]),
        "gross_received_from_expiry": str(manager_summary["gross_received_from_expiry"]),
        "trading_fees_paid": str(manager_summary["trading_fees_paid"]),
        "gross_profit_before_rebate": str(gross_profit),
        "resolved_rebate_reserve": str(resolved_rebate_reserve),
        "eligible_rebate": str(eligible_rebate),
        "rebate_fraction": str(TERMINAL_REBATE_FRACTION),
        "rebate_amount": str(rebate_amount),
        "residual_rebate_reserve": str(residual_rebate_reserve),
        "returned_rebate_reserve": str(returned_rebate_reserve),
        "returned_pool_cash": str(returned_pool_cash),
        "returned_cash": str(returned_cash),
        "materialized_profit": str(materialized_profit),
        "lp_profit": str(lp_profit),
        "protocol_profit": str(protocol_profit),
        "manager_balance_after": str(state["manager_balance"]),
        "vault_idle_balance_after": str(state["vault_idle_balance"]),
        "vault_protocol_reserve_balance_after": str(state["vault_protocol_reserve_balance"]),
        "pending_protocol_profit_after": str(state["pending_protocol_profit"]),
        "profit_basis_debits_after": str(state["profit_basis_debits"]),
        "profit_basis_credits_after": str(state["profit_basis_credits"]),
        "expiry_cash_balance_after": str(state["expiry_cash_balance"]),
        "expiry_unresolved_trading_fees_after": str(state["expiry_unresolved_trading_fees"]),
        "open_order_count_after": str(state["open_order_count"]),
        "liquidated_order_count_after": str(state["liquidated_order_count"]),
    }


# ---------------------------------------------------------------------------
# Derived (Python-only) data. Not produced by localnet, so it never enters the
# canonical parity diff. These functions introspect the live replay model to
# expose per-transaction valuation and liquidation-efficiency metrics that the
# canonical projection deliberately omits.
# ---------------------------------------------------------------------------


def initial_analytics() -> dict[str, Any]:
    return {
        "orders": {},
        "active_refs": set(),
        "orders_by_range": {},
        "probability_oracle_key": None,
        "probability_cache": {},
    }


def active_range_key(order: dict[str, Any]) -> tuple[int, int]:
    return (order["lower"], order["higher"])


def analytics_insert_order(analytics: dict[str, Any], order: dict[str, Any]) -> None:
    ref = order["ref"]
    analytics["orders"][ref] = order
    if order["leverage"] == LEVERAGE_ONE_X or order["status"] != "active":
        return
    analytics["active_refs"].add(ref)
    analytics["orders_by_range"].setdefault(active_range_key(order), []).append(order)


def analytics_remove_active_order(analytics: dict[str, Any], ref: str) -> dict[str, Any] | None:
    order = analytics["orders"].get(ref)
    if order is None or ref not in analytics["active_refs"]:
        return order
    analytics["active_refs"].remove(ref)
    range_key = active_range_key(order)
    orders = analytics["orders_by_range"].get(range_key)
    if orders is not None:
        orders.remove(order)
        if not orders:
            del analytics["orders_by_range"][range_key]
    return order


def analytics_delete_order(analytics: dict[str, Any], ref: str) -> None:
    analytics_remove_active_order(analytics, ref)
    analytics["orders"].pop(ref, None)


def apply_analytics_update(analytics: dict[str, Any], update: dict[str, Any], time_ctx: dict[str, int]) -> None:
    update_type = update["type"]
    if update_type == "order_minted":
        leverage = int(update["leverage"])
        if leverage == LEVERAGE_ONE_X:
            return
        terms = compute_mint_terms(int(update["entry_probability"]), int(update["quantity"]), leverage)
        floor_shares = terms["floor_shares"]
        lower, higher = strikes_from_ticks(int(update["lower_tick"]), int(update["higher_tick"]))
        analytics_insert_order(
            analytics,
            {
                "ref": update["order_ref"],
                "sequence": int(update["order_sequence"]),
                "lower": lower,
                "higher": higher,
                "leverage": leverage,
                "entry_probability": int(update["entry_probability"]),
                "quantity": int(update["quantity"]),
                "opened_ms": time_ctx["now_ms"],
                "floor_shares": floor_shares,
                "status": "active",
            },
        )
    elif update_type == "live_order_redeemed":
        ref = update["order_ref"]
        order = analytics_remove_active_order(analytics, ref)
        if order is None:
            return
        del analytics["orders"][ref]
        remaining_quantity = int(update["remaining_quantity"])
        replacement_ref = update["replacement_order_ref"]
        if remaining_quantity == 0 or not replacement_ref:
            return
        close_quantity = int(update["quantity_closed"])
        _, floor_shares, _ = split_partial_close_floor(
            order["quantity"],
            order["floor_shares"],
            close_quantity,
        )
        analytics_insert_order(
            analytics,
            {
                **order,
                "ref": replacement_ref,
                "sequence": int(update["replacement_order_sequence"]),
                "quantity": remaining_quantity,
                "floor_shares": floor_shares,
                "opened_ms": order["opened_ms"],
                "status": "active",
            },
        )
    elif update_type == "order_liquidated":
        order = analytics_remove_active_order(analytics, update["order_ref"])
        if order is not None:
            order["status"] = "liquidated"
    elif update_type in ("liquidated_order_redeemed", "settled_order_redeemed"):
        analytics_delete_order(analytics, update["order_ref"])


def apply_analytics_updates(analytics: dict[str, Any], updates: list[dict[str, Any]], time_ctx: dict[str, int]) -> None:
    for update in updates:
        apply_analytics_update(analytics, update, time_ctx)


def budget_for_action(action: str, row: dict[str, Any]) -> int:
    """Liquidation scan budget the engine applies for this action's pass."""
    if action in ("oracle_mint_ptb", "redeem"):
        return TRADE_LIQUIDATION_BUDGET
    if action in ("supply", "withdraw"):
        return VALUATION_LIQUIDATION_BUDGET
    return 0


def normalized_flow_action(action: str) -> str:
    return "mint" if action == "oracle_mint_ptb" else action


def analytics_oracle_key(model: dict[str, Any]) -> tuple[int, int, bool, int, int, bool, int, bool, int]:
    if model["current_svi"] is None or model["current_forward"] == 0:
        raise ValueError("liquidation requires prior price and SVI updates")
    return (model["current_forward"], *svi_cache_key(model["current_svi"]))


def analytics_range_probability(model: dict[str, Any], analytics: dict[str, Any], lower: int, higher: int) -> int:
    oracle_key = analytics_oracle_key(model)
    if analytics["probability_oracle_key"] != oracle_key:
        analytics["probability_oracle_key"] = oracle_key
        analytics["probability_cache"].clear()
    range_key = (lower, higher)
    cached = analytics["probability_cache"].get(range_key)
    if cached is not None:
        return cached
    probability = compute_range_price(model["current_svi"], model["current_forward"], lower, higher)
    analytics["probability_cache"][range_key] = probability
    return probability


def analytics_order_floor_amount(order: dict[str, Any], time_ctx: dict[str, int]) -> int:
    return floor_amount(order["floor_shares"])


def empty_liquidation_observability() -> dict[str, Any]:
    return {
        "liquidatable_count": 0,
        "liquidatable_value": 0,
        "leveraged_floor_value": 0,
    }


def analytics_liquidation_observability(
    model: dict[str, Any],
    analytics: dict[str, Any],
    curve: list[dict[str, int]] | None,
    time_ctx: dict[str, int],
) -> dict[str, Any]:
    if not analytics["active_refs"]:
        return empty_liquidation_observability()
    try:
        assert_liquidation_inputs(model)
    except ValueError:
        return empty_liquidation_observability()
    if curve is None:
        curve = build_valuation_curve(model)

    liquidatable_floor_by_ref: dict[str, int] = {}
    total_leveraged_floor = 0
    for (lower, higher), orders in analytics["orders_by_range"].items():
        lower_probability, upper_probability = directional_probability_bounds(curve, lower, higher)
        exact_probability: int | None = None
        for order in orders:
            floor_amount = analytics_order_floor_amount(order, time_ctx)
            total_leveraged_floor += floor_amount
            threshold_value = liquidation_threshold_value(floor_amount)
            upper_gross_value = deepbook_mul(upper_probability, order["quantity"])
            if upper_gross_value <= threshold_value:
                liquidatable_floor_by_ref[order["ref"]] = floor_amount
                continue
            lower_gross_value = deepbook_mul(lower_probability, order["quantity"])
            if lower_gross_value > threshold_value:
                continue
            if exact_probability is None:
                exact_probability = analytics_range_probability(model, analytics, lower, higher)
            gross_value = deepbook_mul(exact_probability, order["quantity"])
            if gross_value <= threshold_value:
                liquidatable_floor_by_ref[order["ref"]] = floor_amount

    total_liquidatable_value = sum(liquidatable_floor_by_ref.values())

    return {
        "liquidatable_count": len(liquidatable_floor_by_ref),
        "liquidatable_value": total_liquidatable_value,
        "leveraged_floor_value": total_leveraged_floor,
    }


def analytics_crystallized_borrow_fee(analytics: dict[str, Any], time_ctx: dict[str, int]) -> int:
    return 0


def step_trading_fee(updates: list[dict[str, Any]]) -> int:
    return sum(
        int(update["trading_fee"])
        for update in updates
        if update["type"] in ("order_minted", "live_order_redeemed")
    )


def step_premium(updates: list[dict[str, Any]]) -> int:
    return sum(int(update["contribution"]) for update in updates if update["type"] == "order_minted")


def step_redeem_payout(updates: list[dict[str, Any]]) -> int:
    total = 0
    for update in updates:
        if update["type"] == "live_order_redeemed":
            total += int(update["redeem_amount"])
        elif update["type"] == "settled_order_redeemed":
            total += int(update["payout_amount"])
    return total


def step_liquidated_floor_value(updates: list[dict[str, Any]]) -> int:
    return sum(int(update["floor_amount"]) for update in updates if update["type"] == "order_liquidated")


def step_liquidated_gross_value(updates: list[dict[str, Any]]) -> int:
    return sum(int(update["gross_value"]) for update in updates if update["type"] == "order_liquidated")


def step_liquidation_bad_debt(updates: list[dict[str, Any]]) -> int:
    return sum(
        max(0, int(update["floor_amount"]) - int(update["gross_value"]))
        for update in updates
        if update["type"] == "order_liquidated"
    )


def step_liquidation_surplus(updates: list[dict[str, Any]]) -> int:
    return sum(
        max(0, int(update["gross_value"]) - int(update["floor_amount"]))
        for update in updates
        if update["type"] == "order_liquidated"
    )


def active_open_contribution(model: dict[str, Any]) -> int:
    return sum(
        int(order["contribution"])
        for order in model["orders"].values()
        if order["status"] == "active"
    )


def ratio_scaled(numerator: int, denominator: int) -> int | None:
    if denominator <= 0:
        return None
    return mul_div_round_down(numerator, FLOAT_SCALING, denominator)


def signed_ratio_scaled(numerator: int, denominator: int) -> int | None:
    if denominator <= 0:
        return None
    sign = -1 if numerator < 0 else 1
    return sign * mul_div_round_down(abs(numerator), FLOAT_SCALING, denominator)


def should_sample_global_observability(row: dict[str, Any]) -> bool:
    return row["step"] % GLOBAL_OBSERVABILITY_INTERVAL == 0


def build_derived_record(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
    updates: list[dict[str, Any]],
    analytics: dict[str, Any],
    interval: dict[str, Any],
    scan_active_count: int,
    time_ctx: dict[str, int],
) -> dict[str, Any]:
    sampled_global = should_sample_global_observability(row)
    curve = None
    liability: int | None = None
    vault_value: int | None = None
    if sampled_global:
        if model["minted_min_strike"] is not None and model["minted_max_strike"] is not None:
            curve = build_valuation_curve(model)
        liability = live_position_liability(model, curve)
        try:
            vault_value = compute_pool_value(model, state, curve, liability)
        except ValueError:
            vault_value = None
    rebate_reserve = deepbook_mul(state["expiry_unresolved_trading_fees"], TRADING_LOSS_REBATE_RATE)
    active_expiry_value = None
    unmaterialized_protocol_profit = None
    protocol_profit_exclusion = None
    if liability is not None:
        reserved_cash = liability + rebate_reserve
        if state["expiry_cash_balance"] >= reserved_cash:
            active_expiry_value = state["expiry_cash_balance"] - reserved_cash
            unmaterialized_protocol_profit = unmaterialized_protocol_profit_exclusion(
                state,
                active_expiry_value,
            )
            protocol_profit_exclusion = unmaterialized_protocol_profit + state["pending_protocol_profit"]

    liquidation_observability: dict[str, Any] | None = None
    liquidatable_count: int | None = None
    liquidatable_value: int | None = None
    leveraged_floor_value: int | None = None
    borrow_fee: int | None = None

    if sampled_global:
        liquidation_observability = analytics_liquidation_observability(model, analytics, curve, time_ctx)
        liquidatable_count = liquidation_observability["liquidatable_count"]
        liquidatable_value = liquidation_observability["liquidatable_value"]
        leveraged_floor_value = liquidation_observability["leveraged_floor_value"]
        borrow_fee = analytics_crystallized_borrow_fee(analytics, time_ctx)
    liquidated_this_step = sum(1 for update in updates if update["type"] == "order_liquidated")
    premium = step_premium(updates)
    trading_fee = step_trading_fee(updates)
    redeem_payout = step_redeem_payout(updates)
    liquidated_floor_value = step_liquidated_floor_value(updates)
    liquidated_gross_value = step_liquidated_gross_value(updates)
    liquidation_gap = step_liquidation_bad_debt(updates)
    liquidation_surplus = step_liquidation_surplus(updates)
    interval["liquidated_count"] += liquidated_this_step
    interval["liquidated_value"] += liquidated_floor_value
    interval_action = normalized_flow_action(row["action"])
    interval["liquidated_value_by_action"].setdefault(interval_action, 0)
    interval["liquidated_value_by_action"][interval_action] += liquidated_floor_value
    active_contribution = active_open_contribution(model)
    active_count = len(analytics["active_refs"])
    budget = budget_for_action(row["action"], row)
    scan_coverage = (
        FLOAT_SCALING
        if scan_active_count == 0
        else min(FLOAT_SCALING, mul_div_round_down(budget, FLOAT_SCALING, scan_active_count))
    )
    interval_liquidated_count = interval["liquidated_count"] if sampled_global else None
    interval_liquidated_value = interval["liquidated_value"] if sampled_global else None
    interval_liquidated_value_by_action = (
        dict(interval["liquidated_value_by_action"]) if sampled_global else None
    )
    backlog_remaining_ratio = None
    liquidation_pressure_value = None
    all_passive_required_manual_topup_value = None
    all_passive_required_manual_topup_share = None
    mint_redeem_required_manual_topup_value = None
    mint_redeem_required_manual_topup_share = None
    all_passive_coverage_share = None
    mint_redeem_coverage_share = None
    if liquidatable_value is not None and interval_liquidated_value is not None:
        backlog_remaining_ratio = ratio_scaled(
            liquidatable_value,
            liquidatable_value + interval_liquidated_value,
        )
        previous_backlog_value = interval.get("last_liquidatable_value", 0)
        liquidation_pressure_value = max(
            0,
            liquidatable_value - previous_backlog_value + interval_liquidated_value,
        )
        all_passive_value = sum(interval["liquidated_value_by_action"].values())
        mint_redeem_value = (
            interval["liquidated_value_by_action"].get("mint", 0)
            + interval["liquidated_value_by_action"].get("redeem", 0)
        )
        all_passive_required_manual_topup_value = max(0, liquidation_pressure_value - all_passive_value)
        mint_redeem_required_manual_topup_value = max(0, liquidation_pressure_value - mint_redeem_value)
        all_passive_required_manual_topup_share = ratio_scaled(
            all_passive_required_manual_topup_value,
            liquidation_pressure_value,
        )
        mint_redeem_required_manual_topup_share = ratio_scaled(
            mint_redeem_required_manual_topup_value,
            liquidation_pressure_value,
        )
        all_passive_coverage_share = ratio_scaled(all_passive_value, liquidation_pressure_value)
        mint_redeem_coverage_share = ratio_scaled(mint_redeem_value, liquidation_pressure_value)
    if sampled_global:
        interval["last_liquidatable_value"] = liquidatable_value or 0
        interval["liquidated_count"] = 0
        interval["liquidated_value"] = 0
        interval["liquidated_value_by_action"] = {
            "mint": 0,
            "redeem": 0,
            "supply": 0,
            "withdraw": 0,
        }

    expiry_funding_basis = expiry_net_funding(state)
    lp_live_mtm_pnl = (
        None
        if active_expiry_value is None or protocol_profit_exclusion is None
        else active_expiry_value - protocol_profit_exclusion - expiry_funding_basis
    )
    active_book_live_pnl = None if liability is None else active_contribution - liability
    position_liability_over_funding = None if liability is None else ratio_scaled(liability, expiry_funding_basis)
    active_open_contribution_over_funding = ratio_scaled(active_contribution, expiry_funding_basis)
    lp_live_mtm_pnl_over_funding = (
        None if lp_live_mtm_pnl is None else signed_ratio_scaled(lp_live_mtm_pnl, expiry_funding_basis)
    )
    active_book_live_pnl_over_funding = (
        None if active_book_live_pnl is None else signed_ratio_scaled(active_book_live_pnl, expiry_funding_basis)
    )
    active_book_live_pnl_over_liability = (
        None if active_book_live_pnl is None or liability is None else signed_ratio_scaled(active_book_live_pnl, liability)
    )
    liquidatable_value_over_liability = (
        None if liquidatable_value is None or liability is None else ratio_scaled(liquidatable_value, liability)
    )
    step_trading_fee_over_funding = ratio_scaled(trading_fee, expiry_funding_basis)
    step_liquidation_gap_over_funding = ratio_scaled(liquidation_gap, expiry_funding_basis)
    step_net_liquidation_over_funding = signed_ratio_scaled(liquidation_surplus - liquidation_gap, expiry_funding_basis)

    return {
        "step": row["step"],
        "action": row["action"],
        "timestamp_ms": None
        if time_ctx.get("record_timestamp_ms") is None
        else str(time_ctx["record_timestamp_ms"]),
        "valuation": {
            "vault_value": None if vault_value is None else str(vault_value),
            "total_plp_supply": str(state["vault_total_plp_supply"]),
            "idle": str(state["vault_idle_balance"]),
            "expiry_cash_balance": str(state["expiry_cash_balance"]),
            "active_expiry_value": None if active_expiry_value is None else str(active_expiry_value),
            "position_liability": None if liability is None else str(liability),
            "rebate_reserve": str(rebate_reserve),
            "unmaterialized_protocol_profit_exclusion": None
            if unmaterialized_protocol_profit is None
            else str(unmaterialized_protocol_profit),
            "pending_protocol_profit": str(state["pending_protocol_profit"]),
            "protocol_profit_exclusion": None
            if protocol_profit_exclusion is None
            else str(protocol_profit_exclusion),
            "active_open_contribution": str(active_contribution),
            "lp_live_mtm_pnl": None if lp_live_mtm_pnl is None else str(lp_live_mtm_pnl),
            "active_book_live_pnl": None if active_book_live_pnl is None else str(active_book_live_pnl),
        },
        "flows": {
            "premium": str(premium),
            "trading_fee": str(trading_fee),
            "redeem_payout": str(redeem_payout),
            "borrow_fee_accrued": None if borrow_fee is None else str(borrow_fee),
            "counterparty_position_value": None if liability is None else str(liability),
            "liquidated_floor_value": str(liquidated_floor_value),
            "liquidated_gross_value": str(liquidated_gross_value),
            "liquidation_gap": str(liquidation_gap),
            "liquidation_surplus": str(liquidation_surplus),
        },
        "liquidation": {
            "active_count": str(active_count),
            "liquidatable_count": None if liquidatable_count is None else str(liquidatable_count),
            "liquidatable_value": None if liquidatable_value is None else str(liquidatable_value),
            "leveraged_floor_value": None if leveraged_floor_value is None else str(leveraged_floor_value),
            "liquidated_count": str(liquidated_this_step),
            "liquidated_value": str(liquidated_floor_value),
            "interval_liquidated_count": None if interval_liquidated_count is None else str(interval_liquidated_count),
            "interval_liquidated_value": None if interval_liquidated_value is None else str(interval_liquidated_value),
            "interval_liquidated_value_by_action": None
            if interval_liquidated_value_by_action is None
            else {key: str(value) for key, value in sorted(interval_liquidated_value_by_action.items())},
            "liquidation_pressure_value": None
            if liquidation_pressure_value is None
            else str(liquidation_pressure_value),
            "all_passive_coverage_share": None
            if all_passive_coverage_share is None
            else str(all_passive_coverage_share),
            "mint_redeem_coverage_share": None
            if mint_redeem_coverage_share is None
            else str(mint_redeem_coverage_share),
            "all_passive_required_manual_topup_value": None
            if all_passive_required_manual_topup_value is None
            else str(all_passive_required_manual_topup_value),
            "all_passive_required_manual_topup_share": None
            if all_passive_required_manual_topup_share is None
            else str(all_passive_required_manual_topup_share),
            "mint_redeem_required_manual_topup_value": None
            if mint_redeem_required_manual_topup_value is None
            else str(mint_redeem_required_manual_topup_value),
            "mint_redeem_required_manual_topup_share": None
            if mint_redeem_required_manual_topup_share is None
            else str(mint_redeem_required_manual_topup_share),
            "budget": str(budget),
            "scan_active_count": str(scan_active_count),
            "scan_coverage": str(scan_coverage),
            "backlog_remaining_ratio": None if backlog_remaining_ratio is None else str(backlog_remaining_ratio),
            "sampled": sampled_global,
        },
        "risk": {
            "expiry_funding_basis": str(expiry_funding_basis),
            "open_order_quantity": str(state["open_order_quantity"]),
            "active_leveraged_count": str(active_count),
            "position_liability_over_funding": None
            if position_liability_over_funding is None
            else str(position_liability_over_funding),
            "active_open_contribution_over_funding": None
            if active_open_contribution_over_funding is None
            else str(active_open_contribution_over_funding),
            "lp_live_mtm_pnl_over_funding": None
            if lp_live_mtm_pnl_over_funding is None
            else str(lp_live_mtm_pnl_over_funding),
            "active_book_live_pnl_over_funding": None
            if active_book_live_pnl_over_funding is None
            else str(active_book_live_pnl_over_funding),
            "active_book_live_pnl_over_liability": None
            if active_book_live_pnl_over_liability is None
            else str(active_book_live_pnl_over_liability),
            "liquidatable_value_over_liability": None
            if liquidatable_value_over_liability is None
            else str(liquidatable_value_over_liability),
            "step_trading_fee_over_funding": None
            if step_trading_fee_over_funding is None
            else str(step_trading_fee_over_funding),
            "step_liquidation_gap_over_funding": None
            if step_liquidation_gap_over_funding is None
            else str(step_liquidation_gap_over_funding),
            "step_net_liquidation_over_funding": None
            if step_net_liquidation_over_funding is None
            else str(step_net_liquidation_over_funding),
        },
    }


def exact_row_timestamp_ms(row: dict[str, Any]) -> int:
    timestamp = row.get("replayTimestampMs")
    if timestamp is None:
        raise ValueError(
            f"exact-time replay requires replay_timestamp_ms at scenario line {row['lineNumber']}"
        )
    return int(timestamp)


def flush_checkpoints(row_count: int) -> set[int]:
    raw = os.environ.get("SIM_FLUSH_AFTER", "")
    if raw:
        return {
            int(value)
            for part in raw.split(",")
            if (value := part.strip()).isdigit() and int(value) > 0
        }
    return {checkpoint for checkpoint in (300, 999) if checkpoint <= row_count}


def cash_rebalance_checkpoints(row_count: int, flush_after: set[int]) -> set[int]:
    return {
        checkpoint
        for checkpoint in range(100, row_count + 1, 100)
        if checkpoint not in flush_after
    }


def parity_flush_updates(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
    supply_queue: list[dict[str, Any]],
    withdraw_queue: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    updates: list[dict[str, Any]] = []
    apply_inline_oracle_refresh(model, row, updates)
    updates.extend(run_liquidation_pass(model, VALUATION_LIQUIDATION_BUDGET))
    sync_updates, pool_value, synced_state = flush_valuation(model, state)
    updates.extend(sync_updates)

    total_supply = synced_state["vault_total_plp_supply"]
    idle_balance_before = synced_state["vault_idle_balance"]
    idle_balance_after = idle_balance_before
    total_supply_after = total_supply
    supplies_filled = 0
    withdrawals_filled = 0
    requests_processed = 0

    while supply_queue:
        request = supply_queue.pop(0)
        shares = (
            mul_div_round_down(request["amount"], total_supply, pool_value)
            if pool_value > 0
            else 0
        )
        requests_pending_after = len(supply_queue)
        if shares == 0:
            updates.append(
                {
                    "type": "request_cancelled",
                    "index": str(request["index"]),
                    "amount": str(request["amount"]),
                    "is_supply": True,
                    "reason": "1",
                    "requests_pending_after": str(requests_pending_after),
                }
            )
        else:
            updates.append(
                {
                    "type": "supply_filled",
                    "index": str(request["index"]),
                    "dusdc_amount": str(request["amount"]),
                    "shares_minted": str(shares),
                    "requests_pending_after": str(requests_pending_after),
                }
            )
            model["lp_refs"][request["ref"]] = shares
            idle_balance_after += request["amount"]
            total_supply_after += shares
            supplies_filled += 1
        requests_processed += 1

    while withdraw_queue:
        request = withdraw_queue[0]
        payout = (
            mul_div_round_down(request["shares"], pool_value, total_supply)
            if total_supply > 0
            else 0
        )
        if payout > idle_balance_after:
            break
        withdraw_queue.pop(0)
        requests_pending_after = len(withdraw_queue)
        if payout == 0:
            updates.append(
                {
                    "type": "request_cancelled",
                    "index": str(request["index"]),
                    "amount": str(request["shares"]),
                    "is_supply": False,
                    "reason": "1",
                    "requests_pending_after": str(requests_pending_after),
                }
            )
        else:
            updates.append(
                {
                    "type": "withdraw_filled",
                    "index": str(request["index"]),
                    "shares_burned": str(request["shares"]),
                    "dusdc_amount": str(payout),
                    "requests_pending_after": str(requests_pending_after),
                }
            )
            idle_balance_after -= payout
            total_supply_after -= request["shares"]
            withdrawals_filled += 1
        requests_processed += 1

    updates.append(
        {
            "type": "flush_executed",
            "pool_value": str(pool_value),
            "total_supply": str(total_supply),
            "active_market_nav": str(current_nav(model, synced_state)),
            "market_count": "1",
            "idle_balance_before": str(idle_balance_before),
            "supplies_filled": str(supplies_filled),
            "withdrawals_filled": str(withdrawals_filled),
            "requests_processed": str(requests_processed),
            "idle_balance_after": str(idle_balance_after),
            "total_supply_after": str(total_supply_after),
        }
    )
    return updates


def replay(
    rows: list[dict[str, Any]],
    collect_derived: bool = False,
    exact_time: bool = False,
    expiry_ms: int | None = None,
    settlement_price: int | None = None,
    settlement_timestamp_ms: int | None = None,
    terminal_closeout: bool = False,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    if exact_time and expiry_ms is None:
        raise ValueError("exact-time replay requires expiry_ms")
    if terminal_closeout:
        if not exact_time:
            raise ValueError("terminal closeout requires exact-time replay")
        if expiry_ms is None or settlement_price is None:
            raise ValueError("terminal closeout requires expiry_ms and settlement_price")
        if settlement_timestamp_ms is None:
            settlement_timestamp_ms = expiry_ms + 1

    # No grid to configure: strikes are absolute ticks (raw = tick*tick_size), so
    # the tick domain is fixed and known before any row runs.
    state = initial_state()
    model: dict[str, Any] = {
        "current_forward": 0,
        "current_svi": None,
        "next_sequence": 0,
        "orders": {},
        "exact_time": exact_time,
        "expiry_ms": expiry_ms if exact_time else None,
        "now_ms": None,
        "liquidation": LiquidationBook(),
        "lp_refs": {},
        "minted_min_strike": None,
        "minted_max_strike": None,
        "payout": StrikePayoutTree(
            min_strike=ORACLE_MIN_STRIKE,
            tick_size=ORACLE_TICK_SIZE,
            max_strike=ORACLE_MAX_STRIKE,
            neg_inf=NEG_INF_STRIKE,
            pos_inf=POS_INF_STRIKE,
        ),
        "valuation_cache": {
            "curve_key": None,
            "curve": None,
            "liability_key": None,
            "liability": None,
        },
    }
    records = []
    derived_records: list[dict[str, Any]] = []
    analytics = initial_analytics()
    derived_interval = {
        "liquidated_count": 0,
        "liquidated_value": 0,
        "last_liquidatable_value": 0,
        "liquidated_value_by_action": {
            "mint": 0,
            "redeem": 0,
            "supply": 0,
            "withdraw": 0,
        },
    }
    manager_summary = initial_manager_summary()

    total_steps = len(rows)
    derived_expiry_ms = expiry_ms if exact_time and expiry_ms is not None else total_steps
    # Parity-path async-LP request bookkeeping (mirrors the localnet runner). Supply /
    # withdraw rows only ENQUEUE a request in the parity model; the flush (runner
    # machinery, not a CSV row) drains them later, so no fill/oracle-refresh update is
    # emitted per row. The bootstrap supply consumed supply-queue index 0, so scenario
    # supplies start at 1; withdraws start at 0. Withdraws draw against the bootstrap
    # PLP only (conservative, matching the runner) and any that exceed it are skipped
    # with no emitted record (the runner `continue`s).
    supply_queue_index = 1
    withdraw_queue_index = 0
    available_settled_plp = VAULT_SEED
    lp_request_amounts: dict[str, int] = {}
    supply_queue: list[dict[str, Any]] = []
    withdraw_queue: list[dict[str, Any]] = []
    flush_after = set() if exact_time else flush_checkpoints(total_steps)
    rebalance_after = (
        set() if exact_time else cash_rebalance_checkpoints(total_steps, flush_after)
    )

    def append_maintenance_record(after_row: int, row: dict[str, Any]) -> None:
        if after_row in flush_after:
            maintenance_action = "flush"
            maintenance_updates = parity_flush_updates(
                model,
                state,
                row,
                supply_queue,
                withdraw_queue,
            )
        elif after_row in rebalance_after:
            maintenance_action = "rebalance_expiry_cash"
            maintenance_updates = sync_active_expiry_cash_updates(model, dict(state))
        else:
            return

        for maintenance_update in maintenance_updates:
            apply_update(state, maintenance_update)
            apply_manager_summary_update(manager_summary, maintenance_update)
        records.append(
            {
                "step": row["step"],
                "action": maintenance_action,
                "input": {"after_row": after_row},
                "updates": maintenance_updates,
                "state": state_snapshot(state),
            }
        )

    for step_index, row in enumerate(rows):
        updates: list[dict[str, Any]] = []
        action = row["action"]
        row_timestamp_ms = exact_row_timestamp_ms(row) if exact_time else row["step"]
        model["now_ms"] = row_timestamp_ms
        scan_active_count = active_order_count(model)
        if action == "oracle_mint_ptb":
            model["current_forward"] = live_forward(
                row["spot"],
                row["forward"],
                row["spot"],
            )
            model["current_svi"] = row
            updates.append(pyth_feed_update(row))
            updates.append(block_scholes_surface_update(row))
            scan_active_count = active_order_count(model)
            updates.extend(run_liquidation_pass(model, TRADE_LIQUIDATION_BUDGET))
            updates.append(mint_order(model, row, row_timestamp_ms))
        elif action == "redeem":
            apply_inline_oracle_refresh(model, row, updates)
            scan_active_count = active_order_count(model)
            # Mirror Move `redeem_internal`: the bounded liquidation pass runs on every
            # live-market redeem (before the is-liquidated check), so it advances the
            # passive watermark even when redeeming an already-liquidated order. Skipping
            # it there silently drifted the watermark vs localnet. Settlement is stubbed
            # in this model (the market never settles), so the pass is unconditional.
            updates.extend(run_liquidation_pass(model, TRADE_LIQUIDATION_BUDGET))
            updates.append(redeem_order(model, row))
        elif action == "supply":
            if exact_time:
                # Long Python-only replay keeps the synchronous fill model so the
                # economic charts still see LP fills + pool funding.
                apply_inline_oracle_refresh(model, row, updates)
                scan_active_count = active_order_count(model)
                pool_value, synced_state = append_pool_sync_phase(model, state, updates)
                updates.append(supply_update(model, row, pool_value, synced_state))
            else:
                # Parity: request_supply only escrows DUSDC into the queue (no oracle
                # refresh, no fill). Mirror the localnet request record exactly.
                ref = row["lpRef"]
                amount = row["amount"]
                lp_request_amounts[ref] = amount
                supply_queue.append(
                    {
                        "ref": ref,
                        "index": supply_queue_index,
                        "amount": amount,
                    }
                )
                updates.append(
                    {
                        "type": "supply_requested",
                        "lp_ref": ref,
                        "index": str(supply_queue_index),
                        "amount": str(amount),
                        "requests_pending_after": str(len(supply_queue)),
                    }
                )
                supply_queue_index += 1
        elif action == "withdraw":
            if exact_time:
                apply_inline_oracle_refresh(model, row, updates)
                scan_active_count = active_order_count(model)
                pool_value, synced_state = append_pool_sync_phase(model, state, updates)
                updates.append(withdraw_update(model, row, pool_value, synced_state))
            else:
                # Parity: request_withdraw escrows PLP (materialized from the bootstrap
                # pool) into the queue. The runner skips — with no record — any withdraw
                # the bootstrap PLP can't cover; mirror that exactly.
                ref = row["lpRef"]
                shares = lp_request_amounts.get(ref, 0)
                if shares == 0 or shares > available_settled_plp:
                    append_maintenance_record(step_index + 1, row)
                    continue
                available_settled_plp -= shares
                withdraw_queue.append(
                    {
                        "ref": ref,
                        "index": withdraw_queue_index,
                        "shares": shares,
                    }
                )
                updates.append(
                    {
                        "type": "withdraw_requested",
                        "lp_ref": ref,
                        "index": str(withdraw_queue_index),
                        "amount": str(shares),
                        "requests_pending_after": str(len(withdraw_queue)),
                    }
                )
                withdraw_queue_index += 1
        else:
            raise ValueError(f"unsupported action {action}")

        for update in updates:
            apply_update(state, update)
            apply_manager_summary_update(manager_summary, update)

        record = {
            "step": row["step"],
            "action": action,
            "input": row_input(row),
            "updates": updates,
            "state": state_snapshot(state),
        }
        if exact_time:
            record["timestamp_ms"] = str(row_timestamp_ms)
        records.append(record)

        if collect_derived:
            now_ms = row_timestamp_ms if exact_time else step_index
            time_ctx = {
                "now_ms": now_ms,
                "expiry_ms": derived_expiry_ms,
                "record_timestamp_ms": row_timestamp_ms if exact_time else None,
            }
            apply_analytics_updates(analytics, updates, time_ctx)
            derived_records.append(
                build_derived_record(
                    model,
                    state,
                    row,
                    updates,
                    analytics,
                    derived_interval,
                    scan_active_count,
                    time_ctx,
                )
            )
        append_maintenance_record(step_index + 1, row)

    if terminal_closeout:
        assert expiry_ms is not None
        assert settlement_timestamp_ms is not None
        assert settlement_price is not None
        model["now_ms"] = settlement_timestamp_ms
        update = terminal_closeout_update(
            model,
            state,
            manager_summary,
            expiry_ms=expiry_ms,
            settlement_timestamp_ms=settlement_timestamp_ms,
            settlement_price=settlement_price,
        )
        terminal_record = {
            "step": (records[-1]["step"] + 1) if records else 1,
            "action": "terminal_closeout",
            "timestamp_ms": str(settlement_timestamp_ms),
            "input": {
                "expiry_ms": str(expiry_ms),
                "settlement_timestamp_ms": str(settlement_timestamp_ms),
                "settlement_price": str(settlement_price),
            },
            "updates": [update],
            "state": state_snapshot(state),
        }
        records.append(terminal_record)

    scenario = {"quantity_scale": str(scenario_quantity_scale())}
    if exact_time:
        scenario["expiry_ms"] = str(expiry_ms)
    if terminal_closeout:
        scenario["settlement_timestamp_ms"] = str(settlement_timestamp_ms)
        scenario["settlement_price"] = str(settlement_price)

    canonical = {
        "schema_version": ECONOMIC_SCHEMA_VERSION,
        "scenario": scenario,
        "records": records,
    }
    derived = None
    if collect_derived:
        derived_scenario = {"quantity_scale": str(scenario_quantity_scale())}
        if exact_time:
            derived_scenario["expiry_ms"] = str(expiry_ms)
        if terminal_closeout:
            derived_scenario["settlement_timestamp_ms"] = str(settlement_timestamp_ms)
            derived_scenario["settlement_price"] = str(settlement_price)
        derived = {
            "schema_version": DERIVED_SCHEMA_VERSION,
            "scenario": derived_scenario,
            "records": derived_records,
        }
    return canonical, derived


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", default=str(Path(__file__).with_name("data") / "generated" / "normal_scenario.csv"))
    parser.add_argument("--out")
    parser.add_argument("--derived-out")
    parser.add_argument("--max-rows", type=int)
    parser.add_argument("--config", type=Path, default=DEFAULT_SCENARIO_CONFIG_PATH)
    parser.add_argument("--long-run", action="store_true")
    args = parser.parse_args()

    if not args.out and not args.derived_out:
        parser.error("at least one of --out / --derived-out is required")

    config = load_scenario_config(args.config)
    apply_scenario_config(config, long_run=args.long_run)
    expiry_ms = config_source_value(config, "expiry_ms")
    settlement_price = config_source_value(config, "settlement_price")
    settlement_timestamp_ms = config_source_value(config, "settlement_timestamp_ms")

    rows = parse_scenario(Path(args.scenario))
    if args.max_rows is not None:
        rows = rows[: args.max_rows]
    canonical, derived = replay(
        rows,
        collect_derived=bool(args.derived_out),
        exact_time=args.long_run,
        expiry_ms=expiry_ms,
        settlement_price=settlement_price,
        settlement_timestamp_ms=settlement_timestamp_ms,
        terminal_closeout=args.long_run,
    )
    if args.out:
        write_json(Path(args.out), canonical)
    if args.derived_out:
        write_json(Path(args.derived_out), derived)


if __name__ == "__main__":
    main()
