# Code Review Patterns

Read this manual-trigger file when the user asks for a code review. It is routed by `AGENTS.md` and `CLAUDE.md`, not by path frontmatter. These patterns are accumulated from real PR review feedback; update this file when reviewers catch new patterns.

## Review Scope

- When the user asks to "review uncommitted changes" or "review uncomitted changes", review the full working-tree diff.
- For Move reviews, also read `.claude/rules/move.md` and `.claude/rules/unit-tests.md`.
- **Deep Predict protocol review.** This flat checklist is the quick pass. For a pre-merge / pre-testnet review of `packages/predict`, use the purpose-built harness: read `.claude/predict-review/00-primer.md` (shared orientation + the finding format) and the relevant lens (`01-invariants`, `02-audit`, `03-oracle`, `04-access-control`, `05-surface-area`, `06-assertions`, `07-lifecycle`). For a full rule audit, follow `rule-auditor.md` (12 read-only rule-family agents over `packages/predict`). Emit findings in the primer's Severity / Location / Claim / Scenario / Impact / Confidence / Recommendation format.
- Treat design docs (`.redesign/`, `.claude/predict-design/`) as **leads to verify against current HEAD**, not ground truth — verify every load-bearing claim against Move source + git + `sui move test`.
- Findings should focus on correctness, regressions, missing coverage, and brittle assumptions.
- Say whether the diff is safe as a standalone PR or only as an intermediate step that requires follow-up work in the same branch.

## Review Emphasis

- Rule violations, including repo guidance, package-specific rules, visibility, comments, validation ownership, and API naming.
- Simplification opportunities, especially one-use helpers, wide tuples, unnecessary structs, duplicated state, boolean-mode helpers, and wrappers that only reroute.
- Redundancies to remove, including duplicated assertions, duplicated accounting calculations, stale compatibility paths, and dead comments/imports/functions created by the diff.
- Architectural bottlenecks and new chokepoints introduced by the change.
- Flow and branching friction: trace the affected flows end to end and identify new dependencies, surprising sequencing, non-landable intermediate states, or branches that now do too much.
- Intuitive behavior: check whether names, public APIs, events, and state transitions match what a protocol integrator or maintainer would expect.
- Ownership and responsibility boundaries for modules/functions: verify state is mutated by its owner, helpers do not absorb parent responsibilities, and callers do not duplicate leaf invariants without a sequencing reason.
- Producer-side policy: flag cross-module returns that pre-apply a consumer's policy — especially lossy transforms (clamp at zero, saturating subtraction, `min`/`max`, rounding) that a downstream consumer then corrects for or re-derives. Bug signatures: the same economic quantity clamped at two altitudes, stance-named returns (`*_optimistic`, `net_*`), or tests that must invert a producer's step to state expectations.

## Comments and Documentation

- Math comments must match the actual function being called. If the code calls `mul_div_round_down(a, b, c)`, write `a * b / c`, not an invented two-step `mul(a, div(b, c))` that doesn't correspond to any real function.
- Use `ceil(a * b / c)` for `mul_div_round_up` calls to make the rounding direction visible.
- Don't write intermediate scaled values in comments (e.g., `div(1, 1_000_001) = 999`). Just write the integer formula and result.

## Naming

- Test names must match what the test actually verifies. If a test checks `oracle_ids` is empty, don't name it `init_registry_has_no_predict_id`.
- Error constant names must cover all cases they guard against. `EExceedsMaxSpread` is wrong if it also rejects zero — use a neutral name like `EInvalidSpread`.
- Receiver-syntax cleanup is not a reason to rename existing public APIs. Keep compatibility wrappers or make the API break explicit.

## Module Boundaries

- Utility and math modules guard math preconditions only (division by zero, overflow, insufficient balance in a data structure). They do not encode application-level policy ("this state shouldn't happen", "this user type gets different treatment"). Application-level guards belong in the calling module.
- If a function has branches that treat the same parameter differently (allowed in one path, rejected in another), verify the asymmetry is mathematically necessary, not an accidental policy decision.

## Tests

- Every `expected_failure` test should trigger the abort on a specific line. The trailing guard abort must use a code distinct from the expected one (for example `abort 999`) so the test still fails if execution reaches the guard.
- When a test checks a return value against a stored value, use a getter to read the stored value directly. Don't use indirect checks like "ID is non-zero" when you can assert the exact value matches.

## Generated Test Data

- For generated-test changes, check for duplicate scenarios, overly loose assertions, and hardcoded fixture indices that can silently drift.
- Every generated test vector must be exercised against the contract. If generated data isn't passed to the function under test, delete it.
- Don't add workarounds (magic thresholds, special-case branches) in test assertions to make generated tests pass. If a test can't assert directly, understand why and fix the root cause.
- Review generated output before committing — check for duplicates, trivial cases (100 inputs that all return 0), and wasted coverage.

## Constants and Configuration

- Don't hardcode values in tests that exist in the `constants` module. Import the macro instead. A "must stay in sync" comment is a sign you should be importing.
- Protocol parameters that may need tuning (e.g., staleness thresholds) should be configurable via config structs, not compile-time constants. Pattern: constant defines the default, config struct stores the runtime value, `new()` initializes from default, `set_*` lets admin update.

## Self-Review Checklist (before pushing)

- [ ] Do all comments match the actual code they describe?
- [ ] Do test names match what the test actually verifies?
- [ ] Do error constant names make sense for every case that triggers them?
- [ ] Are utility module guards strictly about math correctness, not application policy?
- [ ] Are assertions in `expected_failure` tests targeting the right abort codes?
- [ ] Does every test call the function it claims to test?
- [ ] Is all generated test data exercised against the contract?
- [ ] Are there any workaround thresholds or special-case branches hiding assertion failures?
- [ ] Are all constants imported from the `constants` module, not hardcoded?
- [ ] Do all `expected_failure` tests specify a named abort code (no bare `expected_failure`)?
- [ ] Do timestamp updates match the field's documented semantics?
- [ ] Do cross-module returns carry owned facts, with every lossy clamp applied once at the policy owner?
