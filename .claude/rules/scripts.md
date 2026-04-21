---
paths:
  - "scripts/**"
  - "packages/predict/simulations/**"
---

# Scripts Development Rules

**Update this file** when you discover new TypeScript/Sui SDK patterns, transaction gotchas, or debugging tips during sessions.

## Codebase Structure

- `scripts/utils/utils.ts` - Shared utilities (getSigner, getClient, prepareMultisigTx)
- `scripts/config/constants.ts` - Network constants, package IDs, admin caps
- `scripts/transactions/` - Transaction scripts for various operations
- `scripts/tx/` - Output directory for serialized transaction bytes

## Common Commands

- Run script: `pnpm tsx transactions/<script>.ts`
- With gas object: `GAS_OBJECT=0x... pnpm tsx transactions/<script>.ts`
- Predict simulation setup smoke test: `cd packages/predict/simulations && bash run.sh --setup --skip-analysis`
- Predict simulation end-to-end smoke test: `cd packages/predict/simulations && SIM_MAX_ROWS=1 bash run.sh --skip-analysis`

## User Preferences

### "Update SDK"

When the user says "update sdk", directly update the version in `scripts/package.json` and run `pnpm install` in the `scripts/` directory. Do not ask for confirmation — just do it.

## Key Patterns

### Transaction Setup

```typescript
import { Transaction } from "@mysten/sui/transactions";
import { namedPackagesPlugin } from "@mysten/sui/transactions";

const tx = new Transaction();
tx.addSerializationPlugin(
  namedPackagesPlugin({ url: "https://mainnet.mvr.mystenlabs.com" }),
);
```

### Multisig Transactions

Use `prepareMultisigTx()` from utils.ts for mainnet multisig:

```typescript
import { prepareMultisigTx } from "../utils/utils";
await prepareMultisigTx(tx, "mainnet");
```

This handles gas object setup, epoch-based expiration, and outputs to `tx/tx-data.txt`.

### Direct Execution (testnet/devnet)

```typescript
import { signAndExecute } from "../utils/utils";
const res = await signAndExecute(tx, "testnet");
```

## Common Issues

### Verify Predict Simulation Changes End to End

If you change files under `packages/predict/simulations/**` or change Move entrypoints used by the
predict benchmark harness, do not stop at Move unit tests. Run at least the local setup smoke test,
and if execution paths may be affected, also run a small end-to-end sim like
`SIM_MAX_ROWS=1 bash run.sh --skip-analysis`.

### Keep Predict Simulation Calls in Sync with Move Entrypoints

When a Move entrypoint used by the predict simulation changes its generic parameters or signature,
audit `packages/predict/simulations/src/runtime.ts` for stale `typeArguments` or argument lists.
Otherwise benchmark CI may fail only as an external `sim exited with code 1` error.

### Oracle Feed Tier Overlap

When working on `scripts/services/oracle-feed/**`, treat oracle identity as `(underlying, expiry)`,
not `(tier, expiry)`. `inferTier()` assigns each discovered oracle to only one matching tier, so
creation/dedupe logic must guard by expiry alone or overlapping `15m`/`1h` schedules can recreate
the same oracle expiry.

### Oracle Feed Lane Gas Refs Can Go Stale

When working on `scripts/services/oracle-feed/**`, do not assume a cached
`Lane.gasCoinVersion` / `Lane.gasCoinDigest` stays valid forever. Preflight
errors like `Transaction needs to be rebuilt because object ... version ... is
unavailable for consumption` mean the lane must refresh its gas coin object ref
from chain before the next submit, or the manager can get stuck retrying the
same dead version and leave expired oracles unsettled.

### Oracle Feed SVI Subscriptions Need 9 Decimals

When subscribing to BlockScholes `model.params` in `scripts/services/oracle-feed/**`,
do not use low websocket decimal formatting like `5`. SVI params are later
scaled to `1e9` on-chain, so `5` decimal places quantizes short-dated values
into `1e-5` steps and can zero out `a` entirely. Keep subscription precision at
least `9` decimals so the pushed SVI surface is not flattened before it reaches
chain.

### TransactionExpiration Enum Error

SDK v2.1.0+ uses `ValidDuring` (enum value 2) by default. Older multisig tools may not recognize it.
Fix: Set explicit epoch-based expiration:

```typescript
const { epoch } = await client.getLatestSuiSystemState();
tx.setExpiration({ Epoch: Number(epoch) + 5 });
```

This is already handled in `prepareMultisigTx()`.

### Gas Object Required for Mainnet

Mainnet multisig transactions require a gas object:

```bash
GAS_OBJECT=0x... pnpm tsx transactions/script.ts
```

### Move Abort Errors

Format: `MoveAbort(MoveLocation { module: ModuleId { address: ..., name: "module_name" }, function: N, instruction: M }, ERROR_CODE)`

To decode:

1. Find the module in `packages/`
2. Search for `const E.*: u64 = ERROR_CODE`
3. Common errors:
   - `ECannotLiquidate (9)` - Position not eligible for liquidation
   - `EBorrowRiskRatioExceeded (7)` - Borrow would exceed risk ratio
   - `EWithdrawRiskRatioExceeded (8)` - Withdraw would exceed risk ratio

### Environment Variables

- `PRIVATE_KEY` - Use instead of local keystore
- `RPC_URL` - Custom RPC endpoint
- `GAS_OBJECT` - Gas coin object ID for multisig
- `SUI_BINARY` - Path to sui binary (default: `sui`)
- `NODE_ENV=development` - Outputs to `tx-data-local.txt`

### Local Sui CLI Version Matters

If `sui move build` starts failing with missing `sui`/`std` address aliases or
unsupported Move syntax, check which `sui` binary is actually being used.
This repo's current Move packages require a newer CLI than some Homebrew
installs provide. Prefer setting `SUI_BINARY` explicitly or using the newer
user-local binary if `PATH` resolves to an older `sui`.

## DeepBook Client Usage

```typescript
import { DeepBookClient } from "@mysten/deepbook-v3";

const dbClient = new DeepBookClient({
  address: "0x...", // sender address
  env: "mainnet",
  client: new SuiClient({ url: getFullnodeUrl("mainnet") }),
  adminCap: adminCapID["mainnet"], // from constants.ts
});

// Admin operations
dbClient.deepBookAdmin.adjustMinLotSize("DEEP_USDC", 1, 10)(tx);
```
