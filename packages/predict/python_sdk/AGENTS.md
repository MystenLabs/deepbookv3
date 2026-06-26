# Predict Python SDK Agent Guide

This file is the SDK-local entry point for agents working in
`packages/predict/python_sdk`. The repo-level `AGENTS.md` and `CLAUDE.md` still
apply; this file only adds SDK-specific routing.

## Start Here

- Read `README.md` for the user-facing package contract.
- Read `docs/sdk-map.md` before making non-trivial SDK changes.
- Keep SDK changes scoped to this package unless the request explicitly crosses into
  Move contracts, deployment artifacts, or services.

## Core Invariants

- Trading is included in the base package install; PyNaCl is not a `tx` extra.
- CLI write commands are dry-run by default and submit only with `--execute`.
- The indexer is the data plane: observe/monitor reads come from the predict-server +
  oracle service (D001). The chain is the execution plane — dry-run, submit, refs, and
  the one live value the indexer lacks, a market's `reference_tick` (D002).
- The data-plane clients fail open: observe commands degrade to "unavailable" rather
  than crashing, and trading still works when the indexer is down.
- There is no off-chain Predict pricer in this SDK. Discover entry probability and
  premium by dry-running a real mint and reading the returned `OrderMinted` event.
- Keep tests offline by default. Do not require live testnet, private keys, or funded
  wallets in normal unit tests.
- Do not commit `.env`; it is local operator state.

## Context Routing

Before editing these files, read the matching context doc:

- `predict_sdk/actions.py`, `tx.py`, `bcs.py`, `signer.py`, `gas.py`:
  read `docs/write-path.md`.
- `predict_sdk/observability.py`, `indexer.py`, `render.py`:
  read `docs/read-path.md`.
- `predict_sdk/cli.py`: read `docs/sdk-map.md`, then `docs/read-path.md` or
  `docs/write-path.md` depending on the command surface.
- `predict_sdk/portfolio.py`, `dashboard.py`: read
  `docs/sdk-map.md` and `docs/reuse-guide.md`.
- `predict_sdk/config.py`, `constants.py`, `deployments/**`: read `docs/sdk-map.md`
  and `docs/decisions.md`.
- `pyproject.toml`, packaging, install docs, or tests: read `docs/development.md`
  and `docs/decisions.md`.

## Common Commands

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
pip install -e ".[tui]"
PYTHONPATH=. python3 -m unittest discover -s tests
predict-sdk status --fixture-live
```

## Change Guidelines

- Add or update tests for behavior changes. Prefer focused offline unit tests with
  fake transports or fake action clients.
- Keep `README.md` concise and user-facing. Put deeper agent/developer context under
  `docs/`.
- When changing settled SDK behavior, update `docs/decisions.md`.
- When adding a public workflow, update `docs/reuse-guide.md`.
- When adding a module or changing boundaries, update `docs/sdk-map.md`.
