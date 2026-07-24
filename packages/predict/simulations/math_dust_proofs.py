#!/usr/bin/env python3
"""Exact-rational dust certificates for every inventoried money function."""

from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass
from fractions import Fraction
from typing import Any

import money_math_inventory as inventory
import python_replay as replay

F = replay.FLOAT_SCALING
PROTOCOL_PARTIES = {
    "lp_pool",
    "protocol_reserve",
    "fee_incentive_reserve",
    "expiry_cash",
}

def _site(function_id: str, ordinal: int) -> str:
    return f"{function_id}::site#{ordinal}"


# Every certificate is tied to the exact source call sites that implement its
# rounded atom. The inventory digest detects any source drift; these bindings
# separately prevent a refreshed digest from certifying an opposite rounding
# direction.
CERTIFICATE_SOURCE_BINDINGS: dict[str, tuple[tuple[str, str], ...]] = {
    "rebate_reserve": ((
        _site("packages/predict/sources/config/expiry_cash_config.move::rebate_reserve_for_fee_basis", 1),
        "mul_down",
    ),),
    "stake_benefit_ratio": (
        (_site("packages/predict/sources/config/stake_config.move::benefit_ratio", 2), "mul_div_down"),
        (_site("packages/predict/sources/config/stake_config.move::benefit_ratio", 3), "mul_div_down"),
    ),
    "discount_fraction": ((
        _site("packages/predict/sources/config/stake_config.move::fee_amount_after_discount", 1),
        "mul_down",
    ),),
    "discounted_fee_complement": (
        (_site("packages/predict/sources/config/stake_config.move::fee_amount_after_discount", 2), "mul_down"),
        (_site("packages/predict/sources/config/stake_config.move::fee_amount_after_discount", 3), "raw_sub"),
    ),
    "stake_rebate": ((
        _site("packages/predict/sources/config/stake_config.move::rebate_amount", 1),
        "mul_down",
    ),),
    "trading_fee": ((
        _site("packages/predict/sources/config/strike_exposure_config.move::trading_fee", 1),
        "mul_up",
    ),),
    "mint_entry_value": ((
        _site("packages/predict/sources/config/strike_exposure_config.move::assert_mint_admission", 1),
        "mul_down",
    ),),
    "net_premium": ((
        _site("packages/predict/sources/config/strike_exposure_config.move::net_premium_from_entry_value", 1),
        "div_up",
    ),),
    "fee_rate": ((
        _site("packages/predict/sources/config/strike_exposure_config.move::fee_rate", 3),
        "mul_down",
    ),),
    "bernoulli_variance": (
        (_site("packages/predict/sources/config/strike_exposure_config.move::raw_bernoulli_fee_rate", 2), "mul_down"),
        (_site("packages/predict/sources/config/strike_exposure_config.move::raw_bernoulli_fee_rate", 3), "sqrt_down"),
    ),
    "raw_bernoulli_fee": ((
        _site("packages/predict/sources/config/strike_exposure_config.move::raw_bernoulli_fee_rate", 4),
        "mul_down",
    ),),
    "expiry_fee_ramp": ((
        _site("packages/predict/sources/config/strike_exposure_config.move::expiry_fee_multiplier", 1),
        "mul_div_down",
    ),),
    "ewma_penalty": (
        (_site("packages/predict/sources/ewma.move::penalty_fee", 1), "sqrt_down"),
        (_site("packages/predict/sources/ewma.move::penalty_fee", 2), "div_down"),
        (_site("packages/predict/sources/ewma.move::penalty_fee", 4), "mul_up"),
    ),
    "fee_incentive_subsidy": ((
        _site("packages/predict/sources/expiry_market.move::fee_incentive_subsidy_amount", 1),
        "mul_down",
    ),),
    "builder_fee": (
        (_site("packages/predict/sources/expiry_market.move::builder_fee_amount", 1), "mul_down"),
        (_site("packages/predict/sources/expiry_market.move::builder_fee_amount", 3), "mul_down"),
    ),
    "lp_supply_shares": ((
        _site("packages/predict/sources/plp/lp_book.move::quote_supply_shares", 1),
        "try_mul_div_down",
    ),),
    "lp_withdraw_dusdc": ((
        _site("packages/predict/sources/plp/lp_book.move::quote_withdraw_dusdc", 1),
        "try_mul_div_down",
    ),),
    "fee_incentive_live_target": ((
        _site("packages/predict/sources/plp/plp.move::sync_fee_incentives", 1),
        "mul_down",
    ),),
    "fee_incentive_lifetime_cap": ((
        _site("packages/predict/sources/plp/pool_accounting.move::register_expiry", 1),
        "mul_down",
    ),),
    "expiry_rebalance_buffer": ((
        _site("packages/predict/sources/plp/plp.move::expiry_rebalance_cash_terms", 1),
        "mul_down",
    ),),
    "protocol_profit_cut": ((
        _site("packages/predict/sources/plp/plp.move::materialize_expiry_profit", 1),
        "mul_down",
    ),),
    "withdraw_nav_bid": ((
        _site("packages/predict/sources/plp/plp.move::pool_nav_bid_ask", 2),
        "raw_sub",
    ),),
    "supply_nav_ask": (
        (_site("packages/predict/sources/plp/plp.move::pool_nav_bid_ask", 1), "raw_sub"),
        (_site("packages/predict/sources/plp/plp.move::pool_nav_bid_ask", 3), "raw_add"),
    ),
    "live_payout_buffer": ((
        _site("packages/predict/sources/strike_exposure/strike_exposure.move::payout_liability", 2),
        "mul_down",
    ),),
    "exact_amount_search_probe": ((
        _site("packages/predict/sources/strike_exposure/strike_exposure.move::quote_mint_terms", 5),
        "mul_down",
    ),),
    "close_gross_value": ((
        _site("packages/predict/sources/strike_exposure/strike_exposure.move::quote_close", 1),
        "mul_down",
    ),),
    "partial_close_remaining_floor": ((
        _site("packages/predict/sources/strike_exposure/strike_exposure.move::quote_live_close", 2),
        "mul_div_down",
    ),),
    "partial_close_gross_redeem": ((
        _site("packages/predict/sources/strike_exposure/strike_exposure.move::quote_live_close", 4),
        "mul_down",
    ),),
    "gross_order_value": ((
        _site("packages/predict/sources/strike_exposure/strike_exposure.move::gross_order_value", 1),
        "mul_down",
    ),),
}

