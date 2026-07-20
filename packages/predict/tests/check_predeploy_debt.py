#!/usr/bin/env python3
"""Require the clean-room rebuild's exact transitional predeploy debt set."""

from __future__ import annotations

import csv
import importlib.util
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

TESTS = Path(__file__).resolve().parent
PREDICT = TESTS.parent
PREDEPLOY = PREDICT / "predeploy"
KNOWN_RED_MANIFEST = TESTS / "known_red_manifest.csv"
KNOWN_RED_FIELDS = ("test", "open_item", "phase", "summary")
QUALIFIED_TEST = re.compile(
    r"^deepbook_predict::(?P<module>scope_[a-z0-9_]+_tests)::(?P<function>[a-z][a-z0-9_]*)$"
)
OPEN_ITEM_HEADING = re.compile(r"^### (?P<item>[A-Z]{1,2}-\d+):", re.MULTILINE)
OPEN_ITEM_TEST_FIELD = re.compile(
    r"^\*\*(?P<label>Known RED test|Deferred test):\*\*\s*`(?P<test>[^`]+)`",
    re.MULTILINE,
)
MOVE_TEST_FAILURE = re.compile(r"^\[\s*FAIL\s*\]\s+(?P<test>[a-z0-9_:]+)\s*$", re.MULTILINE)
MOVE_TEST_RESULT = re.compile(
    r"^Test result: (?P<status>OK|FAILED)\. Total tests: (?P<total>\d+); "
    r"passed: (?P<passed>\d+); failed: (?P<failed>\d+)\s*$",
    re.MULTILINE,
)


@dataclass(frozen=True)
class KnownRed:
    test: str
    open_item: str
    phase: str
    summary: str

EXPECTED_MISSING_PINS = {
    ("RP-1", "finish_flush_with_zero_pool_nav_and_empty_queues_succeeds"),
    ("RP-1", "finish_flush_with_low_plp_price_and_empty_queues_succeeds"),
    ("RP-1", "finish_flush_with_high_plp_price_and_empty_queues_succeeds"),
    ("RP-3", "finish_flush_with_zero_pool_nav_and_empty_queues_succeeds"),
    ("RP-4", "try_settle_without_exact_expiry_spot_returns_false_without_mutation"),
    ("RP-4", "expired_unsettled_standalone_rebalance_moves_no_cash"),
    ("RP-4", "explicit_settlement_unblocks_pool_valuation_sweep"),
    ("RP-11", "rebate_claim_requires_settled_market"),
    ("RP-11", "rebate_claim_with_open_position_aborts"),
    ("RP-11", "deauthorized_predict_app_blocks_permissionless_rebate_claim"),
    ("RP-11", "owner_auth_rebate_claim_survives_predict_app_deauth"),
    ("RP-11", "prepare_settled_loss_with_inactive_rebate_stake"),
    ("RP-15", "current_nav_rejects_non_monotone_active_book_surface"),
}

EXPECTED_WARNINGS = {
    "response-policies.md: names file `pool_valuation_flow_tests.move` not found under packages/predict/ or .claude/",
    "response-policies.md: names file `settlement_flow_tests.move` not found under packages/predict/ or .claude/",
    "response-policies.md: names file `current_nav_flow_tests.move` not found under packages/predict/ or .claude/",
}
EXPECTED_UNCATALOGUED_POLICIES = {"RP-6", "RP-8", "RP-13"}
EXPECTED_NON_UNIT_POLICIES = {"RP-10"}
EXPECTED_UNREACHABLE_PIN_BRANCHES = {
    ("RP-2", "priced_supply_that_rounds_to_zero_shares_refunds"),
    ("RP-2", "priced_withdraw_that_rounds_to_zero_payout_refunds"),
}
EXPECTED_ACCUMULATOR_DELIVERY_GAPS = {
    ("RP-2", "non_executable_supply_refunds_spend_supply_budget"),
    ("RP-2", "non_executable_withdraw_refunds_spend_withdraw_budget"),
    ("RP-12", "supply_limit_expires_after_three_misses"),
    ("RP-12", "withdraw_limit_expires_after_three_misses"),
}


