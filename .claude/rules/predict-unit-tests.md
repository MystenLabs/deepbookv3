---
paths:
  - "packages/predict/tests/**"
---

# Predict Unit-Test Architecture

- Put every executable test module under one scope path: `framework`, `mechanics`, `structure`, or `flow`.
- Name every executable module `scope_<scope>__intent_<intent>__<subject>_tests`, where intent is `behavior`, `guard`, `boundary`, `rounding`, `accounting`, `reference`, or `policy`; reserved `scope_*__` and `intent_*__` markers appear only in the module segment so Sui substring filters remain exact.
- Use `test_world` as the only owner of `test_scenario::Scenario`; capture shared identities once and retrieve them by ID after bootstrap.
- Create at most one World in each test; reuse it across profiles and seed successive feed rows with strictly increasing source timestamps.
- Keep post-bootstrap actor and transaction changes in test bodies. Prerequisite helpers operate only in the caller's current transaction.
- Fixtures construct state and return identity/capability handles; they do not compute expected truth or mirror production business APIs.
- Keep executable unit tests and fixture modules under `packages/predict/tests/**`; never add test functions to `sources/**`. If existing production APIs and approved irreducible test-only seams cannot express the required state or flow, stop and flag the testability gap instead of adding a source-local test or convenience seam.
- Call the production unit under test in the test body. A prerequisite helper may call production transitions only when a different function is the declared unit under test.
- Every successful executable test contains a direct `assert!` or `assert_eq!` in its own body; expected-failure tests use their abort annotation as the oracle and are exempt.
- Keep exact integer/rounding claims separate from independent true-model accuracy and economic-accounting claims.
- Numerical reference data proves representative implementation accuracy, not complete envelope calibration; it must have a committed independent generator, committed inputs, a documented regeneration command, an ex-ante precision bound that does not inspect contract output, and a CI stale-output check under a pinned interpreter.
- Treat an independently valid out-of-bound result as a product/audit finding under `.claude/rules/unit-tests.md`; never widen the bound or snapshot the observed value.
