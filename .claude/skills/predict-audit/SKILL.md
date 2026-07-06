---
name: predict-audit
description: Deep, multi-lens security & correctness audit of the DeepBook Predict smart contracts (the predict + propbook + block_scholes_oracle + account Move source). Use when asked to audit Predict, hunt bugs/invariant-violations/exploits in Predict, review Predict contract changes before merge, or assess economic safety of the Predict protocol. Smart-contract audit — finds bugs, invariant violations, exploits, and architecture/maintainability issues; it does not check deploy/ops readiness. RUNNING IT IS EXPENSIVE (a full run is a few hundred subagents / millions of tokens — each harness now caps its own agent count by construction) and REQUIRES explicit user confirmation before every run — never execute it automatically.
---

# Predict Smart-Contract Audit

## ⛔ STOP — explicit run confirmation is MANDATORY
This skill launches **expensive multi-agent audits** — a maximal end-to-end run (all three harnesses) is **a few hundred subagents and several million tokens**. Each harness now BOUNDS its own agent count by construction (`maxRounds`×units + `verifyCap` verify, severity-gated), so it cannot run away to the old ~100M / 1000-agent-cap territory unless you explicitly raise the caps via args. It must NEVER run automatically or as a side effect of being invoked, read, or mentioned.

**Before launching ANY harness run (`orchestrator` / `ownership-walk` / `rule-sweep`), you MUST:**
1. Show the user the run plan as **two independent axes** plus cost: (a) **breadth/scope** — which harness(es) and `lenses` / `units` / `rules` (or "full"); (b) **depth tier** — `depth: mini|low|standard|max` (see the table under "Launching a run"); and the budget / rough cost (agent count, token estimate). Splitting breadth from depth lets the user pick e.g. "full breadth, low depth" (all lenses, `depth:'low'` = single round) for a cheap complete pass and reserve `depth:'max'` for runs with ample token budget. When you ask the launch questionnaire, ask **both** axes.
2. Ask explicitly — e.g. *"Run this audit? (≈N agents / ≈X tokens)"* — and **WAIT for an explicit "yes."**
3. Only after the user confirms, call `Workflow(...)`. If anything is ambiguous, ask; never assume.

Invoking, reading, explaining, or editing this skill never needs the gate — **only *executing a harness run* does.** When in doubt, do not run.

A self-driving harness for a deep, adversarial, **smart-contract-only** audit of DeepBook "Predict" — a leveraged binary prediction market on Sui — and its three split-out sibling packages. The goal is to **find real bugs**: solvency/fund-loss, liveness/abort (a bricked flow), griefing/DoS, mispricing, broken invariants, and authorization holes — plus, via a dedicated lens, architecture/cohesion/readability issues (overgrown "god" modules, coupling, decomposition). Findings are reasoned from the code AND, where it matters, **empirically reproduced** on localnet or in Python.

This is a *code-audit* skill (security/correctness + maintainability). It does NOT do testnet-readiness/deploy/ops checks (Move.toml hygiene, post-deploy admin steps, indexer parity, runbooks). If asked for those, say so and scope them separately. Scope is FIXED to the four Predict-cluster packages (predict + propbook + block_scholes_oracle + account); do NOT broaden it to deepbook core or other repo packages. Upgrade / object-layout migration correctness is also out of scope (matches `move.md` pre-deploy) — revisit only when nearing deploy.

## When to use
- "Audit Predict" / "deep audit of the predict contracts" / "find bugs in Predict before testnet."
- "Review these Predict changes for correctness/exploits/invariant violations."
- Any request to assess Predict economic safety at the Move-source level.

## Packages in scope (all Move source, read-only)
The oracle and custody layers were extracted out of `predict`, so the audit spans four packages. Dependency order (leaves first):

