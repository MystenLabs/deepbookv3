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

from python_indexes.liquidation_book import (
    LiquidationBook,
    encode_order_id,
    strike_index_for_order_side,
)
from python_indexes.strike_nav_matrix import StrikeNavMatrix
from python_indexes.strike_payout_tree import StrikePayoutTree

FLOAT_SCALING = 1_000_000_000
POSITION_LOT_SIZE = 10_000
ECONOMIC_SCHEMA_VERSION = "predict_economic_v1"
DERIVED_SCHEMA_VERSION = "predict_derived_v1"
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
MIN_ASK_PRICE = 10_000_000
MAX_ASK_PRICE = 990_000_000
ORACLE_TICK_SIZE = FLOAT_SCALING
ORACLE_GRID_TICKS = 100_000
ORACLE_CENTER_TICKS = ORACLE_GRID_TICKS // 2
# Centered grid bounds are derived from the first scenario spot by
# configure_oracle_grid(). They stay None until then so any strike math run
# before configuration fails loudly instead of silently snapping against a
# stale default grid (mirrors the oracleGrid() guard in sim.ts).
ORACLE_MIN_STRIKE = None
ORACLE_MAX_STRIKE = None
NEG_INF_STRIKE = 0
POS_INF_STRIKE = (1 << 64) - 1
MIN_ORDER_PRINCIPAL = 1_000_000
DUSDC_DECIMALS = 1_000_000
VAULT_SEED = 500_000 * DUSDC_DECIMALS
MANAGER_SEED = 500_000 * DUSDC_DECIMALS
INITIAL_EXPIRY_ALLOCATION = 50_000 * DUSDC_DECIMALS
INITIAL_TOTAL_PLP_SUPPLY = VAULT_SEED
TRADE_LIQUIDATION_BUDGET = 24
VALUATION_LIQUIDATION_BUDGET = 192
LIQUIDATION_HEAD_SCAN_DIVISOR = 3
CURVE_SAMPLES = 50
LP_FEE_SHARE = 600_000_000
PROTOCOL_FEE_SHARE = 200_000_000
INSURANCE_FEE_SHARE = 200_000_000
TRADING_LOSS_REBATE_RATE = 500_000_000
TERMINAL_REBATE_FRACTION = 0
# Upgrade constant, mirrored directly from constants::expiry_fee_window_ms!() (1 day).
EXPIRY_FEE_WINDOW_MS = 24 * 60 * 60 * 1000
EXPIRY_FEE_MAX_MULTIPLIER = FLOAT_SCALING

# Floor-index model for Python-only observability. Normal parity replay keeps a
# flat index to match localnet's far-future expiry; long replay uses source
# timestamps and settlement data from scenario_config.json.
LEVERAGE_FLOOR_WINDOW_MS = 31_536_000_000  # 365 days, core/constants.move
LEVERAGE_ONE_X_ONLY_PRICE_THRESHOLD = 100_000_000  # 0.10, core/constants.move
LEVERAGE_TWO_X_MAX_PRICE_THRESHOLD = 200_000_000  # 0.20, core/constants.move
MAX_EXPIRY_FLOOR_PREMIUM = 200_000_000  # 0.20, default_max_expiry_floor_premium
LIQUIDATION_LTV = 850_000_000  # 0.85, default_liquidation_ltv
BORROW_STEP_DT_MS: int | None = None  # None => window / total_steps (a full 0->1 phase sweep)
GLOBAL_OBSERVABILITY_INTERVAL = 10
TERMINAL_FLOOR_INDEX = FLOAT_SCALING + MAX_EXPIRY_FLOOR_PREMIUM
LEVERAGE_ONE_X = 1_000_000_000
LEVERAGE_ONE_AND_HALF_X = 1_500_000_000
LEVERAGE_TWO_X = 2_000_000_000
LEVERAGE_TWO_AND_HALF_X = 2_500_000_000
LEVERAGE_THREE_X = 3_000_000_000

F = 1_000_000_000
PRICE_CACHE_SIZE = 1_000_000
LN2_U128 = 693_147_180
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
    global INITIAL_EXPIRY_ALLOCATION
    global INITIAL_TOTAL_PLP_SUPPLY
    global BASE_FEE
    global MIN_FEE
    global MIN_ASK_PRICE
    global MAX_ASK_PRICE
    global TRADE_LIQUIDATION_BUDGET
    global VALUATION_LIQUIDATION_BUDGET
    global LIQUIDATION_HEAD_SCAN_DIVISOR
    global CURVE_SAMPLES
    global LP_FEE_SHARE
    global PROTOCOL_FEE_SHARE
    global INSURANCE_FEE_SHARE
    global TRADING_LOSS_REBATE_RATE
    global TERMINAL_REBATE_FRACTION
    global EXPIRY_FEE_MAX_MULTIPLIER
    global LEVERAGE_FLOOR_WINDOW_MS
    global MAX_EXPIRY_FLOOR_PREMIUM
    global LIQUIDATION_LTV
    global TERMINAL_FLOOR_INDEX

    capital_mode = "long" if long_run else "normal"
    VAULT_SEED = _capital_int(config, capital_mode, "vault_seed", VAULT_SEED)
    MANAGER_SEED = _capital_int(config, capital_mode, "manager_seed", MANAGER_SEED)
    INITIAL_EXPIRY_ALLOCATION = _capital_int(
        config,
        capital_mode,
        "initial_expiry_allocation",
        INITIAL_EXPIRY_ALLOCATION,
    )
    if INITIAL_EXPIRY_ALLOCATION > VAULT_SEED:
        raise ValueError(f"{capital_mode} initial_expiry_allocation exceeds vault_seed")
    INITIAL_TOTAL_PLP_SUPPLY = VAULT_SEED

    BASE_FEE = _config_int(config, "protocol", "base_fee", BASE_FEE)
    MIN_FEE = _config_int(config, "protocol", "min_fee", MIN_FEE)
    MIN_ASK_PRICE = _config_int(config, "protocol", "min_ask_price", MIN_ASK_PRICE)
    MAX_ASK_PRICE = _config_int(config, "protocol", "max_ask_price", MAX_ASK_PRICE)
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
    LP_FEE_SHARE = _config_int(config, "protocol", "lp_fee_share", LP_FEE_SHARE)
    PROTOCOL_FEE_SHARE = _config_int(config, "protocol", "protocol_fee_share", PROTOCOL_FEE_SHARE)
    INSURANCE_FEE_SHARE = _config_int(config, "protocol", "insurance_fee_share", INSURANCE_FEE_SHARE)
    TRADING_LOSS_REBATE_RATE = _config_int(
        config,
        "protocol",
        "trading_loss_rebate_rate",
        TRADING_LOSS_REBATE_RATE,
    )
    TERMINAL_REBATE_FRACTION = FLOAT_SCALING if long_run else 0
    EXPIRY_FEE_MAX_MULTIPLIER = _config_int(
        config,
        "protocol",
        "expiry_fee_max_multiplier",
        EXPIRY_FEE_MAX_MULTIPLIER,
    )
    LEVERAGE_FLOOR_WINDOW_MS = _config_int(
        config,
        "protocol",
        "leverage_floor_window_ms",
        LEVERAGE_FLOOR_WINDOW_MS,
    )
    MAX_EXPIRY_FLOOR_PREMIUM = _config_int(
        config,
        "protocol",
        "max_expiry_floor_premium",
        MAX_EXPIRY_FLOOR_PREMIUM,
    )
    LIQUIDATION_LTV = _config_int(config, "protocol", "liquidation_ltv", LIQUIDATION_LTV)
    TERMINAL_FLOOR_INDEX = FLOAT_SCALING + MAX_EXPIRY_FLOOR_PREMIUM


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


