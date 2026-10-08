# Predict local development system

The harness owns localnet process lifecycle and live actor orchestration. The contract-parity engine lives beside it under `simulations/`; both use the shared TypeScript substrate under `devtools/`.

Run commands from `packages/predict` after `npm install`.

## Tasks

```bash
python3 -m harness smoke
python3 -m harness live --traders 1 --seconds 300
python3 -m harness campaign mint-only mixed-churn fuzz --timeout 600
python3 -m harness parity --source simulations/data/synthetic_oracle_fixture.csv --seed 0 --max-rows 20
python3 -m harness analyze harness/.localnets/campaigns/<campaign-id>
python3 -m harness status
python3 -m harness cleanup --instances
```

| Task | Purpose | Retained output |
| --- | --- | --- |
| `smoke` | Stage and publish the package closure once, including the `predict_math` library and the `predict_orders` order-flow companion. | Failure artifacts, or the full instance with `--keep`. |
| `live` | Hold one localnet with keeper, signed oracle updater, and optional fuzz traders. | Deployment and actor traces. |
| `campaign` | Run named strategies concurrently, one isolated localnet per strategy, from one market-data hub. | Atomic campaign manifest, hub metrics, and per-strategy traces. |
| `parity` | Generate a seeded scenario, run it on localnet through the delayed-execution queue, and compare the result with the independent Python model (see [the simulations README](../simulations/README.md)). | Exact scenario, manifest, local trace, economic outputs, and failures. |
| `analyze` | Reduce retained campaign traces into measurements and a contract-bug verdict. | Terminal report and exit status. |
| `status` / `cleanup` | Inspect or reclaim localnet slots. | Slot registry state. |

The external gas-benchmark worker calls `python3 -m harness benchmark --source <downloaded-snapshot.csv> --results-output <path>`. It runs the same parity scenario. The worker passes the downloaded source path directly; the task runs the same independent Python replay and parity comparison, retains the canonical run artifacts, and copies only `results.json` to the requested delivery path.

## Delayed execution

The immediate mints and `redeem_live` abort, so every trade is queued in the order-flow companion, `deepbook_predict_orders`. The staged closure publishes `predict_math`, then Predict, then `predict_orders`, whose publish shares the deployment's one `OrderDesk` with the launch policy. `deployment.json` records it as `order_desk`, and the actors read it with the companion's package ID from `.env.localnet`. Setup allowlists the companion's `OrderFlow` witness with `protocol_config::set_order_flow`, without which Predict refuses every admission, commit, and fill, and adds the publisher, which sends every flush, as a flush operator before the bootstrap flush. Both steps read first, so re-attaching to a localnet stays idempotent.

Each market needs its `MarketQueue` before anyone can place on it. The keeper creates it with `queue::create_and_share` right after the market, at the ID derived from the desk and the market, and before it funds and advertises the market. A market picked up from chain without a queue, as after a restart between the two transactions, gets its queue on the next funding pass.

Traders fill their own orders. The strategy context enqueues a mint or an early sell in the market's queue, waits for the order's τ, signs the updater's latest spot for τ with the local Pyth signer, and commits and resolves in one PTB, since both calls are permissionless. Commit takes the verified Lazer updates by value. A held position is the Open record a fill left, and an early sell goes through `enqueue_redeem_open`. A partial fill keeps the remainder in the sell's own record. Mint and redeem traces carry the enqueue gas, the fill gas, and the outcome: filled, refunded with a reason, or still waiting. The queue events come from `predict_orders::queue_events`, and a fill also emits Predict's `OrderMinted` or `LiveOrderRedeemed`, so the readers match events by module and name rather than by the called package.

The keeper rebalances every live market each tick, so queued orders' cash need is funded. It settles each expired market in its own transactions: Predict's `try_settle` until the market is settled, then the queue's `settle_step`, one call per transaction, until the payout walk completes, then `cleanup` of the finished records, and only then the sweep. So a market with unpaid Open records stays in the chain-reconciled active set. Before a flush it first settles, pays, and sweeps every market that expired since, and the snapshot transaction settles nothing, so the snapshot's own sweep never drops a market whose Open records are unpaid.

The bug oracle treats aborts from the companion's `queue`, `order_queue`, `desk`, and `delayed_execution_config` modules, and from the library's `lazer_price`, as expected guards, like Predict's own guard modules.

## Strategy registry

Evergreen behavioral strategies, which trade through the queue:

- `fuzz`
- `mint-only`
- `mixed-churn`

