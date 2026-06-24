---
name: predict-audit
description: Deep, multi-lens security & correctness audit of the DeepBook Predict smart contracts (the predict + propbook + block_scholes_oracle + account Move source). Use when asked to audit Predict, hunt bugs/invariant-violations/exploits in Predict, review Predict contract changes before merge, or assess economic safety of the Predict protocol. Smart-contract audit — finds bugs, invariant violations, exploits, and architecture/maintainability issues; it does not check deploy/ops readiness. RUNNING IT IS EXPENSIVE (a full run is hundreds of subagents / up to ~100M tokens) and REQUIRES explicit user confirmation before every run — never execute it automatically.
---

# Predict Smart-Contract Audit

## ⛔ STOP — explicit run confirmation is MANDATORY
This skill launches **expensive multi-agent audits** — a maximal end-to-end run is **hundreds of subagents and up to ~100M tokens**. It must NEVER run automatically or as a side effect of being invoked, read, or mentioned.

**Before launching ANY harness run (`orchestrator` / `ownership-walk` / `rule-sweep`), you MUST:**
1. Show the user the run plan: which harness(es), the scope (`lenses` / `units` / `rules`, or "full"), `dryRounds`, and the budget / rough cost (agent count, token estimate).
2. Ask explicitly — e.g. *"Run this audit? (≈N agents / ≈X tokens)"* — and **WAIT for an explicit "yes."**
3. Only after the user confirms, call `Workflow(...)`. If anything is ambiguous, ask; never assume.

Invoking, reading, explaining, or editing this skill never needs the gate — **only *executing a harness run* does.** When in doubt, do not run.

A self-driving harness for a deep, adversarial, **smart-contract-only** audit of DeepBook "Predict" — a leveraged binary prediction market on Sui — and its three split-out sibling packages. The goal is to **find real bugs**: solvency/fund-loss, liveness/abort (a bricked flow), griefing/DoS, mispricing, broken invariants, and authorization holes — plus, via a dedicated lens, architecture/cohesion/readability issues (overgrown "god" modules, coupling, decomposition). Findings are reasoned from the code AND, where it matters, **empirically reproduced** on localnet or in Python.

This is a *code-audit* skill (security/correctness + maintainability). It does NOT do testnet-readiness/deploy/ops checks (Move.toml hygiene, post-deploy admin steps, indexer parity, runbooks). If asked for those, say so and scope them separately.

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
3. **Adversarial verify.** Every candidate finding is independently refuted/confirmed; High/Critical get an empirical-repro attempt.
4. **Empirical deep pass (required).** The economic-simulation lens runs the localnet + Python sims and writes new adversarial scenarios to actually break invariants.
5. **Consolidate (no-slip) + synthesize.** Read each harness's FULL output file (the notification preview is truncated), run `consolidate.py` to deterministically merge all three into ONE `consolidated-report.md` covering **open + settled + refuted + coverage** with a `DROPPED 0` accounting guarantee, then write the executive summary on top. The orchestrator's promote pass + the consolidator's coverage section catch buried items; never hand-pick from a truncated return.

## Harnesses
Three complementary review *shapes*, all sharing this `primer.md`, the report format, and the read-only / compiler-in-main-loop discipline. Read `primer.md` first either way.
- **Lens fan-out** — `orchestrator.workflow.js`: the 10 perspective lenses (broad multi-angle bug hunt). Or hand a single `lenses/NN-*.md` to one session. Scope with `args.lenses`.
- **Ownership walk** — `ownership-walk.workflow.js`: recursive *per-module* conformance against the contextual ownership/boundary/policy rules in `references/ownership-rules.md` (R1–R7). Map (barrier) → per-module check → adversarial verify; the unit of work is a code node, not a perspective. Scope with `args.units` (subsystem clusters). Use this for "who owns what / where are boundaries violated."
- **Rule sweep** *(refreshed from the old root `rule-auditor.md`)* — `rule-sweep.workflow.js`: per-*rule* sweep for the 11 mechanical/local rule families (config-reads, config API shape, public-API exposure, object-identity keys, `create_and_share` naming, ProtocolConfig gate matrix, arithmetic-guard noise, test-coverage, timestamp semantics, events hygiene, **dead-field liveness** — the exhaustive write-only / read-only-mirror sweep that catches the rebate-reserve bug class). Broad-shallow is correct there; the contextual ownership families (ex-rule-auditor 6/8/9) live in the ownership walk instead. Scope with `args.rules`.

Axis split: lenses = perspective × whole codebase; ownership walk = per-module (deep context); rule sweep = per-rule × whole codebase (mechanical).

