---
paths:
  - "scripts/**"
---

# Scripts Development Rules

**Update this file** when you discover new TypeScript/Sui SDK patterns, transaction gotchas, or debugging tips during sessions.

## What lives here

`scripts/` holds only the **protocol package-upgrade** transactions and a couple of SDK examples:

- `scripts/transactions/mainPackageUpgrade.ts`, `marginPackageUpgrade.ts`, `vaultPackageUpgrade.ts` — run `sui client upgrade` and serialize an unsigned upgrade tx to `tx/tx-data.txt` for the multisig.
- `scripts/transactions/createPermissionlessPool.ts`, `deepbookMarketMaker.ts` — SDK usage examples.
- `scripts/config/constants.ts` — the DeepBook core `upgradeCapID`.
- `scripts/tx/` — output directory for serialized transaction bytes.

The **mainnet multisig admin scripts** (create/disable pools, fund vaults, transfer funds, pool params, margin-pool ops, version enable/disable, MVR/package-registry setup) moved to the private **deepbook-services** repo under `multisig-txs/`, where reads go over gRPC. Build those there, not here.

## Common Commands

- Run script: `pnpm tsx transactions/<script>.ts`
- With gas object: `GAS_OBJECT=0x... pnpm tsx transactions/<script>.ts`

## User Preferences

### "Update SDK"
When the user says "update sdk", directly update the version in `scripts/package.json` and run `pnpm install` in the `scripts/` directory. Do not ask for confirmation — just do it.

## Upgrading deepbook core: `CURRENT_VERSION` is a two-part change
`sui client upgrade` reads `[published.<env>]` from `Published.toml` and rewrites `published-at`,
`version`, and `toolchain-version` on success — commit that file (precedent: #957, #1111).
`Move.toml` stays `deepbook = "0x0"`.

Publishing is only half the job. Every gated entrypoint asserts
`allowed_versions.contains(current_version())` (`registry.move`; each `Pool` also caches its own
copy), so a package whose `constants::CURRENT_VERSION` is not in the Registry's set aborts with
`EPackageVersionNotEnabled` on essentially every call — the upgrade lands and is dead on arrival.
Full sequence:
1. `sui client upgrade -c <UpgradeCap>` — `mainPackageUpgrade.ts` (UpgradeCap id in `config/constants.ts`).
2. `registry::enable_version(registry, N, admin_cap)` for the new `CURRENT_VERSION`.
3. `pool::update_pool_allowed_versions(pool, registry)` for **every** pool — pools cache
   `allowed_versions` and never re-read the Registry, so an unrefreshed pool still rejects the
   new version. Permissionless, no admin cap.

Steps 2–3 are multisig admin actions, now built from **deepbook-services** `multisig-txs/`:
`enableVersion.ts` + `updateAllPoolAllowedVersions.ts` on mainnet, `enableTestnetVersionsAndPools.ts`
on testnet (it enumerates pools via GraphQL — there is no testnet `pool_created` indexer — and
chunks them across txs, since a single PTB over all ~117 pools is both a size and
shared-object-congestion risk).

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

## Move Abort Errors
Format: `MoveAbort(MoveLocation { module: ModuleId { address: ..., name: "module_name" }, function: N, instruction: M }, ERROR_CODE)`

To decode:
1. Find the module in `packages/`
2. Search for `const E.*: u64 = ERROR_CODE` in that module — the source constant is the authority (codes hardcoded here drifted and were removed)

## Environment Variables
- `RPC_URL` - Custom RPC endpoint
- `GAS_OBJECT` - Gas coin object ID for the upgrade tx
- `SUI_BINARY` - Path to sui binary (default: `sui`)
- `NODE_ENV=development` - Outputs to `tx-data-local.txt`