def configure_oracle_grid(initial_spot: int) -> None:
    global ORACLE_MIN_STRIKE
    global ORACLE_MAX_STRIKE

    if initial_spot <= 0:
        raise ValueError("initial Pyth spot must be positive")
    # Mirror config_constants::assert_oracle_tick_size_covers_spot: Move checks the
    # tick-floored spot (`spot / tick_size <= grid_ticks`), so compare on ticks too.
    if initial_spot // ORACLE_TICK_SIZE > ORACLE_GRID_TICKS:
        raise ValueError(
            "initial Pyth spot exceeds oracle tick coverage; raise the oracle "
            "tick size to cover a higher spot"
        )
    center_strike_index = initial_spot // ORACLE_TICK_SIZE
    if center_strike_index <= ORACLE_CENTER_TICKS:
        raise ValueError("initial Pyth spot is too low for centered oracle grid")

    ORACLE_MIN_STRIKE = (center_strike_index - ORACLE_CENTER_TICKS) * ORACLE_TICK_SIZE
    ORACLE_MAX_STRIKE = ORACLE_MIN_STRIKE + ORACLE_GRID_TICKS * ORACLE_TICK_SIZE


def first_block_scholes_spot(rows: list[dict[str, Any]]) -> int:
    if not rows:
        raise ValueError("scenario has no executable rows")
    first = rows[0]
    if first["action"] == "oracle_mint_ptb":
        return first["spot"]
    return first["oracleRefresh"]["spot"]


def signed_svi_value(magnitude: int, is_negative: bool) -> str:
    if magnitude == 0:
        return "0"
    return f"-{magnitude}" if is_negative else str(magnitude)


def align_strike_to_grid(strike: int) -> int:
    if ORACLE_MIN_STRIKE is None:
        raise ValueError("oracle grid has not been configured")
    relative = strike - ORACLE_MIN_STRIKE
    tick_index = relative // ORACLE_TICK_SIZE
    snapped = ORACLE_MIN_STRIKE + tick_index * ORACLE_TICK_SIZE
    if snapped < ORACLE_MIN_STRIKE:
        return ORACLE_MIN_STRIKE
    if snapped > ORACLE_MAX_STRIKE:
        return ORACLE_MAX_STRIKE
    return snapped


def binary_range_bounds(strike: int, is_up: bool) -> tuple[int, int]:
    if is_up:
        return strike, POS_INF_STRIKE
    return NEG_INF_STRIKE, strike


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


