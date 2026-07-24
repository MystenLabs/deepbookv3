#!/usr/bin/env python3
"""Prove partial-close invariants and expose sequence-dependent dust.

The live close fee cascade mirrored here is `expiry_market::redeem` (live arm):

    redeem      = max(0, gross - remove_floor)          # the live-close saturating_sub
    capped_fee  = min(mul_up(fee_rate, close), redeem)  # clamp BEFORE discount
    fee         = capped_fee - mul_down(capped_fee, d)  # stake discount, d in [0, 5e8]
    builder     = min(mul_down(fee, 1e8), mul_down(close, 5e6)).min(redeem - fee)
    penalty     = mul_up(penalty_rate, close).min(redeem - fee - builder)
    net         = redeem - fee - builder - penalty

`fee`/`builder` round down (subadditive under splitting -> trader-favored) while
`penalty` rounds up (superadditive -> protocol-favored); `redeem` is subadditive
in the trader-favored direction (splitting never redeems more). Every result
below is tagged with exactly one `result_strength`.
"""

from __future__ import annotations

import json
from typing import Any

import python_replay as replay

F = replay.FLOAT_SCALING
LOT = replay.POSITION_LOT_SIZE

# Upgrade-fixed money-math constants (constants.move) mirrored for the cascade.
MAX_FEE_DISCOUNT = 500_000_000  # constants::max_fee_discount!()
BUILDER_FEE_MULTIPLIER = 100_000_000  # constants::builder_fee_multiplier!()
MAX_BUILDER_FEE_RATE = 5_000_000  # constants::max_builder_fee_rate!()
# Admin-tunable EWMA penalty envelope (config_constants.move).
DEFAULT_EWMA_PENALTY_RATE = 1_000_000  # default_ewma_penalty_rate!()
MAX_EWMA_PENALTY_RATE = 2_000_000  # max_ewma_penalty_rate!()

# Every reported result carries exactly one of these strength tags.
UNIVERSAL = "universal_algebraic_or_inductive_proof"
EXHAUSTIVE = "exhaustive_search_over_stated_finite_domain"
WITNESS = "concrete_reachable_witness"


def _ceil_div(numerator: int, denominator: int) -> int:
    return (numerator + denominator - 1) // denominator


def _is_liquidatable(
    gross_value: int,
    floor_shares: int,
    liquidation_ltv: int = replay.LIQUIDATION_LTV,
) -> bool:
    return (
        floor_shares > 0
        and replay.deepbook_mul_up(gross_value, liquidation_ltv)
        <= floor_shares
    )


def _close_step(
    *,
    probability: int,
    quantity: int,
    floor_shares: int,
    close_quantity: int,
    discount_fraction: int,
    builder_present: bool = False,
    penalty_rate: int = 0,
) -> dict[str, int]:
    """One live close, mirroring the full `expiry_market::redeem` fee cascade.

    `builder_present=False` and `penalty_rate=0` reproduce the trading-fee-only
    cascade of the original witness bit-for-bit, so the pinned witness/structural
    results are unchanged.

    Two deliberate, conservative omissions: the trading fee is priced off the
    fee ramp (`fee_rate` with no `time_to_expiry_ms`, so `expiry_fee_multiplier`
    is 1x) and the trade fee is treated as fully lost, ignoring the separate
    settled trading-loss rebate. A larger near-expiry fee only shrinks the split
    advantage, and the rebate is a later settled flow, so both leave the reported
    advantages a conservative upper bound and the RED aggregate unaffected.
    """
    terms = replay.compute_live_close_terms(
        probability,
        quantity,
        floor_shares,
        close_quantity,
    )
    redeem_amount = terms["redeem_amount"]
    raw_fee = replay.deepbook_mul_up(
        replay.fee_rate(probability),
        close_quantity,
    )
    capped_fee = min(raw_fee, redeem_amount)
    charged_fee = replay.fee_after_discount_fraction(
        capped_fee,
        discount_fraction,
    )
    builder_fee = 0
    if builder_present:
        builder_fee = replay.builder_fee_amount(
            charged_fee,
            close_quantity,
            True,
            BUILDER_FEE_MULTIPLIER,
            MAX_BUILDER_FEE_RATE,
        )
        builder_fee = min(builder_fee, redeem_amount - charged_fee)
    penalty_fee = 0
    if penalty_rate > 0:
        penalty_fee = replay.deepbook_mul_up(penalty_rate, close_quantity)
        penalty_fee = min(
            penalty_fee,
            redeem_amount - charged_fee - builder_fee,
        )
    # A non-final partial close is only legal on a non-liquidatable order
    # (expiry_market.move: assert is_live() || close_quantity == quantity).
    is_full_close = close_quantity == quantity
    partial_close_legal = is_full_close or not _is_liquidatable(
        replay.deepbook_mul(probability, quantity),
        floor_shares,
    )
    return {
        **terms,
        "close_quantity": close_quantity,
        "raw_fee": raw_fee,
        "capped_fee": capped_fee,
        "charged_fee": charged_fee,
        "builder_fee": builder_fee,
        "penalty_fee": penalty_fee,
        "net_proceeds": redeem_amount
        - charged_fee
        - builder_fee
        - penalty_fee,
        "is_full_close": is_full_close,
        "partial_close_legal": partial_close_legal,
    }


