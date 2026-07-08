# DeepBook V3 Agent Guide

This file is the repo-level entry point for coding agents working in `deepbookv3`.

## Start Here

- Read [`CLAUDE.md`](/Users/aslantashtanov/Desktop/Projects/deepbookv3/CLAUDE.md) first.
- Treat `.claude/rules/*.md` as the source of truth for file-type-specific guidance.
- Keep changes scoped. This repo mixes Move contracts, Rust services, and TypeScript scripts.

## Repo Layout

- `packages/` contains Sui Move packages:
  - `deepbook/` is the core protocol.
  - `predict/` is the prediction-market package built on top of DeepBook patterns.
  - `deepbook_margin/`, `margin_trading/`, `margin_liquidation/`, `token/`, `dbtc/`, `dusdc/` are supporting packages.
- `crates/` contains Rust services:
  - `server/`, `indexer/`, `schema/` — the core DeepBook indexer stack
- `scripts/` contains TypeScript transaction and ops scripts.
- `.claude/rules/` contains repo-specific coding, testing, and review guidance.

## Context Routing

**Do not assume the rule files are in your context.** Codex auto-loads this `AGENTS.md` but nothing loads `.claude/rules/*.md` for you (recent Claude Code versions inject them by path via the `paths:` frontmatter; Codex and other agents get no injection). **Before editing a file under one of these globs, open and read the matching rule file.** Read manual-trigger files when the request matches.

### Path-Scoped Rules — read before editing files under the glob

- `.claude/rules/move.md` for `packages/**/*.move`
- `.claude/rules/predict-contracts.md` for the Predict-cluster packages `packages/{predict,propbook,block_scholes_oracle,account}/**/*.move` (also read `move.md`)
- `.claude/rules/unit-tests.md` for `packages/**/tests/**`
- `.claude/rules/predict-harness.md` for `packages/predict/harness/**`
- `.claude/rules/indexer.md` for the CORE crates `crates/{server,indexer,schema}/**` (thin stub)
- `.claude/rules/scripts.md` for `scripts/**`

### Manual-Trigger Rules — read when the request matches

- `.claude/rules/code-review.md` when the user asks for a code review or review of uncommitted changes (for a deep Predict smart-contract audit, invoke the `predict-audit` skill at `.claude/skills/predict-audit/` — `rule-sweep.workflow.js` is the per-rule mechanical sweep, `ownership-walk.workflow.js` the per-module ownership conformance).
- Before proposing/changing any **Predict economics** (NAV/backing, rounding, oracle trust, liquidation, tick/order-id encoding, floor/leverage, supply/withdraw): read `packages/predict/predeploy/README.md` (the system map + authority order), then `open-items.md`, `response-policies.md` (incl. its Rounding policy R1–R3 section), and the settled + rejected lists below. `.claude/predict-design/` and `.redesign/` are personal scratch only — nothing load-bearing lives there; verify any old claim against current HEAD before relying on it.
- `.claude/rules/harness-strategy.md` when the user wants to add or build a Predict harness trading strategy or test a scenario in the harness (also read `.claude/rules/predict-harness.md`).
- `.claude/rules/wrap-up.md` when the user says "wrap up".

## Common Commands

### Move

- Build all Move packages:
  - `sui move build`
- Build a specific package:
  - `sui move build --path packages/predict`
  - `sui move build --path packages/deepbook`
- Run all tests for a package:
  - `sui move test --path packages/predict --gas-limit 100000000000`
  - `sui move test --path packages/deepbook --gas-limit 100000000000`
- Format Move code:
  - `bunx prettier-move -c path/to/file.move --write`

### Rust

- Build server:
  - `cargo build -p deepbook-server`
- Test server:
  - `cargo test -p deepbook-server`

### JavaScript / TypeScript

- Lint:
  - `pnpm run lint`
- Format:
  - `pnpm run prettier:fix`

## Working Norms

- Prefer narrow tests over broad changes. Most bugs here are boundary-condition bugs.
- For Move work, run the smallest relevant package test suite before expanding scope.
- For protocol changes, add or update unit tests in the package you touched.
- For complex unit tests, follow the existing style in core DeepBook tests:
  - short scenario comments above the test
  - inline arithmetic comments when expected values are not obvious
- Do not assume generated fixtures are authoritative if the on-chain integer math differs; test the contract behavior directly when needed.

## Predict Package Notes

- Predict sources are organized by domain subsystem, not by visibility. See `.claude/rules/predict-contracts.md` for the canonical layout rule.
- Predict tests mirror source domain folders except shared helpers and broad flow tests.
- If you change Predict pricing, pool/vault accounting, oracle math, or public protocol flows, rerun the full Predict suite:
  - `sui move test --path packages/predict --gas-limit 100000000000`

## Predict Rework — LANDED (oracle extraction + tick re-encode + async NAV/LP)

The three reworks are **landed on `main`**: the oracle
extracted to the standalone `propbook` feeds (`predict_math`→`fixed_math`), strikes
re-encoded as absolute integer ticks, and the pool/NAV/LP layer rebuilt async with a
privileged flush + exact `current_nav` mark. Source builds `--warnings-are-errors`
green; `sui move test --path packages/predict --gas-limit 100000000000` is green; docs
are current. The earlier build-phase directives (source-only / defer-tests / defer-docs)
are **retired** — the normal norms (tests + docs land with code) apply again.

**Design decisions live in `packages/predict/docs/design/decisions.md`** — the canonical record of
Predict's settled design decisions and rejected directions, with rationale and revisit conditions.
Tail-state response decisions live in `packages/predict/predeploy/response-policies.md` (the RP
register); open questions in `packages/predict/predeploy/open-items.md`. **Do not re-litigate a
settled decision or reintroduce a rejected direction without meeting the revisit condition stated in
`decisions.md`;** record any new design decision there, not here.

## Code Review Norms

- When the user asks for a review, read `.claude/rules/code-review.md` before producing findings and review the relevant diff in a code-review stance.
- For Move reviews, also read `.claude/rules/move.md` and `.claude/rules/unit-tests.md`.
- For a deep Predict smart-contract audit (predict + propbook + block_scholes_oracle + account), invoke the **`predict-audit`** skill (`.claude/skills/predict-audit/`): read its `primer.md` + the relevant `lenses/NN-*.md`, or launch `orchestrator.workflow.js` (lens fan-out), `ownership-walk.workflow.js` (per-module ownership/boundary/policy conformance, R1–R7), or `rule-sweep.workflow.js` (per-rule mechanical sweep).

## When Updating Repo Guidance

Update `CLAUDE.md` or `.claude/rules/*.md` when you learn something that should change future agent behavior, especially:

- newly discovered bug patterns
- test-writing rules
- package-specific gotchas
- build or tooling pitfalls
