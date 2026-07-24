#!/usr/bin/env python3
"""Source-backed inventory of Predict fixed-point and custody math."""

from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
SOURCE_ROOT = REPO_ROOT / "packages" / "predict" / "sources"
EXPECTED_SOURCE_TREE_SHA256 = (
    "9442492c2be835df115e0ce876ac3edc56261393543c6ac40820f7864775b9f6"
)

CANDIDATE_RE = re.compile(
    r"math::[A-Za-z0-9_]+\s*\("
    r"|\.saturating_sub\("
    r"|\.saturating_add\("
    r"|\.div_ceil\("
    r"|\.min\("
    r"|\.max\("
    r"|\.diff\("
    r"|\.split\("
    r"|approx::[A-Za-z0-9_]+\s*\("
    r"|\.(?:mul_scaled|div_scaled|square_scaled|mul_div_down|half|double"
    r"|clamp_nonnegative|clamp_unit_interval|clamp_upper|add|sub)\("
)
FUNCTION_RE = re.compile(r"\bfun\s+([A-Za-z0-9_]+)\s*\(")
# Exclude comparisons, assignments, and Move's `->` return arrow. Comments are
# removed before this pattern is applied.
RAW_OPERATOR_RE = re.compile(r"(?<![-<>=!])([+\-*/%])(?![=>])")

NUMERICAL_EVALUATION = "numerical_evaluation"
MONEY_COLLAPSE = "money_collapse"
MONEY_VALUATION = "money_valuation"
POLICY_PROJECTION = "policy_projection"
POLICY_CLAMP = "policy_clamp"
GUARD_ONLY = "guard_only"
EXACT_CUSTODY = "exact_custody"
DATA_STRUCTURE = "data_structure"
NON_MONEY_INTEGER = "non_money_integer"

DIRECTED_ROUNDING_OPERATORS = {
    "try_mul_div_down",
    "mul_div_down",
    "mul_down",
    "mul_up",
    "div_down",
    "div_up",
    "sqrt_down",
    "sqrt_u128_down",
    "sqrt_u128_up",
}


@dataclass(frozen=True)
class Candidate:
    path: str
    function: str
    ordinal: int
    line: int
    operator: str
    source: str

    @property
    def function_id(self) -> str:
        return f"{self.path}::{self.function}"

    @property
    def site_id(self) -> str:
        return f"{self.path}::{self.function}::site#{self.ordinal}"