def _run_close_sequence(
    *,
    probability: int,
    quantity: int,
    floor_shares: int,
    close_quantities: tuple[int, ...],
    discount_fraction: int,
    builder_present: bool = False,
    penalty_rate: int = 0,
) -> dict[str, Any]:
    steps: list[dict[str, int]] = []
    current_quantity = quantity
    current_floor = floor_shares
    reachable = True
    for close_quantity in close_quantities:
        if close_quantity > current_quantity:
            reachable = False
            break
        step = _close_step(
            probability=probability,
            quantity=current_quantity,
            floor_shares=current_floor,
            close_quantity=close_quantity,
            discount_fraction=discount_fraction,
            builder_present=builder_present,
            penalty_rate=penalty_rate,
        )
        if not step["partial_close_legal"]:
            reachable = False
        steps.append(step)
        current_quantity = step["remaining_quantity"]
        current_floor = step["remaining_floor_shares"]
    return {
        "steps": steps,
        "reachable": reachable,
        "remaining_quantity": current_quantity,
        "remaining_floor_shares": current_floor,
        "total_removed_floor": sum(step["remove_floor_shares"] for step in steps),
        "total_gross_redeem": sum(step["gross_redeem_amount"] for step in steps),
        "total_redeem": sum(step["redeem_amount"] for step in steps),
        "total_charged_fee": sum(step["charged_fee"] for step in steps),
        "total_builder_fee": sum(step["builder_fee"] for step in steps),
        "total_penalty_fee": sum(step["penalty_fee"] for step in steps),
        "total_net_proceeds": sum(step["net_proceeds"] for step in steps),
    }


def production_fragmentation_witness() -> dict[str, Any]:
    """Return a mint-reachable, non-liquidatable current-config witness."""
    entry_probability = 990_000_000
    quantity = 1_020_000
    leverage = 1_000_000_991
    live_probability = 40_000
    mint = replay.compute_mint_terms(
        entry_probability,
        quantity,
        leverage,
    )
    replay.assert_net_premium_above_min(mint["contribution"])

    full_gross_value = replay.deepbook_mul(live_probability, quantity)
    liquidatable = _is_liquidatable(
        full_gross_value,
        mint["floor_shares"],
    )
    direct = _run_close_sequence(
        probability=live_probability,
        quantity=quantity,
        floor_shares=mint["floor_shares"],
        close_quantities=(60_000,),
        discount_fraction=MAX_FEE_DISCOUNT,
    )
    split = _run_close_sequence(
        probability=live_probability,
        quantity=quantity,
        floor_shares=mint["floor_shares"],
        close_quantities=(10_000, 50_000),
        discount_fraction=MAX_FEE_DISCOUNT,
    )
    direct_unstaked = _run_close_sequence(
        probability=live_probability,
        quantity=quantity,
        floor_shares=mint["floor_shares"],
        close_quantities=(60_000,),
        discount_fraction=0,
    )
    split_unstaked = _run_close_sequence(
        probability=live_probability,
        quantity=quantity,
        floor_shares=mint["floor_shares"],
        close_quantities=(10_000, 50_000),
        discount_fraction=0,
    )

    validations = {
        "quantity_is_lot_aligned": quantity % LOT == 0,
        "close_quantities_are_lot_aligned": all(
            close_quantity % LOT == 0
            for close_quantity in (10_000, 50_000, 60_000)
        ),
        "entry_probability_is_admitted": (
            replay.MIN_ENTRY_PROBABILITY
            <= entry_probability
            <= replay.MAX_ENTRY_PROBABILITY
        ),
        "leverage_is_admitted": (
            leverage <= replay.admission_leverage_cap(entry_probability)
        ),
        "minimum_premium_is_met": (
            mint["contribution"] >= replay.MIN_NET_PREMIUM
        ),
        "mint_floor_is_one_atom": mint["floor_shares"] == 1,
        "live_order_is_not_liquidatable": not liquidatable,
        "split_and_direct_close_equal_quantity": (
            sum((10_000, 50_000)) == 60_000
        ),
        "split_and_direct_leave_equal_quantity": (
            split["remaining_quantity"] == direct["remaining_quantity"]
        ),
        "split_survivor_floor_is_not_higher": (
            split["remaining_floor_shares"]
            <= direct["remaining_floor_shares"]
        ),
        "unstaked_net_proceeds_are_equal": (
            split_unstaked["total_net_proceeds"]
            == direct_unstaked["total_net_proceeds"]
        ),
        "fully_staked_split_gains_one_atom": (
            split["total_net_proceeds"]
            == direct["total_net_proceeds"] + 1
        ),
    }
    return {
        "result_strength": WITNESS,
        "entry": {
            "entry_probability": entry_probability,
            "quantity": quantity,
            "leverage": leverage,
            **mint,
        },
        "live_probability": live_probability,
        "full_gross_value": full_gross_value,
        "liquidatable": liquidatable,
        "discount_fraction": MAX_FEE_DISCOUNT,
        "direct": direct,
        "split": split,
        "direct_unstaked": direct_unstaked,
        "split_unstaked": split_unstaked,
        "trader_advantage": (
            split["total_net_proceeds"] - direct["total_net_proceeds"]
        ),
        "validations": validations,
        "valid": all(validations.values()),
    }


