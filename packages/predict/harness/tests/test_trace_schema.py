"""The TypeScript actors emit trace records; `analyze` validates them.

Nothing else connects the two. `strategy.ts` renaming a field is invisible to
`tsc`, to the Move suites, and to every other Python test, but it makes
`_validate_trace_record` reject the record and fails the whole campaign at
analysis time on an otherwise healthy run. This test reads the emitting
TypeScript and checks each trace literal against the schema that will judge it.
"""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from harness import analyze  # noqa: E402

_HARNESS_TS = Path(__file__).resolve().parents[1] / "ts"
_EMITTERS = [
    _HARNESS_TS / "strategy.ts",
    _HARNESS_TS / "traderService.ts",
    *sorted((_HARNESS_TS / "strategies").glob("*.ts")),
]
# `appendTrace` stamps these onto every record; the strategy runner adds `strategy`.
_INJECTED = {"schema", "ts", "strategy"}


def _split_top_level(body: str) -> list[str]:
    """Split an object literal's body on commas that are not nested."""
    parts, depth, current = [], 0, []
    for char in body:
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        if char == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
    parts.append("".join(current))
    return [p.strip() for p in parts if p.strip()]


def _trace_literals(source: str):
    """Yield (type, keys, has_spread) for each `trace({...})` object literal."""
    for match in re.finditer(r"\btrace\(\{", source):
        start = match.end() - 1
        depth = 0
        for index in range(start, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    body = source[start + 1 : index]
                    break
        else:
            raise AssertionError("unbalanced trace literal")

        keys, has_spread = set(), False
        trace_type = None
        for part in _split_top_level(body):
            if part.startswith("..."):
                has_spread = True
                continue
            key_match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:?", part)
            if not key_match:
                continue
            key = key_match.group(1)
            keys.add(key)
            if key == "type":
                literal = re.match(r'^type\s*:\s*"([^"]+)"', part)
                if literal:
                    trace_type = literal.group(1)
        if trace_type is not None:
            yield trace_type, keys, has_spread


class TraceSchemaMatchesEmitters(unittest.TestCase):
    def test_every_emitted_trace_type_has_a_schema(self):
        for path in _EMITTERS:
            for trace_type, _keys, _spread in _trace_literals(path.read_text()):
                self.assertIn(
                    trace_type,
                    analyze._TRADER_TRACE_SCHEMAS,
                    f"{path.name} emits trace type {trace_type!r} with no schema in analyze.py",
                )

    def test_emitted_fields_are_accepted_by_the_schema(self):
        for path in _EMITTERS:
            for trace_type, keys, has_spread in _trace_literals(path.read_text()):
                required, optional = analyze._TRADER_TRACE_SCHEMAS[trace_type]
                allowed = required | optional | analyze._BASE_TRACE_FIELDS | _INJECTED
                unknown = sorted(keys - allowed)
                self.assertEqual(
                    unknown,
                    [],
                    f"{path.name} {trace_type} emits field(s) the schema rejects: {unknown}",
                )
                if has_spread:
                    # A spread can only add fields, so `missing` is not decidable here.
                    continue
                missing = sorted(required - keys - _INJECTED)
                self.assertEqual(
                    missing,
                    [],
                    f"{path.name} {trace_type} omits schema-required field(s): {missing}",
                )

    def test_a_representative_mint_record_validates(self):
        # The exact shape `strategy.ts` writes, with the fields `appendTrace` stamps on.
        record = {
            "schema": 1,
            "ts": 0,
            "strategy": "mint-only",
            "type": "mint",
            "market": "0xabc",
            "direction": "UP",
            "moneyness": 1.0,
            "prob": 0.5,
            "premium": 12.5,
            "gas": 1000,
        }
        analyze._validate_trace_record(record, "trader", "test")

    def test_a_leverage_era_mint_record_is_rejected(self):
        record = {
            "schema": 1,
            "ts": 0,
            "strategy": "mint-only",
            "type": "mint",
            "market": "0xabc",
            "direction": "UP",
            "moneyness": 1.0,
            "prob": 0.5,
            "leverage": 2.0,
            "netPremium": 12.5,
            "gas": 1000,
        }
        with self.assertRaises(ValueError):
            analyze._validate_trace_record(record, "trader", "test")


if __name__ == "__main__":
    unittest.main()
