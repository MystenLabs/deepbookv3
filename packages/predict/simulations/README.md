# Predict Simulations

This folder is a localnet harness for the `predict` package. The core workflow is:

- run a fresh simulation to produce `runs/<run-id>/artifacts/results.json`
- render charts from that `results.json`

## Prerequisites

- `sui` available on `PATH`
- Node.js available on `PATH`
- Python 3 with `matplotlib` and `numpy` installed for charting
- dependencies installed in this folder

## Workflow

Fresh run:

```bash
bash packages/predict/simulations/run.sh
```

Analyze existing results:

```bash
cd packages/predict/simulations
npm run analyze -- runs/<run-id>/artifacts/results.json
```

## Outputs

- `runs/<run-id>/artifacts/results.json`: simulation output consumed by `visualize.py`
- `runs/<run-id>/artifacts/chart_*.png`: optional charts emitted by `visualize.py`
- `runs/<run-id>/artifacts/state.json`: setup state for resumed execution
- `runs/<run-id>/localnet/` and `runs/<run-id>/.env.localnet`: localnet implementation details

## Schema

`results.json` uses schema `results_v3`:

- `summary.totalTxs`
- `summary.byAction.{update_prices,update_svi,mint,supply}`
- `mints[]`
- `supplies[]`

Each action summary has `count`, `gas.{avg,min,max}`, and `wallMs.{avg,min,max}`.
Each mint and supply row has `wallMs`, `computationCost`, `storageCost`, `storageRebate`, and `gasTotal`.
The simulation records one NAV-triggering supply after every 100 successful mints.

## Advanced

- `bash packages/predict/simulations/run.sh --setup`
- `bash packages/predict/simulations/run.sh --list`
- `bash packages/predict/simulations/run.sh --resume <run-id>`
- `bash packages/predict/simulations/run.sh --resume <run-id> --sim`
- `bash packages/predict/simulations/run.sh --skip-analysis`
- `bash packages/predict/simulations/run.sh --continue-on-rejects`
- `SIM_QUANTITY_SCALE=10000 bash packages/predict/simulations/run.sh`

`SIM_QUANTITY_SCALE` divides the CSV mint quantity before submitting the transaction.
The default is `10000`, which is 10x smaller than the earlier `1000` scale.
`--continue-on-rejects` records failed mint attempts in `rejectedMints` and keeps
processing, but the run still fails unless every CSV mint succeeds.

## Localnet Limitation

This harness does not produce replay-derived trace profiles. The useful localnet output is transaction gas, latency, and mint-level execution data extracted into `results.json`.
