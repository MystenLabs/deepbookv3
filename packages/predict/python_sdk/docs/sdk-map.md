# Predict Python SDK Map

This SDK is a Python package plus CLI for observing and trading DeepBook Predict
range-digital markets on Sui. It is intentionally small: live state comes from Sui
JSON-RPC, historical views come from the Predict indexer, and transaction building is
implemented directly in Python.

## Main Flows

### Observe

`predict-sdk status`:

1. `cli.py` loads the testnet `DeploymentConfig`.
2. `indexer.py` reads markets / market-state / vault-state / config from the
   predict-server, and `OracleClient` reads latest pyth + block-scholes for freshness.
3. `observability.py` assembles those into a `PredictStatusReport`.
4. `indexer.py` also checks `/status` for indexer lag/health.
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
| `_http.py` | Shared urllib JSON transport (POST/GET) for every service caller |
| `indexer.py` | Data-plane clients: `PredictIndexerClient` (predict-server) + `OracleClient` (oracle service), all fail-open |
| `observability.py` | Assembles the indexer data into gates, oracle freshness, pool/market status, timelines |
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
- The indexer is the data plane: all observe/monitor reads come from the predict-server
  and oracle service (D001).
- The chain is the execution plane: dry-run, submit, refs, and the one live value the
  indexer lacks — a market's `reference_tick` (D002).
- The signer's `AccountWrapper` id is resolved from the indexer (`/managers?owner=`)
  and cached in memory for the session; the SDK keeps no local state file.
- Amounts inside SDK internals are raw integers: DUSDC uses 6 decimals, SUI uses
  9 decimals, and probabilities use a 1e9 scale.

## Public Surfaces

- CLI entry point: `predict-sdk`.
- Import package: `predict_sdk`.
- Stable high-level classes/functions for reuse:
  - `load_testnet_config`
  - `PredictIndexerClient`, `OracleClient`
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
- New/changed service endpoint or response field (incl. drift fixes): update
  `docs/api.md` (hand-maintained; the services own the real contract).
- New package/deployment wiring: update `docs/sdk-map.md`, config tests, and
  `docs/decisions.md` if behavior changed.
