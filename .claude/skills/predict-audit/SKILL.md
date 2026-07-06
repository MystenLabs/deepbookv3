---
name: predict-audit
description: Deep, multi-lens security & correctness audit of the DeepBook Predict smart contracts (the predict + propbook + block_scholes_oracle + account Move source). Use when asked to audit Predict, hunt bugs/invariant-violations/exploits in Predict, review Predict contract changes before merge, or assess economic safety of the Predict protocol. Smart-contract audit — finds bugs, invariant violations, exploits, and architecture/maintainability issues; it does not check deploy/ops readiness. RUNNING IT IS EXPENSIVE (a whole-fleet run is dozens of agents / a few million tokens; every harness requires an explicit scope and bounds its own agent count by construction) and REQUIRES explicit user confirmation before every run — never execute it automatically.
---

# Predict Smart-Contract Audit

## ⛔ STOP — explicit run confirmation is MANDATORY
This skill launches **expensive multi-agent audits** — a whole-fleet run (all three harnesses at `'all'` scope) is dozens of agents and a few million tokens. Each harness requires an explicit scope and bounds its own agent count by construction, so it cannot go maximal by accident — but it must NEVER run automatically or as a side effect of being invoked, read, or mentioned.

**Before launching ANY harness run (`orchestrator` / `ownership-walk` / `rule-sweep`), you MUST:**
1. Show the user the run plan — which harness(es) and scope (`lenses` / `units` / `rules`; the explicit string `'all'` is the whole-fleet opt-in) — plus cost. Quote cost from the LAST run's measured actuals (its usage block records agents and tokens), never from intuition: guessed estimates have been 2x+ wrong.
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
2. **Find.** The orchestrator's lenses loop-until-dry (bug findings are SAMPLED, so each lens re-runs — bounded by `maxRounds`, retiring per-lane once dry — until it stops surfacing new ones). The rule sweep and ownership walk are SINGLE-PASS: mechanical and per-module conformance ENUMERATE rather than sample, and the next run is round 2.
3. **Adversarial verify — High/Critical only, cross-model.** Only findings that can lose funds or brick a flow earn verify subagents: the orchestrator panels High/Critical (codex refute + codex repro + Claude settled — an escalated finding clears a different model than the one that found it; needs the codex CLI), the walk sends its 'high' violations to one codex verifier. Everything Medium and below is reported RAW — **the operator is the verifier for that tail** (that is where dispositions actually come from). A null codex verdict retries once on Claude, then surfaces as `unverified-panel` rather than silently degrading.
4. **Empirical deep pass.** The economic-simulation lens (orchestrator 09) runs the localnet + Python sims and writes new adversarial scenarios to actually break invariants.
5. **Consolidate (no-slip) + curate.** Read each harness's FULL output file (the notification preview is truncated), run `consolidate.py` to deterministically merge all three into ONE `consolidated-report.md` covering **open + settled + refuted + coverage** with a `DROPPED 0` accounting guarantee, then reason over the committed `packages/predict/predeploy/open-items.md` and curate findings into it. The consolidator's coverage section catches buried items; never hand-pick from a truncated return.

