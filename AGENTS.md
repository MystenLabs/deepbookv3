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
  - `server/`, `indexer/`, `schema/`
- `scripts/` contains TypeScript transaction and ops scripts.
- `.claude/rules/` contains repo-specific coding, testing, and review guidance.

## Context Routing

These are the context files to consult. Path-scoped files are normally loaded by the agent runtime based on touched files; manual-trigger files must be read when the request matches the trigger.

### Path-Scoped Rules

- `.claude/rules/move.md` for `packages/**/*.move`
- `.claude/rules/unit-tests.md` for `packages/**/tests/**`
- `.claude/rules/indexer.md` for `crates/server/**`, `crates/indexer/**`, `crates/schema/**`
- `.claude/rules/scripts.md` for `scripts/**`
- `.claude/rules/predict-simulations.md` for `packages/predict/simulations/**`

### Manual-Trigger Rules

- `.claude/rules/code-review.md` when the user asks for a code review or review of uncommitted changes.
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

- Predict sources are organized by domain subsystem, not by visibility. See `.claude/rules/move.md` for the canonical layout rule.
- Predict tests mirror source domain folders except shared helpers and broad flow tests.
- If you change Predict pricing, pool/vault accounting, oracle math, or public protocol flows, rerun the full Predict suite:
  - `sui move test --path packages/predict --gas-limit 100000000000`

## Code Review Norms

- When the user asks for a review, read `.claude/rules/code-review.md` before producing findings and review the relevant diff in a code-review stance.
- For Move reviews, also read `.claude/rules/move.md` and `.claude/rules/unit-tests.md`.

## When Updating Repo Guidance

Update `CLAUDE.md` or `.claude/rules/*.md` when you learn something that should change future agent behavior, especially:

- newly discovered bug patterns
- test-writing rules
- package-specific gotchas
- build or tooling pitfalls
