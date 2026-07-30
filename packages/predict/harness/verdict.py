"""Pure contract-failure classification for harness traces and VM artifacts."""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

GUARD_MODULES = {
    "pricing",
    "expiry_market",
    "strike_exposure",
    "strike_exposure_config",
    "predict_account",
    "pricing_config",
    "config_constants",
    "protocol_config",
    "registry",
    "market_manager",
    "pyth_feed",
    "block_scholes_store",
    "verify",
}
INVARIANT_MODULES = {
    "math",
    "i64",
    "plp",
    "pool_accounting",
    "strike_payout_tree",
    "lp_book",
    "expiry_cash",
    "liquidation_book",
    "range_codec",
    "account",
    "account_registry",
}
EXPECTED_CODES = {
    "liquidation_book:4",
    "strike_payout_tree:1",
    "lp_book:0",
    "lp_book:1",
    "lp_book:2",
    "lp_book:3",
}
TRANSIENT_MARKERS = (
    "rpc",
    "timeout",
    "network",
    "fetch",
    "econn",
    "socket",
    "validators",
    "non-retriable",
    "equivocat",
    "rejected as invalid",
    "balance of gas object",
    "http",
    "rate limit",
    "pyth history",
    "no price for feed",
    "expected ts",
)
MOVE_ABORT = re.compile(r"^[a-z_][a-z0-9_]*:\d+$")


def is_transient(tag: str) -> bool:
    return not MOVE_ABORT.match(tag) and any(
        marker in tag.lower() for marker in TRANSIENT_MARKERS
    )


def classify_failures(
    failures: list[dict],
) -> tuple[Counter[str], Counter[str], list[str]]:
    expected: Counter[str] = Counter()
    transient: Counter[str] = Counter()
    flagged: list[str] = []
    for record in failures:
        tag = str(record.get("tag", ""))
        module = tag.split(":")[0] if ":" in tag else ""
        if tag in EXPECTED_CODES:
            expected[tag] += 1
        elif module in INVARIANT_MODULES:
            flagged.append(tag)
        elif module in GUARD_MODULES:
            expected[tag] += 1
        elif MOVE_ABORT.match(tag):
            flagged.append(tag)
        elif is_transient(tag):
            transient[tag[:40]] += 1
        else:
            flagged.append(tag)
    return expected, transient, flagged


def _error_message(error: object) -> str:
    if isinstance(error, str):
        return error
    if isinstance(error, dict):
        message = error.get("message")
        if isinstance(message, str):
            return message
        return json.dumps(error, sort_keys=True)
    return str(error) if error else ""


def vm_summary(source: str, fallback: object) -> str:
    status_match = re.search(r"status (\w+)", source)
    message_match = re.search(
        r"and message (.+?)(?: at code offset| in function|$)",
        source,
    )
    parts = [
        status_match.group(1) if status_match else None,
        message_match.group(1).strip() if message_match else None,
    ]
    return (" — ".join(part for part in parts if part) or _error_message(fallback))[:200]


def vm_errors(instance: Path) -> Counter[str]:
    errors: Counter[str] = Counter()
    artifacts = instance / "artifacts" / "failed_transactions"
    if not artifacts.is_dir():
        return errors
    for path in sorted(artifacts.glob("*.json")):
        try:
            artifact = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        dry_run = artifact.get("dry_run") or {}
        status = (dry_run.get("effects") or {}).get("status") or {}
        source = dry_run.get("executionErrorSource") or ""
        is_abort = (
            "status ABORTED" in source
            or "MoveAbort" in str(status.get("error") or "")
        )
        summary = vm_summary(source, status.get("error") or "")
        if summary and not is_abort:
            errors[summary] += 1
    return errors


def declared_terminals(records: list[dict]) -> list[str]:
    terminals: list[str] = []
    for record in records:
        if record.get("type") == "expect":
            terminals.extend(str(value) for value in (record.get("terminal") or []))
    return terminals
