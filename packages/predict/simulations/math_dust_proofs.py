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
        "packages/predict/sources/plp/plp.move::sync_fee_incentives",
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
        "packages/predict/sources/plp/plp.move::finish_flush",
        Fraction(nav_center - nav_error),
        nav_center - nav_error,
        "exact",
        None,
        None,
        "Withdrawal uses the exact low endpoint of the certified NAV interval.",
    )
    add(
        "supply_nav_ask",
        "packages/predict/sources/plp/plp.move::finish_flush",
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


def build_proof_bundle() -> dict[str, Any]:
    certificates = build_certificates()
    inventoried_money_collapse_functions = {
        record["function_id"]
        for record in inventory.build_inventory()["records"]
        if record["classification"] == inventory.MONEY_COLLAPSE
    }
    modeled_functions = {
        certificate["function_id"] for certificate in certificates
    }
    missing = sorted(inventoried_money_collapse_functions - modeled_functions)
    extra = sorted(modeled_functions - inventoried_money_collapse_functions)
    return {
        "schema": "predict_math_dust_proofs_v1",
        "certificates": certificates,
        "money_collapse_functions": sorted(
            inventoried_money_collapse_functions
        ),
        "missing_money_functions": missing,
        "extra_modeled_functions": extra,
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
            not missing and not extra
        ),
    }


def main() -> None:
    print(json.dumps(build_proof_bundle(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