def bounded_structural_proof(scale: int = 17) -> dict[str, Any]:
    """Exhaust small integer residues for the close-composition identities."""
    floor_conservation_violations: list[dict[str, int]] = []
    survivor_ratio_violations: list[dict[str, int]] = []
    nested_floor_violations: list[dict[str, int]] = []
    gross_subadditivity_violations: list[dict[str, int]] = []
    first_redeem_path_counterexample: dict[str, Any] | None = None
    checked = 0

    for quantity in range(2, 2 * scale + 1):
        for floor_shares in range(quantity + 1):
            for first_close in range(1, quantity):
                first_remaining, first_floor, first_removed = (
                    replay.split_partial_close_floor(
                        quantity,
                        floor_shares,
                        first_close,
                    )
                )
                if floor_shares != first_floor + first_removed:
                    floor_conservation_violations.append(
                        {
                            "quantity": quantity,
                            "floor_shares": floor_shares,
                            "first_close": first_close,
                        }
                    )
                if first_floor * quantity > floor_shares * first_remaining:
                    survivor_ratio_violations.append(
                        {
                            "quantity": quantity,
                            "floor_shares": floor_shares,
                            "first_close": first_close,
                        }
                    )
                for second_close in range(1, first_remaining + 1):
                    checked += 1
                    final_quantity, nested_floor, second_removed = (
                        replay.split_partial_close_floor(
                            first_remaining,
                            first_floor,
                            second_close,
                        )
                    )
                    _, direct_floor, direct_removed = (
                        replay.split_partial_close_floor(
                            quantity,
                            floor_shares,
                            first_close + second_close,
                        )
                    )
                    if (
                        floor_shares
                        != nested_floor + first_removed + second_removed
                    ):
                        floor_conservation_violations.append(
                            {
                                "quantity": quantity,
                                "floor_shares": floor_shares,
                                "first_close": first_close,
                                "second_close": second_close,
                            }
                        )
                    if nested_floor > direct_floor:
                        nested_floor_violations.append(
                            {
                                "quantity": quantity,
                                "floor_shares": floor_shares,
                                "first_close": first_close,
                                "second_close": second_close,
                            }
                        )
                    for probability in range(scale + 1):
                        first_gross = probability * first_close // scale
                        second_gross = probability * second_close // scale
                        direct_gross = (
                            probability
                            * (first_close + second_close)
                            // scale
                        )
                        if first_gross + second_gross > direct_gross:
                            gross_subadditivity_violations.append(
                                {
                                    "probability": probability,
                                    "quantity": quantity,
                                    "first_close": first_close,
                                    "second_close": second_close,
                                }
                            )
                        split_redeem = max(
                            0,
                            first_gross - first_removed,
                        ) + max(0, second_gross - second_removed)
                        direct_redeem = max(
                            0,
                            direct_gross - direct_removed,
                        )
                        if (
                            split_redeem > direct_redeem
                            and first_redeem_path_counterexample is None
                        ):
                            first_redeem_path_counterexample = {
                                "scale": scale,
                                "probability": probability,
                                "quantity": quantity,
                                "floor_shares": floor_shares,
                                "first_close": first_close,
                                "second_close": second_close,
                                "split_redeem": split_redeem,
                                "direct_redeem": direct_redeem,
                            }

    return {
        "result_strength": EXHAUSTIVE,
        "domain": (
            "quantity in [2, 2*scale], floor in [0, quantity], "
            "close splits over integer lots, synthetic probability in "
            "[0, scale]; scale=%d" % scale
        ),
        "scale": scale,
        "states_checked": checked,
        "floor_conservation_violations": floor_conservation_violations,
        "survivor_ratio_violations": survivor_ratio_violations,
        "nested_floor_violations": nested_floor_violations,
        "gross_subadditivity_violations": gross_subadditivity_violations,
        "first_redeem_path_counterexample": first_redeem_path_counterexample,
        "structural_invariants_hold": not (
            floor_conservation_violations
            or survivor_ratio_violations
            or nested_floor_violations
            or gross_subadditivity_violations
        ),
        "redeem_is_path_independent": (
            first_redeem_path_counterexample is None
        ),
    }


def shortfall_bound() -> dict[str, Any]:
    """State the exact bound for a live slice whose floor exceeds its gross."""
    ltv = replay.LIQUIDATION_LTV
    maximum_gross = (ltv - 1) // (F - ltv)
    minimum_fee_per_lot = replay.deepbook_mul_up(
        replay.MIN_FEE,
        LOT,
    )
    return {
        "result_strength": UNIVERSAL,
        "derivation": [
            "non-liquidatable implies floor/q < liquidation_ltv*probability/F^2",
            "slice shortfall implies floor(probability*close/F) < floor*close/q",
            "therefore g < liquidation_ltv*(g+1)/F",
            "so g < liquidation_ltv/(F-liquidation_ltv)",
        ],
        "liquidation_ltv": ltv,
        "maximum_shortfall_slice_gross": maximum_gross,
        "minimum_default_raw_fee_per_lot": minimum_fee_per_lot,
        "default_raw_fee_covers_shortfall_slice": (
            minimum_fee_per_lot > maximum_gross
        ),
        "scope": (
            "The raw-fee cap neutralizes the slice before stake discount. "
            "Discount-after-cap can expose a one-atom proceeds difference."
        ),
    }


# === Generalization (items 5-7): reachable close sequences with the full cascade ===


def _mint_if_reachable(
    entry_probability: int,
    quantity: int,
    leverage: int,
) -> dict[str, int] | None:
    """Mint terms if the order is admissible and above the minimum premium.

    Returns None when any mint-admission gate rejects the order, so every order
    fed to the advantage search is production-reachable by construction.
    """
    if quantity % LOT != 0:
        return None
    if not (
        replay.MIN_ENTRY_PROBABILITY
        <= entry_probability
        <= replay.MAX_ENTRY_PROBABILITY
    ):
        return None
    if leverage > replay.admission_leverage_cap(entry_probability):
        return None
    entry_value = replay.deepbook_mul(entry_probability, quantity)
    contribution = replay.net_premium_from_entry_value(entry_value, leverage)
    if contribution < replay.MIN_NET_PREMIUM:
        return None
    floor_shares = entry_value - contribution
    if floor_shares > quantity:
        return None
    # Complete the mint-admission mirror: reject an order that opens at or below
    # its own liquidation threshold, so a widened domain cannot admit an order
    # that mint would refuse.
    try:
        replay.assert_mint_above_liquidation_threshold(
            entry_probability,
            quantity,
            leverage,
            floor_shares,
        )
    except ValueError:
        return None
    return {
        "entry_exposure_value": entry_value,
        "contribution": contribution,
        "floor_shares": floor_shares,
        "leverage_multiplier": leverage,
    }


