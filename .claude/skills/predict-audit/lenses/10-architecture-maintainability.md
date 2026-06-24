# Lens 10 — Architecture, Cohesion & Maintainability

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Architecture, cohesion & maintainability — the **code-quality** lens. The other lenses hunt bugs; you
assess whether the code is *structured well enough to stay correct as it changes*. Output is
**restructure / decomposition / clarity proposals** that preserve behavior but improve cohesion,
coupling, and readability. This is the one lens allowed to propose **structural refactors** (splits,
extractions, re-homing) — the surface-area lens (05) is restricted to behavior-preserving *deletions/
merges* and explicitly hands god-module and decomposition concerns to YOU.

This is not nit-picking. An overgrown orchestration module that bundles sequencing + accounting +
payment + events + policy is a *correctness risk multiplier*: every future change touches it, reviewers
can't hold it in their head, and bugs hide in the glue. Treat low cohesion as a finding, not a style note.

Ground every judgment in the repo's OWN conventions — `.claude/rules/move.md` (domain-subsystem
organization, function ordering, return-tuple discipline, the producer-fact rule, receiver syntax,
config-storage-vs-compute split) and `.claude/rules/code-review.md` ("architectural bottlenecks and new
chokepoints", "one-use helpers, wide tuples, duplicated state", Simplicity First). A finding is strongest
when it cites the specific repo rule it violates.

**Produce a MODULE RESPONSIBILITY MAP, then audit it:**

1. **Cohesion / single-responsibility (the headline axis).** For each central module — especially the
   large orchestration hubs `expiry_market.move` and `plp/plp.move` — enumerate its *distinct*
   responsibilities (e.g. trade sequencing, cash/accounting, payment settlement, event emission, policy
   glue, lifecycle transitions). Judge whether they belong in one module or are a **god-module** that
   should be decomposed. Name the orchestration chokepoints: modules every flow must route through, where
   unrelated concerns are interleaved. For each, propose concrete cohesive seams (what would move to a new
   sub-module / helper, and why each piece is independently understandable + testable).

2. **Function complexity.** Functions doing too much: long bodies, deep nesting, many branches, long
   parameter lists, multiple state transitions in one function, mixed abstraction levels (high-level
   sequencing next to low-level arithmetic). Flag extraction candidates and name the phase each extracted
   helper would own (with its own pre/postconditions, per move.md's phase-boundary guidance).

3. **Coupling & boundaries.** Modules reaching into another's internals; leaky abstractions; a helper that
   absorbs its parent's responsibility; a caller re-deriving a callee's owned fact; wide cross-module
   tuples that should be a named summary or fewer values. Flag where ownership (per move.md's
   validation/ownership rules) is smeared across modules.

4. **Duplication / DRY.** Repeated logic that should be one owned function — the canonical example here is
   the three BS feeds' near-identical `update`/`insert_at` guard+construct blocks. Distinguish *true*
   duplication (should be unified) from the intentional bit-equal round-trip rule (the `index_terms`
   evaluator MUST be one function — that's not duplication, that's the rule).

5. **Readability & idiom.** Naming that obscures intent; comments that don't match the code (a real
   defect, per code-review.md); magic numbers that should be named constants/macros; structure that hides
   the happy path; non-idiomatic Move (module-qualified calls where receiver syntax reads better, manual
   loops where a macro fits, `get_`-prefixed getters, `Self`-only imports) measured against move.md.

6. **Maintainability hazards.** Sync-invariant state (the same quantity tracked in two places that must be
   kept consistent by hand); boolean-mode functions that should be two clear callees; configurability never
   exercised; abstractions that only shuttle data across a boundary.

## Discipline
- **Behavior-preserving is mandatory.** Every proposal must preserve outputs, gas profile, rounding,
  abort conditions, event emission, and ordering — a refactor that shifts any of those is out of scope;
  say so explicitly if a proposal has a tradeoff and let the maintainer decide.
- **Surgical bias.** Per CLAUDE.md, don't propose unrelated rewrites. The best findings are high-leverage:
  a large cohesion win that's obviously safe. Rank by (maintainability gain) × (safety of the change).
- **Stay in your lane.** Don't re-report 05's deletions or the bug lenses' correctness findings; if a
  structural smell *also* hides a bug, note it and hand the bug to the owning lens.
- Do NOT run sui build/test or localnet (watchdog). Read-only on source.

## Output
For each proposal: location(s), the responsibility/smell, the specific repo rule it violates (if any), the
concrete restructure (what moves where + the cohesive seam), exactly what behavior/properties are
preserved, call sites affected, an estimate of the maintainability gain, and risk. Use the primer's report
format (Impact = `cleanup-only` for pure maintainability; raise it only if low cohesion is actively hiding
a correctness/solvency risk). End with the module responsibility map, the public-surface/responsibility
counts you assessed, and Top 3 highest-leverage restructures. Return structured findings to the
orchestrator or write the solo report. Never modify source.
