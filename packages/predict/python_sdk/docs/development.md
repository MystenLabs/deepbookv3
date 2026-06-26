# Development Guide

This file is for agents and developers changing the Python SDK itself.

## Environment

```bash
cd packages/predict/python_sdk
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
pip install -e ".[tui]"   # optional dashboard UI
```

The base install includes PyNaCl for signing. There is no `tx` extra.

## Verification

Run the full SDK suite:

```bash
PYTHONPATH=. python3 -m unittest discover -s tests
```

Useful focused checks:

```bash
PYTHONPATH=. python3 -m unittest discover -s tests -p test_cli.py
PYTHONPATH=. python3 -m unittest discover -s tests -p test_observability.py
PYTHONPATH=. python3 -m unittest discover -s tests -p test_strategy.py
PYTHONPATH=. python3 -m unittest discover -s tests -p test_packaging.py
predict-sdk status --fixture-live
```

## Dependency Policy

- Keep the base package practical for the CLI and SDK. PyNaCl is a base dependency
  because signing is part of the default package.
- Keep Textual optional under `[project.optional-dependencies].tui`.
- Avoid adding dependencies for read-path parsing or rendering unless they remove
  clear complexity.
- If package metadata changes, update `tests/test_packaging.py`.

## Test Policy

- Normal unit tests must not require network, live testnet, private keys, or funded
  accounts.
- Prefer fake transports, fake readers, and fake action clients.
- For write-path behavior, test PTB/signing primitives locally and transaction flow via
  stubs.
- For read-path behavior, test object parsing with fixture objects that reflect Sui's
  nested field shapes.
- For strategy behavior, keep price discovery stubbed through fake dry-run mint events.

## Adding A CLI Command

1. Add the parser entry in `cli.py`.
2. Keep write commands dry-run by default with `--execute` for submission.
3. Lazy-import write-path modules for commands that need keys or signing.
4. Add CLI tests with redirected stdout/stderr.
5. Update `README.md` and `docs/reuse-guide.md`.

## Adding A Write Action

1. Read `docs/write-path.md`.
2. Add a method to `PredictActions` only if it maps to a real user/protocol action.
3. Use `Ptb` helpers and `TransactionClient.run()`.
4. Keep raw integer units in public Python methods unless the CLI is converting from
   human units.
5. Add focused tests that do not need testnet submission.

## Adding Read-Path Data

1. Read `docs/read-path.md`.
2. Parse object fields defensively. Sui may wrap values in nested `fields` dictionaries
   or Move `Option` vectors.
3. Keep `PredictStatusReport` and render output deterministic.
4. Add fixture coverage for flat and nested field shapes when relevant.

## Updating Docs

- `README.md`: concise user instructions.
- `AGENTS.md`: startup and routing rules.
- `docs/sdk-map.md`: module ownership and flow map.
- `docs/write-path.md`: transaction/signing/gas behavior.
- `docs/read-path.md`: RPC/indexer/status behavior.
- `docs/reuse-guide.md`: snippets for SDK consumers.
- `docs/decisions.md`: settled SDK behavior.
