# Predict Python SDK Map

This SDK is a Python package plus CLI for observing and trading DeepBook Predict
range-digital markets on Sui. It is intentionally small: live state comes from Sui
JSON-RPC, historical views come from the Predict indexer, and transaction building is
implemented directly in Python.

## Main Flows

### Observe

`predict-sdk status`:

1. `cli.py` loads the testnet `DeploymentConfig`.
2. `rpc.py` reads Sui objects with `sui_getObject` and dynamic fields with
   `suix_getDynamicFieldObject`.
3. `observability.py` turns raw object fields into a `PredictStatusReport`.
4. `indexer.py` optionally checks `/status` for indexer health.
5. `render.py` prints the boxed status dashboard or markets table.

### Trade

`predict-sdk deposit`, `trade`, `redeem`, and `withdraw`:

1. `cli.py` lazy-imports the write path and loads `SUI_PRIVATE_KEY`.
2. `signer.py` decodes the Sui bech32 private key and signs transaction bytes.
3. `actions.py` builds high-level Predict PTBs for account custody and trading.
4. `bcs.py` serializes the programmable transaction and `TransactionData`.
5. `tx.py` resolves object/gas refs, dry-runs, estimates gas, and executes only when
   requested.

### Monitor And Parallel Execution

- `portfolio.py` reconstructs open positions and realized PnL from on-chain order
  events.
- `dashboard.py` provides an optional Textual read-only account monitor.
- `gas.py` manages distinct SUI gas coins for parallel write transactions.

## Module Responsibilities

| Module | Responsibility |
|---|---|
| `config.py` / `deployments/` | Testnet package IDs, shared objects, feeds, cadences, servers |
| `constants.py` | Decimals, cadence periods, reserved object IDs, tick constants |
| `_http.py` | Shared urllib JSON transport (POST/GET) for every RPC/indexer caller |
| `rpc.py` | Minimal read-only Sui object reader |
| `indexer.py` | Best-effort Predict server client for `/status` and `/markets` |
| `observability.py` | Protocol gates, oracle freshness, pool state, market status, timelines |
| `render.py` | Terminal dashboard and markets table rendering |
| `signer.py` | Ed25519 key loading, address derivation, Sui intent signing |
| `bcs.py` | Narrow BCS encoder and PTB builder for this SDK's transaction shapes |
| `tx.py` | RPC transaction runner, dry-run-first gas estimate, execution |
| `actions.py` | High-level account, custody, mint, and redeem operations |
| `portfolio.py` | Event-based portfolio and PnL reconstruction |
| `dashboard.py` | Optional Textual read-only account dashboard |
| `gas.py` | Gas lane/pool helper for concurrent writes |

## Data Boundaries

- Deployment data is static SDK wiring. It is not live protocol state.
- Sui RPC object reads are the live source of truth.
- The Predict indexer adds history and health. It should not be required for the
  live status path to work.
- `.predict_state.json` only stores the local mapping from signer address to
  `AccountWrapper` object ID.
- Amounts inside SDK internals are raw integers: DUSDC uses 6 decimals, SUI uses
  9 decimals, and probabilities use a 1e9 scale.

## Public Surfaces

- CLI entry point: `predict-sdk`.
- Import package: `predict_sdk`.
- Stable high-level classes/functions for reuse:
  - `load_testnet_config`
  - `SuiRpcObjectReader`
  - `PredictIndexerClient`
  - `ObservabilityClient`
  - `PredictActions`
  - `PortfolioReader`
  - `GasPool`

## Update Checklist

- New command: update `README.md`, `docs/reuse-guide.md`, and CLI tests.
- New write action: update `docs/write-path.md`, add action tests, and keep dry-run
  default behavior.
- New read/status field: update `docs/read-path.md`, render tests, and fixture
  coverage.
- New package/deployment wiring: update `docs/sdk-map.md`, config tests, and
  `docs/decisions.md` if behavior changed.