FUNCTION_CLASSIFICATION = {
    # Approx-valued money surfaces carry numerical envelopes to a later collapse.
    "packages/predict/sources/expiry_market.move::current_nav_approx": MONEY_VALUATION,
    "packages/predict/sources/plp/plp.move::lp_pool_value_approx": MONEY_VALUATION,
    "packages/predict/sources/plp/plp.move::value_expiry": MONEY_VALUATION,
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::walk_linear": MONEY_VALUATION,
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::walk_linear_subtree": MONEY_VALUATION,
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::combine_summaries": MONEY_VALUATION,
    "packages/predict/sources/strike_exposure/strike_exposure.move::marked_live_liability": MONEY_VALUATION,
    # Monetary values or entitlements are rounded here.
    "packages/predict/sources/config/expiry_cash_config.move::rebate_reserve_for_fee_basis": MONEY_COLLAPSE,
    "packages/predict/sources/config/stake_config.move::fee_amount_after_discount": MONEY_COLLAPSE,
    "packages/predict/sources/config/stake_config.move::rebate_amount": MONEY_COLLAPSE,
    "packages/predict/sources/config/stake_config.move::benefit_ratio": MONEY_COLLAPSE,
    "packages/predict/sources/config/strike_exposure_config.move::net_premium_from_entry_value": MONEY_COLLAPSE,
    "packages/predict/sources/config/strike_exposure_config.move::trading_fee": MONEY_COLLAPSE,
    "packages/predict/sources/config/strike_exposure_config.move::assert_mint_admission": MONEY_COLLAPSE,
    "packages/predict/sources/config/strike_exposure_config.move::fee_rate": MONEY_COLLAPSE,
    "packages/predict/sources/config/strike_exposure_config.move::raw_bernoulli_fee_rate": MONEY_COLLAPSE,
    "packages/predict/sources/config/strike_exposure_config.move::expiry_fee_multiplier": MONEY_COLLAPSE,
    "packages/predict/sources/ewma.move::penalty_fee": MONEY_COLLAPSE,
    "packages/predict/sources/expiry_market.move::fee_incentive_subsidy_amount": MONEY_COLLAPSE,
    "packages/predict/sources/expiry_market.move::builder_fee_amount": MONEY_COLLAPSE,
    "packages/predict/sources/plp/lp_book.move::quote_supply_shares": MONEY_COLLAPSE,
    "packages/predict/sources/plp/lp_book.move::quote_withdraw_dusdc": MONEY_COLLAPSE,
    "packages/predict/sources/plp/plp.move::sync_fee_incentives": MONEY_COLLAPSE,
    "packages/predict/sources/plp/plp.move::expiry_rebalance_cash_terms": MONEY_COLLAPSE,
    "packages/predict/sources/plp/plp.move::materialize_expiry_profit": MONEY_COLLAPSE,
    "packages/predict/sources/plp/plp.move::pool_nav_bid_ask": MONEY_COLLAPSE,
    "packages/predict/sources/plp/pool_accounting.move::register_expiry": MONEY_COLLAPSE,
    "packages/predict/sources/strike_exposure/strike_exposure.move::payout_liability": MONEY_COLLAPSE,
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_mint_terms": MONEY_COLLAPSE,
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_close": MONEY_COLLAPSE,
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_live_close": MONEY_COLLAPSE,
    "packages/predict/sources/strike_exposure/strike_exposure.move::gross_order_value": MONEY_COLLAPSE,
    # These round or clamp a policy variable, but do not themselves move money.
    "packages/predict/sources/config/strike_exposure_config.move::admitted_leverage_cap": POLICY_PROJECTION,
    "packages/predict/sources/expiry_cash.move::free_cash": POLICY_CLAMP,
    "packages/predict/sources/expiry_market.move::claim_trading_loss_rebate": POLICY_CLAMP,
    "packages/predict/sources/expiry_market.move::quote_mint_for_account": POLICY_CLAMP,
    "packages/predict/sources/expiry_market.move::mint_exact_amount": POLICY_CLAMP,
    "packages/predict/sources/plp/pool_accounting.move::available_expiry_funding": POLICY_CLAMP,
    "packages/predict/sources/plp/pool_accounting.move::record_fee_incentives_allocated_up_to": POLICY_CLAMP,
    "packages/predict/sources/plp/pool_accounting.move::flow_net_funding": POLICY_CLAMP,
    "packages/predict/sources/predict_account.move::resolve_expiry_summary": POLICY_CLAMP,
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::positive_net_delta": POLICY_CLAMP,
    # Numerical conditioning and state estimation, upstream of policy.
    "packages/predict/sources/ewma.move::update": NUMERICAL_EVALUATION,
    "packages/predict/sources/plp/plp.move::start_pool_valuation_internal": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::assert_min_total_variance_positive": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::cached_range_price": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::cached_up_price": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::compute_range_price": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::compute_up_price": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::digital_price": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::moneyness_terms": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::variance_slope": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::resolve_live_pricer": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::min_svi_variance_increment": NUMERICAL_EVALUATION,
    "packages/predict/sources/pricing/pricing.move::variance_denominator_terms": NUMERICAL_EVALUATION,
    # Admission or branch guards consume rounded values but do not transfer them.
    "packages/predict/sources/config/strike_exposure_config.move::is_liquidatable": GUARD_ONLY,
    "packages/predict/sources/plp/lp_book.move::is_executable_mark": GUARD_ONLY,
    "packages/predict/sources/pricing/pricing.move::assert_inputs_pricing_safe": GUARD_ONLY,
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::correction_value": GUARD_ONLY,
    "packages/predict/sources/strike_exposure/range_codec.move::prefix_limit_tick": GUARD_ONLY,
    # Integer balance splits are exact custody operations, not dust births.
    "packages/predict/sources/expiry_cash.move::release_surplus": EXACT_CUSTODY,
    "packages/predict/sources/expiry_cash.move::pay_authorized": EXACT_CUSTODY,
    "packages/predict/sources/expiry_market.move::release_fee_incentives": EXACT_CUSTODY,
    "packages/predict/sources/expiry_market.move::settle_mint_payment": EXACT_CUSTODY,
    "packages/predict/sources/expiry_market.move::settle_live_redeem_payment": EXACT_CUSTODY,
    "packages/predict/sources/plp/lp_book.move::emit_request_limit_missed": EXACT_CUSTODY,
    "packages/predict/sources/plp/plp.move::unstake_deep": EXACT_CUSTODY,
    "packages/predict/sources/plp/pool_accounting.move::withdraw_idle": EXACT_CUSTODY,
    "packages/predict/sources/plp/pool_accounting.move::send_expiry_cash": EXACT_CUSTODY,
    "packages/predict/sources/plp/pool_accounting.move::realize_pending_protocol_profit": EXACT_CUSTODY,
    # False positives from generic `.add` calls are recorded, not silently dropped.
    "packages/predict/sources/predict_account.move::add_position": DATA_STRUCTURE,
    "packages/predict/sources/predict_account.move::ensure_summary": DATA_STRUCTURE,
    "packages/predict/sources/registry/market_manager.move::record_expiry_creation": DATA_STRUCTURE,
    "packages/predict/sources/registry/market_manager.move::register_underlying": DATA_STRUCTURE,
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::insert_active_order_id": DATA_STRUCTURE,
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::apply_at": DATA_STRUCTURE,
}

