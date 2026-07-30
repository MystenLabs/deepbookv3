# Predict contract-parity simulation

This directory is the deterministic contract-parity engine. It executes the same scenario through a published localnet package and an independent Python model, then compares canonical economic records.

Long-run economics, charts, and encoding experiments are research concerns and intentionally live outside this public repository.

## Run

From `packages/predict`:

```bash
python3 -m harness parity \
  --source /path/to/scenario_dataset.csv \
  --seed 0 \
  --max-rows 20
```

`--max-rows` is optional. The source dataset is not committed; the default ignored path is `simulations/data/scenario_dataset.csv`.

The external benchmark worker calls:

```bash
python3 -m harness benchmark --results-output /path/to/results.json
```

The task honors `SCENARIO_PATH` and `SIM_MAX_ROWS`, runs the independent replay and parity comparison, retains the canonical instance artifacts, and copies `results.json` to the requested delivery path.

## Outputs

Every run retains:

- `scenario.csv` — the exact generated scenario executed by both engines
- `run-manifest.json` — source revision, dirty flag, source/config/scenario hashes, seed, row limit, command, chain id, and package ids
- `local_trace.json` — transaction receipts, gas, and events
- `local_data.json` — canonical localnet economic records
- `python_data.json` — canonical Python-model records
- `state.json` — published simulation object ids
- `failed_transactions/` — transaction-build, execution, and dry-run diagnostics

The manifest status is atomically changed from `running` to `complete` or `failed`, so interrupted and failed retained runs remain machine-readable.

## Flow

```text
ignored oracle snapshot CSV
  → seeded scenario generator
  → shared initialized-localnet lifecycle
  → TypeScript localnet executor (gRPC)
  → actual local Pyth + Block Scholes verification/ingest path
  → independent Python replay
  → parity projection and first-difference check
```

The Block Scholes local fixture signs the canonical BCS batch, binds it to the published verifier package, normalizes the recoverable signature, calls the actual `bs_oracle` verifier, and passes the gated batch into Propbook ingest in the same transaction. It tests the trust boundary without claiming to consume the provider’s official stream.

## Configuration

`data/scenario_config.json` is the complete, versioned protocol and generator configuration. Missing, unknown, malformed, and unsupported fields fail before execution. Scenario generation is byte-deterministic for a fixed source, configuration, and seed. Changing any input is visible in the retained manifest hashes.

The generator writes fixed-point integers as decimal text. The Python replay remains independent of Move execution and is the semantic oracle for the parity check.

## Verification

```bash
python3 -m unittest discover -s simulations/tests -p 'test_*.py' -v
npm run build
npm test
```

The external Predict Gas Benchmark check runs a bounded end-to-end parity case because pure unit tests cannot validate package publication, transaction composition, event decoding, or the on-chain verifier boundary.
