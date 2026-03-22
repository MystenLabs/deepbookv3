# Predict Fuzz — Differential Fuzzing Framework

Deploy multiple versions of the predict package on testnet, feed them real Block Scholes oracle data, spam random mints, and compare behavior across versions.

See `DESIGN.md` for the full architecture. This README covers practical knowledge for running and modifying the framework.

## Quick Start

```bash
cd predict_fuzz
npm install

# 1. One-time setup (deploy DUSDC, fund wallets)
npx tsx src/init.ts

# 2. Deploy a predict package at a specific commit
npx tsx src/deploy.ts --commit <hash> --label <name>

# 3. Start oracle price feed (long-running)
npx tsx src/oracle-updater.ts

# 4. Start fuzz minting (long-running, in separate terminal)
npx tsx src/fuzz-worker.ts

# 5. Add new expiries to all packages
npx tsx src/oracle-manager.ts

# 6. Post-processing
npx tsx src/replay-service.ts
npx tsx src/analyze.ts
npx tsx src/check-health.ts
```

## Wallets

| Wallet | Address | Purpose |
|--------|---------|---------|
| Deployer | `0x820d86e36619ef4d71256612da85c99585cfd11b4b4a32ba6d221e619b871216` | Publishing, admin ops |
| Oracle | `0x69cbd324ad8349168efd7a112893af7d9ebeb1b9e8bcc9f9242df49353878ea0` | Price feed updates |
| Minter | `0x0ed095c2863c5fecfb7e90f929ddab2aebaa4ed968673d42eef8e98c5a07c0cf` | Fuzz minting |

Keys are in `.env` (gitignored). Deployer was funded with 10k SUI, oracle and minter with 2k SUI each.

## Block Scholes API — Critical Details

The `blockscholes_oracle_deepbook_demo.py` file is the reference implementation. Key learnings:

**Spot price** — `POST /api/v1/price/index`
- No `exchange` field needed
- `asset_type: "spot"`, `base_asset: "BTC"`