```
block_scholes_oracle (update)            account (account, account_registry, account_events)
fixed_math (math) ─────────────┐              │
                               ▼              │
        propbook (registry, oracle_lane, feeds/{pyth,bs_spot,bs_forward,bs_svi}, constants)
                               ▼              ▼
                    predict (31 modules — the center of gravity)
```

`predict` is the top consumer and gets most of the audit budget; the siblings are audited for their own correctness AND for the trust `predict` places in them (lens 08).

## Method (5 phases)
1. **Ground truth — MAIN LOOP ONLY.** `sui build` + `sui test` all four packages (`--warnings-are-errors`), and a localnet sim smoke. "Tests don't compile / are red" is itself a finding. Results feed the audit.
2. **Loop-until-dry find.** Each lens re-samples across rounds (told what's already found, so it hunts new ground); the union grows until K consecutive dry rounds (`dryRounds`) or the token-budget floor — converting LLM sampling into near-enumeration and auto-retrying flaky units.
3. **Adversarial verify (cross-model).** Every candidate finding is independently refuted/confirmed; High/Critical get an empirical-repro attempt. Verify is **cross-model for bias reduction** across all three harnesses — the refute/repro/verify verifiers run on **codex** (the orchestrator keeps the settled-decision check on **Claude**), so an escalated finding clears a different model than the one that found it (needs the codex CLI; a null verdict retries once on Claude, then surfaces as `unverified-panel` rather than silently degrading).
4. **Empirical deep pass (required).** The economic-simulation lens runs the localnet + Python sims and writes new adversarial scenarios to actually break invariants.
5. **Consolidate (no-slip) + curate.** Read each harness's FULL output file (the notification preview is truncated), run `consolidate.py` to deterministically merge all three into ONE `consolidated-report.md` covering **open + settled + refuted + coverage** with a `DROPPED 0` accounting guarantee, then reason over the committed `packages/predict/predeploy/open-items.md` and curate findings into it. The orchestrator's promote pass + the consolidator's coverage section catch buried items; never hand-pick from a truncated return.

## Harnesses
Three complementary review *shapes*, all sharing this `primer.md`, the report format, and the read-only / compiler-in-main-loop discipline. Read `primer.md` first either way.
- **Lens fan-out** — `orchestrator.workflow.js`: the 10 perspective lenses (broad multi-angle bug hunt). Or hand a single `lenses/NN-*.md` to one session. Scope with `args.lenses` (or `profile`). Shared across all three harnesses now: **per-lane/family/unit retirement** — a lane that goes dry for `dryRounds` rounds drops out, so later rounds re-run only the lanes still surfacing issues (set `dryRounds:1` to re-run only lanes fresh last round, `maxRounds:1` for a single pass) — and **cross-model verify** (codex refute+repro/verify, Claude settled), with a null-verdict retried once on Claude so an infra flake never silently demotes a finding. The orchestrator additionally runs the **full mixed panel** for High/Critical (codex refute + codex repro + Claude settled); the siblings run one codex verifier per finding.
- **Ownership walk** — `ownership-walk.workflow.js`: recursive *per-module* conformance against the contextual ownership/boundary/policy rules in `references/ownership-rules.md` (R1–R7). Map (barrier) → per-module check → adversarial verify; the unit of work is a code node, not a perspective. Scope with `args.units` (subsystem clusters). Use this for "who owns what / where are boundaries violated."
- **Rule sweep** *(refreshed from the old root `rule-auditor.md`)* — `rule-sweep.workflow.js`: per-*rule* sweep for the 17 mechanical/local rule families (config-reads, config API shape, public-API exposure, object-identity keys, `create_and_share` naming, ProtocolConfig gate matrix, arithmetic-guard noise, test-coverage, timestamp semantics, events hygiene, **dead-field liveness** — the exhaustive write-only / read-only-mirror sweep that catches the rebate-reserve bug class — plus the hygiene trio **signature-shape** / **module-layout** / **comment-hygiene** for input ordering, visibility-group layout, and comment quality, and the polish trio **test-independence** / **docs-drift** / **abort-code-multiplexing** for expected-value independence, prose-vs-HEAD drift, and one-code-per-condition). Broad-shallow is correct there; the contextual ownership families (ex-rule-auditor 6/8/9) live in the ownership walk instead. Scope with `args.rules`.

Axis split: lenses = perspective × whole codebase; ownership walk = per-module (deep context); rule sweep = per-rule × whole codebase (mechanical).

## Launching a run (copyable)
**Step 1 — ground truth, MAIN LOOP only** (feeds every subagent via `args.groundTruth`; a wrong command starts the run from a false "all green"):
```
python3 .claude/skills/predict-audit/preflight.py               # drift lint FIRST: fatal on primer module-map drift, warns on dangling D-ids
python3 packages/predict/predeploy/check.py                     # dev-system linter: register pinning tests, ID cross-refs, MEASURED links, dead paths
sui move build --path packages/<pkg> --warnings-are-errors   # pkg ∈ predict propbook account block_scholes_oracle
sui move test  --path packages/<pkg> --gas-limit 100000000000   # each of the four (predict is the big suite)
(cd packages/predict/simulations && bash run.sh --python-only)   # sim smoke; localnet `bash run.sh` is also main-loop-only
```
`preflight.py` guards the primer (the single point of failure — its module map + D-id citations reach every subagent): a missing module path is fatal, a D-id that resolves only to the local decision journal warns (promote it into a committed ledger). `check.py` guards the predeploy system itself (a register decision whose pinning test vanished is un-enforced; a dangling tracker cross-ref means a broken workflow). The workflows also self-warn if `groundTruth` looks empty/short, but run the lint yourself so drift is caught before the launch questionnaire.

**Register obligations (every run).** `packages/predict/predeploy/response-policies.md` is part of the audited surface: (a) re-verify each entry at HEAD — the code still implements the recorded response, the pinning tests still pin it, and `docs/risks.md` still describes it truthfully; drift between an entry and HEAD is itself a finding. (b) Do NOT re-flag a registered decision whose reasoning verifies at HEAD — cite the entry instead. (c) Anti-ossification: pick 1–2 entries per run and adversarially re-derive them from scratch, ignoring the recorded reasoning (a well-reasoned decision can still be wrong by omission — the P-1 circuit-breaker removal is the precedent: its fairness argument was sound and it still silently dropped the only u64-headroom bound on LP fill math).
**Step 2 — launch a harness.** Each **loops-until-dry**, but is **BOUNDED BY CONSTRUCTION**: defaults are `maxRounds 3` / `dryRounds 2` / `verifyCap 60`, and verify is severity-gated (Info/Low/cleanup reported raw, no subagent; Medium 1 verifier; High/Critical the full panel). So total agents ≤ `maxRounds`×lenses/units/families + `verifyCap`×panel — it cannot hit the 1000-agent cap. **Do NOT rely on a `+NNNm` budget directive to bound it** — the budget often does NOT propagate into a background workflow (`budget.total` arrives null), which is exactly how the first maximal run blew past 25M tokens to the agent cap. Deepen a run by raising `maxRounds`/`verifyCap`/`maxFindings` via args, not via the budget. Scope is REQUIRED: every harness errors without `lenses`/`units`/`rules` (pass the explicit string `'all'` to deliberately run everything — there is no whole-fleet accident default); the config log echoes scope + caps.
```
Workflow({ scriptPath: '.claude/skills/predict-audit/orchestrator.workflow.js',
           args: { groundTruth: '<build/test summary>', scope: 'full protocol at HEAD', lenses: ['invariants','adversarial'], maxFindings: 8 } })
Workflow({ scriptPath: '.claude/skills/predict-audit/ownership-walk.workflow.js',
           args: { groundTruth: '<build/test summary>', units: ['predict-plp'], maxViolations: 6 } })
Workflow({ scriptPath: '.claude/skills/predict-audit/rule-sweep.workflow.js',
           args: { groundTruth: '<build/test summary>', rules: ['events-hygiene'], maxFindings: 8 } })
```
**Depth tiers** — pass `depth` to any of the three harnesses (orthogonal to breadth; `low` still runs ALL lenses/units/families, just fewer rounds). An explicit `maxRounds`/`verifyCap`/`maxFindings` arg overrides the preset. All three siblings now read `depth` (ownership-walk uses `maxViolations` where the orchestrator uses `maxFindings`).

| `depth` | rounds / dry | verifyCap | use when |
|---|---|---|---|
| `mini` | `maxRounds 1` | **0** (all raw) | **cleanup triage** — surface easy items cheaply, no verify subagents (you are the verifier), finder effort `medium`; see the mini-pass recipe below |
| `low` | `maxRounds 1` | 30 | **full breadth, low depth** — a cheap complete pass, one sample per lens |
| `standard` *(default)* | `maxRounds 3` / `dryRounds 2` | 60 | the bounded default |
| `max` | `maxRounds 5` / `dryRounds 3` | 100 (+ `maxFindings 16`) | reserve for special runs with ample token budget |

**Scope knobs (breadth, orthogonal to depth):** `profile: 'security'` (orchestrator) runs full bug-hunt breadth minus the cleanup-tier lenses (`surface-area`, `architecture`) whose output is mostly the unverified Info tail — a cheaper pre-merge pass than all 10; `profile: 'cleanup'` is the inverse (ONLY `surface-area` + `assertions` + `architecture`, for the mini pass); an explicit `lenses` arg always wins. See **Incremental & delta runs** below for `files` + `priorAdjudications`.

### Mini pass (cleanup triage — the cheap pre-audit sweep)
Purpose: surface the easy cleanups (mechanical rule violations, hygiene, surface-area/assertion/architecture nits) for the operator to fix or disposition BEFORE a deep run, so the expensive lenses spend their `maxFindings` slots on genuinely new ground instead of re-finding known easy stuff. Everything is reported RAW (`verifyCap 0`, no codex panels) — the operator is the verifier for this tier. ~21 finder agents + 1 promote total, a few hundred k tokens. Still gated: present this plan + cost and get an explicit "yes" first.
```
Workflow({ scriptPath: '.claude/skills/predict-audit/rule-sweep.workflow.js',
           args: { groundTruth: '<build/test summary>', depth: 'mini' } })          # all 17 mechanical families
Workflow({ scriptPath: '.claude/skills/predict-audit/orchestrator.workflow.js',
           args: { groundTruth: '<build/test summary>', profile: 'cleanup', depth: 'mini' } })  # cleanup-tier lenses only
```
Then consolidate + curate as usual (Steps 3–4). The payoff loop: fix or disposition the mini findings, then feed the run's `findings.json` into the deep run's `priorAdjudications` so it doesn't re-report them (drop entries whose cited files changed since — see Incremental & delta runs).

**Step 3 — consolidate in the MAIN LOOP (no-slip guarantee).** Each harness's FULL result is persisted to its task output file — **the notification preview is TRUNCATED; never synthesize from it.** Re-run any failed units first (`Workflow({ scriptPath, resumeFromRunId })`), then run the deterministic consolidator over the full files:
```
python3 .claude/skills/predict-audit/consolidate.py .claude/predict-review/reports/<run>/ <orchestrator.output> <ownership-walk.output> <rule-sweep.output>
```
It emits ONE `consolidated-report.md` (a per-run snapshot under `reports/<run>/`) covering **open + settled + refuted + coverage**, plus `findings.json`, with an `ACCOUNTING — … DROPPED 0` line proving every input finding is accounted for (it exits non-zero if anything would be lost). Write the executive summary *on top of* that report — do NOT hand-pick from the truncated returns.

**Step 4 — reasoned update to the committed worklist.** Manually curate audit findings into `packages/predict/predeploy/open-items.md`, which is the only open-items document and the team-facing consolidated tracker for deploy gates, audit findings, stress-test follow-ups, and manual items. This must be a reasoning pass, not a script or mechanical overwrite:
- Read `packages/predict/predeploy/open-items.md` completely before editing it.
- Compare the new `findings.json` and the per-run `consolidated-report.md` against the committed worklist.
- Preserve manual/non-audit items and existing grouping unless the content is stale.
- Merge by substance, not by exact wording: if a finding is already represented, refresh severity/action/evidence/source as needed instead of duplicating it.
- Add genuinely new findings under the most appropriate existing section, or create a concise new section only when none fits.
- Keep the committed item actionable: state the risk, current evidence, and required action; include the audit finding id only as supporting provenance when useful.
- Remove or edit resolved/stale items only after verifying the current tree or run output supports that change.
- Use normal file edits (`apply_patch` in Codex), not a generated sync, because `open-items.md` is a general curated document and may contain manual items audit output cannot understand.
- **Then run the no-slip check** so a curation drop is loud, not silent (the guarantee `track.py` used to give, without the mechanical merge):
  ```
  python3 .claude/skills/predict-audit/check_curation.py reports/<run>/findings.json packages/predict/predeploy/open-items.md [dispositions.json]
  ```
  It fails unless every `open` finding (and every panel-dead `unverified-panel` finding) is EITHER referenced by its 6-char id in `open-items.md` OR listed in an optional `dispositions.json` (`{ "<id>": "reason" }`) as a conscious merge/refute/duplicate/accept. Write a disposition for anything you curated by substance without pasting the id.

### Incremental & delta runs (the everyday mode)
The whole-codebase last-line-of-defense run is the exception, not the default. For a per-PR or since-last-time audit, scope the run and carry adjudications forward — marginal whole-codebase rounds are the lowest-yield tokens; diff-focused rounds are the highest.
- **`args.files`** (orchestrator + rule-sweep) — the changed files. Lenses/families concentrate on them **plus their direct callers/callees** (grep both directions) and report anywhere the blast radius reaches. Scout the change set in the main loop first (`git diff --name-only <base>..HEAD`), then pass it.
- **Ownership-walk uses `units`, not `files`** — map a changed file to its subsystem cluster and pass `units`:

  | changed path | unit |
  |---|---|
  | `predict/sources/plp/**` | `predict-plp` |
  | `predict/sources/strike_exposure/**` | `predict-strike` |
  | `predict/sources/pricing/**` | `predict-pricing` |
  | `predict/sources/registry/**`, `market_manager` | `predict-registry` |
  | `predict/sources/config/**` | `predict-config` |
  | `predict/sources/capabilities/**` | `predict-capabilities` |
  | `predict/sources/{expiry_market,expiry_cash,order,ewma,builder_code,predict_account,constants}.move` | `predict-core` |
  | `predict/sources/events/**` | `predict-events` |
  | `propbook/**` / `account/**` / `block_scholes_oracle/**` | `propbook` / `account` / `block_scholes_oracle` |

- **`args.priorAdjudications`** (all three) — cross-run memory: the previous run's adjudicated findings so this run doesn't re-find and re-verify the settled ones at full panel cost. Build it from the prior `findings.json` (`refuted` + `settled`; you may include `confirmed` for context but they are NOT suppressed — a still-open bug keeps flowing into `kept[]`), as `[{title, location, status, note?}]`. **A refutation is only valid for the code it was issued against** — before passing an entry, drop any whose cited file appears in `git diff --name-only <that-run's-SHA>..HEAD`; a stale suppression can hide a bug that became real. The orchestrator suppresses exact-key refuted/settled rematches (returned under `prior_rediscovered`); the siblings seed the list into their prompts.
- **Watermark**: record the audited SHA (in `reports/<run>/` or an `open-items.md` note) so the next incremental run scopes `files`/`units` to `git diff` since it and refreshes the watermark.

### Which harness, in what order
- **"Audit Predict" / find bugs** → start with the **lens fan-out** (orchestrator). For a pre-merge pass, add the **ownership walk** + **rule sweep**.
- **Subsystem deep-dive** → ownership walk on that `units` cluster. **Mechanical hygiene** → rule sweep on the relevant `rules`.
- **Maximal end-to-end:** ground truth → run the three harnesses (each bounded by its default caps) → `consolidate.py` → reasoned update to `packages/predict/predeploy/open-items.md`. Run them in **separate turns** (so a slow one doesn't block the others, and to read each full output before the next), but you no longer need a per-turn `+NNNm` budget directive — the caps bound each run regardless. Last-line-of-defense mode, a few hundred agents total. For more depth, raise `maxRounds`/`verifyCap` via args; for a quick pass, scope (`lenses`/`units`/`rules`) + `maxRounds: 1`.

## Hard rules (non-negotiable)
- **Read-only on source.** Never modify `packages/*/sources/**`. Audit-run writes are reports (to `.claude/predict-review/reports/<date>/`, gitignored), temp sims/scripts (to the session scratchpad), and the reasoned curation update to `packages/predict/predeploy/open-items.md`.
- **Compiler/localnet run in the MAIN LOOP, never in a subagent.** `sui build`, `sui test`, and localnet `bash run.sh` trip the 600s subagent watchdog and the run is lost (the CLAUDE.md "Predict Build & Verify" guardrail). The orchestrator runs these itself and passes results in as `args`; subagents reason from source, grep, git, and **Python** sims (fast, watchdog-safe).
- **After editing `consolidate.py`, run `python3 .claude/skills/predict-audit/evals/test_consolidate.py`** (main loop). It locks the no-slip and id/dedup invariants found across skill reviews. It exits non-zero on regression; treat a red as a blocker.
- **Check the REAL exit code.** Never pipe `sui build`/`test` through `tail` (it masks failures). Grep the captured log for `error`/`Test result`, or read `${PIPESTATUS[0]}`.
- **Be prior-aware. Do not re-litigate settled decisions.** Before raising anything, check the committed sources: `AGENTS.md` "Settled design decisions", `packages/predict/predeploy/rounding-policy.md`, and `packages/predict/predeploy/open-items.md`. Do not use local ignored design scratch as authority for audit triage. A finding that matches an accepted/rejected decision is tagged with its D-id or committed-policy reference and downranked to Info, not raised as new.
- **Verify each claim against the function body, not its name.** Trace call sites with grep before judging. Prefer a few verified findings over many speculative ones; rank uncertain items low-confidence rather than overstating.

## The 10 lenses (`lenses/`)
| # | Lens | Hunts |
|---|------|-------|
| 01 | invariants & solvency | conservation, NAV/backing, rounding (R1–R3), value leaks — empirically tested |
| 02 | adversarial audit | actor-by-actor exploit chains + PoCs (theft, mint-from-nothing, brick, extract) |
| 03 | oracle, pricing & numerical | propbook feeds + block_scholes_oracle + `predict::pricing`; fixed-point/sentinel/overflow |
| 04 | access control & capabilities | Move ownership/visibility, cap system, version-gating, cross-package auth |
| 05 | surface-area reduction | dead/over-broad authority paths, eliminable state, behavior-preserving cuts |
| 06 | assertions & error model | guard ownership/placement/dedup, error-name correctness |
| 07 | state machine & lifecycle | phase/lock atomicity, intra-PTB interleaving, stranded/non-landable states |
| 08 | cross-package trust boundaries | the split seams; forgeable/stub inputs; Account custody boundary |
| 09 | economic simulation & invariant fuzzing | localnet + Python adversarial sims that break solvency/NAV/rounding/liquidation |
| 10 | architecture, cohesion & maintainability | overgrown "god" modules, coupling, decomposition/DRY, readability vs the repo's `move.md` conventions |

## References & self-validation
- `references/` — distilled external audit knowledge (Move/Sui checklist, DeFi invariant classes, economic-attack catalog) that lenses cite instead of re-deriving.
- `evals/` — the harness's own regression guards, so it doesn't silently rot as the code changes: `test_consolidate.py` (consolidator no-slip + panel-health render), `verify_corpus.json` + `verify-bench.workflow.js` (verify-panel PRECISION bench — a cheap panel-only run), `seeds.md` (seeded-bug RECALL harness — apply a planted bug, confirm a run catches it), and the `evals.md` checklist (must-rediscover / must-settle / ground-truth-gate). `preflight.py` (skill root) lints primer/D-id drift before a run; `check_curation.py` guards the findings.json → open-items.md hop.

## Operational notes (read before relying on a single run)
- **StructuredOutput flakiness.** A small fraction (~5–15%) of find/check/sweep agents can exhaust the StructuredOutput retry cap on the most verbose units and return nothing (the run reports them under `failures`, and the config log shows what ran). Mitigated by concise-candidate output + proof-in-verify + lower effort, but not eliminated. **Recovery:** `Workflow({scriptPath, resumeFromRunId})` re-runs only the failed units — successful agents return cached — so a partial run is cheaply completed.
- **Run-to-run variance is handled in-harness (loop-until-dry).** LLM finding samples the space rather than enumerating it, so all three harnesses re-run each lens/module/rule across rounds and union until K consecutive dry rounds (`dryRounds`, default 2) or the round cap (`maxRounds`, default 3). (The lens fan-out now applies `dryRounds` **per-lane** — a converged lens retires individually instead of waiting on one global counter.) Tune thoroughness with `maxRounds`/`verifyCap`/`maxFindings` via args — **not** the turn budget: the `+NNNm` directive often does NOT propagate into a background workflow (`budget.total` arrives null), so it's an unreliable bound. A converged run is a strong floor; still treat it as a floor, not a proof of absence. (`resumeFromRunId` still tops up any units a run didn't reach.)
- **Cost is bounded by construction.** Each run's agents ≤ `maxRounds`×(lenses/units/families) + `verifyCap`×panel, and verify is severity-gated (Info/Low/cleanup reported raw, no subagent). At defaults that's well under the 1000-agent cap / a few million tokens. Scope is required (`args.lenses` / `args.units` / `args.rules`, or the explicit `'all'`) — a no-arg launch errors instead of silently running the whole fleet.
- **Cross-model verify needs the codex CLI (all three harnesses).** The verifiers route to the `codex:codex-rescue` agent — a different model than the Claude finder — for bias reduction (the orchestrator keeps the settled-decision verifier on Claude). Spike-verified: codex emits schema-valid `VERDICT_SCHEMA` JSON and re-derives findings from its own git/grep evidence. A `null` verdict (codex unavailable or a StructuredOutput flake) is **retried once on the default Claude agent**; if it still dies, the finding is surfaced as `unverified-panel` (orchestrator) / a `verifier-dead` `unverified` entry (siblings) — never silently dropped or demoted to `uncertain`. High/Critical that lose the panel to attrition (<2 live verdicts) are flagged `panel_degraded`. Codex prompts are kept tightly scoped (it can balloon/hang on open-ended reads). NOTE: codex reasoning effort is governed by codex config, **not** the workflow `effort` knob — confirm it runs at the intended tier when wiring.
- **`kept` is three populations, not one.** The orchestrator returns `kept` sorted `confirmed` → `uncertain` → `unverified-panel`, with per-status counts in `summary` (`kept_confirmed`/`kept_uncertain`/`kept_panel_dead`) and a `panel_severity` field recording the panel's own (upgrades-only-excluded) severity. Triage `confirmed` first; treat `uncertain`/`panel-dead` as needing a human look. The consolidator renders each with its own tag.