## Launching a run (copyable)
**Step 1 — ground truth, MAIN LOOP only** (feeds every subagent via `args.groundTruth`; a wrong command starts the run from a false "all green"):
```
sui move build --path packages/<pkg> --warnings-are-errors   # pkg ∈ predict propbook account block_scholes_oracle
sui move test  --path packages/<pkg> --gas-limit 100000000000   # each of the four (predict is the big suite)
(cd packages/predict/simulations && bash run.sh --python-only)   # sim smoke; localnet `bash run.sh` is also main-loop-only
```
**Step 2 — launch a harness.** Each **loops-until-dry** (tune `dryRounds`/`maxRounds`). Precede the turn with a budget directive (e.g. `+100m`) to cap a maximal full run — it loops until ~70% spent, reserving 30% for verify. Scope with `lenses`/`units`/`rules`; the config log echoes scope + budget. The no-arg default loops the WHOLE fleet until dry (= maximal mode):
```
Workflow({ scriptPath: '.claude/skills/predict-audit/orchestrator.workflow.js',
           args: { groundTruth: '<build/test summary>', scope: 'full protocol at HEAD', lenses: ['invariants','adversarial'], maxFindings: 8 } })
Workflow({ scriptPath: '.claude/skills/predict-audit/ownership-walk.workflow.js',
           args: { groundTruth: '<build/test summary>', units: ['predict-plp'], maxViolations: 6 } })
Workflow({ scriptPath: '.claude/skills/predict-audit/rule-sweep.workflow.js',
           args: { groundTruth: '<build/test summary>', rules: ['events-hygiene'], maxFindings: 8 } })
```
**Step 3 — consolidate in the MAIN LOOP (no-slip guarantee).** Each harness's FULL result is persisted to its task output file — **the notification preview is TRUNCATED; never synthesize from it.** Re-run any failed units first (`Workflow({ scriptPath, resumeFromRunId })`), then run the deterministic consolidator over the full files:
```
python3 .claude/skills/predict-audit/consolidate.py .claude/predict-review/reports/<run>/ <orchestrator.output> <ownership-walk.output> <rule-sweep.output>
```
It emits ONE `consolidated-report.md` (a per-run snapshot under `reports/<run>/`) covering **open + settled + refuted + coverage**, plus `findings.json`, with an `ACCOUNTING — … DROPPED 0` line proving every input finding is accounted for (it exits non-zero if anything would be lost). Write the executive summary *on top of* that report — do NOT hand-pick from the truncated returns.

**Step 4 — update the ONE live tracker.** Merge this run's open findings into the single persistent worklist:
```
python3 .claude/skills/predict-audit/track.py .claude/predict-review/ merge --run <run-id> .claude/predict-review/reports/<run>/findings.json
```
`.claude/predict-review/OPEN-ITEMS.md` is the single place to work from — severity-sorted, **deduped by a stable per-issue id across runs** (so re-runs update in place, never duplicate), with a per-run changelog (`+new ~updated ↑re-opened`). Fix code → delete the item's block (or `track.py … resolve <id>` / `wontfix <id>`); a later run **re-opens (⚠) anything you resolved that the audit still finds**. (The tracker lives in the gitignored reports dir — commit `OPEN-ITEMS.md` if you want it shared with the team.)

### Which harness, in what order
- **"Audit Predict" / find bugs** → start with the **lens fan-out** (orchestrator). For a pre-merge pass, add the **ownership walk** + **rule sweep**.
- **Subsystem deep-dive** → ownership walk on that `units` cluster. **Mechanical hygiene** → rule sweep on the relevant `rules`.
- **Maximal end-to-end:** ground truth → run the three harnesses loop-until-dry, **each in its OWN turn with its OWN budget directive** — they share the turn's `budget` pool, so launching all three in one turn starves the later two; give each e.g. a `+35m` → `consolidate.py` → `track.py`. Last-line-of-defense mode, hundreds of agents. Quick pass instead: scope + `dryRounds: 1`.

## Hard rules (non-negotiable)
- **Read-only on source.** Never modify `packages/*/sources/**`. The only writes are reports (to `.claude/predict-review/reports/<date>/`, gitignored) and temp sims/scripts (to the session scratchpad).
- **Compiler/localnet run in the MAIN LOOP, never in a subagent.** `sui build`, `sui test`, and localnet `bash run.sh` trip the 600s subagent watchdog and the run is lost (repo guardrail D004). The orchestrator runs these itself and passes results in as `args`; subagents reason from source, grep, git, and **Python** sims (fast, watchdog-safe).
- **After editing `consolidate.py` or `track.py`, run `python3 .claude/skills/predict-audit/evals/test_consolidate_track.py`** (main loop). It locks the no-slip / id↔dedup / tracker invariants found across three reviews — each round's fix kept introducing the next round's silent-slip bug. It exits non-zero on regression and is verified to actually fail when a fix is reverted; treat a red as a blocker.
- **Check the REAL exit code.** Never pipe `sui build`/`test` through `tail` (it masks failures). Grep the captured log for `error`/`Test result`, or read `${PIPESTATUS[0]}`.
- **Be prior-aware. Do not re-litigate settled decisions.** Before raising anything, check `.claude/predict-design/DECISION_JOURNAL.md` (D000–latest), `HISTORY.md`, the `AGENTS.md` "Settled design decisions" block, and `ROUNDING_POLICY.md`. A finding that matches an accepted/rejected decision is tagged with its D-id and downranked to Info, not raised as new.
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
- `evals/` — seeded known-issues that a full run must catch, so the harness doesn't silently rot as the code changes.

## Operational notes (read before relying on a single run)
- **StructuredOutput flakiness.** A small fraction (~5–15%) of find/check/sweep agents can exhaust the StructuredOutput retry cap on the most verbose units and return nothing (the run reports them under `failures`, and the config log shows what ran). Mitigated by concise-candidate output + proof-in-verify + lower effort, but not eliminated. **Recovery:** `Workflow({scriptPath, resumeFromRunId})` re-runs only the failed units — successful agents return cached — so a partial run is cheaply completed.
- **Run-to-run variance is handled in-harness (loop-until-dry).** LLM finding samples the space rather than enumerating it, so all three harnesses re-run each lens/module/rule across rounds and union until K consecutive dry rounds (`dryRounds`, default 2–3) or the budget floor. Tune thoroughness with `dryRounds`/`maxRounds` and the turn budget — e.g. a **`+100m`** directive makes a run keep going until ~70% spent (30% reserved for verify). A converged run is a strong floor; still treat it as a floor, not a proof of absence. (`resumeFromRunId` still tops up any units a run didn't reach.)
- **Cost.** A full lens or ownership-walk run is dozens of agents / millions of tokens. Always scope first (`args.lenses` / `args.units` / `args.rules`) and check the config log; the no-arg default runs the whole fleet.