# Raw integer arithmetic is scanned in every function, not only functions
# preselected as monetary. These explicit dispositions make new raw-only
# functions fail the inventory instead of silently falling outside its pattern.
EXACT_ACCOUNTING_FUNCTIONS = {
    "packages/predict/sources/expiry_cash.move::collect_trade_fee",
    "packages/predict/sources/expiry_cash.move::required_cash",
    "packages/predict/sources/expiry_cash.move::resolve_rebate_reserve_for_fee_basis",
    "packages/predict/sources/expiry_market.move::compute_mint_quote",
    "packages/predict/sources/expiry_market.move::redeem",
    "packages/predict/sources/expiry_market.move::release_settled_pool_cash",
    "packages/predict/sources/order.move::decode_floor_shares",
    "packages/predict/sources/order.move::decode_quantity_lots",
    "packages/predict/sources/order.move::encode_floor_shares_key",
    "packages/predict/sources/order.move::encode_quantity_lots_key",
    "packages/predict/sources/order.move::new",
    "packages/predict/sources/order.move::quantity",
    "packages/predict/sources/order.move::quantity_lots_from_quantity",
    "packages/predict/sources/plp/plp.move::sweep_live_expiry_surplus",
    "packages/predict/sources/plp/plp.move::top_up_live_expiry_cash",
    "packages/predict/sources/plp/pool_accounting.move::materialize_expiry_profit",
    "packages/predict/sources/plp/pool_accounting.move::realize_protocol_profit",
    "packages/predict/sources/plp/pool_accounting.move::record_received_from_expiry",
    "packages/predict/sources/plp/pool_accounting.move::record_sent_to_expiry",
    "packages/predict/sources/plp/pool_accounting.move::start_terminal_accounting_if_needed",
    "packages/predict/sources/predict_account.move::add_inactive_stake",
    "packages/predict/sources/predict_account.move::record_gross_paid_to_expiry",
    "packages/predict/sources/predict_account.move::record_gross_received_from_expiry",
    "packages/predict/sources/predict_account.move::record_trading_fee_paid",
    "packages/predict/sources/predict_account.move::remove_all_stake",
    "packages/predict/sources/predict_account.move::remove_position",
    "packages/predict/sources/predict_account.move::roll_active_stake",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::add_terms",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::apply_boundary_delta",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::apply_terms_delta",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::insert_range",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::net_payout",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::net_payout_reserve_terms",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::settlement_prefix_terms",
    "packages/predict/sources/strike_exposure/strike_exposure.move::allocate_mint_order",
    "packages/predict/sources/strike_exposure/strike_exposure.move::process_live_close",
    "packages/predict/sources/strike_exposure/strike_exposure.move::process_settled_close",
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_settled_close",
    "packages/predict/sources/strike_exposure/strike_exposure.move::settled_payout",
}