Capacity profiles generated by one strategy family, disabled pending a queued-flow redesign:

- `capacity-single` — one far market, batched book fill
- `capacity-pool` — round-robin batched fill across live markets
- `capacity-tree` — one market with distinct payout-tree strikes

Cleanup-economics profiles generated by one state machine, disabled pending a queued-flow redesign:

- `cleanup-survivor`

The capacity and cleanup profiles stay registered but cannot run. They build their books with batched immediate mints, which always abort now, so the context's batch-mint helper throws a clear error and the run fails with that reason. The cleanup profile also measures settled redemption of account positions, and a queued fill never enters the account.

Duration-only strategies require `campaign --timeout` and may stop successfully at that bound only after emitting trader progress; a keeper-only or declaration-only trace fails. Strategies with `maxOps` or semantic completion fail as incomplete if they are still running at the deadline. Strategy metadata is read from the TypeScript registry, so the Python router does not duplicate funding, gas-budget, cadence, or completion configuration.

## Architecture

```text
harness CLI
  ├─ session.py: isolated localnet, staged publication, oracle/account initialization
  ├─ live.py: hub, updater, keeper, traders, campaign ownership
  ├─ parity.py: deterministic scenario + localnet/Python parity or benchmark task
  └─ analyze.py: measurements and verdict

devtools/ts
  ├─ gRPC Sui execution and receipt/failure artifacts
  ├─ local Pyth and Block Scholes signed payload helpers
  └─ Block Scholes BCS/signature codec

harness/run_manifest.py
  └─ shared versioned lifecycle and provenance manifest for campaign, parity, and benchmark
```

The transaction path uses `SuiGrpcClient`. The Sui CLI remains responsible for localnet management and package publication; the harness does not instantiate a deprecated Sui JSON-RPC client.

The local Block Scholes path signs the same BCS payload shape and submits it through the actual `bs_oracle` verifier package before Propbook ingest. Live campaigns can subscribe to the provider’s signed WebSocket stream when credentials are present. The two paths deliberately share the wire codec but have different data sources.

## Reproducibility and artifacts

Parity and benchmark runs retain `artifacts/run-manifest.json` with the source commit and dirty flag, source/config/scenario SHA-256 hashes, arguments, localnet identity, declared artifacts, and terminal outcome. The generated scenario is retained at `artifacts/scenario.csv`.

Each campaign writes `harness/.localnets/campaigns/<campaign-id>/manifest.json` atomically before starting actors, records each ready localnet as setup completes, and reaches `complete`, `failed`, or `interrupted` only after teardown, hub-metrics validation, and manifest-scoped analysis. Each strategy has one result: `completed`, `failed`, `bounded_stop`, `incomplete`, or `no_progress`; Ctrl-C and SIGTERM finalize the manifest before the CLI exits 130. A manifest left `running` is incomplete and `analyze` rejects it. The hub snapshot lives under the campaign's `runtime/` directory and is deleted at normal teardown; retained hub metrics and per-strategy instance paths are declared by the manifest. Failed transactions retain execution context and dry-run diagnostics under each instance's `artifacts/failed_transactions/`.

Instances live under `harness/.localnets/instances/`. Heavy validator and staged-workspace state is removed after context-managed runs while evidence remains. The generated local signer configuration is captured in memory and written only to the mode-0600 per-instance `.env.localnet`; teardown deletes that file before retaining evidence. `deployment.json` contains public package, object, address, and run metadata only.

Hub snapshots and actor traces carry explicit schema versions. Scenario configuration, hub snapshots, and traces reject missing, unknown, malformed, or unsupported current-schema data instead of applying compatibility defaults.

The localnet updater's landed snapshot uses schema version 3 and retains the last ten confirmed Block Scholes spot writes, including their source timestamps. Strategy pricing pairs each latest forward with its exact source-timestamp spot and skips quotes when that pair is absent or stale. Equal, rejected, or unconfirmed spot updates do not advance the history. The raw provider hub snapshot remains schema version 2 and does not represent on-chain history.

## Prerequisites

- Python 3.11 or newer
- Node dependencies installed from `packages/predict/package.json`
- A Sui CLI build whose client operations use gRPC
- Network access when pinned Move dependencies are absent from the local cache
- Live provider credentials only for live signed-feed runs; parity does not require them

Historical capacity measurements remain under `harness/reports/` and `packages/predict/predeploy/evidence/`; their one-off strategy implementations are intentionally not part of the current operator surface.
