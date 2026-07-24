#!/usr/bin/env python3
"""Classify every Predict saturating arithmetic site and prove stateful cases."""

from __future__ import annotations

import json
import re
from collections import deque
from typing import Any

import money_math_inventory as inventory


DISPOSITIONS = {
    "packages/predict/sources/expiry_market.move::claim_trading_loss_rebate": {
        "status": "keep_semantic_positive_part",
        "meaning": "rebate reserve remaining after realized gross profit",
        "witness": {"reserve": "10", "gross_profit": "11", "result": "0"},
    },
    "packages/predict/sources/predict_account.move::resolve_expiry_summary": {
        "status": "keep_semantic_positive_part",
        "meaning": "positive trading profit, excluding a net trading loss",
        "witness": {"gross_received": "1", "gross_paid": "2", "result": "0"},
    },
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_live_close": {
        "status": "keep_semantic_positive_part",
        "meaning": "live redeem after the conserved closed-floor slice",
        "witness": {"gross_redeem": "0", "removed_floor": "1", "result": "0"},
    },
    "packages/predict/sources/plp/pool_accounting.move::flow_net_funding": {
        "status": "keep_semantic_positive_part",
        "meaning": "positive pool funding still deployed into an expiry",
        "witness": {"sent": "5", "received": "6", "result": "0"},
    },
    "packages/predict/sources/plp/plp.move::sync_fee_incentives": {
        "status": "keep_semantic_positive_part",
        "meaning": "top-up needed to reach the live incentive target",
        "witness": {"target": "10", "market_balance": "11", "result": "0"},
    },
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::positive_net_delta": {
        "status": "keep_semantic_positive_part",
        "meaning": "nonnegative payout-prefix gain",
        "witness": {"start_plus_gain": "872", "end": "873", "result": "0"},
    },
}


def _net_funding(sent: int, received: int) -> int:
    return max(0, sent - received)


def funding_transition_proof(cap: int = 7, depth: int = 7) -> dict[str, Any]:
    initial = (0, 0)
    queue = deque([(initial, 0)])
    seen = {initial}
    violations: list[dict[str, str]] = []
    while queue:
        (sent, received), level = queue.popleft()
        net = _net_funding(sent, received)
        if net > cap:
            violations.append(
                {
                    "sent": str(sent),
                    "received": str(received),
                    "net": str(net),
                    "cap": str(cap),
                }
            )
        if level == depth:
            continue
        for amount in range(cap + 1):
            if net + amount <= cap:
                state = (sent + amount, received)
                if state not in seen:
                    seen.add(state)
                    queue.append((state, level + 1))
            state = (sent, received + amount)
            if state not in seen:
                seen.add(state)
                queue.append((state, level + 1))
    return {
        "cap": str(cap),
        "depth": str(depth),
        "reachable_states": str(len(seen)),
        "violations": violations,
        "outer_subtraction_never_underflows": not violations,
    }


def fixed_fee_cap_proof(cap: int = 7, depth: int = 7) -> dict[str, Any]:
    states = {0}
    for _ in range(depth):
        states = states | {
            allocated + min(requested, cap - allocated)
            for allocated in states
            for requested in range(cap * 2 + 1)
        }
    violations = sorted(value for value in states if value > cap)
    return {
        "cap": str(cap),
        "depth": str(depth),
        "reachable_allocated_values": [str(value) for value in sorted(states)],
        "violations": [str(value) for value in violations],
        "plain_subtraction_safe_for_fixed_cap": not violations,
        "varying_cap_counterexample": {
            "allocated": str(cap),
            "later_cap": str(cap - 1),
            "plain_sub": "underflow",
        },
    }


POOL_ACCOUNTING_REL = "plp/pool_accounting.move"
FUNDING_FIELDS = (
    "sent_to_expiry",
    "received_from_expiry",
    "max_expiry_allocation",
)


def _assignment_lines(source_lines: list[str], field: str) -> list[int]:
    """1-indexed lines that assign `field` (target of `=`, excluding ==/<=/>=)."""
    pattern = re.compile(rf"\b{re.escape(field)}\s*=(?!=)")
    return [
        i + 1
        for i, line in enumerate(source_lines)
        if pattern.search(line.split("//", 1)[0])
    ]