NON_MONEY_RAW_FUNCTIONS = {
    "packages/predict/sources/config/config_constants.move::assert_market_tick_size_bounds",
    "packages/predict/sources/config/config_constants.move::default_lower_benefit_power",
    "packages/predict/sources/config/config_constants.move::default_max_admission_leverage",
    "packages/predict/sources/config/config_constants.move::default_upper_benefit_power",
    "packages/predict/sources/config/config_constants.move::max_expiry_fee_max_multiplier",
    "packages/predict/sources/config/config_constants.move::max_lower_benefit_power",
    "packages/predict/sources/config/config_constants.move::max_max_admission_leverage",
    "packages/predict/sources/config/config_constants.move::max_max_entry_probability",
    "packages/predict/sources/config/config_constants.move::max_min_entry_probability",
    "packages/predict/sources/config/config_constants.move::max_upper_benefit_power",
    "packages/predict/sources/config/config_constants.move::min_lower_benefit_power",
    "packages/predict/sources/config/config_constants.move::min_upper_benefit_power",
    "packages/predict/sources/config/stake_config.move::set_benefit_powers",
    "packages/predict/sources/events/order_events.move::emit_live_order_redeemed",
    "packages/predict/sources/ewma.move::scaled_gas_price",
    "packages/predict/sources/expiry_market.move::liquidate_order",
    "packages/predict/sources/expiry_market.move::redeem_live",
    "packages/predict/sources/order.move::<module>",
    "packages/predict/sources/order.move::assert_valid_quantity",
    "packages/predict/sources/order.move::tick_mask",
    "packages/predict/sources/plp/lp_book.move::new_page",
    "packages/predict/sources/plp/lp_book.move::page_id_for_index",
    "packages/predict/sources/plp/lp_book.move::requests_processed",
    "packages/predict/sources/plp/lp_book.move::under_budget",
    "packages/predict/sources/pricing/pricing.move::price_and_cache",
    "packages/predict/sources/pricing/pricing.move::timestamp_is_fresh",
    "packages/predict/sources/registry/market_manager.move::assert_cadence_config",
    "packages/predict/sources/registry/market_manager.move::cadence_config",
    "packages/predict/sources/registry/market_manager.move::expiry_market_id",
    "packages/predict/sources/registry/market_manager.move::has_higher_rank_overlap",
    "packages/predict/sources/registry/market_manager.move::next_deployable_market",
    "packages/predict/sources/registry/market_manager.move::set_template_cadence_config",
    "packages/predict/sources/registry/registry.move::create_and_share_expiry_market",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::collect_head_candidates",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::collect_passive_candidates",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::cursor_after_order_id",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::first_passive_cursor",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::lower_bound",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::merge_adjacent_pages",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::merge_page_if_small",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::new_page_id",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::next_cursor",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::page_index_for_insert",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::remove_active_order_id",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::select_liquidation_candidates",
    "packages/predict/sources/strike_exposure/index/liquidation_book.move::upper_bound",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::merge_subtrees",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::resummarize",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::subtree_summary",
    "packages/predict/sources/strike_exposure/range_codec.move::grid_tick",
    "packages/predict/sources/strike_exposure/range_codec.move::strike_from_tick",
    "packages/predict/sources/strike_exposure/strike_exposure.move::assert_admitted_mint_ticks",
    "packages/predict/sources/strike_exposure/strike_exposure.move::close_terms",
    "packages/predict/sources/strike_exposure/strike_exposure.move::liquidate_live_orders",
    "packages/predict/sources/strike_exposure/strike_exposure.move::set_reference_tick",
}

FUNCTION_CLASSIFICATION.update(
    {
        function_id: EXACT_CUSTODY
        for function_id in EXACT_ACCOUNTING_FUNCTIONS
    }
)
FUNCTION_CLASSIFICATION.update(
    {
        function_id: NON_MONEY_INTEGER
        for function_id in NON_MONEY_RAW_FUNCTIONS
    }
)


def _operator(token: str) -> str:
    token = token.rstrip()
    if token.endswith("("):
        token = token[:-1].rstrip()
    if token.startswith("math::"):
        return token.removeprefix("math::")
    if "saturating_sub" in token:
        return "saturating_sub"
    if "saturating_add" in token:
        return "saturating_add"
    if "div_ceil" in token:
        return "div_ceil"
    if "split" in token:
        return "balance_split"
    if token.startswith("approx::"):
        return token.removeprefix("approx::")
    if token.startswith("."):
        return token[1:]
    raise ValueError(f"unknown candidate token: {token}")