**Forward price** — `POST /api/v1/price/mark`
- No `exchange` field needed
- `asset_type: "future"`, `base_asset: "BTC"`, `expiry: "<iso>"`
- NOT `/api/v1/rate/forward` (that endpoint doesn't exist)

**SVI params** — `POST /api/v1/modelparams`
- `exchange: "composite"` (not `"blockscholes"` or `"deribit"`)
- `model: "SVI"`, `base_asset: "BTC"`, `expiry: "<iso>"`
- Response fields are `alpha`, `beta`, `rho`, `m`, `sigma` (not `a`, `b`)

**Common options for all endpoints:**
```json
{
  "frequency": "1m",
  "start": "LATEST",
  "end": "LATEST",
  "options": { "format": { "timestamp": "s", "hexify": false, "decimals": 5 } }
}
```

**`decimals: 5` is critical** — with `decimals: 0`, SVI values get rounded to zero and mints fail with division errors.

**Expiry discovery** — `POST /api/v1/catalog`
- Uses plural fields: `exchanges: ["deribit"]`, `base_assets: ["BTC"]`, `asset_types: ["option"]`
- Requires `start`/`end` as ISO timestamps (not `"LATEST"`)

**Rate limits** — The API will return 429 if you fire too many parallel requests. The oracle-updater fetches forwards sequentially to avoid this. Tick interval is 2s.

## Sui SDK — Critical Details

**SDK version**: `@mysten/sui ^2.5.0` (resolves to v2.9.1). Uses `SuiJsonRpcClient` from `@mysten/sui/jsonRpc` — NOT `SuiClient` from `@mysten/sui/client` (that export doesn't exist in v2.5+).

**Client constructor requires `network`:**
```typescript
new SuiJsonRpcClient({ url: SUI_RPC_URL, network: "testnet" })
```

**RPC indexing delays**: After publishing a package or creating shared objects, the RPC node needs time to index them. Use `waitForObject(objectId)` between transactions that create objects and transactions that reference them.

**Object version staleness**: When an owned object is used as input to a transaction (even by immutable reference), its version is bumped. Subsequent transactions referencing the same object may get a stale version if the RPC hasn't caught up. Use `waitForObjectVersion(objectId)` to poll until the version advances.

**`transfer::public_share_object` does NOT work from PTBs on testnet** — aborts with code 0 in `share_object_impl`. The workaround is to transfer the object to the wallet that needs it instead of sharing.

**Parallel transactions to shared `&mut` objects**: Sui sequences all transactions touching the same `&mut` shared object at consensus. Firing parallel mints to the same `Predict` object doesn't parallelize — it just spams the RPC and triggers 429s. Send mints sequentially within a package; parallelism only helps across different packages.

## Deploy Pipeline (7 Transactions)

The deploy is split into 7 transactions because Sui requires shared objects to be confirmed before they can be referenced:

1. **TX1** (deployer): Publish package → get package_id, Registry, AdminCap
2. **TX2** (deployer): Create 2 OracleCapSVIs, create Predict, mint DUSDC for vault + minter
3. **TX3** (deployer): Deposit vault, create oracles for all live expiries
4. **TX4a** (deployer): Register both caps on all oracles, activate oracles
5. **TX4b** (deployer): Transfer oracle_cap to oracle wallet
6. **TX5** (minter): Create PredictManager
7. **TX6** (minter): Deposit DUSDC into PredictManager

**Oracle-expiry mapping**: When parsing TX3 results, use `OracleCreated` events (which contain both `oracle_id` and `expiry`). Do NOT rely on the order of created objects in `objectChanges` — it's not guaranteed to match the order of `create_oracle` calls.

## Architecture Pivots from DESIGN.md

| DESIGN.md | Reality | Why |
|-----------|---------|-----|
| oracle_cap is shared via `public_share_object` | oracle_cap is transferred to oracle wallet | `public_share_object` aborts in PTB context |
| Forward price from `/api/v1/rate/forward` | Forward price from `/api/v1/price/mark` | The rate/forward endpoint doesn't exist |
| Expiry discovery by probing individual dates | Expiry discovery via catalog API | Much faster, no rate limit issues |
| Parallel mints within a package | Sequential mints within a package | Parallel txs to same shared object = RPC 429s |
| 500ms oracle-updater tick | 2s tick | API rate limits with 12 sequential forward fetches |

## File Layout

```
predict_fuzz/
├── .env                          # wallet keys, DUSDC IDs, API key (gitignored)
├── .gitignore
├── DESIGN.md                     # original architecture document
├── README.md                     # this file
├── progress_log.md               # build session log
├── packages.json                 # deployment manifest (gitignored, generated by deploy)
├── package.json
├── tsconfig.json
├── blockscholes_oracle_deepbook_demo.py  # reference API client
├── digests/                      # mint tx records (gitignored)
├── replays/                      # replay results (gitignored)
├── oracle-data/                  # raw oracle data (gitignored)
├── logs/                         # structured logs (gitignored)
├── analysis/                     # analysis output (gitignored)
└── src/
    ├── types.ts                  # shared types
    ├── config.ts                 # .env loader, constants, paths
    ├── logger.ts                 # structured JSONL logger
    ├── manifest.ts               # packages.json read/write with cross-process lock
    ├── sui-helpers.ts            # SuiJsonRpcClient, keypairs, tx execution
    ├── blockscholes.ts           # Block Scholes API client
    ├── gas-pool.ts               # gas coin management for parallel txs
    ├── init.ts                   # one-time: deploy DUSDC, fund wallets
    ├── deploy.ts                 # deploy a predict package (7 txs)
    ├── oracle-manager.ts         # discover expiries, create oracles
    ├── oracle-updater.ts         # continuous price/SVI feed
    ├── fuzz-worker.ts            # random mint generation
    ├── replay-service.ts         # digest enrichment with gas/vault data
    ├── analyze.ts                # cross-package comparison
    └── check-health.ts           # heartbeat staleness check
```

## Integration Test Results (2026-03-21)

- init: DUSDC deployed, wallets funded
- deploy: 12 oracles created across all live BTC deribit expiries
- oracle-updater: real spot + forward + SVI data flowing
- fuzz-worker: **24/27 mints succeeded** in first live run (3 failures were from expired near-term oracles)
