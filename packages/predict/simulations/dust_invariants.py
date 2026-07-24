#!/usr/bin/env python3
"""Evaluate Predict rounding and NAV-collapse policy over the algebra trace."""

from __future__ import annotations

import argparse
import algebra_minimality
import itertools
import json
from collections import defaultdict
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Any

import algebra_trace
import economic_lifecycle_proofs
import math_dust_proofs
import money_math_inventory
import partial_close_proofs
import payout_tree_proofs
import python_replay as replay
import saturation_proofs

SCHEMA_VERSION = "predict_dust_invariants_v1"
CONTRACT_BASELINE = algebra_trace.CONTRACT_BASELINE
PRICING_PROFILE = algebra_trace.PRICING_PROFILE
F = replay.FLOAT_SCALING
U64_MAX = (1 << 64) - 1
EXECUTABLE_PRICE_BAND_FACTOR = 100
MAX_NAV_DEVIATION = 10_000_000


def _fraction_text(value: Fraction) -> str:
    return f"{value.numerator}/{value.denominator}"


def _ceil_fraction(value: Fraction) -> int:
    return -(-value.numerator // value.denominator)


def _round_fraction(value: Fraction, direction: str) -> int:
    if direction == "down":
        return value.numerator // value.denominator
    if direction == "up":
        return _ceil_fraction(value)
    raise ValueError(f"unknown rounding direction: {direction}")


def _ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


@dataclass(frozen=True)
class NavBand:
    center: int
    error: int

    def __post_init__(self) -> None:
        if self.center < 0 or self.error < 0:
            raise ValueError("NAV center and error must be nonnegative")
        if self.center + self.error > U64_MAX:
            raise ValueError("NAV ask exceeds u64")

    @property
    def bid(self) -> int:
        return max(0, self.center - self.error)

    @property
    def ask(self) -> int:
        return self.center + self.error

    @property
    def flush_marks(self) -> tuple[int, int]:
        """Mirror `plp::finish_flush`'s zero-center economic boundary."""
        if self.center == 0:
            return (0, 0)
        if not self.flush_precision_eligible:
            raise ValueError("NAV band fails finish_flush precision policy")
        return (self.bid, self.ask)

    @property
    def flush_precision_eligible(self) -> bool:
        return (
            self.center == 0
            or self.true_relative_deviation_within(MAX_NAV_DEVIATION)
        )

    def side(self, side: str) -> int:
        if side == "bid":
            return self.bid
        if side == "center":
            return self.center
        if side == "ask":
            return self.ask
        raise ValueError(f"unknown NAV side: {side}")

    def flush_side(self, side: str) -> int:
        bid, ask = self.flush_marks
        if side == "bid":
            return bid
        if side == "center":
            return self.center
        if side == "ask":
            return ask
        raise ValueError(f"unknown NAV side: {side}")

    def shifted_by_exact_cash(self, amount: int) -> "NavBand":
        return NavBand(self.center + amount, self.error)

    def contains(self, value: Fraction) -> bool:
        return Fraction(self.bid) <= value <= Fraction(self.ask)

    def true_relative_deviation_within(self, max_deviation: int) -> bool:
        if self.error > self.center:
            return False
        return self.error * F <= max_deviation * (self.center - self.error)


@dataclass(frozen=True)
class CollapseSpec:
    role: str
    pool_party: str
    counterparty: str
    doctrine_owner: str


@dataclass(frozen=True)
class BalanceSheet:
    balances: dict[str, dict[str, int]]

    def balance(self, asset: str, party: str) -> int:
        return self.balances.get(asset, {}).get(party, 0)

    def total(self, asset: str) -> int:
        return sum(self.balances.get(asset, {}).values())

    def parties(self, asset: str) -> set[str]:
        return set(self.balances.get(asset, {}))


@dataclass(frozen=True)
class PositionState:
    quantity: int
    floor_shares: int
    status: str

    @property
    def winner_liability(self) -> int:
        if self.status == "liquidated":
            return 0
        return self.quantity - self.floor_shares

    @property
    def valid(self) -> bool:
        return (
            self.quantity >= 0
            and self.floor_shares >= 0
            and self.floor_shares <= self.quantity
            and self.status
            in {"active", "settled_winner", "settled_loser", "liquidated"}
        )


@dataclass(frozen=True)
class LifecycleState:
    trader_cash: int
    pool_cash: int
    position: PositionState | None

    @property
    def valid(self) -> bool:
        return (
            self.trader_cash >= 0
            and self.pool_cash >= 0
            and (self.position is None or self.position.valid)
        )

    def balance_sheet(self) -> BalanceSheet:
        return BalanceSheet(
            {
                "dusdc_1e6": {
                    "trader": self.trader_cash,
                    "lp_pool": self.pool_cash,
                }
            }
        )


def _cash_transition(
    state: LifecycleState,
    *,
    amount: int,
    sender: str,
    recipient: str,
    position: PositionState | None,
) -> LifecycleState:
    if amount < 0:
        raise ValueError("cash transfer amount must be nonnegative")
    if {sender, recipient} != {"trader", "lp_pool"}:
        raise ValueError("lifecycle cash transfer must be trader <-> pool")
    trader_delta = -amount if sender == "trader" else amount
    pool_delta = -amount if sender == "lp_pool" else amount
    return LifecycleState(
        trader_cash=state.trader_cash + trader_delta,
        pool_cash=state.pool_cash + pool_delta,
        position=position,
    )


def reconcile_transfer(
    *,
    before: BalanceSheet,
    after: BalanceSheet,
    asset: str,
    sender: str,
    recipient: str,
    exact_amount: Fraction,
    pool_party: str,
) -> dict[str, Any]:
    """Derive the actual transfer and dust owner from independent snapshots."""
    sender_out = before.balance(asset, sender) - after.balance(asset, sender)
    recipient_in = after.balance(asset, recipient) - before.balance(
        asset,
        recipient,
    )
    account_legs_match = sender_out == recipient_in and sender_out >= 0
    asset_conserved = before.total(asset) == after.total(asset)
    untouched_parties_unchanged = all(
        before.balance(asset, party) == after.balance(asset, party)
        for party in before.parties(asset) | after.parties(asset)
        if party not in {sender, recipient}
    )
    actual_amount = sender_out if account_legs_match else None
    pool_advantage: Fraction | None = None
    actual_owner: str | None = None
    if actual_amount is not None:
        if recipient == pool_party:
            pool_advantage = Fraction(actual_amount) - exact_amount
        elif sender == pool_party:
            pool_advantage = exact_amount - Fraction(actual_amount)
        else:
            raise ValueError("pool party must be one leg of a dust transfer")
        actual_owner = (
            pool_party
            if pool_advantage > 0
            else recipient
            if sender == pool_party and pool_advantage < 0
            else sender
            if recipient == pool_party and pool_advantage < 0
            else "none"
        )
    valid = (
        account_legs_match
        and asset_conserved
        and untouched_parties_unchanged
    )
    return {
        "sender_out": str(sender_out),
        "recipient_in": str(recipient_in),
        "actual_amount": (
            None if actual_amount is None else str(actual_amount)
        ),
        "exact_amount": _fraction_text(exact_amount),
        "pool_advantage": (
            None
            if pool_advantage is None
            else _fraction_text(pool_advantage)
        ),
        "actual_owner": actual_owner,
        "account_legs_match": account_legs_match,
        "asset_conserved": asset_conserved,
        "untouched_parties_unchanged": untouched_parties_unchanged,
        "valid": valid,
    }


COLLAPSE_REGISTRY = {
    "net_premium": CollapseSpec("cash_inflow", "lp_pool", "trader", "lp_pool"),
    "trading_fee": CollapseSpec("cash_inflow", "lp_pool", "trader", "lp_pool"),
    "redeem_amount": CollapseSpec("cash_outflow", "lp_pool", "trader", "lp_pool"),
    "settlement_winner_payout": CollapseSpec("cash_outflow", "lp_pool", "trader", "lp_pool"),
    "settlement_loser_payout": CollapseSpec("cash_outflow", "lp_pool", "trader", "lp_pool"),
    "supply_shares": CollapseSpec("share_outflow", "lp_pool", "supplier", "lp_pool"),
    "withdraw_dusdc": CollapseSpec("cash_outflow", "lp_pool", "withdrawer", "lp_pool"),
}

PRIOR_1E9_PROFILE = {
    "ordinary_1x": {
        "mint_range_price": (528_329_890, 534),
        "net_premium": (6_339_958, 0),
        "floor_shares": (0, 0),
        "redeem_amount": (2_113_319, 0),
        "settlement_winner_payout": (12_000_000, 0),
        "pool_value": (500_000_059_904, 9),
        "supply_shares": (5_000_099, 0),
        "withdraw_dusdc": (4_999_999, 0),
    },
    "leveraged_boundary": {
        "mint_range_price": (499_130_082, 1_959),
        "net_premium": (3_993_040, 0),
        "floor_shares": (5_989_561, 0),
        "redeem_amount": (1_996, 0),
        "settlement_winner_payout": (14_010_439, 0),
        "pool_value": (500_000_100_000, 83),
        "supply_shares": (5_000_098, 0),
        "withdraw_dusdc": (4_999_999, 0),
    },
    "precision_sensitive": {
        "mint_range_price": (877_148_869, 4_043),
        "net_premium": (10_525_786, 0),
        "floor_shares": (15_788_680, 0),
        "redeem_amount": (3_508_594, 0),
        "settlement_winner_payout": (14_211_320, 0),
        "pool_value": (500_000_098_480, 247),
        "supply_shares": (5_000_099, 0),
        "withdraw_dusdc": (4_999_999, 0),
    },
}

FLOW_COVERAGE = {
    "modeled": [
        "exact-quantity mint premium and raw trading fee",
        "stored quantity and floor atoms",
        "partial live close",
        "repeated partial-close composition and discounted net proceeds",
        "liquidation zero-payout classification",
        "winner and loser settlement",
        "single-order live liability and NAV",
        "LP supply and withdrawal collapse",
        "protocol-profit split",
        "stake discount",
        "builder fee",
        "fee-incentive subsidy",
        "EWMA penalty",
        "rebate claim",
        "exact-amount mint search",
        "multi-order payout-tree aggregation and settled redemption",
    ],
    "not_yet_modeled": [],
}


class DustLedger:
    def __init__(self) -> None:
        self.balances: dict[str, dict[str, Fraction]] = defaultdict(
            lambda: defaultdict(Fraction)
        )
        self.transfers: list[dict[str, str]] = []

    def transfer(
        self,
        *,
        asset: str,
        amount: Fraction,
        sender: str,
        recipient: str,
        site: str,
    ) -> None:
        if amount < 0:
            raise ValueError("dust transfer amount must be nonnegative")
        if amount == 0:
            return
        self.balances[asset][sender] -= amount
        self.balances[asset][recipient] += amount
        self.transfers.append(
            {
                "asset": asset,
                "amount": _fraction_text(amount),
                "sender": sender,
                "recipient": recipient,
                "site": site,
            }
        )

    def payload(self) -> dict[str, Any]:
        balances = {
            asset: {
                party: _fraction_text(amount)
                for party, amount in sorted(parties.items())
                if amount
            }
            for asset, parties in sorted(self.balances.items())
        }
        conserved = {
            asset: sum(parties.values(), Fraction()) == 0
            for asset, parties in self.balances.items()
        }
        return {
            "balances": balances,
            "transfers": self.transfers,
            "conserved_by_asset": conserved,
            "all_assets_conserved": all(conserved.values()),
        }


def _node_inputs(
    node: dict[str, Any],
    nodes_by_id: dict[str, dict[str, Any]],
) -> list[int]:
    return [int(nodes_by_id[node_id]["center"]) for node_id in node["inputs"]]


def _local_reference(
    node: dict[str, Any],
    nodes_by_id: dict[str, dict[str, Any]],
) -> Fraction:
    inputs = _node_inputs(node, nodes_by_id)
    op = node["op"]
    if op in {"mul_scaled", "mul_scaled_up"}:
        return Fraction(inputs[0] * inputs[1], F)
    if op in {"div_scaled", "div_scaled_up"}:
        return Fraction(inputs[0] * F, inputs[1])
    if op == "mul_div_down":
        return Fraction(inputs[0] * inputs[1], inputs[2])
    if op == "half":
        return Fraction(inputs[0], 2)
    return Fraction(int(node["center"]))


def _pool_advantage(
    role: str,
    actual: int,
    reference: Fraction,
) -> Fraction:
    if role == "cash_inflow":
        return Fraction(actual) - reference
    if role in {"cash_outflow", "share_outflow"}:
        return reference - Fraction(actual)
    raise ValueError(f"unknown collapse role: {role}")


def analyze_collapse_sites(algebra_bundle: dict[str, Any]) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    unknown: list[dict[str, str]] = []
    untagged: list[dict[str, str]] = []
    observed: set[str] = set()
    ledger = DustLedger()

    for scenario in algebra_bundle["scenarios"]:
        nodes_by_id = {node["id"]: node for node in scenario["nodes"]}
        for node in scenario["nodes"]:
            if node["boundary"] != "money":
                continue
            name = node["name"]
            observed.add(name)
            if node["flow_direction"] is None or node["dust_owner"] is None:
                untagged.append(
                    {
                        "scenario": scenario["scenario"],
                        "node": node["id"],
                        "name": name,
                        "move_site": node["move_site"],
                    }
                )
            spec = COLLAPSE_REGISTRY.get(name)
            if spec is None:
                unknown.append(
                    {
                        "scenario": scenario["scenario"],
                        "node": node["id"],
                        "name": name,
                        "move_site": node["move_site"],
                    }
                )
                continue
            actual = int(node["center"])
            reference = _local_reference(node, nodes_by_id)
            advantage = _pool_advantage(spec.role, actual, reference)
            actual_owner = (
                spec.pool_party
                if advantage > 0
                else spec.counterparty
                if advantage < 0
                else "none"
            )
            if advantage > 0:
                ledger.transfer(
                    asset=node["unit"],
                    amount=advantage,
                    sender=spec.counterparty,
                    recipient=spec.pool_party,
                    site=node["id"],
                )
            elif advantage < 0:
                ledger.transfer(
                    asset=node["unit"],
                    amount=-advantage,
                    sender=spec.pool_party,
                    recipient=spec.counterparty,
                    site=node["id"],
                )
            declared_owner = node["dust_owner"]
            declared_owner_matches = (
                actual_owner == "none"
                or declared_owner == actual_owner
                or (
                    declared_owner == "pool"
                    and actual_owner == spec.pool_party
                )
            )
            records.append(
                {
                    "scenario": scenario["scenario"],
                    "node": node["id"],
                    "name": name,
                    "move_site": node["move_site"],
                    "role": spec.role,
                    "asset": node["unit"],
                    "actual": str(actual),
                    "local_reference": _fraction_text(reference),
                    "pool_advantage": _fraction_text(advantage),
                    "actual_owner": actual_owner,
                    "declared_owner": declared_owner,
                    "doctrine_owner": spec.doctrine_owner,
                    "declared_owner_matches": declared_owner_matches,
                    "doctrine_matches": actual_owner in {"none", spec.doctrine_owner},
                }
            )

    unobserved = sorted(set(COLLAPSE_REGISTRY) - observed)
    doctrine_mismatches = [
        record for record in records if not record["doctrine_matches"]
    ]
    return {
        "registry": {
            name: {
                "role": spec.role,
                "pool_party": spec.pool_party,
                "counterparty": spec.counterparty,
                "doctrine_owner": spec.doctrine_owner,
            }
            for name, spec in sorted(COLLAPSE_REGISTRY.items())
        },
        "records": records,
        "unknown_money_sites": unknown,
        "untagged_money_sites": untagged,
        "unobserved_registry_sites": unobserved,
        "complete": not unknown and not unobserved and not untagged,
        "doctrine_mismatches": doctrine_mismatches,
        "ledger": ledger.payload(),
    }


def analyze_net_premium_lifecycle(
    algebra_bundle: dict[str, Any],
) -> list[dict[str, Any]]:
    outcomes = []
    for scenario in algebra_bundle["scenarios"]:
        nodes_by_id = {node["id"]: node for node in scenario["nodes"]}
        nodes_by_name = {node["name"]: node for node in scenario["nodes"]}
        premium = nodes_by_name["net_premium"]
        exact_premium = _local_reference(premium, nodes_by_id)
        actual_premium = int(premium["center"])
        protocol_upfront_advantage = Fraction(actual_premium) - exact_premium
        entry_value = int(nodes_by_name["entry_exposure_value"]["center"])
        quantity = int(nodes_by_name["stored_order_quantity"]["center"])
        actual_floor = int(nodes_by_name["stored_order_floor"]["center"])
        exact_floor = Fraction(entry_value) - exact_premium
        actual_winner_payout = quantity - actual_floor
        exact_winner_payout = Fraction(quantity) - exact_floor
        trader_winner_payout_advantage = (
            Fraction(actual_winner_payout) - exact_winner_payout
        )
        outcomes.append(
            {
                "scenario": scenario["scenario"],
                "protocol_upfront_advantage": _fraction_text(
                    protocol_upfront_advantage
                ),
                "trader_winner_payout_advantage": _fraction_text(
                    trader_winner_payout_advantage
                ),
                "mint_to_winner_net_protocol_advantage": _fraction_text(
                    protocol_upfront_advantage
                    - trader_winner_payout_advantage
                ),
                "mint_to_loser_net_protocol_advantage": _fraction_text(
                    protocol_upfront_advantage
                ),
                "full_live_close_at_entry_net_protocol_advantage": "0/1",
                "interpretation": (
                    "premium ceil dust is paired with the opposite stored-floor "
                    "and winner-payout movement; it is protocol-owned only on a "
                    "losing terminal path"
                ),
            }
        )
    return outcomes


def is_executable_mark(pool_value: int, total_supply: int) -> bool:
    if total_supply == 0:
        return False
    band = EXECUTABLE_PRICE_BAND_FACTOR
    return (
        _ceil_div(pool_value, band) <= total_supply
        and _ceil_div(total_supply, band) <= pool_value
    )


def quote_supply(
    amount: int,
    total_supply: int,
    pool_value: int,
    rounding: str,
) -> int | None:
    executable = is_executable_mark(pool_value, total_supply)
    if rounding == "down":
        return replay.quote_supply_shares(
            amount,
            total_supply,
            pool_value,
            executable,
        )
    if not executable:
        return None
    shares = _round_fraction(Fraction(amount * total_supply, pool_value), rounding)
    return shares if shares > 0 else None


def quote_withdraw(
    shares: int,
    total_supply: int,
    pool_value: int,
    rounding: str,
) -> int | None:
    executable = is_executable_mark(pool_value, total_supply)
    if rounding == "down":
        return replay.quote_withdraw_dusdc(
            shares,
            pool_value,
            total_supply,
            executable,
        )
    if not executable:
        return None
    payout = _round_fraction(Fraction(shares * pool_value, total_supply), rounding)
    return payout if payout > 0 else None


@dataclass(frozen=True)
class LpPolicy:
    supply_side: str
    withdraw_side: str
    supply_rounding: str
    withdraw_rounding: str

    @property
    def name(self) -> str:
        return (
            f"supply={self.supply_side}/{self.supply_rounding},"
            f"withdraw={self.withdraw_side}/{self.withdraw_rounding}"
        )


LANDED_LP_POLICY = LpPolicy("ask", "bid", "down", "down")
PRIOR_CENTER_LP_POLICY = LpPolicy("center", "center", "down", "down")


def evaluate_lp_policy(
    band: NavBand,
    *,
    amount: int,
    total_supply: int,
    withdraw_shares: int,
    policy: LpPolicy,
) -> dict[str, Any]:
    if not band.flush_precision_eligible:
        return {
            "policy": policy.name,
            "policy_terms": {
                "supply_side": policy.supply_side,
                "withdraw_side": policy.withdraw_side,
                "supply_rounding": policy.supply_rounding,
                "withdraw_rounding": policy.withdraw_rounding,
            },
            "flush_status": "valuation_rejected",
            "supply_mark": None,
            "withdraw_mark": None,
            "supplied_shares": None,
            "withdraw_payout": None,
            "roundtrip_payout": None,
            "roundtrip_executable": False,
            "supply_no_overmint": True,
            "withdraw_no_overpay": True,
            "roundtrip_no_extraction": True,
            "all_invariants_hold": True,
        }
    supply_mark = band.flush_side(policy.supply_side)
    withdraw_mark = band.flush_side(policy.withdraw_side)
    supplied = quote_supply(
        amount,
        total_supply,
        supply_mark,
        policy.supply_rounding,
    )
    withdrawn = quote_withdraw(
        withdraw_shares,
        total_supply,
        withdraw_mark,
        policy.withdraw_rounding,
    )
    truths = (band.bid, band.ask)
    supply_no_overmint = supplied is None or all(
        Fraction(supplied) <= Fraction(amount * total_supply, truth)
        for truth in truths
        if truth > 0
    )
    withdraw_no_overpay = withdrawn is None or all(
        Fraction(withdrawn)
        <= Fraction(withdraw_shares * truth, total_supply)
        for truth in truths
    )

    roundtrip_payout: int | None = None
    roundtrip_executable = False
    roundtrip_no_extraction = True
    if supplied is not None:
        post_band = band.shifted_by_exact_cash(amount)
        post_supply = total_supply + supplied
        roundtrip_payout = quote_withdraw(
            supplied,
            post_supply,
            post_band.flush_side(policy.withdraw_side),
            policy.withdraw_rounding,
        )
        roundtrip_executable = roundtrip_payout is not None
        if roundtrip_payout is not None:
            roundtrip_no_extraction = roundtrip_payout <= amount

    return {
        "policy": policy.name,
        "policy_terms": {
            "supply_side": policy.supply_side,
            "withdraw_side": policy.withdraw_side,
            "supply_rounding": policy.supply_rounding,
            "withdraw_rounding": policy.withdraw_rounding,
        },
        "flush_status": "accepted",
        "supply_mark": str(supply_mark),
        "withdraw_mark": str(withdraw_mark),
        "supplied_shares": None if supplied is None else str(supplied),
        "withdraw_payout": None if withdrawn is None else str(withdrawn),
        "roundtrip_payout": (
            None if roundtrip_payout is None else str(roundtrip_payout)
        ),
        "roundtrip_executable": roundtrip_executable,
        "supply_no_overmint": supply_no_overmint,
        "withdraw_no_overpay": withdraw_no_overpay,
        "roundtrip_no_extraction": roundtrip_no_extraction,
        "all_invariants_hold": (
            supply_no_overmint
            and withdraw_no_overpay
            and roundtrip_no_extraction
        ),
    }


def lp_mutation_matrix(
    band: NavBand,
    *,
    amount: int,
    total_supply: int,
) -> dict[str, Any]:
    withdraw_shares = max(1, total_supply // 1_000)
    results = [
        evaluate_lp_policy(
            band,
            amount=amount,
            total_supply=total_supply,
            withdraw_shares=withdraw_shares,
            policy=LpPolicy(*values),
        )
        for values in itertools.product(
            ("bid", "center", "ask"),
            ("bid", "center", "ask"),
            ("down", "up"),
            ("down", "up"),
        )
    ]
    passing = [result["policy"] for result in results if result["all_invariants_hold"]]
    single_mark_passing = [
        result["policy"]
        for result in results
        if result["all_invariants_hold"]
        and result["policy_terms"]["supply_side"]
        == result["policy_terms"]["withdraw_side"]
    ]
    return {
        "cases": results,
        "passing_policies": passing,
        "single_mark_passing_policies": single_mark_passing,
        "landed_policy_passes": LANDED_LP_POLICY.name in passing,
    }


def nav_spread_proof(band: NavBand) -> dict[str, Any]:
    """State the amount-independent endpoint constraints on an LP mark."""
    return {
        "supply_mark_must_be_at_least": str(band.ask),
        "withdraw_mark_must_be_at_most": str(band.bid),
        "universal_single_mark_exists": band.ask <= band.bid,
        "split_mark_satisfies_both": True,
        "reason": (
            "no-overmint requires mark >= true NAV, whose maximum is ask; "
            "no-overpay requires mark <= true NAV, whose minimum is bid"
        ),
    }


def _money_rounding_flips(
    algebra_bundle: dict[str, Any],
) -> list[dict[str, Any]]:
    flips = []
    for scenario in algebra_bundle["scenarios"]:
        nodes_by_id = {node["id"]: node for node in scenario["nodes"]}
        for node in scenario["nodes"]:
            if node["name"] not in {"net_premium", "trading_fee"}:
                continue
            reference = _local_reference(node, nodes_by_id)
            current = int(node["center"])
            counterfactual = reference.numerator // reference.denominator
            flips.append(
                {
                    "scenario": scenario["scenario"],
                    "site": node["name"],
                    "move_site": node["move_site"],
                    "exact_local_reference": _fraction_text(reference),
                    "current_rounding": node["rounding"],
                    "current": str(current),
                    "current_dust_owner": (
                        "none"
                        if Fraction(current) == reference
                        else "lp_pool"
                    ),
                    "counterfactual_rounding": "down",
                    "counterfactual": str(counterfactual),
                    "counterfactual_dust_owner": (
                        "none"
                        if Fraction(counterfactual) == reference
                        else "trader"
                    ),
                    "protocol_bias_delta": str(current - counterfactual),
                    "current_matches_r2": Fraction(current) >= reference,
                    "counterfactual_matches_r2": (
                        Fraction(counterfactual) >= reference
                    ),
                }
            )
    return flips


def analyze_knot_flips(algebra_bundle: dict[str, Any]) -> dict[str, Any]:
    pyth_spot = 80_123_456_789_012
    bs_forward = 75_799_394_374_445
    bs_spot = 75_852_009_440_344
    fused_forward = pyth_spot * bs_forward // bs_spot
    two_floor_forward = replay.deepbook_mul(
        pyth_spot,
        replay.deepbook_div(bs_forward, bs_spot),
    )

    old_quantity = 20_000_000
    old_floor = 5_989_561
    close_quantity = 10_000
    remaining_quantity = old_quantity - close_quantity
    remaining_floor = old_floor * remaining_quantity // old_quantity
    complementary_removed_floor = old_floor - remaining_floor
    independently_rounded_removed_floor = (
        old_floor * close_quantity // old_quantity
    )

    probability = 19_000_027
    quantity = 18_520_000
    leverage = 1_500_000_000
    entry_value = probability * quantity // F
    staged_premium = (entry_value * F + leverage - 1) // leverage
    fused_premium = (
        probability * quantity + leverage - 1
    ) // leverage

    money_flips = _money_rounding_flips(algebra_bundle)
    r2_conflicts = [
        flip
        for flip in money_flips
        if (
            flip["current_matches_r2"]
            and not flip["counterfactual_matches_r2"]
        )
    ]
    return {
        "money_rounding_flips": money_flips,
        "r2_conflict_count": len(r2_conflicts),
        "knots": [
            {
                "name": "live_forward_fusion",
                "current": "one fused mul-div floor",
                "mutation": "division floor followed by multiplication floor",
                "status": "keep_current_proven_simplification",
                "current_value": str(fused_forward),
                "mutation_value": str(two_floor_forward),
                "mutation_delta": str(two_floor_forward - fused_forward),
                "invariant": "one floor of the exact rational and target parity",
            },
            {
                "name": "partial_close_floor_split",
                "current": "floor survivor once; assign complement to closed slice",
                "mutation": "floor survivor and closed slice independently",
                "status": "keep_current_proven_simplification",
                "remaining_floor": str(remaining_floor),
                "current_removed_floor": str(complementary_removed_floor),
                "mutation_removed_floor": str(independently_rounded_removed_floor),
                "mutation_unassigned_floor": str(
                    old_floor
                    - remaining_floor
                    - independently_rounded_removed_floor
                ),
                "invariant": "stored floor atoms are conserved exactly",
            },
            {
                "name": "net_premium_stacked_rounding",
                "current": "floor entry value, then round premium upward",
                "mutation": "fuse probability*quantity/leverage",
                "status": "refuted_as_bit_preserving_simplification",
                "witness": {
                    "probability": str(probability),
                    "quantity": str(quantity),
                    "leverage": str(leverage),
                    "current": str(staged_premium),
                    "mutation": str(fused_premium),
                    "delta": str(fused_premium - staged_premium),
                },
                "invariant": (
                    "net premium and stored floor atoms must remain bit-identical "
                    "unless mint economics changes deliberately"
                ),
            },
            {
                "name": "live_redeem_saturating_sub",
                "current": "max(0, gross redeem - removed floor)",
                "mutation": "plain subtraction",
                "status": "reject_mutation_liveness",
                "witness": {
                    "gross_redeem": "0",
                    "removed_floor": "1",
                    "current": "0",
                    "mutation": "underflow abort",
                },
                "invariant": "one-unit partial-close dust must not abort redeem",
            },
            {
                "name": "range_product_reuse",
                "current": "round aggregate boundary and per-order correction separately",
                "mutation": "reuse one per-order range product in both structures",
                "status": "refuted_by_non_distributive_rounding",
                "witness": {
                    "sum_of_per_order_values": "873",
                    "aggregate_boundary_value": "872",
                    "delta": "-1",
                },
                "invariant": (
                    "tree aggregation and per-order liquidation correction retain "
                    "their own rounding domains"
                ),
            },
            {
                "name": "linear_minus_correction_clamp",
                "current": "saturating subtraction",
                "mutation": "directional boundary rounding plus plain subtraction",
                "status": "keep_semantic_clamp_p13_underflow_witness",
                "witness": {
                    "boundary_linear": "872",
                    "knocked_out_correction": "873",
                    "plain_sub": "underflow",
                    "saturating_sub": "0",
                },
                "invariant": (
                    "boundary aggregation can understate per-order correction by "
                    "one raw unit, so ordinary subtraction is not total"
                ),
            },
            {
                "name": "nav_shared_mark",
                "current": "ask for supply; bid for withdrawal",
                "mutation": "one center mark for supply and withdrawal",
                "status": "reject_shared_mark_competing_endpoint_invariants",
                "invariant": (
                    "supply never overmints at the high truth endpoint and "
                    "withdrawal never overpays at the low truth endpoint"
                ),
            },
            {
                "name": "nav_nonnegative_clamp",
                "current": "floor free_cash-liability at zero",
                "mutation": "plain subtraction",
                "status": "keep_semantic_clamp",
                "invariant": (
                    "a bid/ask representation carries numerical uncertainty but "
                    "does not make economically negative NAV representable in u64"
                ),
            },
        ],
    }


def zero_bid_queue_comparison() -> list[dict[str, Any]]:
    cases = []
    for center, error, total_supply in (
        (1, 1, 10),
        (10, 10, 100),
        (0, 0, 100),
        (0, 7, 100),
    ):
        band = NavBand(center, error)
        if band.flush_precision_eligible:
            flush_bid, flush_ask = band.flush_marks
            withdrawal = quote_withdraw(
                1,
                total_supply,
                flush_bid,
                "down",
            )
            action = "refund" if withdrawal is None else "fill"
        else:
            flush_bid, flush_ask = None, None
            withdrawal = None
            action = "valuation_rejected"
        cases.append(
            {
                "center": str(center),
                "error": str(error),
                "bid": str(band.bid),
                "ask": str(band.ask),
                "flush_precision_eligible": (
                    band.flush_precision_eligible
                ),
                "flush_bid": (
                    None if flush_bid is None else str(flush_bid)
                ),
                "flush_ask": (
                    None if flush_ask is None else str(flush_ask)
                ),
                "withdraw_quote": (
                    None if withdrawal is None else str(withdrawal)
                ),
                "current_non_executable_action": action,
                "alternative_non_executable_action": "carry",
                "semantics_diverge": (
                    band.flush_precision_eligible
                    and withdrawal is None
                ),
            }
        )
    return cases


def protocol_profit_split(profit: int, share: int) -> dict[str, Any]:
    exact_protocol = Fraction(profit * share, F)
    actual_protocol = exact_protocol.numerator // exact_protocol.denominator
    reserve_advantage = Fraction(actual_protocol) - exact_protocol
    ledger = DustLedger()
    if reserve_advantage < 0:
        ledger.transfer(
            asset="dusdc_1e6",
            amount=-reserve_advantage,
            sender="protocol_reserve",
            recipient="lp_pool",
            site="pool_accounting::materialize_expiry_profit",
        )
    elif reserve_advantage > 0:
        ledger.transfer(
            asset="dusdc_1e6",
            amount=reserve_advantage,
            sender="lp_pool",
            recipient="protocol_reserve",
            site="pool_accounting::materialize_expiry_profit",
        )
    return {
        "profit": str(profit),
        "share": str(share),
        "exact_protocol_cut": _fraction_text(exact_protocol),
        "actual_protocol_cut": str(actual_protocol),
        "reserve_advantage": _fraction_text(reserve_advantage),
        "ledger": ledger.payload(),
    }


def _node_center(scenario: dict[str, Any], name: str) -> int:
    matching = [node for node in scenario["nodes"] if node["name"] == name]
    if len(matching) != 1:
        raise ValueError(
            f"{scenario['scenario']} expected one {name} node, found {len(matching)}"
        )
    return int(matching[0]["center"])


def run_lifecycle_invariants(scenario: dict[str, Any]) -> dict[str, Any]:
    starting_user_cash = 1_000_000_000_000
    starting_pool_cash = 1_000_000_000_000
    nodes_by_id = {node["id"]: node for node in scenario["nodes"]}
    nodes_by_name = {node["name"]: node for node in scenario["nodes"]}
    net_premium = _node_center(scenario, "net_premium")
    trading_fee = _node_center(scenario, "trading_fee")
    mint_payment = net_premium + trading_fee
    quantity = _node_center(scenario, "stored_order_quantity")
    floor = _node_center(scenario, "stored_order_floor")
    close_redeem = _node_center(scenario, "redeem_amount")
    remaining_quantity = _node_center(scenario, "remaining_quantity")
    remaining_floor = _node_center(scenario, "remaining_floor_shares")
    removed_floor = _node_center(scenario, "remove_floor_shares")
    original_winner_liability = _node_center(
        scenario,
        "settlement_winner_payout",
    )

    initial = LifecycleState(
        trader_cash=starting_user_cash,
        pool_cash=starting_pool_cash,
        position=None,
    )
    minted_position = PositionState(quantity, floor, "active")
    after_mint = _cash_transition(
        initial,
        amount=mint_payment,
        sender="trader",
        recipient="lp_pool",
        position=minted_position,
    )
    mint_reconciliation = reconcile_transfer(
        before=initial.balance_sheet(),
        after=after_mint.balance_sheet(),
        asset="dusdc_1e6",
        sender="trader",
        recipient="lp_pool",
        exact_amount=(
            _local_reference(nodes_by_name["net_premium"], nodes_by_id)
            + _local_reference(nodes_by_name["trading_fee"], nodes_by_id)
        ),
        pool_party="lp_pool",
    )

    close_quantity = quantity - remaining_quantity
    removed_winner_liability = close_quantity - removed_floor
    remaining_winner_liability = (
        original_winner_liability - removed_winner_liability
    )
    remaining_position = PositionState(
        remaining_quantity,
        remaining_floor,
        "active",
    )
    after_close = _cash_transition(
        after_mint,
        amount=close_redeem,
        sender="lp_pool",
        recipient="trader",
        position=remaining_position,
    )
    close_reconciliation = reconcile_transfer(
        before=after_mint.balance_sheet(),
        after=after_close.balance_sheet(),
        asset="dusdc_1e6",
        sender="lp_pool",
        recipient="trader",
        exact_amount=_local_reference(
            nodes_by_name["redeem_amount"],
            nodes_by_id,
        ),
        pool_party="lp_pool",
    )

    winner_payout = remaining_quantity - remaining_floor
    settled_winner = LifecycleState(
        trader_cash=after_close.trader_cash,
        pool_cash=after_close.pool_cash,
        position=PositionState(
            remaining_quantity,
            remaining_floor,
            "settled_winner",
        ),
    )
    after_winner_redemption = _cash_transition(
        settled_winner,
        amount=winner_payout,
        sender="lp_pool",
        recipient="trader",
        position=None,
    )
    winner_reconciliation = reconcile_transfer(
        before=settled_winner.balance_sheet(),
        after=after_winner_redemption.balance_sheet(),
        asset="dusdc_1e6",
        sender="lp_pool",
        recipient="trader",
        exact_amount=Fraction(remaining_winner_liability),
        pool_party="lp_pool",
    )
    liability_after_settlement = remaining_winner_liability - winner_payout

    settled_loser = LifecycleState(
        trader_cash=after_close.trader_cash,
        pool_cash=after_close.pool_cash,
        position=PositionState(
            remaining_quantity,
            remaining_floor,
            "settled_loser",
        ),
    )
    after_loser_redemption = LifecycleState(
        trader_cash=settled_loser.trader_cash,
        pool_cash=settled_loser.pool_cash,
        position=None,
    )

    liquidated = LifecycleState(
        trader_cash=after_mint.trader_cash,
        pool_cash=after_mint.pool_cash,
        position=PositionState(quantity, floor, "liquidated"),
    )
    after_liquidated_redemption = LifecycleState(
        trader_cash=liquidated.trader_cash,
        pool_cash=liquidated.pool_cash,
        position=None,
    )

    pool_output = scenario["key_outputs"]["pool_value"]
    band = NavBand(
        int(pool_output["center"]),
        int(pool_output["certificate_error"]),
    )
    supply_amount = 5_000_000
    total_supply = replay.INITIAL_TOTAL_PLP_SUPPLY
    supplied = quote_supply(
        supply_amount,
        total_supply,
        band.ask,
        "down",
    )
    if supplied is None:
        raise ValueError("representative supply unexpectedly non-executable")
    post_band = band.shifted_by_exact_cash(supply_amount)
    withdrawn = quote_withdraw(
        supplied,
        total_supply + supplied,
        post_band.bid,
        "down",
    )
    if withdrawn is None:
        raise ValueError("representative withdrawal unexpectedly non-executable")

    invariants = {
        "cash_conserved_after_mint": (
            after_mint.trader_cash + after_mint.pool_cash
            == starting_user_cash + starting_pool_cash
        ),
        "cash_conserved_after_close_and_settlement": (
            after_winner_redemption.trader_cash
            + after_winner_redemption.pool_cash
            == starting_user_cash + starting_pool_cash
        ),
        "user_cash_nonnegative": all(
            state.trader_cash >= 0
            for state in (
                initial,
                after_mint,
                after_close,
                settled_winner,
                after_winner_redemption,
                settled_loser,
                after_loser_redemption,
                liquidated,
                after_liquidated_redemption,
            )
        ),
        "pool_cash_nonnegative": all(
            state.pool_cash >= 0
            for state in (
                initial,
                after_mint,
                after_close,
                settled_winner,
                after_winner_redemption,
                settled_loser,
                after_loser_redemption,
                liquidated,
                after_liquidated_redemption,
            )
        ),
        "all_order_states_valid": all(
            state.valid
            for state in (
                after_mint,
                after_close,
                settled_winner,
                after_winner_redemption,
                settled_loser,
                after_loser_redemption,
                liquidated,
                after_liquidated_redemption,
            )
        ),
        "floor_conserved_across_partial_close": (
            floor == remaining_floor + removed_floor
        ),
        "remaining_floor_not_above_quantity": remaining_floor <= remaining_quantity,
        "original_winner_liability_matches_stored_order": (
            original_winner_liability == quantity - floor
        ),
        "winner_liability_conserved_across_partial_close": (
            original_winner_liability
            == removed_winner_liability + remaining_winner_liability
            and remaining_winner_liability
            == remaining_quantity - remaining_floor
        ),
        "settlement_clears_remaining_winner_liability": (
            liability_after_settlement == 0
        ),
        "loser_redemption_clears_order_without_cash": (
            after_loser_redemption.position is None
            and after_loser_redemption.trader_cash
            == settled_loser.trader_cash
            and after_loser_redemption.pool_cash == settled_loser.pool_cash
        ),
        "liquidated_redemption_clears_order_without_cash": (
            liquidated.position is not None
            and liquidated.position.winner_liability == 0
            and after_liquidated_redemption.position is None
            and after_liquidated_redemption.trader_cash
            == liquidated.trader_cash
            and after_liquidated_redemption.pool_cash
            == liquidated.pool_cash
        ),
        "observed_cash_transitions_reconcile": all(
            reconciliation["valid"]
            for reconciliation in (
                mint_reconciliation,
                close_reconciliation,
                winner_reconciliation,
            )
        ),
        "lp_roundtrip_does_not_extract": withdrawn <= supply_amount,
    }
    return {
        "scenario": scenario["scenario"],
        "mint_payment": str(mint_payment),
        "partial_close_redeem": str(close_redeem),
        "remaining_winner_payout": str(winner_payout),
        "supply_shares_at_ask": str(supplied),
        "withdraw_payout_at_post_supply_bid": str(withdrawn),
        "lp_roundtrip_cost": str(supply_amount - withdrawn),
        "cash_transition_reconciliations": {
            "mint": mint_reconciliation,
            "partial_close": close_reconciliation,
            "winner_redemption": winner_reconciliation,
        },
        "cash_states": {
            "start": {
                "user": str(starting_user_cash),
                "pool": str(starting_pool_cash),
            },
            "after_mint": {
                "user": str(after_mint.trader_cash),
                "pool": str(after_mint.pool_cash),
            },
            "after_partial_close": {
                "user": str(after_close.trader_cash),
                "pool": str(after_close.pool_cash),
            },
            "after_winner_settlement": {
                "user": str(after_winner_redemption.trader_cash),
                "pool": str(after_winner_redemption.pool_cash),
            },
        },
        "winner_liability_states": {
            "before_close": str(original_winner_liability),
            "removed": str(removed_winner_liability),
            "remaining": str(remaining_winner_liability),
            "after_settlement": str(liability_after_settlement),
        },
        "invariants": invariants,
        "all_invariants_hold": all(invariants.values()),
    }


def run_boundary_suite() -> dict[str, Any]:
    checked = 0
    non_executable = 0
    failures: list[dict[str, str]] = []
    for center in (2, 10, 101, 1_000_000, 500_000_000_000):
        errors = sorted({0, 1, center // 100, center // 2, center - 1})
        total_supply = center
        for error in errors:
            band = NavBand(center, error)
            for amount in (1, 2, max(1, center - 1), center, center + 1):
                checked += 1
                result = evaluate_lp_policy(
                    band,
                    amount=amount,
                    total_supply=total_supply,
                    withdraw_shares=max(1, total_supply // 3),
                    policy=LANDED_LP_POLICY,
                )
                if result["flush_status"] == "valuation_rejected":
                    non_executable += 1
                    continue
                if result["supplied_shares"] is None or result["withdraw_payout"] is None:
                    non_executable += 1
                    continue
                if not result["all_invariants_hold"]:
                    failures.append(
                        {
                            "center": str(center),
                            "error": str(error),
                            "amount": str(amount),
                            "policy": result["policy"],
                        }
                    )
    return {
        "checked": checked,
        "non_executable": non_executable,
        "failures": failures,
        "all_executable_cases_hold": not failures,
    }


def compare_pricing_profiles(
    algebra_bundle: dict[str, Any],
    availability_evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    rows = []
    for scenario in algebra_bundle["scenarios"]:
        name = scenario["scenario"]
        current = scenario["key_outputs"]
        previous = PRIOR_1E9_PROFILE[name]
        changes = {}
        for field, (old_center, old_error) in previous.items():
            new_center = int(current[field]["center"])
            new_error = int(current[field]["certificate_error"])
            changes[field] = {
                "prior_center": str(old_center),
                "accepted_center": str(new_center),
                "center_delta": str(new_center - old_center),
                "prior_error": str(old_error),
                "accepted_error": str(new_error),
                "error_delta": str(new_error - old_error),
            }
        rows.append({"scenario": name, "changes": changes})
    return {
        "from": "sha_94758ffd_compositional_1e9",
        "to": PRICING_PROFILE,
        "external_availability_evidence": availability_evidence,
        "scenarios": rows,
        "representative_pool_value_centers_unchanged": all(
            row["changes"]["pool_value"]["center_delta"] == "0"
            for row in rows
        ),
        "representative_lp_quote_centers_unchanged": all(
            row["changes"]["supply_shares"]["center_delta"] == "0"
            and row["changes"]["withdraw_dusdc"]["center_delta"] == "0"
            for row in rows
        ),
    }


def build_dust_invariant_bundle(
    algebra_bundle: dict[str, Any] | None = None,
    availability_evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    algebra_bundle = algebra_bundle or algebra_trace.build_trace_bundle()
    collapse = analyze_collapse_sites(algebra_bundle)
    premium_lifecycle = analyze_net_premium_lifecycle(algebra_bundle)
    scenarios = []
    for scenario in algebra_bundle["scenarios"]:
        pool_output = scenario["key_outputs"]["pool_value"]
        band = NavBand(
            int(pool_output["center"]),
            int(pool_output["certificate_error"]),
        )
        matrix = lp_mutation_matrix(
            band,
            amount=5_000_000,
            total_supply=replay.INITIAL_TOTAL_PLP_SUPPLY,
        )
        prior_center_policy = evaluate_lp_policy(
            band,
            amount=5_000_000,
            total_supply=replay.INITIAL_TOTAL_PLP_SUPPLY,
            withdraw_shares=max(1, replay.INITIAL_TOTAL_PLP_SUPPLY // 1_000),
            policy=PRIOR_CENTER_LP_POLICY,
        )
        landed_policy = evaluate_lp_policy(
            band,
            amount=5_000_000,
            total_supply=replay.INITIAL_TOTAL_PLP_SUPPLY,
            withdraw_shares=max(1, replay.INITIAL_TOTAL_PLP_SUPPLY // 1_000),
            policy=LANDED_LP_POLICY,
        )
        scenarios.append(
            {
                "scenario": scenario["scenario"],
                "nav_band": {
                    "center": str(band.center),
                    "error": str(band.error),
                    "bid": str(band.bid),
                    "ask": str(band.ask),
                    "width": str(band.ask - band.bid),
                    "target_precision_gate_passes": (
                        band.center == 0
                        or band.true_relative_deviation_within(10_000_000)
                    ),
                },
                "prior_center_policy": prior_center_policy,
                "landed_policy": landed_policy,
                "mutation_matrix": matrix,
                "endpoint_proof": nav_spread_proof(band),
                "lifecycle": run_lifecycle_invariants(scenario),
            }
        )

    boundary = run_boundary_suite()
    zero_bid = zero_bid_queue_comparison()
    reserve_split = protocol_profit_split(123_456_789, 200_000_000)
    knot_flips = analyze_knot_flips(algebra_bundle)
    profile_comparison = compare_pricing_profiles(
        algebra_bundle,
        availability_evidence,
    )
    source_inventory = money_math_inventory.build_inventory()
    contract_dust_proofs = math_dust_proofs.build_proof_bundle()
    minimality = algebra_minimality.build_minimality_bundle()
    fee_lifecycles = economic_lifecycle_proofs.build_lifecycle_bundle()
    payout_tree = payout_tree_proofs.build_payout_tree_bundle()
    saturation = saturation_proofs.build_saturation_bundle()
    partial_close = partial_close_proofs.build_partial_close_bundle()
    return {
        "schema": SCHEMA_VERSION,
        "contract_baseline": CONTRACT_BASELINE,
        "pricing_profile": PRICING_PROFILE,
        "flow_coverage": FLOW_COVERAGE,
        "algebra_schema": algebra_bundle["schema"],
        "collapse_sites": collapse,
        "net_premium_lifecycle_dust": premium_lifecycle,
        "scenarios": scenarios,
        "boundary_suite": boundary,
        "knot_flips": knot_flips,
        "pricing_profile_comparison": profile_comparison,
        "zero_bid_queue_comparison": zero_bid,
        "protocol_profit_split": reserve_split,
        "source_math_inventory": source_inventory,
        "contract_dust_proofs": contract_dust_proofs,
        "algebra_minimality": minimality,
        "fee_lifecycle_proofs": fee_lifecycles,
        "payout_tree_proofs": payout_tree,
        "saturation_proofs": saturation,
        "partial_close_proofs": partial_close,
        "aggregate": {
            "source_math_inventory_complete": source_inventory[
                "complete_for_candidate_pattern"
            ],
            "inventoried_money_collapses_have_dust_certificates": (
                contract_dust_proofs[
                    "complete_for_inventoried_money_collapse_functions"
                ]
            ),
            "all_contract_dust_relations_hold": contract_dust_proofs[
                "all_relations_hold"
            ],
            "all_money_functions_have_minimality_disposition": minimality[
                "all_money_functions_classified"
            ],
            "registered_equivalent_operation_saving_candidates_remaining": bool(
                minimality["equivalent_operation_saving_candidates"]
            ),
            "universal_maximal_simplicity_proven": minimality[
                "universal_maximal_simplicity_proven"
            ],
            "collapse_registry_complete": collapse["complete"],
            "dust_double_entry_conserved": collapse["ledger"][
                "all_assets_conserved"
            ],
            "observed_cash_transitions_reconcile": all(
                scenario["lifecycle"]["invariants"][
                    "observed_cash_transitions_reconcile"
                ]
                for scenario in scenarios
            ),
            "lifecycle_invariants_hold": all(
                scenario["lifecycle"]["all_invariants_hold"]
                for scenario in scenarios
            )
            and fee_lifecycles["all_invariants_hold"]
            and payout_tree["all_invariants_hold"],
            "landed_policy_holds": all(
                scenario["landed_policy"]["all_invariants_hold"]
                for scenario in scenarios
            ),
            "single_mark_resolves_competing_invariants": all(
                scenario["endpoint_proof"]["universal_single_mark_exists"]
                for scenario in scenarios
            ),
            "r2_doctrine_holds_at_all_observed_sites": not collapse[
                "doctrine_mismatches"
            ],
            "boundary_suite_holds": boundary["all_executable_cases_hold"],
            "accepted_non_executable_flush_marks_refund": all(
                case["current_non_executable_action"] == "refund"
                for case in zero_bid
                if case["flush_precision_eligible"]
            ),
            "full_contract_money_surface_complete": not FLOW_COVERAGE[
                "not_yet_modeled"
            ],
            "all_saturating_sites_classified": saturation[
                "all_sites_classified"
            ],
            "proved_redundant_saturations": saturation[
                "proved_immediate_reductions"
            ],
            "proved_landed_saturation_reductions": saturation[
                "proved_landed_reductions"
            ],
            "partial_close_sequence_surface_classified": partial_close[
                "all_sequence_sites_classified"
            ],
            "partial_close_net_proceeds_are_path_independent": partial_close[
                "end_to_end_net_proceeds_path_independent"
            ],
            "unresolved_trader_favored_partial_close_atoms": partial_close[
                "maximum_known_split_close_advantage"
            ],
            # RED while any reachable trader-favored split remains (DBU-640).
            "end_to_end_dust_bias_holds": (
                not collapse["doctrine_mismatches"]
                and partial_close["end_to_end_net_proceeds_path_independent"]
            ),
        },
    }


def render_report(bundle: dict[str, Any]) -> str:
    aggregate = bundle["aggregate"]
    lines = [
        "# Predict dust-invariant analysis",
        "",
        f"Contract baseline: `{bundle['contract_baseline']}`",
        f"Pricing profile: `{bundle['pricing_profile']}`",
        "",
        "## Verdict",
        "",
        f"- Traced collapse registry complete: **{'PASS' if aggregate['collapse_registry_complete'] else 'FAIL'}**.",
        f"- Source fixed-point/clamp/custody inventory classified: **{'PASS' if aggregate['source_math_inventory_complete'] else 'FAIL'}**.",
        f"- Every inventoried money-collapse function has an exact-rational dust certificate: **{'PASS' if aggregate['inventoried_money_collapses_have_dust_certificates'] else 'FAIL'}**.",
        f"- Every certified rounding relation holds: **{'PASS' if aggregate['all_contract_dust_relations_hold'] else 'FAIL'}**.",
        f"- Every money-collapse and money-valuation function has a minimality disposition: **{'PASS' if aggregate['all_money_functions_have_minimality_disposition'] else 'FAIL'}**.",
        f"- Registered equivalent operation-saving rewrites left unapplied: **{'YES' if aggregate['registered_equivalent_operation_saving_candidates_remaining'] else 'NO'}**.",
        f"- Universal maximal simplicity proven: **{'YES' if aggregate['universal_maximal_simplicity_proven'] else 'NO'}**.",
        f"- Algebraic residual assignments balance by asset: **{'PASS' if aggregate['dust_double_entry_conserved'] else 'FAIL'}**.",
        f"- Observed cash transitions reconcile from account snapshots: **{'PASS' if aggregate['observed_cash_transitions_reconcile'] else 'FAIL'}**.",
        f"- Representative stateful lifecycle invariants: **{'PASS' if aggregate['lifecycle_invariants_hold'] else 'FAIL'}**.",
        f"- Landed supply-at-ask / withdraw-at-bid: **{'PASS' if aggregate['landed_policy_holds'] else 'FAIL'}**.",
        f"- One shared mark resolves both endpoint invariants: **{'YES' if aggregate['single_mark_resolves_competing_invariants'] else 'NO'}**.",
        f"- Adversarial executable boundaries: **{'PASS' if aggregate['boundary_suite_holds'] else 'FAIL'}**.",
        f"- Existing observed money sites all follow R2: **{'YES' if aggregate['r2_doctrine_holds_at_all_observed_sites'] else 'NO'}**.",
        f"- Declared contract money surface modeled: **{'YES' if aggregate['full_contract_money_surface_complete'] else 'NO'}**.",
        f"- Every saturating arithmetic site classified: **{'PASS' if aggregate['all_saturating_sites_classified'] else 'FAIL'}**.",
        f"- Repeated partial-close surface classified: **{'PASS' if aggregate['partial_close_sequence_surface_classified'] else 'FAIL'}**.",
        f"- Partial-close net proceeds are path independent: **{'YES' if aggregate['partial_close_net_proceeds_are_path_independent'] else 'NO'}**.",
        f"- End-to-end protocol dust bias holds: **{'YES' if aggregate['end_to_end_dust_bias_holds'] else 'NO'}**.",
        "",
        "## Contract-wide dust surface",
        "",
        f"The source scanner classified `{len(bundle['source_math_inventory']['records'])}` fixed-point, raw-integer, clamp, `Approx`, guard, and custody candidates. `{len(bundle['contract_dust_proofs']['money_collapse_functions'])}` money-collapse functions have `{len(bundle['contract_dust_proofs']['certificates'])}` exact-rational certificates, with `{bundle['contract_dust_proofs']['nonzero_dust_witness_count']}` concrete nonzero residuals.",
        "The mechanically observed local protocol-bias exceptions are:",
    ]
    protocol_bias_mismatches = bundle["contract_dust_proofs"][
        "protocol_bias_mismatches"
    ]
    if not protocol_bias_mismatches:
        lines.append("- None.")
    for mismatch in protocol_bias_mismatches:
        lines.append(
            f"- `{mismatch['name']}` at `{mismatch['function_id']}` leaves "
            f"`{mismatch['residual']}` {mismatch['unit']} with `{mismatch['owner']}`."
        )
    lines.extend(
        [
        "",
        "## Accepted 1e18 sqrt seam",
        "",
        (
            "The accepted profile retains only total variance at 1e18 through "
            "`sqrt(w)`, then rejoins the 1e9 `Approx` path. External corpus "
            "availability is not embedded in the public proof bundle."
            if bundle["pricing_profile_comparison"][
                "external_availability_evidence"
            ]
            is None
            else (
                "The accepted profile retains only total variance at 1e18 "
                "through `sqrt(w)`, then rejoins the 1e9 `Approx` path. "
                "The separately supplied availability evidence is attached "
                "to the JSON bundle with its corpus and runner digests."
            )
        ),
        f"Across these representative flows, pool-value centers are unchanged from the pre-island/pre-premium baseline: **{'YES' if bundle['pricing_profile_comparison']['representative_pool_value_centers_unchanged'] else 'NO'}**; LP supply/withdraw quote centers are unchanged: **{'YES' if bundle['pricing_profile_comparison']['representative_lp_quote_centers_unchanged'] else 'NO'}**. The retained-sqrt seam changes pricing centers and certificate widths; canonical premium rounding can shift stored floor and NAV atoms by one; the NAV bid/ask boundary can additionally reduce an LP quote.",
        "",
        "## NAV spread",
        "",
        ]
    )
    for scenario in bundle["scenarios"]:
        band = scenario["nav_band"]
        prior_center_policy = scenario["prior_center_policy"]
        landed_policy = scenario["landed_policy"]
        passing = scenario["mutation_matrix"]["passing_policies"]
        lines.append(
            f"- **{scenario['scenario']}** — `{band['bid']} .. {band['ask']}` "
            f"(center `{band['center']}`, error `{band['error']}`); "
            f"prior center-mark round-trip `{prior_center_policy['roundtrip_payout']}`, "
            f"landed spread round-trip `{landed_policy['roundtrip_payout']}`; "
            f"{len(passing)} of 36 sampled collapse policies satisfy all three endpoint invariants."
        )
    lines.extend(
        [
            "",
            "For nonzero width, no single bid/center/ask mark satisfies both no-overmint and no-overpay. The split mark is structural, not a fee heuristic.",
            "A particular integer amount can accidentally make a single mark look safe because both quotes floor to the same raw unit. The amount-independent endpoint proof still requires supply mark >= ask and withdrawal mark <= bid.",
            "",
            "## Dust ownership",
            "",
        ]
    )
    mismatches = bundle["collapse_sites"]["doctrine_mismatches"]
    if not mismatches:
        lines.append("- Every observed local rounding transfer follows the registered owner.")
    else:
        for mismatch in mismatches:
            lines.append(
                f"- **{mismatch['scenario']} / {mismatch['name']}** — "
                f"pool advantage `{mismatch['pool_advantage']}` {mismatch['asset']}; "
                f"actual owner `{mismatch['actual_owner']}`, doctrine owner `{mismatch['doctrine_owner']}` "
                f"at `{mismatch['move_site']}`."
            )
    reserve = bundle["protocol_profit_split"]
    lines.extend(
        [
            "",
            f"The protocol-profit split floors `{reserve['exact_protocol_cut']}` to `{reserve['actual_protocol_cut']}`: the residual stays with LPs, while the protocol-reserve bucket is tracked separately.",
            "",
            "The previously identified inflow conflicts are resolved: `trading_fee`, `net_premium`, and `ewma_penalty` round upward. Premium dust is paired with an equal lower stored floor, so mint → winner settlement and full live close at the entry mark net to zero; only a losing terminal path retains the fractional advantage for protocol custody.",
            "",
            "## Algebra knots",
            "",
        ]
    )
    for knot in bundle["knot_flips"]["knots"]:
        lines.append(
            f"- **{knot['name']}** — `{knot['status']}`; {knot['invariant']}."
        )
    lines.extend(
        [
            "",
            "Two simplifications are already validated: fused live-forward reanchoring removes a second floor, and the complementary partial-close split removes an independently rounded floor atom. Fusing net-premium stages and reusing per-order range products are not bit-preserving. P-13 supplies a concrete `linear=872`, knocked-out-correction `=873` witness, so the inner liability clamp cannot become plain subtraction; the outer zero floor at `free_cash - liability` is independently an economic policy boundary.",
            f"The minimality search is exhaustive over `{len(bundle['algebra_minimality']['rewrite_search_scope'])}` registered rewrite families and fail-closed over inventoried money functions. It does not prove universal maximal simplicity across every possible semantics-preserving program.",
            f"The saturation sweep proves `{len(bundle['saturation_proofs']['proved_immediate_reductions'])}` further immediate redundant saturation(s), retains evidence for `{len(bundle['saturation_proofs']['proved_landed_reductions'])}` landed reduction(s), and leaves `{len(bundle['saturation_proofs']['conditional_reductions'])}` conditional on owning a stronger state or API invariant.",
            "",
            "## Stateful flows",
            "",
        ]
    )
    for scenario in bundle["scenarios"]:
        lifecycle = scenario["lifecycle"]
        lines.append(
            f"- **{scenario['scenario']}** — mint → partial close → winner settlement conserves cash and floor atoms; "
            f"LP supply → next-mark withdrawal costs `{lifecycle['lp_roundtrip_cost']}` raw DUSDC."
        )
    boundary = bundle["boundary_suite"]
    lines.extend(
        [
            "",
            "## Boundary and liveness results",
            "",
            f"- Checked `{boundary['checked']}` deterministic NAV/amount boundary cases; "
            f"`{boundary['non_executable']}` were classified non-executable and `{len(boundary['failures'])}` executable cases violated an invariant.",
            "- A zero-center accepted mark collapses both sides to zero and refunds non-executable queue heads. A nonzero center whose error reaches the center is rejected by the NAV precision gate before queue pricing; it is not a refund path. Carry-for-repricing remains a materially different alternative.",
            "",
        "## Interpretation",
        "",
        "This instrument separates three facts: Move compatibility, numerical containment, and economic side choice. A simplification or rounding flip is admissible only if all three continue to pass, stored accounting atoms remain identical unless the policy change explicitly owns them, and no dust-triggered abort is introduced.",
        (
            "The source census scans fixed-point, raw integer, clamp, `Approx`, "
            "and custody operations across every Predict Move source. Every "
            "classified money collapse and valuation function has a minimality "
            "disposition, and every listed lifecycle surface has an executable "
            "state reconciliation. This proves the declared source pattern; "
            "a future arithmetic form outside that pattern must extend the "
            "scanner before contract-wide remains true."
        ),
            "",
        ]
    )
    return "\n".join(lines)


def write_bundle(
    bundle: dict[str, Any],
    output_dir: Path,
) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "dust_invariants.json"
    report_path = output_dir / "dust_invariants.md"
    json_path.write_text(json.dumps(bundle, indent=2, sort_keys=True) + "\n")
    report_path.write_text(render_report(bundle))
    return json_path, report_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).with_name("runs") / "algebra-trace",
        help="Ignored output directory.",
    )
    parser.add_argument(
        "--availability-evidence",
        type=Path,
        help=(
            "Optional external aggregate JSON. Generated runs are ignored; "
            "do not commit private corpora."
        ),
    )
    args = parser.parse_args()
    availability_evidence = (
        None
        if args.availability_evidence is None
        else json.loads(args.availability_evidence.read_text())
    )
    bundle = build_dust_invariant_bundle(
        availability_evidence=availability_evidence,
    )
    json_path, report_path = write_bundle(bundle, args.output_dir)
    print(f"wrote {json_path}")
    print(f"wrote {report_path}")
    required = (
        "collapse_registry_complete",
        "dust_double_entry_conserved",
        "lifecycle_invariants_hold",
        "landed_policy_holds",
        "boundary_suite_holds",
    )
    failed = [name for name in required if not bundle["aggregate"][name]]
    if failed:
        raise SystemExit(f"dust invariant analysis failed: {', '.join(failed)}")


if __name__ == "__main__":
    main()
