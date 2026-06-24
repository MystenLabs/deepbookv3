# Lens 05 — Surface-Area Reduction & Simplification

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Surface-area reduction & simplification. Goal: shrink what can go wrong without changing what the protocol
does. Find code, entry points, state, and moving parts that can be DELETED, MERGED, or made
impossible-to-misuse while **provably preserving behavior**. Output is PROPOSALS with a behavior-preservation
argument — do NOT edit code. Every public function, shared field, config knob, and branch is attack surface and
cognitive load; bias hard toward "less". (This lens finds security-relevant surface — dead authority paths,
over-broad APIs, sync-invariant state — not just style.)

**HARD RULE — behavior-preserving means OUTPUT *and* PROPERTIES preserved:**
- Do not propose a change that trades away an existing property: a loop-invariant hoist, a short-circuit, a
  gas-bounding early-return, a rounding direction, an ordering guarantee, an overflow-abort that acts as a
  guard, a storage-rebate path. If a "simplification" shifts gas/rounding/abort conditions/event emission, it
  is NOT behavior-preserving — reject it or flag the tradeoff explicitly. For each proposal, state precisely
  what is preserved and what (if anything) shifts.

**Hunt for:**
- Dead / unreachable code: functions never called from a non-test path; branches unreachable given upstream
  validation; capabilities/paths permanently inert under the object model (authority no sender can satisfy);
  constants/fields read by nothing. (The oracle extraction + tick re-encode + async-LP rework likely left
  orphans — e.g. error constants renumbered with gaps, getters for removed state.)
- Redundant entry points: thin wrappers over one core; boolean-mode functions that should be two callees or
  one; `as_owner`/`with_cap`/`with_proof` families where a member carries no distinct authority.
- Eliminable flows: steps a deployment doesn't need; ceremony supporting an unused configuration; wrappers that
  only reroute arguments; duplicated cost-guard vs settle math that must be kept bit-identical by hand.
- Duplicated state / accounting: the same quantity tracked in two places kept in sync (a sync invariant is a
  bug surface — can one be derived from the other?); mirrored structs; copy-through helpers.
- Wide tuples / unnecessary structs: 4+-field positional returns; structs constructed only to be destructured.
- Over-generality: configurability never exercised; parameters always passed one value; error handling for
  impossible states.

**Also report (don't propose deletion, just surface):** pre-existing dead code or simplifications that are
real but out of scope for a surgical change — per repo convention, do not delete pre-existing dead code
reflexively; name it for the team to decide.

## Output
For each proposal: location(s), what to remove/merge, the exact behavior/properties preserved, call sites
affected, surface removed (functions/fields/branches/lines), and risk level. Rank by (surface removed) ×
(safety). Emit in the primer's report format (Impact = cleanup-only for pure hygiene; raise severity if a dead
authority path is itself a risk). List modules swept + public-surface count before/after, and Top 3. Return
structured findings to the orchestrator or write the solo report. Never modify source.