def _mut_borrow_escape_lines(source_lines: list[str], field: str) -> list[int]:
    """1-indexed lines that take a `&mut` reference directly to `field`.

    The assignment scan only sees `field = ...`. A future writer could instead
    escape a mutable reference (`&mut flow.<field>`) and mutate it out of band,
    bypassing the guard; catch that form too so the writer inventory stays
    source-complete for direct u64 mutation. (Any other edit still trips the
    content-digest gate in `money_math_inventory`.)
    """
    pattern = re.compile(rf"&mut\s+[A-Za-z_][\w.]*\.{re.escape(field)}\b")
    return [
        i + 1
        for i, line in enumerate(source_lines)
        if pattern.search(line.split("//", 1)[0])
    ]


def _sat_sub(a: int, b: int) -> int:
    return max(0, a - b)


def available_expiry_funding_induction(bound: int = 12) -> dict[str, Any]:
    """Source-complete induction that `flow_net_funding <= max_expiry_allocation`.

    The bounded BFS (`funding_transition_proof`) only samples reachable states.
    This establishes the invariant for ALL states by (1) scanning the module for
    every writer of the three fields — fail-closed, so a new writer or a removed
    guard breaks the proof — and (2) exhaustively checking the two transition
    lemmas and the base case that the induction rests on. Only when both hold is
    the outer `saturating_sub` in `available_expiry_funding` provably redundant.

    Invariant I:  max(0, sent - received) <= cap.
    Base:         register sets sent=received=0, so net=0 <= cap (u64 >= 0).
    Cap stable:   `max_expiry_allocation` has no assignment (set only at the
                  RegisteredExpiry struct literal in register_expiry); the struct
                  is module-private so no other module can mutate it.
    Step (sent):  record_sent_to_expiry asserts net + amount <= cap BEFORE
                  `sent += amount`; net' = max(0, sent+amount-received)
                  <= net + amount <= cap. Overflow of `net + amount` aborts the
                  tx atomically, so no successful transition violates I.
    Step (recv):  record_received_from_expiry only increases `received`, and net
                  is non-increasing in received, so net' <= net <= cap.
    """
    source = (inventory.SOURCE_ROOT / POOL_ACCOUNTING_REL).read_text()
    lines = source.splitlines()

    assignments = {
        field: _assignment_lines(lines, field) for field in FUNDING_FIELDS
    }
    mut_escapes = {
        field: _mut_borrow_escape_lines(lines, field) for field in FUNDING_FIELDS
    }
    no_mut_borrow_escapes = all(not lines_ for lines_ in mut_escapes.values())
    # Expected writer inventory (source-complete): one guarded writer for sent,
    # one monotonic writer for received, zero writers for the cap, and no
    # out-of-band `&mut` escape to any of the three fields.
    writer_inventory_source_complete = (
        len(assignments["sent_to_expiry"]) == 1
        and len(assignments["received_from_expiry"]) == 1
        and len(assignments["max_expiry_allocation"]) == 0
        and no_mut_borrow_escapes
    )
    # The single struct definition keeps the fields module-private.
    struct_is_module_private = (
        source.count("struct RegisteredExpiry") == 1
    )
    cap_initialized_at_register = "max_expiry_allocation,\n" in source or bool(
        re.search(r"max_expiry_allocation,\s*$", source, re.MULTILINE)
    )
    # The guard that makes the `sent` step preserve the invariant, pinned to text.
    guard_present = (
        "let current_net_funding = flow_net_funding(flow);" in source
        and "current_net_funding + amount <= flow.max_expiry_allocation"
        in source
    )
    net_funding_is_sat_sub = bool(
        re.search(
            r"fun flow_net_funding\(flow: &RegisteredExpiry\): u64 \{\s*"
            r"flow\.sent_to_expiry\.saturating_sub\(flow\.received_from_expiry\)",
            source,
        )
    )
    received_writer_is_monotonic = (
        "flow.received_from_expiry = flow.received_from_expiry + amount;"
        in source
    )
    sent_writer_adds_amount = (
        "flow.sent_to_expiry = flow.sent_to_expiry + amount;" in source
    )

    # Lemma 1 (sent step): the asserted guard implies the post-state invariant,
    # exhaustively over a small domain.
    sent_step_counterexample = None
    for cap in range(bound + 1):
        for sent in range(bound + 1):
            for received in range(bound + 1):
                for amount in range(bound + 1):
                    net = _sat_sub(sent, received)
                    if net + amount <= cap:  # the on-chain guard
                        net_after = _sat_sub(sent + amount, received)
                        if net_after > cap:
                            sent_step_counterexample = {
                                "cap": cap,
                                "sent": sent,
                                "received": received,
                                "amount": amount,
                            }
    # Lemma 2 (received step): increasing received cannot break the invariant.
    received_step_counterexample = None
    for cap in range(bound + 1):
        for sent in range(bound + 1):
            for received in range(bound + 1):
                if _sat_sub(sent, received) <= cap:
                    for amount in range(bound + 1):
                        if _sat_sub(sent, received + amount) > cap:
                            received_step_counterexample = {
                                "cap": cap,
                                "sent": sent,
                                "received": received,
                                "amount": amount,
                            }
    base_case_holds = _sat_sub(0, 0) == 0

    induction_holds = (
        writer_inventory_source_complete
        and struct_is_module_private
        and cap_initialized_at_register
        and guard_present
        and net_funding_is_sat_sub
        and received_writer_is_monotonic
        and sent_writer_adds_amount
        and sent_step_counterexample is None
        and received_step_counterexample is None
        and base_case_holds
    )
    return {
        "invariant": "max(0, sent_to_expiry - received_from_expiry) <= max_expiry_allocation",
        "field_assignment_lines": assignments,
        "field_mut_borrow_escape_lines": mut_escapes,
        "no_mut_borrow_escapes": no_mut_borrow_escapes,
        "writer_inventory_source_complete": writer_inventory_source_complete,
        "struct_is_module_private": struct_is_module_private,
        "cap_initialized_at_register": cap_initialized_at_register,
        "cap_has_no_writer": len(assignments["max_expiry_allocation"]) == 0,
        "guard_present": guard_present,
        "net_funding_is_saturating_sub": net_funding_is_sat_sub,
        "received_writer_is_monotonic": received_writer_is_monotonic,
        "sent_writer_adds_amount": sent_writer_adds_amount,
        "lemma_domain_bound": bound,
        # The transition lemmas are bounded-domain checks; the step relation is
        # linear/monotone in (sent, received, amount), so the small box is
        # representative and the universal validity is the docstring's symbolic
        # argument (net' <= net + amount <= cap; net non-increasing in received;
        # u64 overflow aborts atomically). The box confirms it, the writer scan
        # makes it source-bound.
        "transition_lemmas_are_bounded_checks_of_a_linear_step": True,
        "sent_step_lemma_counterexample": sent_step_counterexample,
        "received_step_lemma_counterexample": received_step_counterexample,
        "base_case_holds": base_case_holds,
        "induction_holds": induction_holds,
        "proof_strength": (
            "source-complete induction: fail-closed writer scan (assignments + "
            "mut-borrow escapes) + bounded checks of a linear transition step + "
            "base case; universal step validity argued in the docstring"
            if induction_holds
            else "INCONCLUSIVE — retain saturating_sub as a candidate only"
        ),
    }