## Harnesses
Three complementary review *shapes*, all sharing this `primer.md`, the report format, and the read-only / compiler-in-main-loop discipline. Read `primer.md` first either way. Scope is REQUIRED for each — there is no whole-fleet default.
- **Lens fan-out** — `orchestrator.workflow.js`: the 10 perspective lenses (broad multi-angle bug hunt). Or hand a single `lenses/NN-*.md` to one session. Scope with `lenses: [<keys>]`, `'security'` (all lenses minus the cleanup-tier pair surface-area + architecture — the default choice for a bug hunt), or `'all'`. Loops until dry with per-lane retirement (`maxRounds` 3 / `dryRounds` 2 defaults; explicit cap args are the only tuning knobs) and panels High/Critical findings cross-model.
- **Ownership walk** — `ownership-walk.workflow.js`: recursive *per-module* conformance against the contextual ownership/boundary/policy rules in `references/ownership-rules.md` (R1–R7). Map (barrier) → single per-module check pass → one codex verifier per 'high' violation ('correctness'/'cleanup' reported raw). Scope with `units: [<keys>]` or `'all'`. Use this for "who owns what / where are boundaries violated."
- **Rule sweep** *(refreshed from the old root `rule-auditor.md`)* — `rule-sweep.workflow.js`: per-*rule* sweep for the 17 mechanical/local rule families (config-reads, config API shape, public-API exposure, object-identity keys, `create_and_share` naming, ProtocolConfig gate matrix, arithmetic-guard noise, test-coverage, timestamp semantics, events hygiene, **dead-field liveness** — the exhaustive write-only / read-only-mirror sweep that catches the rebate-reserve bug class — plus the hygiene trio **signature-shape** / **module-layout** / **comment-hygiene** and the polish trio **test-independence** / **docs-drift** / **abort-code-multiplexing**). ONE agent per family, ALL findings raw — the operator is the verifier for this mechanical tier (it enumerates, it doesn't sample). Scope with `rules: [<keys>]` or `'all'`. The contextual ownership families (ex-rule-auditor 6/8/9) live in the ownership walk instead.

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

**Step 2 — launch a harness.** Scope is REQUIRED (`lenses`/`units`/`rules`; the explicit `'all'` is the whole-fleet opt-in — a no-arg launch errors with the valid keys). The orchestrator loops-until-dry but is BOUNDED BY CONSTRUCTION (`maxRounds 3` / `dryRounds 2` / `verifyCap 60` defaults; total agents ≤ `maxRounds`×lenses + `verifyCap`×panel); the siblings are single-pass (1 agent per family / check unit, plus the walk's 'high'-tier verifiers). **Do NOT rely on a `+NNNm` budget directive to bound a run** — the budget often does NOT propagate into a background workflow (`budget.total` arrives null). Deepen the orchestrator by raising `maxRounds`/`verifyCap`/`maxFindings` via args; deepen a sibling by running it again (the next run is round 2).
```
Workflow({ scriptPath: '.claude/skills/predict-audit/orchestrator.workflow.js',
           args: { groundTruth: '<build/test summary>', scope: 'delta since <sha>', lenses: 'security', files: ['<changed file>', '...'] } })
Workflow({ scriptPath: '.claude/skills/predict-audit/ownership-walk.workflow.js',
           args: { groundTruth: '<build/test summary>', units: ['predict-plp'] } })
Workflow({ scriptPath: '.claude/skills/predict-audit/rule-sweep.workflow.js',
           args: { groundTruth: '<build/test summary>', rules: 'all' } })
```

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
The whole-codebase last-line-of-defense run is the exception, not the default. For a per-PR or since-last-time audit, scope the run — marginal whole-codebase rounds are the lowest-yield tokens; diff-focused rounds are the highest.
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

- **Cross-run memory lives in the committed registers, not in run artifacts.** There is no adjudication carry between runs: a disposition worth remembering is promoted into AGENTS.md "Settled design decisions" / `response-policies.md` / `open-items.md` (one home, no staleness filter), and finders/verifiers are prior-aware via those registers. A disposition not worth committing is not worth carrying.
- **Watermark**: record the audited SHA (in `reports/<run>/` or an `open-items.md` note) so the next incremental run scopes `files`/`units` to `git diff` since it and refreshes the watermark.

### Which harness, in what order
- **"Audit Predict" / find bugs** → the **lens fan-out** with `lenses:'security'` (delta-scope via `files` for a change set). For a pre-merge pass, add the **ownership walk** + **rule sweep** on the touched units/families.
- **Subsystem deep-dive** → ownership walk on that `units` cluster. **Mechanical hygiene / cleanup triage** → rule sweep (raw findings; you triage) — add the cleanup lenses (`lenses: ['surface-area','assertions','architecture']`) when hunting surface/assertion/architecture cleanups specifically.
- **Last-line-of-defense (pre-deploy):** ground truth → all three harnesses at `'all'` scope in **separate turns** (so a slow one doesn't block the others, and to read each full output before the next) → `consolidate.py` → reasoned update to `packages/predict/predeploy/open-items.md`.

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

Lenses 05 and 10 are the cleanup tier — excluded from `lenses:'security'`; name them explicitly (or use `'all'`) when cleanup is the goal.

## References & self-validation
- `references/` — distilled external audit knowledge (Move/Sui checklist, DeFi invariant classes, economic-attack catalog) that lenses cite instead of re-deriving.
- `evals/` — the harness's own regression guards, so it doesn't silently rot as the code changes: `test_consolidate.py` (consolidator no-slip + panel-health render), `verify_corpus.json` + `verify-bench.workflow.js` (verify-panel PRECISION bench — a cheap panel-only run), `seeds.md` (seeded-bug RECALL harness — apply a planted bug, confirm a run catches it), and the `evals.md` checklist (must-rediscover / must-settle / ground-truth-gate). `preflight.py` (skill root) lints primer/D-id drift before a run; `check_curation.py` guards the findings.json → open-items.md hop.

## Operational notes (read before relying on a single run)
- **StructuredOutput flakiness.** A small fraction (~5–15%) of find/check/sweep agents can exhaust the StructuredOutput retry cap on the most verbose units and return nothing (the run reports them under `failures`/`failed_families`/`failed_check_units`, and the config log shows what ran). Mitigated by concise-candidate output + lower effort, but not eliminated. **Recovery:** `Workflow({scriptPath, resumeFromRunId})` re-runs only the failed units — successful agents return cached — so a partial run is cheaply completed.
- **Run-to-run variance.** The orchestrator handles it in-harness (loop-until-dry with per-lane retirement — a converged lens retires individually). The sweep and walk are deliberately single-pass: their content enumerates rather than samples (in the last multi-round run no family or lane ever retired dry, and the extra rounds only lengthened the raw tail) — re-run them to sample again; the union across runs replaces rounds within one. A converged run is a strong floor; still treat it as a floor, not a proof of absence.
- **Cost is bounded by construction.** Orchestrator agents ≤ `maxRounds`×lenses + `verifyCap`×panel; siblings ≤ 1 agent per family / check unit (+ the walk's 'high' verifiers, capped by `verifyCap`). Verify is severity-gated — only High/Critical (orchestrator) and 'high' (walk) findings get subagents; the rest is raw for operator triage. Machine-verifying the tail was the historical cost blow-up; the operator dispositions it faster and cheaper.
- **Cross-model verify needs the codex CLI.** The orchestrator's High/Critical panel runs codex refute + codex repro + Claude settled; the walk's 'high' verifier runs on codex — a different model than the Claude finder, for bias reduction. A `null` verdict (codex unavailable or a StructuredOutput flake) is **retried once on the default Claude agent**; if it still dies, the finding is surfaced as `unverified-panel` / a `verifier-dead` `unverified` entry — never silently dropped. High/Critical that lose the panel to attrition (<2 live verdicts) are flagged `panel_degraded`. Codex prompts are kept tightly scoped (it can balloon/hang on open-ended reads). NOTE: codex reasoning effort is governed by codex config, **not** the workflow `effort` knob — confirm it runs at the intended tier when wiring.
- **`kept` is three populations, not one** (orchestrator). `kept` is sorted `confirmed` → `uncertain` → `unverified-panel`, with per-status counts in `summary` (`kept_confirmed`/`kept_uncertain`/`kept_panel_dead`) and a `panel_severity` field recording the panel's own (upgrades-only-excluded) severity. Triage `confirmed` first; treat `uncertain`/`panel-dead` as needing a human look. The consolidator renders each with its own tag.
