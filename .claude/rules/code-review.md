---
paths:
  - "packages/**/*.move"
---

# Code Review Patterns

Accumulated from real PR review feedback. Update this file when reviewers catch new patterns.

## Comments and Documentation

- Math comments must match the actual function being called. If the code calls `mul_div_round_down(a, b, c)`, write `a * b / c`, not an invented two-step `mul(a, div(b, c))` that doesn't correspond to any real function.
- Use `ceil(a * b / c)` for `mul_div_round_up` calls to make the rounding direction visible.
- Don't write intermediate scaled values in comments (e.g., `div(1, 1_000_001) = 999`). Just write the integer formula and result.

## Naming

- Test names must match what the test actually verifies. If a test checks `oracle_ids` is empty, don't name it `init_registry_has_no_predict_id`.
- Error constant names must cover all cases they guard against. `EExceedsMaxSpread` is wrong if it also rejects zero — use a neutral name like `EInvalidSpread`.

## Module Boundaries

- Utility and math modules guard math preconditions only (division by zero, overflow, insufficient balance in a data structure). They do not encode application-level policy ("this state shouldn't happen", "this user type gets different treatment"). Application-level guards belong in the calling module.
- If a function has branches that treat the same parameter differently (allowed in one path, rejected in another), verify the asymmetry is mathematically necessary, not an accidental policy decision.

## Tests

- Every `expected_failure` test should trigger the abort on a specific line. The trailing `abort` is a guard — if execution passes the expected abort point, the bare `abort` produces a different code and fails the test.
- When a test checks a return value against a stored value, use a getter to read the stored value directly. Don't use indirect checks like "ID is non-zero" when you can assert the exact value matches.

## Self-Review Checklist (before pushing)

- [ ] Do all comments match the actual code they describe?
- [ ] Do test names match what the test actually verifies?
- [ ] Do error constant names make sense for every case that triggers them?
- [ ] Are utility module guards strictly about math correctness, not application policy?
- [ ] Are assertions in `expected_failure` tests targeting the right abort codes?