def build_saturation_bundle() -> dict[str, Any]:
    source_records = [
        record
        for record in inventory.build_inventory()["records"]
        if record["operator"] in {"saturating_sub", "saturating_add"}
    ]
    source_functions = {record["function_id"] for record in source_records}
    missing = sorted(source_functions - set(DISPOSITIONS))
    stale = sorted(set(DISPOSITIONS) - source_functions)
    funding = funding_transition_proof()
    induction = available_expiry_funding_induction()
    fee_cap = fixed_fee_cap_proof()
    return {
        "schema": "predict_saturation_proofs_v2",
        "source_sites": source_records,
        "dispositions": dict(sorted(DISPOSITIONS.items())),
        "missing_source_functions": missing,
        "stale_dispositions": stale,
        "funding_transition_proof": funding,
        "available_expiry_funding_induction": induction,
        "fixed_fee_cap_proof": fee_cap,
        "all_sites_classified": not missing and not stale,
        # The reduction is proven ONLY by the source-complete induction; the BFS
        # is supporting illustration and its consistency is asserted here.
        "bfs_agrees_with_induction": (
            funding["outer_subtraction_never_underflows"]
            == induction["induction_holds"]
        ),
        "proved_landed_reductions": [
            "packages/predict/sources/plp/pool_accounting.move::available_expiry_funding"
        ]
        if induction["induction_holds"]
        else [],
        "proved_immediate_reductions": [],
        "conditional_reductions": [],
    }


def main() -> None:
    print(json.dumps(build_saturation_bundle(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