CERTIFIED_FUNCTION_SHA256 = {
    "packages/predict/sources/config/expiry_cash_config.move::rebate_reserve_for_fee_basis": "35109fafae95da5282714d21437ee848519c80308bf770647850b0803d3bd6bd",
    "packages/predict/sources/config/stake_config.move::benefit_ratio": "b46a81e75f9efbf167685be57a7c0b5e4b6a5c3267b552966aa1892cd0745734",
    "packages/predict/sources/config/stake_config.move::fee_amount_after_discount": "de3f433e26894e7697e7931a0854efeb20a99f48a2a650ccc962f9000e98d55d",
    "packages/predict/sources/config/stake_config.move::rebate_amount": "b653dd877c3c6ee86666e29b0375dbf019505a1452997b219d0697f3e965d636",
    "packages/predict/sources/config/strike_exposure_config.move::assert_mint_admission": "783d904e62e6a72d9b3041f8266a9794efb3ce0bb71455ddeea629003876f280",
    "packages/predict/sources/config/strike_exposure_config.move::expiry_fee_multiplier": "c67c748ed94fa71bb2fb86203b07592e4fffaab03385e01de5659af22c6bd272",
    "packages/predict/sources/config/strike_exposure_config.move::fee_rate": "d6d2b29b70c22097f64f3be5f20f0660480df3845b008366bebf3fa27c6e9df3",
    "packages/predict/sources/config/strike_exposure_config.move::net_premium_from_entry_value": "7355181d77c44c24017b0262a33d3b252e6ec78b7acee09c1dc68755f95c4649",
    "packages/predict/sources/config/strike_exposure_config.move::raw_bernoulli_fee_rate": "0b8b31c1011e413302ae7dc8efe63db0fa06e394434da6400ea2c39b1c129ea4",
    "packages/predict/sources/config/strike_exposure_config.move::trading_fee": "d6ca9ab88665e4e2cabe68f5f68aec18d6ae5900e3e377d3b4b174fc975ddc55",
    "packages/predict/sources/ewma.move::penalty_fee": "8a140499880f9062b6f113d72d5e3619c4e9541f55026ac84669e9adfc4bc684",
    "packages/predict/sources/expiry_market.move::builder_fee_amount": "028efada918a444fd35a4ee468ccbda790014a420a5c4f9fdfcc3c3737f16d38",
    "packages/predict/sources/expiry_market.move::fee_incentive_subsidy_amount": "015092ce34962b7f48d4399582f4b64f64900422469cda32668da25125d6ab44",
    "packages/predict/sources/plp/lp_book.move::quote_supply_shares": "de7c62ba9545b7ea00072569c3955e5d66c3d5e1a5aa0e10d524784ae41613d6",
    "packages/predict/sources/plp/lp_book.move::quote_withdraw_dusdc": "425919b7d25ad021abdb061ec16bd7d3a7508958a249f0b2d8e428e150128793",
    "packages/predict/sources/plp/plp.move::expiry_rebalance_cash_terms": "b737bb1efe5646bc4570b0c11d5c72a19018a8e7891cea5695550ce8eca76802",
    "packages/predict/sources/plp/plp.move::materialize_expiry_profit": "f2c5e9717f094c97485a7a8e32985096232c26f8ffd9f5d5f090cd5c17683577",
    "packages/predict/sources/plp/plp.move::pool_nav_bid_ask": "2245a41955da462d994419e31ad9daa74f404de3089b2036787ac3eff149f0c1",
    "packages/predict/sources/plp/plp.move::sync_fee_incentives": "5deac9f8bd2c8cb19c120ef23e483ddae4a9e60561dba06a2c81dd3f298ec01b",
    "packages/predict/sources/plp/pool_accounting.move::register_expiry": "3ed5c5a558b6d39ea9e8791e0d70334d84d2ab20f39ccde20fb5deb07305e701",
    "packages/predict/sources/strike_exposure/strike_exposure.move::gross_order_value": "f129e5e1d8b939ca10121d76e1ea064a2f6a305e5f7c0ba23dfb28ec363d5dca",
    "packages/predict/sources/strike_exposure/strike_exposure.move::payout_liability": "ff766e2468c787b57a9554b21bbf60ac17d3815a87ebff07b2954d3f0be2b9e9",
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_close": "a37ca5d853872667c0ad141909d8257f22eadbb3223dcda47d72c852d6256f96",
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_live_close": "1b24dbd389470368773d7c950400493ddff405f2bfeb090a2849a9698d67e26e",
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_mint_terms": "0485c95dd7bcb10a6de7ea3ef324b167161177183089468150b38bba2ce353c5",
}


