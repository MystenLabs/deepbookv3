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

## User Preferences

### "Update SDK"
When the user says "update sdk", directly update the version in `scripts/package.json` and run `pnpm install` in the `scripts/` directory. Do not ask for confirmation — just do it.

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
There is **no** `signAndExecute` helper in `utils.ts` (this file used to claim one — it never
existed). Build the client yourself and execute. On testnet this MUST be gRPC (see below):
```typescript
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { getSigner } from "../utils/utils.js";

const client = new SuiGrpcClient({ baseUrl: "https://fullnode.testnet.sui.io", network: "testnet" });
const res = await client.signAndExecuteTransaction({ transaction: tx, signer: getSigner() });
```
Result shape is `res.Transaction.{digest,status.success}` — NOT the JSON-RPC `res.effects.status.status`.
`client.simulateTransaction({ transaction })` is the dry-run equivalent and returns the same shape.

## Common Issues

### Testnet JSON-RPC Is Off — Use gRPC
`https://fullnode.testnet.sui.io` **404s on JSON-RPC**. This breaks `getClient("testnet")`
(it builds a `SuiJsonRpcClient`) and therefore every testnet script that uses it — the failure
surfaces as `SuiHTTPStatusError: Unexpected status code: 404` from `getLatestSuiSystemState`
during `tx.build()`, which reads like an SDK bug but is the endpoint being gone.
The same host serves gRPC fine — use `SuiGrpcClient` (see Direct Execution above).
`getClient` has not been migrated (it is shared with the mainnet multisig path), so testnet
scripts must construct their own gRPC client for now.

Knock-on effect when debugging: JSON-RPC reads (`suix_getOwnedObjects`, `sui_getObject`) return
nothing on testnet. Use the GraphQL endpoint `https://graphql.testnet.sui.io/graphql` instead
(NOT `sui-testnet.mystenlabs.com`, which does not resolve), or the `sui client` CLI.

### Upgrading deepbook core: `CURRENT_VERSION` is a two-part change
`sui client upgrade` reads `[published.<env>]` from `Published.toml` and rewrites `published-at`,
`version`, and `toolchain-version` on success — commit that file (precedent: #957, #1111).
`Move.toml` stays `deepbook = "0x0"`.

Publishing is only half the job. Every gated entrypoint asserts
`allowed_versions.contains(current_version())` (`registry.move`; each `Pool` also caches its own
copy), so a package whose `constants::CURRENT_VERSION` is not in the Registry's set aborts with
`EPackageVersionNotEnabled` on essentially every call — the upgrade lands and is dead on arrival.
Full sequence:
1. `sui client upgrade -c <UpgradeCap>` (testnet cap + admin cap IDs are in `config/constants.ts`).
2. `registry::enable_version(registry, N, admin_cap)` for the new `CURRENT_VERSION`.
3. `pool::update_pool_allowed_versions(pool, registry)` for **every** pool — pools cache
   `allowed_versions` and never re-read the Registry, so an unrefreshed pool still rejects the
   new version. Permissionless, no admin cap.

`enable_version`, `update_allowed_versions`, and `update_pool_allowed_versions` are all explicitly
gate-exempt ("This function does not have version restrictions"), so there is no chicken-and-egg
deadlock — you can call them from the newly-published package immediately.

Gotchas:
- `enable_version` asserts the version is **not** already present (`EVersionAlreadyEnabled`), so
  only pass missing versions. Read the live set first: `Registry.inner` is a `Versioned` whose UID
  is *not* a top-level object (GraphQL `object(address:)` returns null) — read it with
  `sui client dynamic-field <Registry.inner.id>` and decode the `Field<u64, RegistryInner>` BCS
  (`allowed_versions` is the first field; same for `PoolInner`).
- Keep testnet's set equal to mainnet's. Enable the version the *previous* package reports too, or
  you brick the still-referenced old package. As of 2026-07, both are `{1,2,3,4,5,6,8}`.
- **7 was never a `CURRENT_VERSION`** — the constant went 6 → 8 (`1ba89515` → `43c3416d`).
  `ee85e213` ("bump core to v7") was a *package* version, not the gate constant. Don't "fill the
  gap" by enabling 7; mainnet skips it on purpose.
- `scripts/transactions/updateAllPoolAllowedVersions.ts` is **mainnet-only** (hardcoded
  `env = "mainnet"` + mainnet package/registry/indexer). For testnet use
  `enableTestnetVersionsAndPools.ts`, which enumerates pools via GraphQL (there is no testnet
  `pool_created` indexer) and chunks them across txs — a single PTB over all ~117 pools is both a
  size and shared-object-congestion risk.

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

### Margin Registry State Persists Across `disable_version`
`MarginRegistry.disable_version(v)` only removes `v` from `allowed_versions`. It does **not**
clear `pool_registry` (the `Table<ID, PoolConfig>` of registered deepbook pools) or reset each
pool's `enabled` flag. Practical consequences for migration scripts:
- Re-calling `registerDeepbookPool` on a pool that's already in the table aborts with
  `EPoolAlreadyRegistered` (margin_registry code 2). After a version disable, use only
  `enableDeepbookPool` to re-enable previously-registered pools.
- A pool's `enabled` state survives the disable. If a pool is already enabled,
  `enableDeepbookPool` aborts with `EPoolAlreadyEnabled` (code 5); if already disabled,
  `disableDeepbookPool` aborts with `EPoolAlreadyDisabled` (code 6).
- `enableDeepbookPoolForLoan` only requires the deepbook pool to be registered, not enabled,
  so you can stage loan flows for pools that will stay disabled in trading.

### Move Abort Errors
Format: `MoveAbort(MoveLocation { module: ModuleId { address: ..., name: "module_name" }, function: N, instruction: M }, ERROR_CODE)`

To decode:
1. Find the module in `packages/`
2. Search for `const E.*: u64 = ERROR_CODE` in that module — the source constant is the authority (codes hardcoded here drifted and were removed)

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