def scan_source_text(relative: str, source: str) -> list[Candidate]:
    """Scan one Move source while preserving stable within-function site ordinals."""
    candidates: list[Candidate] = []
    ordinals: Counter[str] = Counter()
    current_function = "<module>"
    for line_number, line in enumerate(source.splitlines(), start=1):
        function = FUNCTION_RE.search(line)
        if function:
            current_function = function.group(1)
        function_id = f"{relative}::{current_function}"
        for match in CANDIDATE_RE.finditer(line):
            ordinals[function_id] += 1
            candidates.append(
                Candidate(
                    path=relative,
                    function=current_function,
                    ordinal=ordinals[function_id],
                    line=line_number,
                    operator=_operator(match.group(0)),
                    source=line.strip(),
                )
            )
        if function is None:
            code = line.split("//", 1)[0]
            for match in RAW_OPERATOR_RE.finditer(code):
                ordinals[function_id] += 1
                candidates.append(
                    Candidate(
                        path=relative,
                        function=current_function,
                        ordinal=ordinals[function_id],
                        line=line_number,
                        operator={
                            "+": "raw_add",
                            "-": "raw_sub",
                            "*": "raw_mul",
                            "/": "raw_div",
                            "%": "raw_mod",
                        }[match.group(1)],
                        source=line.strip(),
                    )
                )
    return candidates


def scan_candidates() -> list[Candidate]:
    candidates: list[Candidate] = []
    for source_path in sorted(SOURCE_ROOT.rglob("*.move")):
        relative = source_path.relative_to(REPO_ROOT).as_posix()
        candidates.extend(scan_source_text(relative, source_path.read_text()))
    return candidates


def source_tree_sha256() -> str:
    digest = hashlib.sha256()
    for source_path in sorted(SOURCE_ROOT.rglob("*.move")):
        relative = source_path.relative_to(REPO_ROOT).as_posix()
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(source_path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def function_source_sha256() -> dict[str, str]:
    """Hash each complete Move function body for certificate source binding."""
    hashes: dict[str, str] = {}
    for source_path in sorted(SOURCE_ROOT.rglob("*.move")):
        relative = source_path.relative_to(REPO_ROOT).as_posix()
        lines = source_path.read_text().splitlines(keepends=True)
        starts = [
            (index, match.group(1))
            for index, line in enumerate(lines)
            if (match := FUNCTION_RE.search(line))
        ]
        for position, (start, function) in enumerate(starts):
            end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
            digest = hashlib.sha256("".join(lines[start:end]).encode()).hexdigest()
            hashes[f"{relative}::{function}"] = digest
    return hashes


def build_inventory() -> dict[str, Any]:
    candidates = scan_candidates()
    source_digest = source_tree_sha256()
    function_hashes = function_source_sha256()
    records = [
        {
            **asdict(candidate),
            "site_id": candidate.site_id,
            "function_id": candidate.function_id,
            "function_source_sha256": function_hashes.get(
                candidate.function_id
            ),
            "classification": FUNCTION_CLASSIFICATION.get(
                candidate.function_id
            ),
        }
        for candidate in candidates
    ]
    observed_functions = {candidate.function_id for candidate in candidates}
    unknown = [
        record for record in records if record["classification"] is None
    ]
    stale = sorted(set(FUNCTION_CLASSIFICATION) - observed_functions)
    return {
        "schema": "predict_money_math_inventory_v1",
        "source_tree_sha256": source_digest,
        "expected_source_tree_sha256": EXPECTED_SOURCE_TREE_SHA256,
        "source_tree_matches_baseline": (
            source_digest == EXPECTED_SOURCE_TREE_SHA256
        ),
        "candidate_pattern": CANDIDATE_RE.pattern,
        "records": records,
        "counts": dict(
            sorted(
                Counter(
                    record["classification"] or "unclassified"
                    for record in records
                ).items()
            )
        ),
        "unclassified_candidates": unknown,
        "stale_function_classifications": stale,
        "complete_for_candidate_pattern": (
            not unknown
            and not stale
            and source_digest == EXPECTED_SOURCE_TREE_SHA256
        ),
    }


def main() -> None:
    print(json.dumps(build_inventory(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
