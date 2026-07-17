# Predict Predeploy — Source of Truth and System Map

**What this is.** Predict is developed by one architect plus many agent and
human sessions, and no session retains memory — every session starts with total
amnesia. This directory is the externalized state of the development process,
kept durable, machine-legible, and cross-checked so any session can pick up
work without anyone's head as the router. Around it: the rules files
(`.claude/rules/`) are the working program each session runs; the harness
measures instead of guessing; the audit skill re-verifies; the public docs
(`packages/predict/docs/`) disclose — always derived from here, never leading.

**The pipeline.** Everything that needs conscious attention — a bug, a
suspicion, an undecided question, an audit finding — lands in `open-items.md`
first; if it is not on that list, it does not need addressing. An item that
needs measurement carries its experiment plan inline (question, harness
strategy, decision rule written before the run), and run results land as
immutable dated records in `evidence/`. An item exits only by deletion in the
PR that resolves it; if the resolution embodied a judgment call, the decision
graduates to `response-policies.md` — there is no third destination.

## Authority order

When sources disagree, higher wins. Fix the loser or file the drift as a
finding — never leave a known disagreement standing.

1. **Move source + `sui move test`** — ground truth, always.
2. **`response-policies.md`** (incl. the rounding policy R1–R3) — settled
   policy; binds reviewers and future changes.
3. **`open-items.md`** — live work state, including in-flight experiment plans.
4. **`packages/predict/docs/design/decisions.md` (canonical settled + rejected design decisions),
   `.claude/rules/*.md`** — standing design record and working rules. (`AGENTS.md` points here.)
5. **`packages/predict/docs/`** — public disclosure; must describe the behavior
   recorded above, never lead it.

## The surfaces

| Surface | Owns | Notes |
| --- | --- | --- |
| `audit-scope.md` | Audit-snapshot cover: scoped packages, exclusions, trust assumptions, and pointers to the live issue/policy surfaces | Stamp the commit when the audit tag is cut; finding detail stays in `open-items.md` and `response-policies.md` |
| `open-items.md` | THE START — the single intake for open work; items carry inline experiment plans and, for multi-run items, the current measured model | Resolved items leave the OPEN sections; the register entry (`resolves <id>`) is their permanent tombstone — item ids stay referenceable (see Item-id lifecycle) |
| `response-policies.md` | THE END — every decision that outlives an item: chosen tail-state behavior, accepted risks, guard removals, and the rounding policy (R1–R3) | At most one entry resolves a given item; guard removals require a duty inventory |
| `evidence/` | Immutable dated run records, each anchored to the item (or register entry) it serves | Append-only; naming `<item>-<instrument>-<date>.md`; nothing unreferenced |
| `check.py` | The system linter: pinning tests exist, ID cross-refs resolve, MEASURED links evidence, evidence is anchored and referenced, no dead paths | Run on any diff touching this directory or guards; audit preflight runs it too |
| `packages/predict/docs/design/decisions.md` | CANONICAL settled + rejected design decisions with don't-revisit-unless conditions | What the mechanism IS; the register is how it BEHAVES in tail states. `AGENTS.md` (repo root) points here |
| `.claude/rules/*.md` | Working rules per surface (move, tests, harness, indexer, code review) | Accumulated session knowledge; update when a session learns something durable |
| `.claude/skills/predict-audit/` | The deep-audit harness (lenses, workflows, primer) | Audit runs must re-verify register entries at HEAD and not re-flag verified ones |
| `packages/predict/harness/` | Localnet staging sim + strategies + bug-oracle analyzers | `.claude/rules/predict-harness.md` + `harness-strategy.md` are its rules |
| `packages/predict/docs/` | Public conceptual docs + `risks.md` disclosure | Failure-behavior claims must cite reality (and ideally a pinning test) |

Personal scratch (`.claude/predict-design/`, `.redesign/`) is legitimate for
in-flight working logs and raw generated audit output, and for nothing else:
**anything a second person would need to continue the work must live in the
tracked tree.** Durable findings are extracted the day they're confirmed.

## Lifecycle

**Plain fix.** Fix it, add the pinning test, delete the item in the resolving
PR. The PR is the record; nothing else is written anywhere.

**Needs measurement.** Write the plan on the item first — question, harness
strategy, decision rule — then run (`.claude/rules/predict-harness.md`). The
run's record lands in `evidence/` as an immutable dated file; the item's model
block absorbs what the numbers mean. Results flip tags and close items; they
never accumulate as ambient reassurance.

**Needs a judgment call.** Decide, record the decision as a register entry whose
title `resolves <id>` (with pinning tests or an explicit not-yet-catalogued
marker, and a duty inventory if a guard was removed or weakened), then remove the
item's OPEN block. That register entry is the item's **tombstone**: item ids are
permanent, so the id stays a valid reference target (evidence and the register
cite it as provenance forever) — it is simply no longer OPEN. An accepted risk
with no register entry does not exist. When the decision affects users or
integrators, `docs/risks.md` gets its derived disclosure.

**Item-id lifecycle (Model A).** An item id (`P-9`, `C-4`, …) is a permanent
identifier, not a disposable label. An `open-items.md` heading means the id is
OPEN work; a register entry titled `resolves <id>` means it is done — the register
is the single tombstone (there is no `open-items.md` resolved section, honoring
"no third destination"; grep the register for a resolved item's history).
`check.py` enforces this: an item-id reference resolves to an OPEN heading OR a
register tombstone (else it warns as a dangling pointer), and an id that is BOTH
open and resolved is a FATAL contradiction.

**Audit.** `predict-audit` runs emit findings (triaged into `open-items.md`),
and re-verify the register at HEAD: pinning tests exist, code matches recorded
responses, `risks.md` matches code. Drift is itself a finding. Raw audit output
stays in ignored scratch; only durable findings enter this directory.

## Picking up work

- **Fix something:** `open-items.md`, pick an item, check the register for
  already-made decisions touching it.
- **Measure something:** pick an item whose plan block names a strategy, or
  add the plan (with its decision rule) to the item first, then run it through
  the harness.
- **Review/audit something:** `.claude/rules/code-review.md` for the quick
  pass; the `predict-audit` skill for depth.
- **Understand the protocol:** `packages/predict/docs/` (overview → concepts →
  risks → `packages/predict/docs/design/decisions.md` for the settled design record).

## Update rules

- Keep resolved issues out of `open-items.md`; the purpose is a live checklist.
- Keep raw generated audit reports and scratchpads ignored. Extract only durable
  findings or policy decisions into this directory.
- When a finding is accepted rather than fixed, say so explicitly and point to
  the public disclosure or register entry that carries it.
- When a guard is removed or weakened, or a degenerate-state response is
  decided, record it in `response-policies.md` (with a duty inventory for
  removals) — reasoning must not live only in a commit message.
- Evidence records are immutable once written; when a later run supersedes a
  conclusion, update the owning item's model block first and note the
  supersession in the new record, never by editing the old one.
- Every experiment plan gets its decision rule on the item before the run.
- Run `check.py` on any diff that touches this directory.
