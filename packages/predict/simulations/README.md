# Predict Simulations

This folder is a self-contained localnet harness for the `predict` package. A full run:

- creates a fresh local Sui network
- publishes `deepbook`, `dusdc`, and `predict`
- sets up one predict market, oracle, and manager
- executes the scenario CSV
- analyzes gas and mint-level vault state

## Prerequisites

- `sui` available on `PATH`
- Node.js available on `PATH`
- dependencies installed in this folder

## Commands

Run the full flow:

```bash
bash packages/predict/simulations/run.sh
```

Run setup only:

```bash
bash packages/predict/simulations/run.sh --setup-only
```

Skip analysis:

```bash
bash packages/predict/simulations/run.sh --skip-analysis
```

Run analysis again against an existing localnet state:

```bash
cd packages/predict/simulations
npx tsx src/analyze.ts
```

## Generated Files

- `.localnet/`: ephemeral local chain state and local client config
- `.env.localnet`: generated package IDs and signer config for the TS scripts
- `artifacts/state.json`: setup object IDs and fast-executor cache snapshot
- `artifacts/digests.json`: digest and wall-time record for every scenario transaction
- `artifacts/results.json`: grouped gas summary plus per-mint gas and vault MTM deltas

## Result Shape

`results.json` is split by transaction type under `summary.byAction`, so mint gas is not averaged together with oracle updates.

Each mint row includes:

- gas components in MIST and SUI
- wall-clock latency
- strike, direction, quantity, cost, and ask price
- predict object version before and after the mint
- vault balance and total MTM before, after, and delta

## Localnet Limitation

This harness does not produce replay-derived trace profiles. The useful localnet output is transaction gas, mint economics, and vault MTM state extracted into `results.json`.