def _oracle_refresh(row: dict[str, str], line_number: int) -> dict[str, Any]:
    present = [field for field in ORACLE_REFRESH_FIELDS if row.get(field, "") != ""]
    if len(present) != len(ORACLE_REFRESH_FIELDS):
        raise ValueError(f"Scenario line {line_number}: oracle refresh fields must all be present")
    return {
        "oracleRefresh": {
            "spot": _uint(row, "spot", line_number),
            "forward": _uint(row, "forward", line_number),
            "a": _uint(row, "a", line_number),
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


def mul_div_round_up(a: int, b: int, c: int) -> int:
    numerator = a * b
    return numerator // c + (0 if numerator % c == 0 else 1)


def deepbook_mul(x: int, y: int) -> int:
    return x * y // FLOAT_SCALING


def mul_div_round_down(a: int, b: int, c: int) -> int:
    return a * b // c


def live_forward(spot: int, forward: int) -> int:
    # Mirror pricing::live_inputs fresh-spot branch: the on-chain forward used for
    # every live quote/valuation/liquidation is NOT the pushed forward, but is
    # re-derived from the live Pyth spot and the stored Block Scholes basis as
    # mul(spot, div(forward, spot)). That round-trip is lossy (two floors), so it
    # generally differs from `forward` by a few units. In the localnet parity flow
    # the Pyth spot equals the Block Scholes spot pushed in the same PTB, so this
    # is exactly the forward the contracts price with.
    return deepbook_mul(spot, deepbook_div(forward, spot))


def assert_valid_leverage(leverage: int) -> None:
    if leverage not in (
        LEVERAGE_ONE_X,
        LEVERAGE_ONE_AND_HALF_X,
        LEVERAGE_TWO_X,
        LEVERAGE_TWO_AND_HALF_X,
        LEVERAGE_THREE_X,
    ):
        raise ValueError("invalid leverage multiplier")


def leverage_multiplier(leverage: int) -> int:
    assert_valid_leverage(leverage)
    return leverage


def assert_valid_leverage_tier(entry_probability: int, leverage: int) -> None:
    assert_valid_leverage(leverage)
    if entry_probability < LEVERAGE_ONE_X_ONLY_PRICE_THRESHOLD:
        if leverage != LEVERAGE_ONE_X:
            raise ValueError("entry probability below 10c allows only 1x leverage")
    elif entry_probability < LEVERAGE_TWO_X_MAX_PRICE_THRESHOLD and leverage > LEVERAGE_TWO_X:
        raise ValueError("entry probability below 20c allows at most 2x leverage")


def user_contribution_from_exposure_value(exposure_value: int, leverage: int) -> int:
    return mul_div_round_up(exposure_value, FLOAT_SCALING, leverage_multiplier(leverage))


def assert_mint_principal_above_min(contribution: int) -> None:
    # Mirror strike_exposure.move: `user_contribution() >= min_order_principal!()`,
    # so a contribution exactly equal to the minimum is allowed.
    if contribution < MIN_ORDER_PRINCIPAL:
        raise ValueError("order principal below minimum")


def compute_mint_terms(entry_probability: int, quantity: int, leverage: int) -> dict[str, int]:
    assert_valid_leverage_tier(entry_probability, leverage)
    entry_exposure_value = deepbook_mul(entry_probability, quantity)
    contribution = user_contribution_from_exposure_value(entry_exposure_value, leverage)
    return {
        "entry_exposure_value": entry_exposure_value,
        "contribution": contribution,
        "floor_seed_amount": entry_exposure_value - contribution,
        "leverage_multiplier": leverage_multiplier(leverage),
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


def compute_nd2(svi: dict[str, Any], forward: int, strike: int) -> int:
    strike_ratio = deepbook_div(strike, forward)
    k = ln_fixed(strike_ratio)
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
    wing_var = deepbook_mul(svi["b"], inner.magnitude)
    total_var = svi["a"] + wing_var
    sqrt_var = sqrt_fixed(total_var, FLOAT_SCALING)
    d2_numerator = k.add(I64(total_var // 2))
    d2 = d2_numerator.div_scaled(I64(sqrt_var)).neg()
    return normal_cdf(d2)


def svi_cache_key(svi: dict[str, Any]) -> tuple[int, int, int, bool, int, bool, int]:
    return (
        svi["a"],
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
    b: int,
    rho: int,
    rho_negative: bool,
    m: int,
    m_negative: bool,
    sigma: int,
    lower: int,
    higher: int,
) -> int:
    lower_up = compute_up_price_cached(forward, a, b, rho, rho_negative, m, m_negative, sigma, lower)
    higher_up = compute_up_price_cached(forward, a, b, rho, rho_negative, m, m_negative, sigma, higher)
    if lower_up < higher_up:
        raise ValueError("range price underflow")
    return lower_up - higher_up


def compute_range_price(svi: dict[str, Any], forward: int, lower: int, higher: int) -> int:
    return compute_range_price_cached(forward, *svi_cache_key(svi), lower, higher)


def directional_probability_upper_bound(curve: list[dict[str, int]], lower: int, higher: int) -> int:
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
        return point["up_price"] if is_up else FLOAT_SCALING - point["up_price"]

    lo_point = curve[lo - 1]
    if lo_point["up_price"] < point["up_price"]:
        raise ValueError("curve price underflow")
    return lo_point["up_price"] if is_up else FLOAT_SCALING - point["up_price"]


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
        mid = align_strike_to_grid((lo["strike"] + hi["strike"]) // 2)
        points.insert(best_idx + 1, {"strike": mid, "up_price": compute_up_price(svi, forward, mid)})
    return points


def order_strike_index(strike: int) -> int:
    return strike_index_for_order_side(
        strike,
        min_strike=ORACLE_MIN_STRIKE,
        tick_size=ORACLE_TICK_SIZE,
        max_strike=ORACLE_MAX_STRIKE,
        neg_inf=NEG_INF_STRIKE,
        pos_inf=POS_INF_STRIKE,
    )


def order_id_for_terms(order: dict[str, Any]) -> int:
    return encode_order_id(
        opened_at_ms=order["opened_at_ms"],
        min_strike_index=order["min_strike_index"],
        max_strike_index=order["max_strike_index"],
        leverage=order["leverage"],
        entry_probability=order["entry_probability"],
        quantity=order["quantity"],
        sequence=order["sequence"],
        position_lot_size=POSITION_LOT_SIZE,
        float_scaling=FLOAT_SCALING,
    )


def floor_amount_for_index(floor_shares: int, floor_index: int) -> int:
    return mul_div_round_up(floor_shares, floor_index, FLOAT_SCALING)


def order_floor_shares_from_seed(floor_seed_amount: int, leverage: int, open_floor_index: int) -> int:
    if leverage == LEVERAGE_ONE_X:
        return 0
    return mul_div_round_up(floor_seed_amount, FLOAT_SCALING, open_floor_index)


def assert_terminal_ltv_mint_allowed(
    quantity: int,
    leverage: int,
    floor_seed_amount: int,
    open_floor_index: int = FLOAT_SCALING,
) -> None:
    floor_shares = order_floor_shares_from_seed(floor_seed_amount, leverage, open_floor_index)
    terminal_floor = mul_div_round_up(floor_shares, TERMINAL_FLOOR_INDEX, FLOAT_SCALING)
    max_terminal_floor_before_liquidation = mul_div_round_down(quantity, LIQUIDATION_LTV, FLOAT_SCALING)
    if terminal_floor >= max_terminal_floor_before_liquidation:
        raise ValueError("terminal floor exceeds liquidation LTV")


def liquidation_threshold_value(floor_amount: int) -> int:
    return mul_div_round_up(floor_amount, FLOAT_SCALING, LIQUIDATION_LTV)


def assert_mint_above_liquidation_threshold(
    entry_probability: int,
    quantity: int,
    leverage: int,
    floor_seed_amount: int,
    open_floor_index: int = FLOAT_SCALING,
    floor_shares: int | None = None,
) -> None:
    if leverage == LEVERAGE_ONE_X:
        return
    shares = (
        floor_shares
        if floor_shares is not None
        else order_floor_shares_from_seed(floor_seed_amount, leverage, open_floor_index)
    )
    floor_amount = floor_amount_for_index(shares, open_floor_index)
    threshold_value = liquidation_threshold_value(floor_amount)
    gross_value = deepbook_mul(entry_probability, quantity)
    if gross_value <= threshold_value:
        raise ValueError("order below liquidation threshold at entry")


def model_floor_index(model: dict[str, Any], timestamp_ms: int | None = None) -> int:
    if not model.get("exact_time"):
        return FLOAT_SCALING
    now_ms = model.get("now_ms") if timestamp_ms is None else timestamp_ms
    expiry_ms = model.get("expiry_ms")
    if now_ms is None or expiry_ms is None:
        raise ValueError("exact-time replay requires now_ms and expiry_ms")
    return floor_index_at_ms(now_ms, expiry_ms, LEVERAGE_FLOOR_WINDOW_MS, MAX_EXPIRY_FLOOR_PREMIUM)


def order_floor_shares(order: dict[str, Any]) -> int:
    return order_floor_shares_from_seed(
        order["floor_seed_amount"],
        order["leverage"],
        order.get("open_floor_index", FLOAT_SCALING),
    )


def order_floor_amount_at_index(order: dict[str, Any], floor_index: int) -> int:
    return floor_amount_for_index(order_floor_shares(order), floor_index)


def current_order_floor_amount(model: dict[str, Any], order: dict[str, Any]) -> int:
    return order_floor_amount_at_index(order, model_floor_index(model))


def model_fee_time_to_expiry_ms(model: dict[str, Any], timestamp_ms: int | None = None) -> int | None:
    if not model.get("exact_time"):
        return None
    now_ms = model.get("now_ms") if timestamp_ms is None else timestamp_ms
    expiry_ms = model.get("expiry_ms")
    if now_ms is None or expiry_ms is None:
        raise ValueError("exact-time fee ramp requires now_ms and expiry_ms")
    return max(0, expiry_ms - now_ms)


def order_index_update_terms(order: dict[str, Any]) -> tuple[int, int, int]:
    floor_shares = order_floor_shares(order)
    assert_terminal_ltv_mint_allowed(
        order["quantity"],
        order["leverage"],
        order["floor_seed_amount"],
        order.get("open_floor_index", FLOAT_SCALING),
    )
    terminal_floor = floor_amount_for_index(floor_shares, TERMINAL_FLOOR_INDEX)
    floor_at_open = floor_amount_for_index(floor_shares, order.get("open_floor_index", FLOAT_SCALING))
    return (floor_shares, order["quantity"] - terminal_floor, order["quantity"] - floor_at_open)


def invalidate_valuation_cache(model: dict[str, Any]) -> None:
    model["valuation_cache"]["liability_key"] = None
    model["valuation_cache"]["liability"] = None


def insert_live_order(model: dict[str, Any], order: dict[str, Any]) -> None:
    floor_shares, terminal_payout, live_backing_payout = order_index_update_terms(order)
    assert_mint_above_liquidation_threshold(
        order["entry_probability"],
        order["quantity"],
        order["leverage"],
        order["floor_seed_amount"],
        order.get("open_floor_index", FLOAT_SCALING),
        floor_shares,
    )
    model["payout"].insert_range(order["lower"], order["higher"], terminal_payout, live_backing_payout)
    model["nav"].insert_range(order["lower"], order["higher"], order["quantity"], floor_shares)
    invalidate_valuation_cache(model)
    track_minted_boundaries(model, order["lower"], order["higher"])
    insert_active_order(model, order["ref"])


def remove_closed_live_order(
    model: dict[str, Any],
    order: dict[str, Any],
    close_quantity: int,
    resulting_order: dict[str, Any] | None,
) -> int:
    old_floor_shares, old_terminal_payout, old_live_backing_payout = order_index_update_terms(order)
    if resulting_order is None:
        remaining_floor_shares = 0
        remaining_terminal_payout = 0
        remaining_live_backing_payout = 0
    else:
        remaining_floor_shares, remaining_terminal_payout, remaining_live_backing_payout = order_index_update_terms(
            resulting_order
        )

    closed_floor_shares = old_floor_shares - remaining_floor_shares
    closed_terminal_payout = old_terminal_payout - remaining_terminal_payout
    closed_live_backing_payout = old_live_backing_payout - remaining_live_backing_payout
    model["payout"].remove_range(
        order["lower"],
        order["higher"],
        closed_terminal_payout,
        closed_live_backing_payout,
    )
    model["nav"].remove_range(order["lower"], order["higher"], close_quantity, closed_floor_shares)
    invalidate_valuation_cache(model)
    return floor_amount_for_index(closed_floor_shares, model_floor_index(model))


def remove_live_order(model: dict[str, Any], order: dict[str, Any]) -> int:
    return remove_closed_live_order(model, order, order["quantity"], None)


def valuation_curve_key(model: dict[str, Any]) -> tuple[int, int, int, int, bool, int, bool, int, int, int] | None:
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


def live_position_liability(model: dict[str, Any], curve: list[dict[str, int]] | None = None) -> int:
    key = valuation_curve_key(model)
    if key is None:
        return 0
    if curve is None:
        curve = build_valuation_curve(model)
    if curve is None:
        return 0
    cache = model["valuation_cache"]
    floor_index = model_floor_index(model)
    liability_key = (key, model["nav"].version, floor_index)
    if cache["liability_key"] == liability_key:
        return cache["liability"]
    liability = model["nav"].live_value(
        curve,
        minted_min_strike=model["minted_min_strike"],
        minted_max_strike=model["minted_max_strike"],
        floor_index=floor_index,
    )
    cache["liability_key"] = liability_key
    cache["liability"] = liability
    return liability


def compute_pool_value(
    model: dict[str, Any],
    state: dict[str, int],
    curve: list[dict[str, int]] | None = None,
    position_liability: int | None = None,
) -> int:
    if model["current_svi"] is None or model["current_forward"] == 0:
        raise ValueError("pool valuation requires prior price and SVI updates")
    if position_liability is None:
        position_liability = live_position_liability(model, curve)
    rebate_reserve = deepbook_mul(state["expiry_unresolved_trading_fees"], TRADING_LOSS_REBATE_RATE)
    if state["expiry_lp_cash"] < position_liability:
        raise ValueError("valuation exceeds LP cash")
    if state["expiry_fee_balance"] < rebate_reserve:
        raise ValueError("fee balance below rebate reserve")
    position_value = state["expiry_lp_cash"] - position_liability
    lp_fee_surplus = deepbook_mul(state["expiry_fee_balance"] - rebate_reserve, LP_FEE_SHARE)
    return state["vault_idle_balance"] + position_value + lp_fee_surplus


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


def assert_mint_fee_rate(probability: int, time_to_expiry_ms: int | None = None) -> int:
    rate = fee_rate(probability, time_to_expiry_ms)
    ask_price = probability + rate
    if ask_price < MIN_ASK_PRICE or ask_price > MAX_ASK_PRICE:
        raise ValueError("ask price out of bounds")
    return rate


def initial_state() -> dict[str, int]:
    return {
        "manager_balance": MANAGER_SEED,
        "expiry_lp_cash": INITIAL_EXPIRY_ALLOCATION,
        "expiry_fee_balance": 0,
        "expiry_unresolved_trading_fees": 0,
        "vault_idle_balance": VAULT_SEED - INITIAL_EXPIRY_ALLOCATION,
        "vault_total_allocated": INITIAL_EXPIRY_ALLOCATION,
        "vault_total_plp_supply": INITIAL_TOTAL_PLP_SUPPLY,
        "open_order_count": 0,
        "open_order_quantity": 0,
        "liquidated_order_count": 0,
    }


def state_snapshot(state: dict[str, int]) -> dict[str, str]:
    return {key: str(value) for key, value in state.items()}


def svi_input(row: dict[str, Any]) -> dict[str, str]:
    return {
        "a": str(row["a"]),
        "b": str(row["b"]),
        "rho": signed_svi_value(row["rho"], row["rhoNegative"]),
        "m": signed_svi_value(row["m"], row["mNegative"]),
        "sigma": str(row["sigma"]),
    }


def mint_input(row: dict[str, Any]) -> dict[str, str]:
    strike = align_strike_to_grid(row["strike"])
    lower, higher = binary_range_bounds(strike, row["isUp"])
    return {
        "order_ref": row["orderRef"],
        "lower_strike": str(lower),
        "higher_strike": str(higher),
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


def oracle_prices_update(price: dict[str, Any]) -> dict[str, str]:
    return {
        "type": "oracle_prices_updated",
        "spot": str(price["spot"]),
        "forward": str(price["forward"]),
        "basis": str(deepbook_div(price["forward"], price["spot"])),
    }


def oracle_svi_update(svi: dict[str, Any]) -> dict[str, str]:
    return {
        "type": "oracle_svi_updated",
        **svi_input(svi),
    }


def apply_inline_oracle_refresh(model: dict[str, Any], row: dict[str, Any], updates: list[dict[str, Any]]) -> None:
    oracle = row["oracleRefresh"]
    model["current_forward"] = live_forward(oracle["spot"], oracle["forward"])
    model["current_svi"] = oracle
    updates.append(oracle_prices_update(oracle))
    updates.append(oracle_svi_update(oracle))


def order_minted_update(
    mint: dict[str, Any],
    svi: dict[str, Any],
    forward: int,
    sequence: int,
    time_to_expiry_ms: int | None = None,
) -> dict[str, str]:
    strike = align_strike_to_grid(mint["strike"])
    lower, higher = binary_range_bounds(strike, mint["isUp"])
    entry_probability = compute_range_price(svi, forward, lower, higher)
    fee_amount = deepbook_mul(assert_mint_fee_rate(entry_probability, time_to_expiry_ms), mint["quantity"])
    terms = compute_mint_terms(entry_probability, mint["quantity"], mint["leverage"])
    assert_mint_principal_above_min(terms["contribution"])
    return {
        "type": "order_minted",
        "order_ref": mint["orderRef"],
        "order_sequence": str(sequence),
        "lower_strike": str(lower),
        "higher_strike": str(higher),
        "leverage": str(mint["leverage"]),
        "entry_probability": str(entry_probability),
        "quantity": str(mint["quantity"]),
        "contribution": str(terms["contribution"]),
        "trading_fee": str(fee_amount),
        "builder_fee": "0",
        "floor_seed_amount": str(terms["floor_seed_amount"]),
    }


def apply_update(state: dict[str, int], update: dict[str, str]) -> None:
    if update["type"] == "order_minted":
        contribution = int(update["contribution"])
        trading_fee = int(update["trading_fee"])
        builder_fee = int(update["builder_fee"])
        quantity = int(update["quantity"])
        state["manager_balance"] -= contribution + trading_fee + builder_fee
        state["expiry_lp_cash"] += contribution
        state["expiry_fee_balance"] += trading_fee
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
        quantity_closed = int(update["quantity_closed"])
        remaining_quantity = int(update["remaining_quantity"])
        state["manager_balance"] += redeem_amount - trading_fee - builder_fee
        state["expiry_lp_cash"] -= redeem_amount
        state["expiry_fee_balance"] += trading_fee
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
        state["expiry_lp_cash"] -= payout
        state["open_order_count"] -= 1
        state["open_order_quantity"] -= quantity_closed
    elif update["type"] in ("pool_supply", "pool_withdraw"):
        state["vault_idle_balance"] = int(update["idle_balance_after"])
        state["vault_total_allocated"] = int(update["total_allocated_after"])
        state["vault_total_plp_supply"] = int(update["total_supply_after"])


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


def run_liquidation_pass(
    model: dict[str, Any],
    budget: int,
    curve: list[dict[str, int]] | None = None,
) -> list[dict[str, str]]:
    candidates = select_liquidation_candidates(model, budget)
    if not candidates:
        return []
    assert_liquidation_inputs(model)
    updates = []
    for ref in candidates:
        order = model["orders"][ref]
        if order["status"] != "active":
            continue
        probability = (
            directional_probability_upper_bound(curve, order["lower"], order["higher"])
            if curve is not None
            else compute_range_price(
                model["current_svi"],
                model["current_forward"],
                order["lower"],
                order["higher"],
            )
        )
        gross_value = deepbook_mul(probability, order["quantity"])
        floor_amount = current_order_floor_amount(model, order)
        threshold_value = liquidation_threshold_value(floor_amount)
        if gross_value > threshold_value:
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
    return updates


def track_minted_boundaries(model: dict[str, Any], lower: int, higher: int) -> None:
    for strike in (lower, higher):
        if strike in (NEG_INF_STRIKE, POS_INF_STRIKE):
            continue
        if model["minted_min_strike"] is None or strike < model["minted_min_strike"]:
            model["minted_min_strike"] = strike
        if model["minted_max_strike"] is None or strike > model["minted_max_strike"]:
            model["minted_max_strike"] = strike


def mint_order(model: dict[str, Any], row: dict[str, Any], opened_at_ms: int) -> dict[str, str]:
    if model["current_svi"] is None or model["current_forward"] == 0:
        raise ValueError("mint requires prior price and SVI updates")
    if row["orderRef"] in model["orders"]:
        raise ValueError(f"duplicate order_ref {row['orderRef']}")
    update = order_minted_update(
        row,
        model["current_svi"],
        model["current_forward"],
        model["next_sequence"],
        model_fee_time_to_expiry_ms(model, opened_at_ms),
    )
    order = {
        "ref": row["orderRef"],
        "sequence": model["next_sequence"],
        "lower": int(update["lower_strike"]),
        "higher": int(update["higher_strike"]),
        "leverage": row["leverage"],
        "entry_probability": int(update["entry_probability"]),
        "quantity": row["quantity"],
        "contribution": int(update["contribution"]),
        "floor_seed_amount": int(update["floor_seed_amount"]),
        "opened_at_ms": opened_at_ms,
        "open_floor_index": model_floor_index(model, opened_at_ms),
        "status": "active",
    }
    order["min_strike_index"] = order_strike_index(order["lower"])
    order["max_strike_index"] = order_strike_index(order["higher"])
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
    fee = deepbook_mul(fee_rate(probability, model_fee_time_to_expiry_ms(model)), close_quantity)
    gross = deepbook_mul(probability, close_quantity)

    remaining_quantity = order["quantity"] - close_quantity
    if remaining_quantity == 0:
        replacement_ref = None
        replacement_sequence = None
        remove_active_order(model, ref)
        closed_floor = remove_live_order(model, order)
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
            "floor_seed_amount": replacement_terms["floor_seed_amount"],
            "status": "active",
        }
        replacement["order_id"] = order_id_for_terms(replacement)
        remove_active_order(model, ref)
        closed_floor = remove_closed_live_order(model, order, close_quantity, replacement)
        del model["orders"][ref]
        model["next_sequence"] += 1
        model["orders"][replacement_ref] = replacement
        insert_active_order(model, replacement_ref)
        replacement_sequence = replacement["sequence"]

    redeem_amount = gross - min(gross, closed_floor)
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
    }


def supply_update(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
    curve: list[dict[str, int]] | None = None,
) -> dict[str, str]:
    if row["lpRef"] in model["lp_refs"]:
        raise ValueError(f"duplicate lp_ref {row['lpRef']}")
    pool_value = compute_pool_value(model, state, curve)
    total_supply = state["vault_total_plp_supply"]
    shares = row["amount"] if total_supply == 0 else mul_div_round_down(row["amount"], total_supply, pool_value)
    if shares <= 0:
        raise ValueError("supply would mint zero shares")
    model["lp_refs"][row["lpRef"]] = shares
    return {
        "type": "pool_supply",
        "lp_ref": row["lpRef"],
        "payment": str(row["amount"]),
        "shares_minted": str(shares),
        "pool_value_before": str(pool_value),
        "total_supply_after": str(total_supply + shares),
        "idle_balance_after": str(state["vault_idle_balance"] + row["amount"]),
        "total_allocated_after": str(state["vault_total_allocated"]),
    }


def withdraw_update(
    model: dict[str, Any],
    state: dict[str, int],
    row: dict[str, Any],
    curve: list[dict[str, int]] | None = None,
) -> dict[str, str]:
    shares = model["lp_refs"].get(row["lpRef"])
    if shares is None:
        raise ValueError(f"unknown lp_ref {row['lpRef']}")
    pool_value = compute_pool_value(model, state, curve)
    total_supply = state["vault_total_plp_supply"]
    payout = mul_div_round_down(shares, pool_value, total_supply)
    if payout <= 0:
        raise ValueError("withdraw would pay zero")
    if state["vault_idle_balance"] < payout:
        raise ValueError("insufficient idle balance for withdraw")
    del model["lp_refs"][row["lpRef"]]
    return {
        "type": "pool_withdraw",
        "lp_ref": row["lpRef"],
        "shares_burned": str(shares),
        "payout": str(payout),
        "pool_value_before": str(pool_value),
        "total_supply_after": str(total_supply - shares),
        "idle_balance_after": str(state["vault_idle_balance"] - payout),
        "total_allocated_after": str(state["vault_total_allocated"]),
    }


def initial_manager_summary() -> dict[str, int]:
    return {
        "cash_paid_to_expiry": 0,
        "cash_received_from_expiry": 0,
        "trading_fee_paid": 0,
    }


def apply_manager_summary_update(summary: dict[str, int], update: dict[str, Any]) -> None:
    update_type = update["type"]
    if update_type == "order_minted":
        summary["cash_paid_to_expiry"] += int(update["contribution"]) + int(update["trading_fee"])
        summary["trading_fee_paid"] += int(update["trading_fee"])
    elif update_type == "live_order_redeemed":
        summary["cash_received_from_expiry"] += (
            int(update["redeem_amount"]) - int(update["trading_fee"]) - int(update["builder_fee"])
        )
        summary["trading_fee_paid"] += int(update["trading_fee"])
    elif update_type == "settled_order_redeemed":
        summary["cash_received_from_expiry"] += int(update["payout_amount"])


def settled_order_payout(order: dict[str, Any], settlement_price: int) -> int:
    if settlement_price > order["lower"] and settlement_price <= order["higher"]:
        _, terminal_payout, _ = order_index_update_terms(order)
        return terminal_payout
    return 0


def reset_terminal_model(model: dict[str, Any]) -> None:
    model["orders"].clear()
    model["liquidation"] = LiquidationBook()
    model["minted_min_strike"] = None
    model["minted_max_strike"] = None
    model["nav"] = StrikeNavMatrix(
        min_strike=ORACLE_MIN_STRIKE,
        tick_size=ORACLE_TICK_SIZE,
        max_strike=ORACLE_MAX_STRIKE,
        float_scaling=FLOAT_SCALING,
        neg_inf=NEG_INF_STRIKE,
        pos_inf=POS_INF_STRIKE,
    )
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
        "expiry_lp_cash",
        "expiry_fee_balance",
        "expiry_unresolved_trading_fees",
        "vault_total_allocated",
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
    if settled_payout > state["expiry_lp_cash"]:
        raise ValueError("terminal payout exceeds expiry LP cash")

    state["manager_balance"] += settled_payout
    state["expiry_lp_cash"] -= settled_payout
    manager_summary["cash_received_from_expiry"] += settled_payout

    trading_loss = max(0, manager_summary["cash_paid_to_expiry"] - manager_summary["cash_received_from_expiry"])
    max_rebate = deepbook_mul(manager_summary["trading_fee_paid"], TRADING_LOSS_REBATE_RATE)
    eligible_rebate = min(trading_loss, max_rebate, state["expiry_fee_balance"])
    trading_loss_rebate = deepbook_mul(eligible_rebate, TERMINAL_REBATE_FRACTION)
    trading_loss_rebate_to_lp = eligible_rebate - trading_loss_rebate
    state["manager_balance"] += trading_loss_rebate
    state["expiry_fee_balance"] -= eligible_rebate
    state["expiry_lp_cash"] += trading_loss_rebate_to_lp

    fee_surplus = state["expiry_fee_balance"]
    protocol_fee_surplus = deepbook_mul(fee_surplus, PROTOCOL_FEE_SHARE)
    insurance_fee_surplus = deepbook_mul(fee_surplus, INSURANCE_FEE_SHARE)
    lp_fee_surplus = fee_surplus - protocol_fee_surplus - insurance_fee_surplus
    returned_lp_cash = state["expiry_lp_cash"]
    allocated_reduction = state["vault_total_allocated"]

    state["vault_idle_balance"] += returned_lp_cash + lp_fee_surplus
    state["vault_total_allocated"] = 0
    state["expiry_lp_cash"] = 0
    state["expiry_fee_balance"] = 0
    state["expiry_unresolved_trading_fees"] = 0
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
        "cash_paid_to_expiry": str(manager_summary["cash_paid_to_expiry"]),
        "cash_received_from_expiry": str(manager_summary["cash_received_from_expiry"]),
        "trading_fee_paid": str(manager_summary["trading_fee_paid"]),
        "trading_loss_before_rebate": str(trading_loss),
        "trading_loss_eligible_rebate": str(eligible_rebate),
        "trading_loss_rebate_fraction": str(TERMINAL_REBATE_FRACTION),
        "trading_loss_rebate": str(trading_loss_rebate),
        "trading_loss_rebate_to_lp": str(trading_loss_rebate_to_lp),
        "returned_lp_cash": str(returned_lp_cash),
        "fee_surplus": str(fee_surplus),
        "fee_surplus_to_lp": str(lp_fee_surplus),
        "fee_surplus_to_protocol": str(protocol_fee_surplus),
        "fee_surplus_to_insurance": str(insurance_fee_surplus),
        "allocated_reduction": str(allocated_reduction),
        "manager_balance_after": str(state["manager_balance"]),
        "vault_idle_balance_after": str(state["vault_idle_balance"]),
        "vault_total_allocated_after": str(state["vault_total_allocated"]),
        "expiry_lp_cash_after": str(state["expiry_lp_cash"]),
        "expiry_fee_balance_after": str(state["expiry_fee_balance"]),
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
        borrow_index_open = floor_index_at_ms(
            time_ctx["now_ms"], time_ctx["expiry_ms"], time_ctx["window"], time_ctx["max_premium"]
        )
        floor_seed_amount = int(update["floor_seed_amount"])
        floor_shares = order_floor_shares_from_seed(floor_seed_amount, leverage, borrow_index_open)
        analytics_insert_order(
            analytics,
            {
                "ref": update["order_ref"],
                "sequence": int(update["order_sequence"]),
                "lower": int(update["lower_strike"]),
                "higher": int(update["higher_strike"]),
                "leverage": leverage,
                "entry_probability": int(update["entry_probability"]),
                "quantity": int(update["quantity"]),
                "floor_seed_amount": floor_seed_amount,
                "opened_ms": time_ctx["now_ms"],
                "borrow_index_open": borrow_index_open,
                "floor_shares": floor_shares,
                "floor_at_open": floor_amount_for_index(floor_shares, borrow_index_open),
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
        replacement_terms = compute_mint_terms(order["entry_probability"], remaining_quantity, order["leverage"])
        floor_shares = order_floor_shares_from_seed(
            replacement_terms["floor_seed_amount"],
            order["leverage"],
            order["borrow_index_open"],
        )
        analytics_insert_order(
            analytics,
            {
                **order,
                "ref": replacement_ref,
                "sequence": int(update["replacement_order_sequence"]),
                "quantity": remaining_quantity,
                "floor_seed_amount": replacement_terms["floor_seed_amount"],
                "floor_shares": floor_shares,
                "floor_at_open": floor_amount_for_index(floor_shares, order["borrow_index_open"]),
                "opened_ms": order["opened_ms"],
                "borrow_index_open": order["borrow_index_open"],
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


def analytics_oracle_key(model: dict[str, Any]) -> tuple[int, int, int, int, bool, int, bool, int]:
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
    floor_index = floor_index_at_ms(time_ctx["now_ms"], time_ctx["expiry_ms"], time_ctx["window"], time_ctx["max_premium"])
    return floor_amount_for_index(order["floor_shares"], floor_index)


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


def floor_index_at_ms(timestamp_ms: int, expiry_ms: int, window: int, max_premium: int) -> int:
    """Deterministic floor index at a timestamp, mirroring strike_exposure.move.

    The index sits at FLOAT_SCALING (1.0) until the final `window` before expiry,
    then rises quadratically in phase to FLOAT_SCALING + max_premium at expiry.
    """
    remaining = 0 if timestamp_ms >= expiry_ms else expiry_ms - timestamp_ms
    elapsed = 0 if remaining >= window else window - remaining
    phase = mul_div_round_down(elapsed, FLOAT_SCALING, window)
    phase_squared = mul_div_round_down(phase, phase, FLOAT_SCALING)
    return FLOAT_SCALING + mul_div_round_down(max_premium, phase_squared, FLOAT_SCALING)


def analytics_crystallized_borrow_fee(analytics: dict[str, Any], time_ctx: dict[str, int]) -> int:
    index_now = floor_index_at_ms(time_ctx["now_ms"], time_ctx["expiry_ms"], time_ctx["window"], time_ctx["max_premium"])
    total = 0
    for ref in analytics["active_refs"]:
        order = analytics["orders"][ref]
        floor_now = floor_amount_for_index(order["floor_shares"], index_now)
        total += floor_now - order["floor_at_open"]
    return total


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
    fee_surplus = deepbook_mul(max(0, state["expiry_fee_balance"] - rebate_reserve), LP_FEE_SHARE)

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

    allocated_capital = state["vault_total_allocated"]
    lp_live_mtm_pnl = None if liability is None else state["expiry_lp_cash"] - INITIAL_EXPIRY_ALLOCATION + fee_surplus - liability
    active_book_live_pnl = None if liability is None else active_contribution - liability
    position_liability_over_allocated = None if liability is None else ratio_scaled(liability, allocated_capital)
    active_open_contribution_over_allocated = ratio_scaled(active_contribution, allocated_capital)
    lp_live_mtm_pnl_over_allocated = (
        None if lp_live_mtm_pnl is None else signed_ratio_scaled(lp_live_mtm_pnl, allocated_capital)
    )
    active_book_live_pnl_over_allocated = (
        None if active_book_live_pnl is None else signed_ratio_scaled(active_book_live_pnl, allocated_capital)
    )
    active_book_live_pnl_over_liability = (
        None if active_book_live_pnl is None or liability is None else signed_ratio_scaled(active_book_live_pnl, liability)
    )
    liquidatable_value_over_liability = (
        None if liquidatable_value is None or liability is None else ratio_scaled(liquidatable_value, liability)
    )
    liquidatable_value_over_allocated = (
        None if liquidatable_value is None else ratio_scaled(liquidatable_value, allocated_capital)
    )
    step_trading_fee_over_allocated = ratio_scaled(trading_fee, allocated_capital)
    step_liquidation_gap_over_allocated = ratio_scaled(liquidation_gap, allocated_capital)
    step_net_liquidation_over_allocated = signed_ratio_scaled(liquidation_surplus - liquidation_gap, allocated_capital)

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
            "position_value": None if liability is None else str(state["expiry_lp_cash"] - liability),
            "position_liability": None if liability is None else str(liability),
            "lp_fee_surplus": str(fee_surplus),
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
            "allocated_capital": str(allocated_capital),
            "open_order_quantity": str(state["open_order_quantity"]),
            "active_leveraged_count": str(active_count),
            "position_liability_over_allocated": None
            if position_liability_over_allocated is None
            else str(position_liability_over_allocated),
            "active_open_contribution_over_allocated": None
            if active_open_contribution_over_allocated is None
            else str(active_open_contribution_over_allocated),
            "lp_live_mtm_pnl_over_allocated": None
            if lp_live_mtm_pnl_over_allocated is None
            else str(lp_live_mtm_pnl_over_allocated),
            "active_book_live_pnl_over_allocated": None
            if active_book_live_pnl_over_allocated is None
            else str(active_book_live_pnl_over_allocated),
            "active_book_live_pnl_over_liability": None
            if active_book_live_pnl_over_liability is None
            else str(active_book_live_pnl_over_liability),
            "liquidatable_value_over_liability": None
            if liquidatable_value_over_liability is None
            else str(liquidatable_value_over_liability),
            "liquidatable_value_over_allocated": None
            if liquidatable_value_over_allocated is None
            else str(liquidatable_value_over_allocated),
            "step_trading_fee_over_allocated": None
            if step_trading_fee_over_allocated is None
            else str(step_trading_fee_over_allocated),
            "step_liquidation_gap_over_allocated": None
            if step_liquidation_gap_over_allocated is None
            else str(step_liquidation_gap_over_allocated),
            "step_net_liquidation_over_allocated": None
            if step_net_liquidation_over_allocated is None
            else str(step_net_liquidation_over_allocated),
        },
    }


def exact_row_timestamp_ms(row: dict[str, Any]) -> int:
    timestamp = row.get("replayTimestampMs")
    if timestamp is None:
        raise ValueError(
            f"exact-time replay requires replay_timestamp_ms at scenario line {row['lineNumber']}"
        )
    return int(timestamp)


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

    configure_oracle_grid(first_block_scholes_spot(rows))

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
        "nav": StrikeNavMatrix(
            min_strike=ORACLE_MIN_STRIKE,
            tick_size=ORACLE_TICK_SIZE,
            max_strike=ORACLE_MAX_STRIKE,
            float_scaling=FLOAT_SCALING,
            neg_inf=NEG_INF_STRIKE,
            pos_inf=POS_INF_STRIKE,
        ),
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

    # Synthetic-time model for derived borrow fees (Python-only). Default dt
    # spreads the run across the full floor window so phase sweeps 0 -> 1.
    total_steps = len(rows)
    step_dt = BORROW_STEP_DT_MS if BORROW_STEP_DT_MS else max(1, LEVERAGE_FLOOR_WINDOW_MS // max(1, total_steps))
    derived_expiry_ms = expiry_ms if exact_time and expiry_ms is not None else total_steps * step_dt
    for step_index, row in enumerate(rows):
        updates: list[dict[str, Any]] = []
        action = row["action"]
        row_timestamp_ms = exact_row_timestamp_ms(row) if exact_time else row["step"]
        model["now_ms"] = row_timestamp_ms
        scan_active_count = active_order_count(model)
        if action == "oracle_mint_ptb":
            model["current_forward"] = live_forward(row["spot"], row["forward"])
            model["current_svi"] = row
            updates.append(oracle_prices_update(row))
            updates.append(oracle_svi_update(row))
            scan_active_count = active_order_count(model)
            updates.extend(run_liquidation_pass(model, TRADE_LIQUIDATION_BUDGET))
            updates.append(mint_order(model, row, row_timestamp_ms))
        elif action == "redeem":
            apply_inline_oracle_refresh(model, row, updates)
            ref = row["orderRef"]
            order = model["orders"].get(ref)
            scan_active_count = active_order_count(model)
            if order is None or order["status"] != "liquidated":
                updates.extend(run_liquidation_pass(model, TRADE_LIQUIDATION_BUDGET))
            updates.append(redeem_order(model, row))
        elif action == "supply":
            apply_inline_oracle_refresh(model, row, updates)
            curve = build_valuation_curve(model)
            scan_active_count = active_order_count(model)
            updates.extend(run_liquidation_pass(model, VALUATION_LIQUIDATION_BUDGET, curve))
            updates.append(supply_update(model, state, row, curve))
        elif action == "withdraw":
            apply_inline_oracle_refresh(model, row, updates)
            curve = build_valuation_curve(model)
            scan_active_count = active_order_count(model)
            updates.extend(run_liquidation_pass(model, VALUATION_LIQUIDATION_BUDGET, curve))
            updates.append(withdraw_update(model, state, row, curve))
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
            now_ms = row_timestamp_ms if exact_time else step_index * step_dt
            time_ctx = {
                "now_ms": now_ms,
                "expiry_ms": derived_expiry_ms,
                "window": LEVERAGE_FLOOR_WINDOW_MS,
                "max_premium": MAX_EXPIRY_FLOOR_PREMIUM,
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
