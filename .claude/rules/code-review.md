# Code Review Patterns

Read this manual-trigger file when the user asks for a code review. It is routed by `AGENTS.md` and `CLAUDE.md`, not by path frontmatter. These patterns are accumulated from real PR review feedback; update this file when reviewers catch new patterns.

## Review Scope

- When the user asks to "review uncommitted changes" or "review uncomitted changes", review the full working-tree diff.
- For Move reviews, also read `.claude/rules/move.md` and `.claude/rules/unit-tests.md`; for Predict-touching Move reviews additionally `.claude/rules/predict-contracts.md`.
- **Deep Predict smart-contract audit.** This flat checklist is the quick pass. For a deep audit of the Predict contracts (predict + propbook + block_scholes_oracle + account), invoke the **`predict-audit`** skill (`.claude/skills/predict-audit/`): read its `primer.md` (orientation + current module map + finding format) and the relevant `lenses/NN-*.md` (`01-invariants`, `02-adversarial-audit`, `03-oracle-pricing-numerical`, `04-access-control`, `05-surface-area`, `06-assertions`, `07-lifecycle`, `08-cross-package-trust`, `09-economic-simulation`, `10-architecture-maintainability`), or launch its `orchestrator.workflow.js` (lens fan-out), `ownership-walk.workflow.js` (per-module ownership/boundary/policy conformance, R1–R7), or `rule-sweep.workflow.js` (per-rule mechanical sweep). Emit findings in the primer's Severity / Location / Claim / Scenario / Impact / Confidence / Recommendation format.
- Treat design/research docs (`packages/predict/predeploy/`, `.redesign/`, `.claude/predict-design/`) as **leads to verify against current HEAD**, not ground truth — verify every load-bearing claim against Move source + git + `sui move test`.
- Findings should focus on correctness, regressions, missing coverage, and brittle assumptions.
- Say whether the diff is safe as a standalone PR or only as an intermediate step that requires follow-up work in the same branch.

## Review Emphasis

- Rule violations, including repo guidance, package-specific rules, visibility, comments, validation ownership, and API naming.
- Simplification opportunities, especially one-use helpers, wide tuples, unnecessary structs, duplicated state, boolean-mode helpers, and wrappers that only reroute.
- Redundancies to remove, including duplicated assertions, duplicated accounting calculations, stale compatibility paths, and dead comments/imports/functions created by the diff.
- Architectural bottlenecks and new chokepoints introduced by the change.
- Flow and branching friction: trace the affected flows end to end and identify new dependencies, surprising sequencing, non-landable intermediate states, or branches that now do too much.
- Intuitive behavior: check whether names, public APIs, events, and state transitions match what a protocol integrator or maintainer would expect.
- Check the diff against the rule corpus loaded at Review Scope (`move.md`, `predict-contracts.md`, `unit-tests.md`) rather than from memory — those files own the rule text (ownership boundaries, producer-fact/lossy-transform placement, loop-invariant hoists, guard duty inventories, the response-policy blast-radius ladder); violations are findings, and this file does not restate them.
- Two rule-corpus checks need diff-level evidence, not just code shape: a removed or weakened guard must carry its duty inventory and `packages/predict/predeploy/response-policies.md` entry IN THE DIFF (precedent: the P-1 circuit-breaker removal `cc67ed9f`), and a new abort over a market-controlled variable in a shared/mandatory path is an undecided response policy unless registered there.
- Doc claims about failure behavior (`docs/risks.md`, module docs) must match code at HEAD. A doc describing intended-but-unimplemented behavior as shipped is a finding (precedent: risks.md claimed the LP drain refunds degenerate requests while the code hard-aborted, C-4).
- When the same function has been fixed repeatedly across commits (git history shows N competent rewrites at one site), escalate from correctness review to boundary interrogation: ask what question the function answers and whether the flow should still be asking it — repeated defects at one site are evidence about the spec, not the implementers (precedent: `max_quantity_for_net_premium` survived four rewrites and was resolved by deleting the question, DBU-566).
- When the diff touches `packages/predict/predeploy/`, Predict guards, or tests named in the register, run `python3 packages/predict/predeploy/check.py` — it verifies register pinning tests exist, tracker cross-references resolve, MEASURED claims link evidence, and named paths are live. While `packages/predict/tests/check_predeploy_debt.py` exists, also run it: only strict-checker findings represented by its exact transitional manifest are accepted debt; any debt-check error or unrepresented strict finding is a review finding. The branch remains an intermediate draft until the debt wrapper is deleted and the strict checker is clean.

## Comments and Documentation

- Math comments must match the actual function being called. If the code calls `mul_div_round_down(a, b, c)`, write `a * b / c`, not an invented two-step `mul(a, div(b, c))` that doesn't correspond to any real function.
- Use `ceil(a * b / c)` for `mul_div_round_up` calls to make the rounding direction visible.
- Don't write intermediate scaled values in comments (e.g., `div(1, 1_000_001) = 999`). Just write the integer formula and result.

## Naming

- Test names must match what the test actually verifies. If a test checks `oracle_ids` is empty, don't name it `init_registry_has_no_predict_id`.
- Error constant names must cover all cases they guard against. `EExceedsMaxSpread` is wrong if it also rejects zero — use a neutral name like `EInvalidSpread`.
- Receiver-syntax cleanup is not a reason to rename existing public APIs. Keep compatibility wrappers or make the API break explicit.

## Module Boundaries

- If a function has branches that treat the same parameter differently (allowed in one path, rejected in another), verify the asymmetry is mathematically necessary, not an accidental policy decision.

## Tests

- When a test checks a return value against a stored value, use a getter to read the stored value directly. Don't use indirect checks like "ID is non-zero" when you can assert the exact value matches.

## Generated Test Data

- For generated-test changes, check for duplicate scenarios, overly loose assertions, and hardcoded fixture indices that can silently drift.
- Every generated test vector must be exercised against the contract. If generated data isn't passed to the function under test, delete it.
- Don't add workarounds (magic thresholds, special-case branches) in test assertions to make generated tests pass. If a test can't assert directly, understand why and fix the root cause.
- Review generated output before committing — check for duplicates, trivial cases (100 inputs that all return 0), and wasted coverage.

## Self-Review (before pushing)

Re-run the lenses above against your own diff, plus the rule files from Review Scope. The rule corpus is the checklist — an item-by-item copy that lived here restated it and drifted, so it was removed.