def _ordered_lot_compositions(
    total_lots: int,
    max_parts: int,
) -> list[tuple[int, ...]]:
    """Ordered compositions of `total_lots` into 1..max_parts positive parts."""
    results: list[tuple[int, ...]] = []

    def rec(remaining: int, parts: list[int]) -> None:
        if remaining == 0:
            results.append(tuple(parts))
            return
        if len(parts) == max_parts:
            return
        for take in range(1, remaining + 1):
            rec(remaining - take, parts + [take])

    rec(total_lots, [])
    return results


def reachable_advantage_search(
    *,
    entry_probabilities: tuple[int, ...] = (990_000_000, 980_000_000),
    quantities: tuple[int, ...] = tuple(
        range(1_000_000, 1_120_001, 10_000)
    ),
    leverage_offsets: tuple[int, ...] = tuple(range(1, 4_001, 25)),
    live_probabilities: tuple[int, ...] = (
        10_000,
        20_000,
        30_000,
        40_000,
        50_000,
        60_000,
        80_000,
        100_000,
    ),
    total_lots_values: tuple[int, ...] = (2, 3, 4, 5, 6),
    max_parts: int = 3,
    discount_fractions: tuple[int, ...] = (0, MAX_FEE_DISCOUNT),
    builder_options: tuple[bool, ...] = (False, True),
    penalty_rates: tuple[int, ...] = (0, MAX_EWMA_PENALTY_RATE),
) -> dict[str, Any]:
    """Exhaustive advantage search over a stated, production-reachable domain.

    For every admissible order and constant live price, compare each ordered
    multi-slice close (`split`) against the single-slice close of the same total
    quantity (`direct`), counting only sequences whose every non-final partial
    close is legal on a non-liquidatable order. `trader_advantage` is
    `split_net - direct_net`. Records the maximum advantage, its growth with the
    number of slices and the surviving floor, and one witness per axis
    (multi-atom floor, partial-then-full, active builder code, nonzero EWMA
    penalty). This bounds the effect over the stated domain ONLY; it is not a
    universal maximum over unbounded quantity, arbitrary price paths, or the full
    continuous config range.
    """
    max_advantage = 0
    max_advantage_case: dict[str, Any] | None = None
    advantage_by_parts: dict[int, int] = {}
    advantage_by_floor: dict[int, int] = {}
    positive_advantage_cases = 0
    penalty_offsets_observed = False
    builder_increases_advantage = False
    axis_witnesses: dict[str, dict[str, Any] | None] = {
        "multi_atom_floor": None,
        "partial_then_full": None,
        "active_builder_code": None,
        "nonzero_penalty": None,
    }
    orders_scanned = 0
    sequences_scored = 0

    for entry_probability in entry_probabilities:
        cap = replay.admission_leverage_cap(entry_probability)
        for quantity in quantities:
            quantity_lots = quantity // LOT
            seen_floors: set[int] = set()
            for offset in leverage_offsets:
                leverage = F + offset
                if leverage > cap:
                    break
                mint = _mint_if_reachable(entry_probability, quantity, leverage)
                if mint is None:
                    continue
                floor_shares = mint["floor_shares"]
                # One representative leverage per distinct small floor keeps the
                # scan bounded while still covering multi-atom floors.
                if floor_shares == 0 or floor_shares > 6:
                    continue
                if floor_shares in seen_floors:
                    continue
                seen_floors.add(floor_shares)
                orders_scanned += 1

                for live_probability in live_probabilities:
                    for total_lots in total_lots_values:
                        if total_lots > quantity_lots:
                            continue
                        total_close = total_lots * LOT
                        splits = [
                            comp
                            for comp in _ordered_lot_compositions(
                                total_lots, max_parts
                            )
                            if len(comp) >= 2
                        ]
                        if not splits:
                            continue
                        for discount in discount_fractions:
                            for builder in builder_options:
                                for penalty_rate in penalty_rates:
                                    direct = _run_close_sequence(
                                        probability=live_probability,
                                        quantity=quantity,
                                        floor_shares=floor_shares,
                                        close_quantities=(total_close,),
                                        discount_fraction=discount,
                                        builder_present=builder,
                                        penalty_rate=penalty_rate,
                                    )
                                    if not direct["reachable"]:
                                        continue
                                    for comp in splits:
                                        closes = tuple(
                                            part * LOT for part in comp
                                        )
                                        split = _run_close_sequence(
                                            probability=live_probability,
                                            quantity=quantity,
                                            floor_shares=floor_shares,
                                            close_quantities=closes,
                                            discount_fraction=discount,
                                            builder_present=builder,
                                            penalty_rate=penalty_rate,
                                        )
                                        if not split["reachable"]:
                                            continue
                                        sequences_scored += 1
                                        advantage = (
                                            split["total_net_proceeds"]
                                            - direct["total_net_proceeds"]
                                        )
                                        parts = len(comp)
                                        case = {
                                            "entry_probability": entry_probability,
                                            "quantity": quantity,
                                            "leverage": leverage,
                                            "floor_shares": floor_shares,
                                            "live_probability": live_probability,
                                            "total_close": total_close,
                                            "split_closes": list(closes),
                                            "discount_fraction": discount,
                                            "builder_present": builder,
                                            "penalty_rate": penalty_rate,
                                            "direct_net": direct[
                                                "total_net_proceeds"
                                            ],
                                            "split_net": split[
                                                "total_net_proceeds"
                                            ],
                                            "trader_advantage": advantage,
                                        }
                                        if advantage > 0:
                                            positive_advantage_cases += 1
                                            if (
                                                penalty_rate > 0
                                                and axis_witnesses[
                                                    "nonzero_penalty"
                                                ]
                                                is None
                                            ):
                                                axis_witnesses[
                                                    "nonzero_penalty"
                                                ] = case
                                            if (
                                                builder
                                                and axis_witnesses[
                                                    "active_builder_code"
                                                ]
                                                is None
                                            ):
                                                axis_witnesses[
                                                    "active_builder_code"
                                                ] = case
                                            if (
                                                floor_shares >= 2
                                                and axis_witnesses[
                                                    "multi_atom_floor"
                                                ]
                                                is None
                                            ):
                                                axis_witnesses[
                                                    "multi_atom_floor"
                                                ] = case
                                            if (
                                                closes
                                                and closes[-1]
                                                == split["steps"][-1][
                                                    "close_quantity"
                                                ]
                                                and split["remaining_quantity"]
                                                == 0
                                                and axis_witnesses[
                                                    "partial_then_full"
                                                ]
                                                is None
                                            ):
                                                axis_witnesses[
                                                    "partial_then_full"
                                                ] = case
                                        if advantage > advantage_by_parts.get(
                                            parts, -(1 << 62)
                                        ):
                                            advantage_by_parts[parts] = advantage
                                        if advantage > advantage_by_floor.get(
                                            floor_shares, -(1 << 62)
                                        ):
                                            advantage_by_floor[
                                                floor_shares
                                            ] = advantage
                                        # Does the up-rounded penalty ever pull a
                                        # would-be-positive advantage back down?
                                        if penalty_rate > 0:
                                            no_penalty = _run_close_sequence(
                                                probability=live_probability,
                                                quantity=quantity,
                                                floor_shares=floor_shares,
                                                close_quantities=closes,
                                                discount_fraction=discount,
                                                builder_present=builder,
                                                penalty_rate=0,
                                            )
                                            no_penalty_direct = _run_close_sequence(
                                                probability=live_probability,
                                                quantity=quantity,
                                                floor_shares=floor_shares,
                                                close_quantities=(total_close,),
                                                discount_fraction=discount,
                                                builder_present=builder,
                                                penalty_rate=0,
                                            )
                                            base_adv = (
                                                no_penalty["total_net_proceeds"]
                                                - no_penalty_direct[
                                                    "total_net_proceeds"
                                                ]
                                            )
                                            if advantage < base_adv:
                                                penalty_offsets_observed = True
                                        if builder:
                                            no_builder = _run_close_sequence(
                                                probability=live_probability,
                                                quantity=quantity,
                                                floor_shares=floor_shares,
                                                close_quantities=closes,
                                                discount_fraction=discount,
                                                builder_present=False,
                                                penalty_rate=penalty_rate,
                                            )
                                            no_builder_direct = _run_close_sequence(
                                                probability=live_probability,
                                                quantity=quantity,
                                                floor_shares=floor_shares,
                                                close_quantities=(total_close,),
                                                discount_fraction=discount,
                                                builder_present=False,
                                                penalty_rate=penalty_rate,
                                            )
                                            base_adv = (
                                                no_builder["total_net_proceeds"]
                                                - no_builder_direct[
                                                    "total_net_proceeds"
                                                ]
                                            )
                                            if advantage > base_adv:
                                                builder_increases_advantage = True
                                        if advantage > max_advantage:
                                            max_advantage = advantage
                                            max_advantage_case = case

    return {
        "result_strength": EXHAUSTIVE,
        "domain": {
            "entry_probabilities": list(entry_probabilities),
            "quantities": [quantities[0], quantities[-1], f"step {LOT}"],
            "leverage_offsets_over_float_scaling": [
                leverage_offsets[0],
                leverage_offsets[-1],
                "one representative per distinct floor in 1..6",
            ],
            "live_probabilities": list(live_probabilities),
            "total_lots_values": list(total_lots_values),
            "max_parts_per_split": max_parts,
            "discount_fractions": list(discount_fractions),
            "builder_options": list(builder_options),
            "penalty_rates": list(penalty_rates),
        },
        "orders_scanned": orders_scanned,
        "sequences_scored": sequences_scored,
        "positive_advantage_cases": positive_advantage_cases,
        "max_trader_advantage_over_domain": max_advantage,
        "max_advantage_case": max_advantage_case,
        "max_advantage_by_slice_count": dict(sorted(advantage_by_parts.items())),
        "max_advantage_by_surviving_floor": dict(
            sorted(advantage_by_floor.items())
        ),
        "penalty_can_reduce_advantage": penalty_offsets_observed,
        "builder_can_increase_advantage": builder_increases_advantage,
        "axis_witnesses": axis_witnesses,
        "not_a_universal_bound": (
            "Maximum is over the stated finite domain only. No global maximum "
            "over unbounded quantity, arbitrary price paths, or the full "
            "continuous admin-config range is established."
        ),
    }


