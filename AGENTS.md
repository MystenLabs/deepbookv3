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

## Auto-Loaded Rule Files

These are the most important rule files to consult based on the code you touch:

- `.claude/rules/move.md` for `packages/**/*.move`
- `.claude/rules/unit-tests.md` for `packages/**/tests/**`
- `.claude/rules/code-review.md` when reviewing Move changes
- `.claude/rules/indexer.md` for `crates/server/**`, `crates/indexer/**`, `crates/schema/**`
- `.claude/rules/scripts.md` for `scripts/**`

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
  - `bunx prettier-move -c *.move --write`

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

- `packages/predict/tests/generated_tests/` contains generated fixture-based tests.
- Hand-written protocol behavior tests live in:
  - `packages/predict/tests/predict_tests.move`
  - `packages/predict/tests/vault/vault_tests.move`
  - related helper and manager test files under `packages/predict/tests/`
- If you change predict pricing, vault accounting, or oracle math, rerun the full predict suite:
  - `sui move test --path packages/predict --gas-limit 100000000000`
- Predict config rules:
  - Split config into two classes: admin-tunable values and upgrade-required values.
  - Admin-tunable values live in config structs and are updated only through admin-gated entrypoints.
  - Upgrade-required values stay as constants/macros and do not get config structs, setters, bounds, or admin flows.
  - Each admin-tunable value should have a stored field plus package-only `default_*`, `min_*`, `max_*`, and `assert_*` helpers in `config_constants.move`.
  - For admin-tunable values, `config_constants.move` is only for config construction and config update validation. App-layer protocol logic must not read admin-tunable defaults, min bounds, or max bounds directly; it should read the current value from the relevant config object.
  - Upgrade-required values are read directly from constants/macros by the app logic that needs them. Do not hide upgrade-only constants behind config struct getters.
  - For admin-tunable values, constants define the allowed envelope and initialization default, while config structs hold the current protocol value. Runtime logic should treat config fields as plain numbers and should not know which constants produced or bounded them.
  - Each `assert_*` helper should use a specific error code for that config value.
  - Defaults are applied in the module that creates the config/object.
  - Global template config can be snapshotted into per-object state at creation; existing objects should only change through an explicit admin path if one is intentionally added.
  - Name global-template setters with `template` when the value affects future objects but not existing objects.
  - External admin entrypoints live in the admin/router module, currently `registry`; config struct setters stay `public(package)`.
  - Single-value bounds live in `config_constants::assert_*`; relational checks that depend on multiple fields live in the owning config setter.
  - Do not store generic `config_id` fields inside config structs or events; object identity is enough when identity matters.
  - Do not add singleton creation flags for objects created during package init.
  - Per-market oracle bounds can be tunable by `MarketOracleCap`; this is an intentional per-oracle operator control, not a generic admin config path.
  - Public visibility is an API commitment, not secrecy; on-chain state is still observable.
  - Keep admin-tunable config structs readable inside the package by default.
  - Expose public getters only for values needed by external Move composition, PTB construction, or clear user-facing protocol state.
  - Keep config constructors, setters, bounds checks, and template/snapshot wiring `public(package)`.
- Predict naming and API rules:
  - Functions that create and share a shared object should be named `create_and_share`.
  - Pyth Lazer feed IDs should use `u32` consistently across Predict.
  - Avoid created events unless there is a concrete indexer or off-chain discovery requirement.
  - Raw key constructors that take arbitrary object IDs should stay package-only; expose public constructors through the object that anchors the key, using immutable references when possible.

## Code Review Norms

- Findings should focus on correctness, regressions, missing coverage, and brittle assumptions.
- For generated-test changes, check for:
  - duplicate scenarios
  - overly loose assertions
  - hardcoded fixture indices that can silently drift

## When Updating Repo Guidance

Update `CLAUDE.md` or `.claude/rules/*.md` when you learn something that should change future agent behavior, especially:

- newly discovered bug patterns
- test-writing rules
- package-specific gotchas
- build or tooling pitfalls