def load_predeploy_check() -> ModuleType:
    path = PREDEPLOY / "check.py"
    spec = importlib.util.spec_from_file_location("predict_predeploy_check", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_known_red_manifest(path: Path = KNOWN_RED_MANIFEST) -> tuple[KnownRed, ...]:
    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        if tuple(reader.fieldnames or ()) != KNOWN_RED_FIELDS:
            raise ValueError(
                f"known-RED manifest fields must be {KNOWN_RED_FIELDS}, got {reader.fieldnames}"
            )
        return tuple(KnownRed(**row) for row in reader)


def open_item_test_fields(text: str) -> tuple[dict[str, str], dict[str, str]]:
    known_red = {}
    deferred = {}
    headings = list(OPEN_ITEM_HEADING.finditer(text))
    for index, heading in enumerate(headings):
        end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
        item = heading.group("item")
        for field in OPEN_ITEM_TEST_FIELD.finditer(text, heading.end(), end):
            target = known_red if field.group("label") == "Known RED test" else deferred
            if item in target:
                raise ValueError(f"open item {item} repeats {field.group('label')}")
            target[item] = field.group("test")
    return known_red, deferred


def plain_test_catalog() -> set[str]:
    check = load_predeploy_check()
    catalog = set()
    for path in TESTS.rglob("*.move"):
        catalog.update(plain_tests_from_source(path.read_text(), check))
    return catalog


def plain_tests_from_source(source: str, check: ModuleType | None = None) -> set[str]:
    check = check or load_predeploy_check()
    source = check.source_without_comments_and_literals(source)
    module = re.search(
        r"\bmodule\s+(?P<module>[a-z][a-z0-9_]*::[a-z][a-z0-9_]*)\s*;",
        source,
    )
    if not module:
        return set()
    tests = set()
    for function in check.ATTRIBUTED_FUNCTION.finditer(source):
        attributes = function.group("attributes")
        if not re.search(r"\btest\b", attributes):
            continue
        if re.search(r"\b(?:random_test|expected_failure)\b", attributes):
            continue
        tests.add(f"{module.group('module')}::{function.group('name')}")
    return tests


def known_red_bijection_errors(
    rows: tuple[KnownRed, ...],
    open_item_known_red: dict[str, str],
    plain_tests: set[str],
) -> list[str]:
    errors = []
    tests = [row.test for row in rows]
    items = [row.open_item for row in rows]
    for test in sorted({test for test in tests if tests.count(test) > 1}):
        errors.append(f"known-RED manifest repeats test: {test}")
    for item in sorted({item for item in items if items.count(item) > 1}):
        errors.append(f"known-RED manifest repeats open item: {item}")
    for row in rows:
        match = QUALIFIED_TEST.fullmatch(row.test)
        if not match:
            errors.append(f"known-RED manifest test is not fully qualified: {row.test}")
        if not re.fullmatch(r"[A-Z]{1,2}-\d+", row.open_item):
            errors.append(f"known-RED manifest has invalid open item id: {row.open_item}")
        if not row.phase.strip() or not row.summary.strip():
            errors.append(f"known-RED manifest row lacks phase or summary: {row.test}")
        if row.test not in plain_tests:
            errors.append(f"known-RED manifest has no live plain #[test]: {row.test}")
        linked = open_item_known_red.get(row.open_item)
        if linked != row.test:
            errors.append(
                f"known-RED manifest/open-item mismatch: {row.open_item} "
                f"manifest={row.test} open_item={linked}"
            )
    manifest_by_item = {row.open_item: row.test for row in rows}
    for item, test in sorted(open_item_known_red.items()):
        if manifest_by_item.get(item) != test:
            errors.append(f"open item known-RED marker has no matching manifest row: {item}::{test}")
    return errors


def current_known_red_errors() -> list[str]:
    try:
        rows = load_known_red_manifest()
        known_red, _ = open_item_test_fields((PREDEPLOY / "open-items.md").read_text())
    except (OSError, ValueError) as error:
        return [str(error)]
    return known_red_bijection_errors(rows, known_red, plain_test_catalog())


def move_test_failures(output: str) -> set[str]:
    return {match.group("test") for match in MOVE_TEST_FAILURE.finditer(output)}


def known_red_acceptance_errors(
    returncode: int,
    output: str,
    expected: set[str],
) -> list[str]:
    errors = []
    results = list(MOVE_TEST_RESULT.finditer(output))
    if len(results) != 1:
        if not results:
            return ["Move test output has no parseable terminal test result"]
        return [f"Move test output has {len(results)} terminal test results"]
    result = results[0]
    total = int(result.group("total"))
    passed = int(result.group("passed"))
    failed = int(result.group("failed"))
    if total == 0:
        errors.append("Move test ran zero tests")
    if passed + failed != total:
        errors.append(
            f"Move test totals are inconsistent: total={total} passed={passed} failed={failed}"
        )
    if (result.group("status") == "FAILED") != (failed > 0):
        errors.append(
            f"Move test status disagrees with failure total: status={result.group('status')} "
            f"failed={failed}"
        )
    failures = [match.group("test") for match in MOVE_TEST_FAILURE.finditer(output)]
    if len(failures) != failed:
        errors.append(
            f"Move test reported {failed} failures but emitted {len(failures)} failure rows"
        )
    if len(failures) != len(set(failures)):
        errors.append("Move test emitted duplicate failure rows")
    actual = set(failures)
    for test in sorted(actual - expected):
        errors.append(f"unlisted Move test failure: {test}")
    for test in sorted(expected - actual):
        errors.append(f"stale known-RED row did not fail: {test}")
    if failed and returncode == 0:
        errors.append("Move test returned success despite reported failures")
    if not failed and returncode != 0:
        errors.append("Move test returned failure despite a passing terminal result")
    return errors


def registered_policy_debt(
    register: str,
) -> tuple[set[tuple[str, str]], set[str], set[str]]:
    check = load_predeploy_check()
    pins = set()
    uncatalogued = set()
    non_unit = set()
    for entry in re.split(r"^## ", register, flags=re.MULTILINE)[1:]:
        title = entry.splitlines()[0]
        policy = re.match(r"(RP-\d+):", title)
        if not policy:
            continue
        block = re.search(
            r"\*\*Pinning tests[^*]*\*\*(.*?)(?=\n- \*\*|\n## |\Z)",
            entry,
            re.DOTALL,
        )
        if not block:
            continue
        body = block.group(1)
        normalized_body = " ".join(body.lower().split())
        if "not yet catalogued" in normalized_body:
            if "not pinnable in move unit tests by nature" in normalized_body:
                non_unit.add(policy.group(1))
            else:
                uncatalogued.add(policy.group(1))
            continue
        tokens = check.pinning_test_functions_from_block(body)
        if "untested" in normalized_body:
            uncatalogued.add(policy.group(1))
        for token in tokens:
            pins.add((policy.group(1), token))
    return pins, uncatalogued, non_unit


def registered_pins(register: str) -> set[tuple[str, str]]:
    return registered_policy_debt(register)[0]


def pin_gap_manifest_errors(
    label: str,
    gaps: set[tuple[str, str]],
    pins: set[tuple[str, str]],
    executable_functions: set[str],
) -> list[str]:
    errors = []
    for policy, function in sorted(gaps):
        if (policy, function) not in pins:
            errors.append(f"{label} manifest names an unregistered pin: {policy}::{function}")
        if function not in executable_functions:
            errors.append(f"{label} manifest has no executable boundary test: {policy}::{function}")
    return errors


def current_policy_debt() -> tuple[set[tuple[str, str]], set[str], set[str]]:
    register = (PREDEPLOY / "response-policies.md").read_text()
    pins, uncatalogued, non_unit = registered_policy_debt(register)
    check = load_predeploy_check()
    functions = set()
    for path in TESTS.rglob("*.move"):
        functions.update(check.executable_test_functions_from_source(path.read_text()))
    missing = {(policy, function) for policy, function in pins if function not in functions}
    return missing, uncatalogued, non_unit


def current_pin_gap_manifest_errors() -> list[str]:
    register = (PREDEPLOY / "response-policies.md").read_text()
    pins = registered_pins(register)
    check = load_predeploy_check()
    functions = set()
    for path in TESTS.rglob("*.move"):
        functions.update(check.executable_test_functions_from_source(path.read_text()))
    errors = pin_gap_manifest_errors(
        "unreachable branch",
        EXPECTED_UNREACHABLE_PIN_BRANCHES,
        pins,
        functions,
    )
    errors.extend(
        pin_gap_manifest_errors(
            "accumulator delivery gap",
            EXPECTED_ACCUMULATOR_DELIVERY_GAPS,
            pins,
            functions,
        )
    )
    return errors


def current_missing_pins() -> set[tuple[str, str]]:
    return current_policy_debt()[0]


def classify_pin_checker_findings(
    findings: list[str],
    missing_pins: set[tuple[str, str]],
) -> list[str]:
    errors = []
    reported_missing = set()
    for finding in findings:
        match = re.search(
            r"entry '(RP-\d+):.*' pins test `([^`]+)` but no executable",
            finding,
        )
        if match:
            reported_missing.add((match.group(1), match.group(2)))
        else:
            errors.append(finding)
    if reported_missing != missing_pins:
        errors.append(
            "predeploy pin parser disagrees with executable debt: "
            f"checker_only={sorted(reported_missing - missing_pins)} "
            f"debt_only={sorted(missing_pins - reported_missing)}"
        )
    return errors


def current_non_pin_findings(
    missing_pins: set[tuple[str, str]],
) -> tuple[list[str], list[str]]:
    check = load_predeploy_check()
    errors, warnings = check.run_checks()
    return classify_pin_checker_findings(errors, missing_pins), warnings


def debt_errors(
    missing_pins: set[tuple[str, str]],
    uncatalogued_policies: set[str],
    non_unit_policies: set[str],
    non_pin_errors: list[str],
    warnings: set[str],
) -> list[str]:
    errors = [f"unexpected predeploy fatal: {error}" for error in non_pin_errors]
    for policy, function in sorted(missing_pins - EXPECTED_MISSING_PINS):
        errors.append(f"unexpected missing pin: {policy}::{function}")
    for policy, function in sorted(EXPECTED_MISSING_PINS - missing_pins):
        errors.append(f"resolved pin remains in expected debt: {policy}::{function}")
    for policy in sorted(uncatalogued_policies - EXPECTED_UNCATALOGUED_POLICIES):
        errors.append(f"unexpected uncatalogued policy: {policy}")
    for policy in sorted(EXPECTED_UNCATALOGUED_POLICIES - uncatalogued_policies):
        errors.append(f"resolved policy remains in expected uncatalogued debt: {policy}")
    for policy in sorted(non_unit_policies - EXPECTED_NON_UNIT_POLICIES):
        errors.append(f"unexpected non-unit policy exemption: {policy}")
    for policy in sorted(EXPECTED_NON_UNIT_POLICIES - non_unit_policies):
        errors.append(f"expected non-unit policy exemption changed or disappeared: {policy}")
    for warning in sorted(warnings - EXPECTED_WARNINGS):
        errors.append(f"unexpected predeploy warning: {warning}")
    for warning in sorted(EXPECTED_WARNINGS - warnings):
        errors.append(f"resolved warning remains in expected debt: {warning}")
    return errors


def main() -> int:
    missing_pins, uncatalogued_policies, non_unit_policies = current_policy_debt()
    non_pin_errors, warnings = current_non_pin_findings(missing_pins)
    errors = debt_errors(
        missing_pins,
        uncatalogued_policies,
        non_unit_policies,
        non_pin_errors,
        set(warnings),
    )
    errors.extend(current_pin_gap_manifest_errors())
    errors.extend(current_known_red_errors())
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print(f"Predict predeploy debt: {len(errors)} error(s)")
        return 1
    print(
        "Predict predeploy debt: ok "
        f"({len(missing_pins)} missing registered pin obligations, "
        f"{len(EXPECTED_UNREACHABLE_PIN_BRANCHES)} unreachable registered branch obligations, "
        f"{len(EXPECTED_ACCUMULATOR_DELIVERY_GAPS)} accumulator delivery obligations, "
        f"{len(uncatalogued_policies)} uncatalogued policies, "
        f"{len(non_unit_policies)} non-unit policy exemption, {len(warnings)} warnings)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
