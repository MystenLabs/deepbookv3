---
paths:
  - "scripts/**"
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

## Key Patterns

### Transaction Setup
```typescript
import { Transaction } from "@mysten/sui/transactions";
import { namedPackagesPlugin } from "@mysten/sui/transactions";

const tx = new Transaction();
tx.addSerializationPlugin(namedPackagesPlugin({ url: "https://mainnet.mvr.mystenlabs.com" }));
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

## DeepBook Client Usage
```typescript
import { DeepBookClient } from "@mysten/deepbook-v3";

const dbClient = new DeepBookClient({
  address: "0x...",  // sender address
  env: "mainnet",
  client: new SuiClient({ url: getFullnodeUrl("mainnet") }),
  adminCap: adminCapID["mainnet"],  // from constants.ts
});

// Admin operations
dbClient.deepBookAdmin.adjustMinLotSize("DEEP_USDC", 1, 10)(tx);
```
