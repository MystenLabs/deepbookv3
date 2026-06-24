---
name: predict-audit
description: Deep, multi-lens security & correctness audit of the DeepBook Predict smart contracts (the predict + propbook + block_scholes_oracle + account Move source). Use when asked to audit Predict, hunt bugs/invariant-violations/exploits in Predict, review Predict contract changes before merge, or assess economic safety of the Predict protocol. Pure smart-contract audit — finds bugs, it does not check deploy/ops readiness.
---

# Predict Smart-Contract Audit

A self-driving harness for a deep, adversarial, **smart-contract-only** audit of DeepBook "Predict" — a leveraged binary prediction market on Sui — and its three split-out sibling packages. The goal is to **find real bugs**: solvency/fund-loss, liveness/abort (a bricked flow), griefing/DoS, mispricing, broken invariants, and authorization holes. Findings are reasoned from the code AND, where it matters, **empirically reproduced** on localnet or in Python.

This is a *pure audit* skill. It does NOT do testnet-readiness/deploy/ops checks (Move.toml hygiene, post-deploy admin steps, indexer parity, runbooks). If asked for those, say so and scope them separately.

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
2. **Parallel find.** Fan the 9 lenses out concurrently; each is prior-aware and returns structured findings.
3. **Adversarial verify.** Every candidate finding is independently refuted/confirmed; High/Critical get an empirical-repro attempt.
4. **Empirical deep pass (required).** The economic-simulation lens runs the localnet + Python sims and writes new adversarial scenarios to actually break invariants.
5. **Synthesis.** Dedup, severity-rank, and emit one consolidated audit report (report format in `primer.md`).

Run it via the orchestrator (`orchestrator.workflow.js`) for the full automated pipeline, or hand a single `lenses/NN-*.md` file to one session for a focused pass. Either way, read `primer.md` first.

## Hard rules (non-negotiable)
- **Read-only on source.** Never modify `packages/*/sources/**`. The only writes are reports (to `.claude/predict-review/reports/<date>/`, gitignored) and temp sims/scripts (to the session scratchpad).
- **Compiler/localnet run in the MAIN LOOP, never in a subagent.** `sui build`, `sui test`, and localnet `bash run.sh` trip the 600s subagent watchdog and the run is lost (repo guardrail D004). The orchestrator runs these itself and passes results in as `args`; subagents reason from source, grep, git, and **Python** sims (fast, watchdog-safe).
- **Check the REAL exit code.** Never pipe `sui build`/`test` through `tail` (it masks failures). Grep the captured log for `error`/`Test result`, or read `${PIPESTATUS[0]}`.
- **Be prior-aware. Do not re-litigate settled decisions.** Before raising anything, check `.claude/predict-design/DECISION_JOURNAL.md` (D000–latest), `HISTORY.md`, the `AGENTS.md` "Settled design decisions" block, and `ROUNDING_POLICY.md`. A finding that matches an accepted/rejected decision is tagged with its D-id and downranked to Info, not raised as new.
- **Verify each claim against the function body, not its name.** Trace call sites with grep before judging. Prefer a few verified findings over many speculative ones; rank uncertain items low-confidence rather than overstating.

## The 9 lenses (`lenses/`)
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

## References & self-validation
- `references/` — distilled external audit knowledge (Move/Sui checklist, DeFi invariant classes, economic-attack catalog) that lenses cite instead of re-deriving.
- `evals/` — seeded known-issues that a full run must catch, so the harness doesn't silently rot as the code changes.
