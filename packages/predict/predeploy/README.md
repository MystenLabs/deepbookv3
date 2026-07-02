# Predict Predeploy — Source of Truth and System Map

**What this is.** Predict is developed by one architect plus many agent and
human sessions, and no session retains memory — every session starts with total
amnesia. This directory is the externalized state of the development process:
the decisions and their reasoning, the rejected directions, the open work, the
measured evidence, and the binding policies — kept durable, machine-legible,
and cross-checked so any session can pick up work without anyone's head as the
router. Around it: the rules files (`.claude/rules/`) are the working program
each session runs; the harness measures instead of guessing; the audit skill
re-verifies; the public docs (`packages/predict/docs/`) disclose — always
derived from here, never leading. The terminal goal is a correct value-bearing
protocol; this system is how n sessions and m people behave like one coherent
engineer over months.

**How it's used.** Every session runs the same loop: orient here (map +
authority order) → read the rules for the surface being touched → do the work →
verify empirically (tests / harness) → write the state back (trackers,
register, rules) → enforcement (tests, review checklist, audit re-verification)
catches what was missed. Alignment comes from the loops, not from reading:
items can't close without graduating their decisions, guards can't be removed
without a duty inventory, and a risk claim isn't MEASURED without a linked
finding.

This directory is intentionally separate from `packages/predict/docs/`, which
explains the protocol to technical users and evaluators. The files here are for
the protocol team.

## Authority order

When sources disagree, higher wins. Fix the loser or file the drift as a
finding — never leave a known disagreement standing.

1. **Move source + `sui move test`** — ground truth, always.
2. **`response-policies.md` / `rounding-policy.md`** — settled policy; binds
   reviewers and future changes.
3. **`open-items.md` / `experiments.md`** — live work state.
4. **`AGENTS.md` (settled + rejected design decisions), `.claude/rules/*.md`** —
   standing design record and working rules.
5. **`packages/predict/docs/`** — public disclosure; must describe the behavior
   recorded above, never lead it.

## The surfaces

| Surface | Owns | Notes |
| --- | --- | --- |
| `open-items.md` | Live tracker: bugs, deploy gates, follow-ups, required decisions | Resolved items are REMOVED (decisions graduate to the register) |
| `response-policies.md` | Settled response-policy decisions for degenerate/adversarial states: chosen behavior, reasoning, risk profile, pinning tests | Guard removals and tail-state decisions land here, never only in commit messages |
| `experiments.md` | Harness experiment ledger: driving ID, pre-registered decision rule, status, findings link | The bridge between the trackers and the harness |
| `rounding-policy.md` | Protocol-wide rounding and dust-liveness rules (R1–R3) | |
| `settlement-liveness.md` | Accepted operational assumption + testnet evidence for exact-timestamp settlement | |
| `oracle-calibration.md` | Near-expiry oracle miscalibration finding and repro (O-1) | |
| `versioning-and-loaders.md` | Proposed (unimplemented) version-gate/loader cleanup | Verify its "shipped today" claims at HEAD before executing |
| `stress/` | Measured capacity findings: consolidated doc + dated finding docs | Consolidated doc updated first; dated docs are evidence |
| `AGENTS.md` (repo root) | Settled design decisions + rejected directions with don't-revisit-unless conditions | What the mechanism IS; the register is how it BEHAVES in tail states |
| `.claude/rules/*.md` | Working rules per surface (move, tests, harness, indexer, code review) | Accumulated session knowledge; update when a session learns something durable |
| `.claude/skills/predict-audit/` | The deep-audit harness (lenses, workflows, primer) | Audit runs must re-verify register entries at HEAD and not re-flag verified ones |
| `packages/predict/harness/` | Localnet staging sim + strategies + bug-oracle analyzers | `.claude/rules/predict-harness.md` + `harness-strategy.md` are its rules |
| `packages/predict/docs/` | Public conceptual docs + `risks.md` disclosure | Failure-behavior claims must cite reality (and ideally a pinning test) |

Personal scratch (`.claude/predict-design/`, `.redesign/`) is legitimate for
in-flight working logs and raw generated audit output, and for nothing else:
**anything a second person would need to continue the work must live in the
tracked tree.** Durable findings are extracted the day they're confirmed.

## Lifecycle loops

**Finding → decision.** A bug/audit/review finding lands in `open-items.md`
with an ID. Work resolves it; if resolving it embodied a response-policy or
design decision, the decision graduates to `response-policies.md` (tail-state
behavior) or `AGENTS.md` (mechanism design) with pinning tests, and the item is
deleted. While an item is open, the item owns the work state and the register
owns any already-made decision — they link to each other and never paraphrase
each other.

**Experiment.** A question that needs measurement gets an `experiments.md` row:
driving ID + decision rule first, then the run. Results produce a dated doc in
`stress/`, update the consolidated doc, and flip the driving item/register tag.
BEST-GUESS risk profiles in the register are standing experiment candidates.

**Audit.** `predict-audit` runs emit findings (triaged into `open-items.md`),
and re-verify the register at HEAD: pinning tests exist, code matches recorded
responses, `risks.md` matches code. Drift is itself a finding. Raw audit output
stays in ignored scratch; only durable findings enter this directory.

**Guard changes.** Removing or weakening any guard requires a duty inventory
(what else it incidentally bounded) recorded as a register entry — see
`.claude/rules/move.md`.

## Picking up work

- **Fix something:** `open-items.md`, pick an item, check the register for
  already-made decisions touching it.
- **Measure something:** `experiments.md`, pick a BUILT/READY row (or add one
  with its decision rule), run it through the harness
  (`.claude/rules/predict-harness.md`).
- **Review/audit something:** `.claude/rules/code-review.md` for the quick
  pass; the `predict-audit` skill for depth.
- **Understand the protocol:** `packages/predict/docs/` (overview → concepts →
  risks), then `AGENTS.md` for the settled design record.

## Update rules

- Keep resolved issues out of `open-items.md`; the purpose is a live checklist.
- Keep raw generated audit reports and scratchpads ignored. Extract only durable
  findings or policy decisions into this directory.
- When a finding is accepted rather than fixed, say so explicitly and point to
  the public disclosure or design decision that carries it.
- When a guard is removed or weakened, or a degenerate-state response is
  decided, record it in `response-policies.md` (with a duty inventory for
  removals) — reasoning must not live only in a commit message.
- When a stress result is superseded, update the consolidated stress doc first,
  then adjust the narrow dated finding only if its original conclusion changed.
- Every experiment gets its decision rule before the run; results flip tags and
  close items, they don't accumulate as ambient evidence.