def _text(value: Fraction) -> str:
    return f"{value.numerator}/{value.denominator}"


@dataclass(frozen=True)
class DustCertificate:
    name: str
    function_id: str
    exact: Fraction
    actual: int
    relation: str
    sender: str | None
    recipient: str | None
    unit: str
    note: str

    def payload(self) -> dict[str, Any]:
        if self.relation == "down":
            relation_holds = Fraction(self.actual) <= self.exact
            residual = self.exact - self.actual
        elif self.relation == "up":
            relation_holds = Fraction(self.actual) >= self.exact
            residual = Fraction(self.actual) - self.exact
        elif self.relation == "exact":
            relation_holds = Fraction(self.actual) == self.exact
            residual = Fraction()
        else:
            raise ValueError(f"unknown dust relation: {self.relation}")

        owner = "none"
        if residual:
            if self.sender is None or self.recipient is None:
                owner = "policy_state"
            elif self.relation == "down":
                owner = self.sender
            else:
                owner = self.recipient
        protocol_bias_applicable = (
            self.sender in PROTOCOL_PARTIES
            or self.recipient in PROTOCOL_PARTIES
        )
        return {
            **asdict(self),
            "exact": _text(self.exact),
            "actual": str(self.actual),
            "residual": _text(residual),
            "relation_holds": relation_holds,
            "dust_exists": residual > 0,
            "owner": owner,
            "protocol_bias_applicable": protocol_bias_applicable,
            "protocol_favored": not protocol_bias_applicable
            or owner == "none"
            or owner == "policy_state"
            or owner in PROTOCOL_PARTIES,
        }