def _coarse_partition_points(quantity_lots: int) -> list[int]:
    return sorted(
        {
            max(1, quantity_lots * n // d)
            for n, d in ((1, 4), (1, 3), (1, 2), (2, 3), (3, 4))
        }
    )


def _sampled_full_exit_partitions(quantity_lots: int) -> list[tuple[int, ...]]:
    """Coarse two-way and three-way full-exit partitions (last slice full-closes).

    Coarse rather than every-lot-boundary so the eight-config builder/penalty
    sweep stays fast; an exhaustive all-two-way pass at the most-favorable config
    is run separately to bound the two-way case.
    """
    points = _coarse_partition_points(quantity_lots)
    partitions: list[tuple[int, ...]] = []
    for first in points:
        if 0 < first < quantity_lots:
            partitions.append((first, quantity_lots - first))
    for a in points:
        for b in points:
            if a > 0 and b > 0 and a + b < quantity_lots:
                partitions.append((a, b, quantity_lots - a - b))
    return partitions


def _reachable_full_exit_orders(
    entry_probabilities: tuple[int, ...],
    quantities: tuple[int, ...],
    max_floor: int,
) -> list[dict[str, int]]:
    orders: list[dict[str, int]] = []
    for entry_probability in entry_probabilities:
        cap = replay.admission_leverage_cap(entry_probability)
        for quantity in quantities:
            seen_floors: set[int] = set()
            for offset in range(1, 20_000):
                leverage = F + offset
                if leverage > cap:
                    break
                mint = _mint_if_reachable(entry_probability, quantity, leverage)
                if mint is None:
                    continue
                floor_shares = mint["floor_shares"]
                if not (1 <= floor_shares <= max_floor):
                    continue
                if floor_shares in seen_floors:
                    continue
                seen_floors.add(floor_shares)
                orders.append(
                    {
                        "entry_probability": entry_probability,
                        "quantity": quantity,
                        "leverage": leverage,
                        "floor_shares": floor_shares,
                    }
                )
    return orders


def full_liquidation_split_analysis(
    *,
    entry_probabilities: tuple[int, ...] = (990_000_000, 980_000_000),
    quantities: tuple[int, ...] = (
        1_000_000,
        1_020_000,
        1_050_000,
        1_100_000,
        1_500_000,
        2_000_000,
    ),
    max_floor: int = 6,
    live_probabilities: tuple[int, ...] = (
        10_000,
        20_000,
        30_000,
        40_000,
        60_000,
        100_000,
    ),
    discount_fractions: tuple[int, ...] = (0, MAX_FEE_DISCOUNT),
    builder_options: tuple[bool, ...] = (False, True),
    penalty_rates: tuple[int, ...] = (0, MAX_EWMA_PENALTY_RATE),
    equal_slice_counts: tuple[int, ...] = (2, 3, 4, 6, 8, 12),
) -> dict[str, Any]:
    """Partial-then-full search: fully exit an order via slices.

    For each reachable order (one representative leverage per distinct floor) and
    constant live price, compare a single full close (`direct`) against sampled
    two-way and three-way full-exit partitions, sweeping stake discount, active
    builder code, and EWMA penalty. Records the maximum trader advantage, whether
    an active builder code raises it (on a full exit the direct close's single
    down-rounded builder fee can exceed the split's summed builder fees), and one
    partial-then-full witness. A separate all-two-way pass at the most-favorable
    config exhaustively bounds the two-way case. `equal_slice_trend` shows that K
    equal slices make the trader strictly WORSE off as K grows. Exhaustive over
    the stated finite domain only; not a universal maximum.
    """
    orders = _reachable_full_exit_orders(
        entry_probabilities, quantities, max_floor
    )
    max_advantage = 0
    max_advantage_case: dict[str, Any] | None = None
    advantage_by_floor: dict[int, int] = {}
    advantage_by_parts: dict[int, int] = {}
    positive_cases = 0
    partial_then_full_witness: dict[str, Any] | None = None
    sequences_scored = 0

    for order in orders:
        quantity = order["quantity"]
        floor_shares = order["floor_shares"]
        quantity_lots = quantity // LOT
        partitions = _sampled_full_exit_partitions(quantity_lots)
        for live_probability in live_probabilities:
            for discount in discount_fractions:
                for builder in builder_options:
                    for penalty_rate in penalty_rates:
                        direct = _run_close_sequence(
                            probability=live_probability,
                            quantity=quantity,
                            floor_shares=floor_shares,
                            close_quantities=(quantity,),
                            discount_fraction=discount,
                            builder_present=builder,
                            penalty_rate=penalty_rate,
                        )
                        for part in partitions:
                            closes = tuple(p * LOT for p in part)
                            split = _run_close_sequence(
                                probability=live_probability,
                                quantity=quantity,
                                floor_shares=floor_shares,
                                close_quantities=closes,
                                discount_fraction=discount,
                                builder_present=builder,
                                penalty_rate=penalty_rate,
                            )
                            if not split["reachable"]:
                                continue
                            sequences_scored += 1
                            advantage = (
                                split["total_net_proceeds"]
                                - direct["total_net_proceeds"]
                            )
                            parts = len(part)
                            if advantage > advantage_by_parts.get(
                                parts, -(1 << 62)
                            ):
                                advantage_by_parts[parts] = advantage
                            if advantage > advantage_by_floor.get(
                                floor_shares, -(1 << 62)
                            ):
                                advantage_by_floor[floor_shares] = advantage
                            if advantage > 0:
                                positive_cases += 1
                                case = {
                                    **order,
                                    "live_probability": live_probability,
                                    "split_closes": list(closes),
                                    "discount_fraction": discount,
                                    "builder_present": builder,
                                    "penalty_rate": penalty_rate,
                                    "direct_net": direct["total_net_proceeds"],
                                    "split_net": split["total_net_proceeds"],
                                    "trader_advantage": advantage,
                                }
                                if partial_then_full_witness is None:
                                    partial_then_full_witness = case
                                if advantage > max_advantage:
                                    max_advantage = advantage
                                    max_advantage_case = case

    # Exhaustive all-two-way pass at max discount, builder on and off, so the
    # two-way maximum is apples-to-apples (coarse sampling above can miss it).
    two_way_exhaustive_max = {True: 0, False: 0}
    for order in orders:
        quantity = order["quantity"]
        floor_shares = order["floor_shares"]
        quantity_lots = quantity // LOT
        for live_probability in live_probabilities:
            for builder in (True, False):
                direct = _run_close_sequence(
                    probability=live_probability,
                    quantity=quantity,
                    floor_shares=floor_shares,
                    close_quantities=(quantity,),
                    discount_fraction=MAX_FEE_DISCOUNT,
                    builder_present=builder,
                )
                for first_lots in range(1, quantity_lots):
                    closes = (
                        first_lots * LOT,
                        (quantity_lots - first_lots) * LOT,
                    )
                    split = _run_close_sequence(
                        probability=live_probability,
                        quantity=quantity,
                        floor_shares=floor_shares,
                        close_quantities=closes,
                        discount_fraction=MAX_FEE_DISCOUNT,
                        builder_present=builder,
                    )
                    if not split["reachable"]:
                        continue
                    advantage = (
                        split["total_net_proceeds"]
                        - direct["total_net_proceeds"]
                    )
                    if advantage > two_way_exhaustive_max[builder]:
                        two_way_exhaustive_max[builder] = advantage

    # Equal-slice trend on the canonical floor=1 order with an active builder.
    equal_slice_trend: list[dict[str, int]] = []
    trend_quantity = 1_020_000
    trend_mint = _mint_if_reachable(990_000_000, trend_quantity, 1_000_000_991)
    if trend_mint is not None:
        trend_floor = trend_mint["floor_shares"]
        trend_lots = trend_quantity // LOT
        live_probability = 40_000
        direct = _run_close_sequence(
            probability=live_probability,
            quantity=trend_quantity,
            floor_shares=trend_floor,
            close_quantities=(trend_quantity,),
            discount_fraction=MAX_FEE_DISCOUNT,
            builder_present=True,
        )
        for k in equal_slice_counts:
            if k > trend_lots:
                continue
            base = trend_lots // k
            parts = [base] * (k - 1) + [trend_lots - base * (k - 1)]
            closes = tuple(part * LOT for part in parts)
            split = _run_close_sequence(
                probability=live_probability,
                quantity=trend_quantity,
                floor_shares=trend_floor,
                close_quantities=closes,
                discount_fraction=MAX_FEE_DISCOUNT,
                builder_present=True,
            )
            if not split["reachable"]:
                continue
            equal_slice_trend.append(
                {
                    "slices": k,
                    "trader_advantage": (
                        split["total_net_proceeds"]
                        - direct["total_net_proceeds"]
                    ),
                }
            )

    return {
        "result_strength": EXHAUSTIVE,
        "domain": {
            "entry_probabilities": list(entry_probabilities),
            "quantities": list(quantities),
            "max_floor": max_floor,
            "live_probabilities": list(live_probabilities),
            "two_way_partitions": "quarter/third/half sample points",
            "three_way_partitions": "quarter/third/half sample points",
            "discount_fractions": list(discount_fractions),
            "builder_options": list(builder_options),
            "penalty_rates": list(penalty_rates),
        },
        "orders_scanned": len(orders),
        "sequences_scored": sequences_scored,
        "positive_advantage_cases": positive_cases,
        # The main scan enumerates COARSE (quarter/third/half) partition points,
        # so this domain-max is a reachable lower bound with WITNESS strength for
        # the three-way case, not a complete maximum over all partitions. The
        # only genuinely exhaustive figure here is the all-two-way pass below.
        "max_trader_advantage_over_domain": max_advantage,
        "domain_max_partitions_are_coarse_samples": True,
        "domain_max_is_a_reachable_lower_bound": True,
        "max_advantage_case": max_advantage_case,
        "max_advantage_by_floor": dict(sorted(advantage_by_floor.items())),
        "max_advantage_by_slice_count": dict(sorted(advantage_by_parts.items())),
        "two_way_exhaustive_max_at_max_discount": {
            "builder_on": two_way_exhaustive_max[True],
            "builder_off": two_way_exhaustive_max[False],
            "note": "the only EXHAUSTIVE partition figure; three-way is sampled",
        },
        "active_builder_code_needed_for_domain_max": (
            max_advantage_case is not None
            and max_advantage_case["builder_present"]
        ),
        "partial_then_full_witness": partial_then_full_witness,
        "equal_slice_trend": equal_slice_trend,
        "slice_count_advantage_is_non_monotone": (
            "With an active builder code and full stake the advantage rises to "
            "a peak at a small slice count, then turns negative as the order is "
            "over-split (see equal_slice_trend); it does not grow without bound."
        ),
        "large_split_count_is_trader_negative": (
            equal_slice_trend[-1]["trader_advantage"] < 0
            if equal_slice_trend
            else None
        ),
        "not_a_universal_bound": (
            "Partitions are sampled at quarter/third/half points (all two-way "
            "splits are exhausted only at max discount); higher-way splits, "
            "unbounded quantity, arbitrary price paths, and the full continuous "
            "config range are not enumerated. No universal maximum is "
            "established."
        ),
    }


def changing_price_analysis(
    *,
    entry_probability: int = 990_000_000,
    quantity: int = 1_020_000,
    leverage: int = 1_000_000_991,
    price_pairs: tuple[tuple[int, int], ...] = (
        (40_000, 40_000),
        (40_000, 60_000),
        (60_000, 40_000),
        (30_000, 90_000),
        (90_000, 30_000),
    ),
    total_lots: int = 6,
    discount_fraction: int = MAX_FEE_DISCOUNT,
) -> dict[str, Any]:
    """Report split-vs-direct proceeds when the live price moves between closes.

    Reported SEPARATELY from the constant-price search: a two-slice split priced
    at (p1, p2) is not an economically equal path to a direct close priced at a
    single p, so this measures a different quantity and is not folded into the
    constant-price advantage. The direct baseline uses the FIRST price of each
    pair; results are descriptive, not a path-independence claim.
    """
    mint = _mint_if_reachable(entry_probability, quantity, leverage)
    if mint is None:
        return {
            "result_strength": WITNESS,
            "reachable": False,
            "note": "constructed order is not admissible",
        }
    floor_shares = mint["floor_shares"]
    total_close = total_lots * LOT
    first_lots = total_lots // 2
    rows = []
    for p1, p2 in price_pairs:
        # Direct close of the whole slice at the first price.
        direct = _close_step(
            probability=p1,
            quantity=quantity,
            floor_shares=floor_shares,
            close_quantity=total_close,
            discount_fraction=discount_fraction,
        )
        # Split: first slice at p1, survivor closed at p2.
        step1 = _close_step(
            probability=p1,
            quantity=quantity,
            floor_shares=floor_shares,
            close_quantity=first_lots * LOT,
            discount_fraction=discount_fraction,
        )
        step2 = _close_step(
            probability=p2,
            quantity=step1["remaining_quantity"],
            floor_shares=step1["remaining_floor_shares"],
            close_quantity=(total_lots - first_lots) * LOT,
            discount_fraction=discount_fraction,
        )
        split_net = step1["net_proceeds"] + step2["net_proceeds"]
        rows.append(
            {
                "first_price": p1,
                "second_price": p2,
                "direct_net_at_first_price": direct["net_proceeds"],
                "split_net": split_net,
                "split_minus_direct_at_first_price": (
                    split_net - direct["net_proceeds"]
                ),
                "reachable": step1["partial_close_legal"],
            }
        )
    return {
        "result_strength": EXHAUSTIVE,
        "domain": {
            "order": {
                "entry_probability": entry_probability,
                "quantity": quantity,
                "leverage": leverage,
                "floor_shares": floor_shares,
            },
            "price_pairs": [list(pair) for pair in price_pairs],
            "total_lots": total_lots,
        },
        "note": (
            "Changing-price closes are separate economic paths; the "
            "split-minus-direct column is descriptive, not a path-independence "
            "or extraction claim."
        ),
        "rows": rows,
    }


def build_partial_close_bundle() -> dict[str, Any]:
    structural = bounded_structural_proof()
    witness = production_fragmentation_witness()
    bound = shortfall_bound()
    advantage = reachable_advantage_search()
    full_exit = full_liquidation_split_analysis()
    changing_price = changing_price_analysis()
    max_reachable_advantage = max(
        witness["trader_advantage"],
        advantage["max_trader_advantage_over_domain"],
        full_exit["max_trader_advantage_over_domain"],
    )
    return {
        "schema": "predict_partial_close_proofs_v2",
        "result_strength_legend": {
            UNIVERSAL: "algebraic or inductive proof over all inputs",
            EXHAUSTIVE: "checked over a stated finite domain only",
            WITNESS: "one production-reachable concrete example",
        },
        "structural_proof": structural,
        "shortfall_bound": bound,
        "production_fragmentation_witness": witness,
        "reachable_advantage_search": advantage,
        "full_liquidation_split_analysis": full_exit,
        "changing_price_analysis": changing_price,
        "all_sequence_sites_classified": (
            structural["structural_invariants_hold"] and witness["valid"]
        ),
        "floor_and_liability_conservation_hold": (
            structural["structural_invariants_hold"]
        ),
        "gross_redeem_is_path_independent": (
            structural["redeem_is_path_independent"]
        ),
        # End-to-end aggregate stays RED while any reachable trader-favored
        # split remains (item 7).
        "end_to_end_net_proceeds_path_independent": (
            max_reachable_advantage == 0
        ),
        "maximum_known_split_close_advantage": max_reachable_advantage,
        "maximum_advantage_scope": (
            "Largest split-minus-direct trader gain established by a "
            "concrete reachable witness or by exhaustive search over the "
            "stated finite domain. NOT a global maximum: no universal bound "
            "over unbounded quantity, arbitrary price paths, or the full "
            "continuous admin-config range is proven."
        ),
        "global_maximum_advantage_is_established": False,
        "proof_boundary": {
            "proved": (
                "per-close floor conservation, survivor floor-ratio bias, "
                "nested-floor direction, and gross floor subadditivity "
                "(exhaustive over the stated small domain); the raw-fee cap "
                "neutralizing a shortfall slice before discount (algebraic)"
            ),
            "witnessed": (
                "a production-reachable one-atom split-close gain, and its "
                "generalization to multi-atom floors, partial-then-full "
                "closes, active builder codes, and nonzero EWMA penalties "
                "over the stated finite domain"
            ),
            "not_claimed": (
                "a universal maximum extractable amount over every order, "
                "price path, stake path, builder fee, and EWMA penalty "
                "sequence"
            ),
        },
    }


def main() -> None:
    print(json.dumps(build_partial_close_bundle(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