def _floor_product(a: int, b: int) -> tuple[Fraction, int]:
    exact = Fraction(a * b, F)
    return exact, exact.numerator // exact.denominator


def _ceil_fraction(value: Fraction) -> int:
    return -(-value.numerator // value.denominator)


def _ceil_product(a: int, b: int) -> tuple[Fraction, int]:
    exact = Fraction(a * b, F)
    return exact, _ceil_fraction(exact)


def _floor_ratio(a: int, b: int, denominator: int) -> tuple[Fraction, int]:
    exact = Fraction(a * b, denominator)
    return exact, exact.numerator // exact.denominator


def build_certificates() -> list[dict[str, Any]]:
    rows: list[DustCertificate] = []

    def add(
        name: str,
        function_id: str,
        exact: Fraction,
        actual: int,
        relation: str,
        sender: str | None,
        recipient: str | None,
        note: str,
        unit: str = "dusdc_1e6",
    ) -> None:
        rows.append(
            DustCertificate(
                name,
                function_id,
                exact,
                actual,
                relation,
                sender,
                recipient,
                unit,
                note,
            )
        )

    # Rebate reserve and stake-benefit surfaces.
    exact, actual = _floor_product(123_456_789, 200_000_000)
    add(
        "rebate_reserve",
        "packages/predict/sources/config/expiry_cash_config.move::rebate_reserve_for_fee_basis",
        exact,
        actual,
        "down",
        "lp_pool",
        "trader",
        "A lower reserve can only reduce the future rebate outflow.",
    )

    lower, upper, stake = 100_000_003, 300_000_011, 73_000_001
    benefit_exact, benefit = _floor_ratio(F // 2, stake, lower)
    add(
        "stake_benefit_ratio",
        "packages/predict/sources/config/stake_config.move::benefit_ratio",
        benefit_exact,
        benefit,
        "down",
        None,
        None,
        "The benefit projection is floored before either discount or rebate use.",
        "ratio_1e9",
    )
    max_discount = 250_000_000
    discount_exact, discount = _floor_product(benefit, max_discount)
    fee_amount = 17_000_003
    fee_discount_exact = Fraction(fee_amount * discount, F)
    discounted_fee = fee_amount - (
        fee_discount_exact.numerator // fee_discount_exact.denominator
    )
    add(
        "discount_fraction",
        "packages/predict/sources/config/stake_config.move::fee_amount_after_discount",
        discount_exact,
        discount,
        "down",
        None,
        None,
        "A smaller projected discount is protocol-favored.",
        "ratio_1e9",
    )
    add(
        "discounted_fee_complement",
        "packages/predict/sources/config/stake_config.move::fee_amount_after_discount",
        Fraction(fee_amount) - fee_discount_exact,
        discounted_fee,
        "up",
        "trader",
        "expiry_cash",
        "Subtracting a floored discount rounds the fee upward.",
    )
    rebate_exact, rebate = _floor_product(29_000_009, benefit)
    add(
        "stake_rebate",
        "packages/predict/sources/config/stake_config.move::rebate_amount",
        rebate_exact,
        rebate,
        "down",
        "lp_pool",
        "trader",
        "The claimant receives no more than the exact rebate.",
    )

    # Fee construction and mint admission.
    rate, quantity = 13_000_007, 19_000_003
    trading_fee_exact, trading_fee = _ceil_product(rate, quantity)
    add(
        "trading_fee",
        "packages/predict/sources/config/strike_exposure_config.move::trading_fee",
        trading_fee_exact,
        trading_fee,
        "up",
        "trader",
        "expiry_cash",
        "The final rate-to-quantity conversion rounds protocol inflow upward.",
    )
    probability, mint_quantity, leverage = 499_130_085, 20_000_000, 2_500_000_000
    entry_exact, entry_value = _floor_product(probability, mint_quantity)
    add(
        "mint_entry_value",
        "packages/predict/sources/config/strike_exposure_config.move::assert_mint_admission",
        entry_exact,
        entry_value,
        "down",
        None,
        None,
        "Entry value is a stored accounting atom shared by premium and floor.",
    )
    premium_exact = Fraction(entry_value * F, leverage)
    net_premium = _ceil_fraction(premium_exact)
    add(
        "net_premium",
        "packages/predict/sources/config/strike_exposure_config.move::net_premium_from_entry_value",
        premium_exact,
        net_premium,
        "up",
        "trader",
        "expiry_cash",
        "Premium rounds upward and the stored floor is its exact complement.",
    )

    base, multiplier = 7_000_003, 1_700_000_003
    fee_rate_exact, fee_rate = _floor_product(base, multiplier)
    add(
        "fee_rate",
        "packages/predict/sources/config/strike_exposure_config.move::fee_rate",
        fee_rate_exact,
        fee_rate,
        "down",
        None,
        None,
        "The projected fee rate is floored before charging quantity.",
        "rate_1e9",
    )
    probability = 500_000_000
    variance_exact, variance = _floor_product(probability, F - probability)
    add(
        "bernoulli_variance",
        "packages/predict/sources/config/strike_exposure_config.move::raw_bernoulli_fee_rate",
        variance_exact,
        variance,
        "down",
        None,
        None,
        "The selected half-probability witness has an exact square root.",
        "variance_1e9",
    )
    bernoulli_factor = math.isqrt(variance * F)
    raw_rate_exact, raw_rate = _floor_product(33_000_007, bernoulli_factor)
    add(
        "raw_bernoulli_fee",
        "packages/predict/sources/config/strike_exposure_config.move::raw_bernoulli_fee_rate",
        raw_rate_exact,
        raw_rate,
        "down",
        None,
        None,
        "The raw rate floor propagates into the charged fee.",
        "rate_1e9",
    )
    ramp_exact, ramp = _floor_ratio(3_000_000_007, 777, 1_000)
    add(
        "expiry_fee_ramp",
        "packages/predict/sources/config/strike_exposure_config.move::expiry_fee_multiplier",
        ramp_exact,
        ramp,
        "down",
        None,
        None,
        "The near-expiry multiplier ramp is floored.",
        "ratio_1e9",
    )

    penalty_exact, penalty = _ceil_product(21_000_007, 31_000_009)
    add(
        "ewma_penalty",
        "packages/predict/sources/ewma.move::penalty_fee",
        penalty_exact,
        penalty,
        "up",
        "trader",
        "expiry_cash",
        "The final penalty-rate conversion rounds protocol inflow upward.",
    )
    subsidy_exact, subsidy = _floor_product(17_000_003, 100_000_000)
    add(
        "fee_incentive_subsidy",
        "packages/predict/sources/expiry_market.move::fee_incentive_subsidy_amount",
        subsidy_exact,
        subsidy,
        "down",
        "fee_incentive_reserve",
        "trader",
        "The sponsor reserve retains subsidy dust; total expiry fee is unchanged.",
    )
    builder_share_exact, builder_share = _floor_product(
        17_000_003,
        200_000_000,
    )
    builder_cap_exact, builder_cap = _floor_product(
        31_000_009,
        50_000_000,
    )
    add(
        "builder_fee",
        "packages/predict/sources/expiry_market.move::builder_fee_amount",
        min(builder_share_exact, builder_cap_exact),
        min(builder_share, builder_cap),
        "down",
        "trader",
        "builder",
        "Builder-fee dust stays with the paying trader; no pool leg exists.",
    )

    # LP, reserve, and pool-accounting surfaces.
    supply_exact, supply_shares = _floor_ratio(
        5_000_003,
        500_000_000_000,
        499_999_999_937,
    )
    add(
        "lp_supply_shares",
        "packages/predict/sources/plp/lp_book.move::quote_supply_shares",
        supply_exact,
        supply_shares,
        "down",
        "lp_pool",
        "supplier",
        "The supplier receives no more than the ask-priced entitlement.",
        "plp_1e6",
    )
    withdraw_exact, withdraw = _floor_ratio(
        5_000_003,
        499_999_999_911,
        500_000_000_000,
    )
    add(
        "lp_withdraw_dusdc",
        "packages/predict/sources/plp/lp_book.move::quote_withdraw_dusdc",
        withdraw_exact,
        withdraw,
        "down",
        "lp_pool",
        "withdrawer",
        "The withdrawer receives no more than the bid-priced entitlement.",
    )

    target_exact, target = _floor_product(500_000_000_003, 50_000_000)
    add(
        "fee_incentive_live_target",
        "packages/predict/sources/plp/plp.move::sync_fee_incentives",
        target_exact,
        target,
        "down",
        "fee_incentive_reserve",
        "expiry_cash",
        "Both legs are protocol custody; the reserve retains target dust.",
    )
    lifetime_exact, lifetime = _floor_product(
        500_000_000_003,
        250_000_000,
    )
    add(
        "fee_incentive_lifetime_cap",
        "packages/predict/sources/plp/pool_accounting.move::register_expiry",
        lifetime_exact,
        lifetime,
        "down",
        "fee_incentive_reserve",
        "expiry_cash",
        "Both legs are protocol custody; the reserve retains cap dust.",
    )
    rebalance_exact, rebalance_buffer = _floor_product(
        500_000_000_003,
        100_000_000,
    )
    add(
        "expiry_rebalance_buffer",
        "packages/predict/sources/plp/plp.move::expiry_rebalance_cash_terms",
        rebalance_exact,
        rebalance_buffer,
        "down",
        "lp_pool",
        "expiry_cash",
        "Both balances belong to LPs; floor keeps the fraction idle.",
    )
    protocol_exact, protocol_cut = _floor_product(
        123_456_789,
        200_000_000,
    )
    add(
        "protocol_profit_cut",
        "packages/predict/sources/plp/plp.move::materialize_expiry_profit",
        protocol_exact,
        protocol_cut,
        "down",
        "lp_pool",
        "protocol_reserve",
        "The residual remains with LPs, satisfying the protocol-or-pool doctrine.",
    )
    nav_center = 500_000_000_003
    nav_error = 17
    add(
        "withdraw_nav_bid",
        "packages/predict/sources/plp/plp.move::pool_nav_bid_ask",
        Fraction(nav_center - nav_error),
        nav_center - nav_error,
        "exact",
        None,
        None,
        "Withdrawal uses the exact low endpoint of the certified NAV interval.",
    )
    add(
        "supply_nav_ask",
        "packages/predict/sources/plp/plp.move::pool_nav_bid_ask",
        Fraction(nav_center + nav_error),
        nav_center + nav_error,
        "exact",
        None,
        None,
        "Supply uses the exact high endpoint of the certified NAV interval.",
    )
    buffer_exact, buffer = _floor_product(987_654_321, 250_000_000)
    add(
        "live_payout_buffer",
        "packages/predict/sources/strike_exposure/strike_exposure.move::payout_liability",
        buffer_exact,
        buffer,
        "down",
        None,
        None,
        "The settlement floor remains exact; only optional early-exit buffer dust is free.",
    )

    # Exact-amount search and live-close surfaces.
    search_exact, search_probe = _floor_ratio(
        499_130_085,
        31 * replay.POSITION_LOT_SIZE,
        2_500_000_000,
    )
    add(
        "exact_amount_search_probe",
        "packages/predict/sources/strike_exposure/strike_exposure.move::quote_mint_terms",
        search_exact,
        search_probe,
        "down",
        None,
        None,
        "The one-floor search probe is compared with the admitted two-floor premium.",
    )
    close_exact, close_value = _floor_product(499_130_085, 20_000_000)
    add(
        "close_gross_value",
        "packages/predict/sources/strike_exposure/strike_exposure.move::quote_close",
        close_exact,
        close_value,
        "down",
        "expiry_cash",
        "trader",
        "The quoted close value is a user-facing outflow.",
    )
    remaining_exact, remaining_floor = _floor_ratio(
        5_989_561,
        19_990_000,
        20_000_000,
    )
    add(
        "partial_close_remaining_floor",
        "packages/predict/sources/strike_exposure/strike_exposure.move::quote_live_close",
        remaining_exact,
        remaining_floor,
        "down",
        None,
        None,
        "The closed slice receives the exact integer complement.",
        "floor_shares_1e6",
    )
    live_gross_exact, live_gross = _floor_product(499_130_085, 10_000)
    add(
        "partial_close_gross_redeem",
        "packages/predict/sources/strike_exposure/strike_exposure.move::quote_live_close",
        live_gross_exact,
        live_gross,
        "down",
        "expiry_cash",
        "trader",
        "Gross close outflow rounds down before the conserved floor subtraction.",
    )
    order_exact, order_value = _floor_product(877_147_899, 30_000_000)
    add(
        "gross_order_value",
        "packages/predict/sources/strike_exposure/strike_exposure.move::gross_order_value",
        order_exact,
        order_value,
        "down",
        "expiry_cash",
        "trader",
        "The live order mark floors the integer quantity product.",
    )

    return [row.payload() for row in rows]


def build_proof_bundle(
    inventory_bundle: dict[str, Any] | None = None,
) -> dict[str, Any]:
    certificates = build_certificates()
    inventory_bundle = inventory_bundle or inventory.build_inventory()
    inventoried_money_collapse_functions = {
        record["function_id"]
        for record in inventory_bundle["records"]
        if record["classification"] == inventory.MONEY_COLLAPSE
    }
    modeled_functions = {
        certificate["function_id"] for certificate in certificates
    }
    missing = sorted(inventoried_money_collapse_functions - modeled_functions)
    extra = sorted(modeled_functions - inventoried_money_collapse_functions)
    actual_sites = {
        record["site_id"]: record["operator"]
        for record in inventory_bundle["records"]
    }
    actual_function_hashes = {
        record["function_id"]: record["function_source_sha256"]
        for record in inventory_bundle["records"]
        if record["classification"] == inventory.MONEY_COLLAPSE
    }
    source_binding_mismatches = []
    bound_sites = set()
    for certificate in certificates:
        bindings = CERTIFICATE_SOURCE_BINDINGS.get(certificate["name"], ())
        if not bindings:
            source_binding_mismatches.append({
                "certificate": certificate["name"],
                "reason": "missing_declared_source_binding",
            })
        for site_id, expected_operator in bindings:
            bound_sites.add(site_id)
            actual_operator = actual_sites.get(site_id)
            if actual_operator != expected_operator:
                source_binding_mismatches.append({
                    "certificate": certificate["name"],
                    "site_id": site_id,
                    "expected_operator": expected_operator,
                    "actual_operator": actual_operator,
                })
    for function_id in sorted(inventoried_money_collapse_functions):
        expected_hash = CERTIFIED_FUNCTION_SHA256.get(function_id)
        actual_hash = actual_function_hashes.get(function_id)
        if actual_hash != expected_hash:
            source_binding_mismatches.append({
                "function_id": function_id,
                "reason": "function_source_fingerprint_mismatch",
                "expected_sha256": expected_hash,
                "actual_sha256": actual_hash,
            })
    stale_function_source_bindings = sorted(
        set(CERTIFIED_FUNCTION_SHA256)
        - inventoried_money_collapse_functions
    )
    if stale_function_source_bindings:
        source_binding_mismatches.append({
            "reason": "stale_function_source_bindings",
            "function_ids": stale_function_source_bindings,
        })
    directed_money_sites = {
        record["site_id"]
        for record in inventory_bundle["records"]
        if (
            record["classification"] == inventory.MONEY_COLLAPSE
            and record["operator"] in inventory.DIRECTED_ROUNDING_OPERATORS
        )
    }
    unbound_directed_money_sites = sorted(directed_money_sites - bound_sites)
    return {
        "schema": "predict_math_dust_proofs_v1",
        "certificates": certificates,
        "money_collapse_functions": sorted(
            inventoried_money_collapse_functions
        ),
        "missing_money_functions": missing,
        "extra_modeled_functions": extra,
        "source_binding_mismatches": source_binding_mismatches,
        "stale_function_source_bindings": stale_function_source_bindings,
        "unbound_directed_money_sites": unbound_directed_money_sites,
        "all_source_bindings_hold": (
            not source_binding_mismatches
            and not unbound_directed_money_sites
        ),
        "all_relations_hold": all(
            row["relation_holds"] for row in certificates
        ),
        "nonzero_dust_witness_count": sum(
            row["dust_exists"] for row in certificates
        ),
        "protocol_bias_mismatches": [
            row
            for row in certificates
            if (
                row["dust_exists"]
                and row["protocol_bias_applicable"]
                and not row["protocol_favored"]
            )
        ],
        "complete_for_inventoried_money_collapse_functions": (
            not missing
            and not extra
            and not source_binding_mismatches
            and not unbound_directed_money_sites
        ),
    }


def main() -> None:
    print(json.dumps(build_proof_bundle(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
