# Predict Fuzz — Differential Fuzzing Framework

## Goal

Deploy multiple versions of the predict package on testnet (each at a different commit), feed them real oracle data from Block Scholes, spam random mints, replay transactions for gas profiling, and compare behavior across versions.

## Decisions

- **Quote type**: DUSDC throughout (deployed once on testnet, shared across all predict packages)
- **Oracle data**: Real data from Block Scholes API
- **Underlying**: BTC only. On-chain `underlying_asset` string = `"BTC"`
- **Fuzz scope**: Mints only (no redeems)
- **Vault lifecycle**: Seed with 10M DUSDC, let it drain, observe failures
- **Manager funding**: Pre-fund each PredictManager with 1M DUSDC, let exhaust
- **Interface contract**: Current `predict::mint` signature is locked. Incompatible commits fail at deploy
- **Parallelism target**: Per tick: N_packages × N_oracles_sampled × N_mints_per_oracle parallel txs (e.g., 3×3×3 = 27 txs). Each tx is exactly 1 mint, no PTB batching for mints.
- **Fuzz strategy**: Stress mode — independent random mints per package, accept noise in cross-package comparison
- **Notional per mint**: Contract price in [$0.01, $0.99] range, quantity sized so total cost is $5-$200 per mint
- **Expiry probing**: Hourly for near-term (<7d), daily for further out
- **RPC**: Public testnet fullnode (`https://fullnode.testnet.sui.io:443`)
- **Process management**: Raw `tsx` scripts
- **packages.json concurrency**: Atomic writes (write tmp file, rename) + cross-process manifest lock (`packages.json.lock`)
- **DUSDC init**: Framework does a one-time deploy of DUSDC, mints 10B, stores IDs in `.env`

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌───────────────────┐
│  Deploy CLI  │────▶│  packages.json   │◀────│  Oracle Manager   │
│ (deployer)   │     │  (source of      │     │  (deployer)       │
└─────────────┘     │   truth)         │     └───────────────────┘
                    └──────┬───────────┘
                           │
              ┌────────────┼─────────────┐
              ▼            ▼             ▼
     ┌──────────────┐ ┌──────────┐ ┌──────────────┐
     │Oracle Updater│ │Fuzz Worker│ │Replay Service│
     │(oracle)      │ │(minter)  │ │(read-only)   │
     └──────────────┘ └────┬─────┘ └──────┬───────┘
              │             │              │
              ▼             ▼              ▼
       Block Scholes   digests/        replays/
          API          {pkg}.jsonl     {pkg}.jsonl
                                           │
                                           ▼
                                    ┌──────────────┐
                                    │   Analysis   │
                                    └──────────────┘
```

## Wallet Design

### 3 Wallets, Strict Separation

| Wallet     | Used by                          | Owns                              | Concurrency         |
|------------|----------------------------------|-----------------------------------|---------------------|
| `deployer` | Deploy CLI, Oracle Manager       | AdminCap(s), TreasuryCap\<DUSDC\>, deployer OracleCapSVI(s) | Manual only, never concurrent |
| `oracle`   | Oracle Updater                   | SUI for gas (references shared oracle_cap) | 1 tx / 500ms, serialized |
| `minter`   | Fuzz Worker                      | PredictManager(s), DUSDC, gas pool | N_pkg × ORACLES_PER_PKG × MINTS_PER_ORACLE per tick |

### Two OracleCapSVIs Per Package

Each package deploy creates TWO `OracleCapSVI` objects:

- **deployer_cap**: **Owned by deployer wallet.** Used for oracle lifecycle management (`create_oracle`, `register_oracle_cap`, `activate`). These operations also require `&AdminCap` which deployer owns.
- **oracle_cap**: **Shared object** (via `transfer::public_share_object`). Used by oracle wallet for high-frequency price updates (`update_prices`, `update_svi`). Also referenceable by deployer for `register_oracle_cap` on new oracles.

Both caps are registered on every oracle via `register_oracle_cap`.

**Why oracle_cap is shared (not transferred to oracle wallet)**:

When the oracle-manager creates a new oracle later, it must call `register_oracle_cap(oracle, admin_cap, oracle_cap)` to authorize the oracle_cap on that oracle. This requires both `&AdminCap` (deployer) and `&OracleCapSVI` in the same transaction. If oracle_cap were owned by oracle wallet, deployer couldn't reference it. Making it shared solves this — deployer can reference it for registration, oracle wallet can reference it for updates. All oracle functions take `&OracleCapSVI` (immutable ref) so there's zero contention between concurrent users. On testnet, security of the cap is not a concern.

**Deploy-time flow** (across TX2 and TX4, see Deploy CLI section for full details):
- TX2: create both caps (both owned by deployer initially)
- TX4: register both caps on all oracles, activate, then share oracle_cap as LAST step

**Oracle-manager flow** for new oracles on existing packages (2 transactions):
- TX1: `registry::create_oracle(registry, admin_cap, deployer_cap, "BTC", expiry_ms)` for each new expiry → oracle_ids returned, oracles shared internally. Wait for confirmation.
- TX2: For each new oracle:
  - `registry::register_oracle_cap(oracle, admin_cap, deployer_cap)` — deployer_cap is owned
  - `registry::register_oracle_cap(oracle, admin_cap, oracle_cap)` — oracle_cap is shared, deployer references it as `&ref`
  - `oracle::activate(oracle, deployer_cap, clock)`

### Equivocation Prevention Rules

1. **deployer**: Only ONE of (Deploy CLI, Oracle Manager) runs at a time. Enforced via filesystem lockfile (`predict_fuzz/.deployer.lock`) acquired at startup by both scripts. On Sui, equivocation on owned objects permanently locks them.
2. **oracle**: Only Oracle Updater uses this wallet. Runs continuously.
3. **minter**: Only Fuzz Worker uses this wallet. Runs continuously.

### Manifest Lock (`packages.json.lock`)

All processes that read-modify-write `packages.json` must acquire a cross-process manifest lock first. This is separate from the deployer wallet lock (which prevents owned-object equivocation on Sui).

Writers: deploy, oracle-manager, oracle-updater (for `first_update_ts` and `state` flips).

Implementation: `fs.mkdirSync(lockdir)` is atomic on all platforms — spin-wait with short backoff until acquired. Hold time is <1ms (read JSON, flip field, atomic write). The lock is per-file, not per-wallet.

**Stale lock recovery**: On acquisition, write PID and timestamp into a file inside the lockdir (`packages.json.lock/owner.json`). If the lock cannot be acquired within 5 seconds, read the owner file. If the owning PID is no longer running (`kill(pid, 0)` throws), forcibly remove the lockdir and retry. If the PID is alive but the lock is >30 seconds old, log an error (something is stuck) but do NOT steal the lock — the operator must investigate.

```
acquireManifestLock()
  // spin on fs.mkdirSync('packages.json.lock') with 50ms backoff
  // on success: write { pid, ts } to packages.json.lock/owner.json
  // on timeout (5s): read owner.json, check if PID alive
  //   - dead PID → fs.rmSync(lockdir, {recursive:true}), retry
  //   - alive PID + >30s → log error, keep waiting
try { read → modify → atomic write (tmp + rename) }
finally { releaseManifestLock()  // fs.rmSync(lockdir, {recursive:true}) }
```

### Env File (`.env`, gitignored)

```bash
# Wallets (base64 private keys)
DEPLOYER_KEY=...
ORACLE_KEY=...
MINTER_KEY=...

# DUSDC (set after one-time init)
DUSDC_PACKAGE_ID=0x...
TREASURY_CAP_ID=0x...

# Block Scholes
BLOCKSCHOLES_API_KEY=...

# Network
SUI_RPC_URL=https://fullnode.testnet.sui.io:443
```

## Component Details

### 0. One-Time Init (`init.ts`, deployer wallet)

Run once to bootstrap the framework:

1. Check if `DUSDC_PACKAGE_ID` is set in `.env` → skip if already done
2. Build and publish `packages/dusdc/` from deployer wallet
3. Parse created objects → `DUSDC package_id`, `TreasuryCap<DUSDC>`
4. Mint 10B DUSDC (10_000_000_000 * 1e6 = 10_000_000_000_000_000 base units) to deployer
5. Update `.env` with `DUSDC_PACKAGE_ID` and `TREASURY_CAP_ID`
6. Fund oracle and minter wallets with SUI for gas (from faucet or deployer)

**Note**: init does NOT transfer DUSDC to the minter wallet. Each `deploy.ts` run mints per-package DUSDC directly (see TX2). Init only handles SUI gas funding.

### 1. Deploy CLI (`deploy.ts`, deployer wallet)

Manually triggered: `tsx src/deploy.ts --commit <hash> --label <name>`

Steps:
1. Create git worktree: `git worktree add /tmp/predict-fuzz-<hash> <hash>`
2. Build: `sui move build` in worktree's `packages/predict/`
3. **TX1 (deployer)**: `sui client publish` → parse created objects: `package_id`, `Registry` (shared), `AdminCap` (owned by deployer). Wait for confirmation.
4. **TX2 (deployer)**: Setup caps and predict
   - `registry::create_oracle_cap(admin_cap)` → `deployer_cap` (remains owned by deployer)
   - `registry::create_oracle_cap(admin_cap)` → `oracle_cap` (remains owned by deployer FOR NOW)
   - `registry::create_predict<DUSDC>(registry, admin_cap)` → Predict shared internally, get `predict_id`
   - `0x2::coin::mint<DUSDC>(treasury_cap, 10_000_000_000_000)` → 10M DUSDC coin for vault
   - `0x2::coin::mint_and_transfer<DUSDC>(treasury_cap, 1_000_000_000_000, minter_address)` → 1M DUSDC for minter's PredictManager
   - Wait for confirmation.
5. **TX3 (deployer)**: Deposit vault + create oracles (Predict now referenceable as shared object)
   - `registry::admin_deposit<DUSDC>(predict, admin_cap, dusdc_coin)`
   - Call `discoverExpiries()` (shared function from oracle-manager — probes Block Scholes API for live expiries)
   - For each discovered expiry: `registry::create_oracle(registry, admin_cap, deployer_cap, "BTC", expiry_ms)` → oracle_ids (oracles shared internally)
   - Wait for confirmation.
6. **TX4 (deployer)**: Register caps + activate + share oracle_cap (oracles now referenceable)
   - For each oracle: `registry::register_oracle_cap(oracle, admin_cap, deployer_cap)` — deployer_cap is owned, passed as `&ref`
   - For each oracle: `registry::register_oracle_cap(oracle, admin_cap, oracle_cap)` — oracle_cap still owned by deployer, passed as `&ref`
   - For each oracle: `oracle::activate(oracle, deployer_cap, clock)`
   - `transfer::public_share_object(oracle_cap)` — **LAST step**: shares oracle_cap so oracle wallet can reference it
   - Wait for confirmation.
7. **TX5 (minter)**: `predict::create_manager()` → PredictManager shared internally, get `manager_id`. Wait for confirmation.
8. **TX6 (minter)**: Deposit 1M DUSDC into PredictManager (now referenceable as shared object)
9. **Verify deployment**: Before adding to manifest, confirm all object IDs are valid by querying each on-chain (`sui_getObject`). This ensures the package is fully deployed and all shared objects are available.
10. Append entry to `packages.json` (acquire manifest lock, atomic write). All oracle entries are written with `state: "active"` (TX4 already activated them). `first_update_ts: null` until oracle-updater picks them up. The `created` state is never observable for initial deploys — it only appears when oracle-manager adds new expiries to an already-deployed package (between its TX1 and TX2).
11. Clean up worktree: `git worktree remove /tmp/predict-fuzz-<hash>`

**The package is NOT added to packages.json until ALL 6 transactions succeed.** If any step fails, the deploy aborts with clear error output. The oracle-updater and fuzz-worker will only see the package after it's fully set up.

**Why 6 transactions**: On Sui, functions that internally call `transfer::share_object()` return only an `ID` — the shared object is not referenceable as a PTB argument until the transaction confirms. Each step that creates a shared object must be a separate transaction from steps that reference it.

**Key trick in TX4**: `oracle_cap` is kept owned by deployer through TX2-TX4 so deployer can pass it as `&OracleCapSVI` to `register_oracle_cap`. It is shared LAST, after all registration is complete. After TX4, oracle wallet can reference it as a shared object for `update_prices`/`update_svi`.

**Dependency notes**: `predict` depends on `deepbook` (local) → both published together. `deepbook` depends on `token` (git, rev=main) → also published. Each deploy creates its own copies. DUSDC is NOT a Move dependency — it's referenced by type at PTB call sites: `{DUSDC_PACKAGE_ID}::dusdc::DUSDC`.

**Reproducibility**: The `token` dependency uses `rev=main` which is unpinned — deploying the same predict commit at different times could pull different `token` bytecode. The deploy script should record the resolved `token` git SHA in the manifest (`token_rev` field) for traceability. To fully pin, the deploy script could override `rev=main` with a specific commit in the worktree's `Move.toml` before building.

### 2. Oracle Manager (`oracle-manager.ts`, deployer wallet)

Manually triggered: `tsx src/oracle-manager.ts`

Discovers new expiries from Block Scholes and creates/activates oracles across all packages. Also shared as a library by `deploy.ts` for initial oracle creation.

**Expiry discovery** (`discoverExpiries()` — shared function used by both oracle-manager and deploy):
1. Generate candidate expiry dates with varying granularity:
   - **Hourly**: Every hour at :00 UTC for the next 7 days (~168 candidates)
   - **Daily**: Every day at 08:00 UTC for days 7-90 (~83 candidates)
   Near-term hourly probing catches short-lived expiries; daily is sufficient for further out.
2. For each candidate, attempt `fetchSVIParams(expiryIso)` and `fetchForwardPrice(expiryIso)` in parallel
3. If both succeed → this is a live expiry
4. Return list of live expiries

**Oracle creation** for new expiries (2 transactions per package, all using deployer wallet):
- **TX1**: For each new expiry: `registry::create_oracle(registry, admin_cap, deployer_cap, "BTC", expiry_ms)` → oracle shared internally, get oracle_id. Wait for confirmation.
- **TX2**: For each new oracle:
  - `registry::register_oracle_cap(oracle, admin_cap, deployer_cap)` — deployer_cap is owned by deployer
  - `registry::register_oracle_cap(oracle, admin_cap, oracle_cap)` — oracle_cap is shared, deployer references as `&ref`
  - `oracle::activate(oracle, deployer_cap, clock)` — deployer_cap is owned by deployer
- Update `packages.json` with new oracle entries (acquire manifest lock, state: `active`, `first_update_ts: null`)

**Oracle retirement**: Removed from oracle-manager. Expiry retirement is handled automatically by oracle-updater (see Oracle Lifecycle State Machine). Oracle-manager's only role is creating and activating new oracles.

### 3. Oracle Updater (`oracle-updater.ts`, oracle wallet)

Long-running service: `tsx src/oracle-updater.ts`

Feeds real-time Block Scholes data to ALL active oracles across ALL packages.

Loop (~500ms):
1. Read `packages.json` → collect all oracles where `state: "active"` OR `state: "pending_settlement"`
2. **Expiry retirement check**: For each oracle with `state: "active"` where `now > expiry_ms`, flip to `state: "pending_settlement"` in manifest (acquire manifest lock). This is automated — no manual oracle-manager run needed.
3. Fetch from Block Scholes API (parallel):
   - `fetchSpotPrice()` → `{ price }`
   - `fetchForwardPrice(expiry)` for each unique expiry → `{ price }`
   - `fetchSVIParams(expiry)` for each unique expiry (every ~20s) → `{ a, b, rho, m, sigma }`
4. Build PTB — for each package, for each oracle (excluding quarantined oracles):
   ```
   priceData = oracle::new_price_data(spot_scaled, forward_scaled)
   oracle::update_prices(oracle_id, oracle_cap_id, priceData, clock)
   ```
   Every ~20s, also add (ONLY for `state: "active"`, not `pending_settlement`):
   ```
   sviParams = oracle::new_svi_params(a, b, rho, rho_neg, m, m_neg, sigma)
   oracle::update_svi(oracle_id, oracle_cap_id, sviParams, risk_free_rate, clock)
   ```
5. **PTB batching**: Each oracle needs 2-4 commands. If total commands > 500, split into multiple PTBs (executed sequentially within the tick). Use 500 as limit (not 900) to stay safe on serialized byte size.
6. Sign with oracle wallet, execute, log result.
7. **PTB failure handling**: If a PTB aborts, one bad oracle may have poisoned the batch. On failure:
   - Log the error and full oracle list in the failed PTB
   - Next tick: exclude the last-added oracle(s) from the failed PTB and retry
   - If retry succeeds, quarantine the excluded oracle(s) — add to in-memory `Set<oracle_id>`, log a warning
   - If retry still fails, bisect the oracle list to isolate the bad oracle(s)
   - Quarantine set resets on service restart. Quarantined oracles are logged so operators can investigate.
8. **Per-PTB manifest update**: After EACH successful PTB (not after the whole tick), update `packages.json` (acquire manifest lock) for the oracles in that PTB only:
   - For oracles with `state: "active"` that have `first_update_ts: null`: set `first_update_ts` to current timestamp
   - For oracles with `state: "pending_settlement"`: check the transaction events for an `OracleSettled` event matching this oracle's ID. Only if `OracleSettled` is present, set `state: "settled"` in manifest. This avoids trusting tx success alone — the on-chain settled bit is authoritative.
   - If PTB 1 succeeds but PTB 2 fails, PTB 1's oracles still get their state updated. PTB 2's oracles are retried next tick (with quarantine logic from step 7 if applicable).
9. Write oracle data to `oracle-data/{date}.jsonl` for analysis correlation.

**Scaling**: Float values from API are multiplied by `FLOAT_SCALING = 1e9` and rounded to u64. Signed params (rho, m) are split into `(magnitude, is_negative)`.

**Risk-free rate**: Hardcoded at 0.035 (3.5%), matching the existing oracle-feed service. Scaled to `35_000_000` in FLOAT_SCALING. If Block Scholes provides a rate feed in the future, this can be swapped.

**API failure handling**: If Block Scholes API calls fail, the updater retries once after 500ms. If the retry fails, the tick is skipped — oracles keep their last on-chain state. After 3 consecutive failed ticks, log an error. No exponential backoff needed since ticks are already spaced at 500ms. The fuzz-worker independently detects staleness (>30s since last spot price refresh) and pauses minting.

### Oracle Lifecycle State Machine

Each oracle entry in `packages.json` has a `state` field (not just boolean `active`):

```
  created ──TX4/activate──▶ active ──expiry passes──▶ pending_settlement ──updater settles──▶ settled
```

| State | Set by | Oracle-updater behavior | Fuzz-worker behavior |
|-------|--------|------------------------|---------------------|
| `created` | oracle-manager TX1 (only for oracles added to existing packages) | Ignores (not yet activated) | Skips |
| `active` | deploy TX4 / oracle-manager TX2 | Sends `update_prices` + `update_svi` | Mints if `first_update_ts` is set |
| `pending_settlement` | oracle-updater (automated, when `now > expiry_ms`) | Sends `update_prices` ONLY (triggers on-chain auto-settlement) | Skips |
| `settled` | oracle-updater (after confirming `OracleSettled` event in tx response) | Ignores | Skips |

**Key rule**: Oracle-updater automatically flips `active` → `pending_settlement` when `now > expiry_ms` (no manual oracle-manager run needed). It continues to include `pending_settlement` oracles in its price update PTB — the on-chain `update_prices` call after expiry triggers automatic settlement (the Move code freezes settlement price and emits `OracleSettled`). The updater flips `state: "settled"` ONLY after confirming the `OracleSettled` event is present in the transaction response's `events` array for that oracle. This prevents both the race where an oracle is retired before settlement is triggered, and the case where a tx succeeds but settlement didn't actually fire.

**Note on `created` state**: This state is never observed for initial deploys (package is only added to manifest after TX4 activates all oracles). It only appears when oracle-manager adds new expiries to an already-deployed package — between oracle-manager's TX1 (create) and TX2 (activate).

**`first_update_ts`**: Set by oracle-updater on the first successful `update_prices` for this oracle. The fuzz-worker only mints against oracles where `state: "active"` AND `first_update_ts` is not null. This avoids wasting gas on oracles with no data (timestamp=0 → `EOracleStale`).

### 4. Fuzz Worker (`fuzz-worker.ts`, minter wallet)

Long-running service: `tsx src/fuzz-worker.ts`

#### Gas Coin Pool (`gas-pool.ts`)

```
BUFFER = 10
TARGET_COIN_AMOUNT = 500_000_000  (0.5 SUI in MIST)

// Pool size derived from actual package count at startup
POOL_SIZE = N_packages × ORACLES_PER_PACKAGE × MINTS_PER_ORACLE + BUFFER
// e.g., 3 packages × 3 × 3 + 10 = 37 coins

Startup:
  1. Read packages.json → count active packages → compute POOL_SIZE
  2. List all SUI coins owned by minter wallet
  3. If count < POOL_SIZE: merge all, split into POOL_SIZE coins
  4. Populate available queue (simple array + index)

checkout(): string | null  — pop coin ID from queue (returns null if empty)
checkin(coinId: string)    — push coin back to queue

Graceful degradation:
  - If checkout() returns null, the fuzz worker reduces sampling for that tick:
    decrease ORACLES_PER_PACKAGE or MINTS_PER_ORACLE until batch fits available coins.
  - Log a warning when pool utilization > 80% so operator can add SUI or reduce packages.
  - On hot-reload of packages.json (new package added), log if POOL_SIZE should grow.

Notes:
  - Sui SDK resolves object versions at tx build time, so reusing coin IDs
    after a tx mutates them is safe (SDK fetches latest version).
  - If fuzz worker crashes, in-flight txs either complete or expire at
    epoch boundary. On restart, pool re-scans all owned coins — no leaks.
  - Merge+re-split ONLY operates on checked-in coins (available queue),
    never on in-flight coins.
```

#### Fuzz Mint Generation

The fuzz worker reads spot price from Block Scholes every ~5 seconds (never drifts). Each mint targets:
- **Contract price**: $0.01-$0.99 (depends on strike/direction — generated to fall in this range)
- **Total cost (notional)**: $5-$200 per mint (quantity = target_notional / approx_price)

```typescript
const TARGET_NOTIONAL_MIN = 5_000_000;    // $5 in DUSDC base units (6 decimals)
const TARGET_NOTIONAL_MAX = 200_000_000;  // $200 in DUSDC base units
const ORACLES_PER_PACKAGE = 3;            // sample up to 3 oracles per tick
const MINTS_PER_ORACLE = 3;              // 3 random mints per oracle per tick

function generateMint(pkg: PackageEntry, oracle: OracleEntry, spotPrice: number): FuzzMint {
  // Strike: spot * random(0.5, 1.5), scaled to FLOAT_SCALING
  // 5% of mints get adversarial extremes (0.1x or 3.0x) for SVI edge-case testing
  const isAdversarial = Math.random() < 0.05;
  const strikeFactor = isAdversarial
    ? (Math.random() > 0.5 ? 0.1 + Math.random() * 0.2 : 2.0 + Math.random() * 1.0)
    : 0.5 + Math.random() * 1.0;
  const strike = Math.round(spotPrice * strikeFactor * 1e9);

  // Direction: random
  const is_up = Math.random() > 0.5;

  // Estimate ask price for quantity sizing
  // Rough moneyness heuristic — exact price comes from on-chain oracle
  // This can be wrong by 2-5x for near-expiry options (steep sigmoid)
  // which is acceptable — actual cost is logged from PositionMinted event
  const moneyness = is_up ? (spotPrice - strike / 1e9) / spotPrice
                          : (strike / 1e9 - spotPrice) / spotPrice;
  const approxPrice = Math.max(0.01, Math.min(0.99, 0.5 + moneyness * 1.5));

  // Target notional: random within [$5, $200]
  const targetNotional = TARGET_NOTIONAL_MIN +
    Math.random() * (TARGET_NOTIONAL_MAX - TARGET_NOTIONAL_MIN);

  // Quantity = notional / approx_price, rounded to whole contracts (1_000_000 = $1)
  const quantity = Math.max(1_000_000,
    Math.round(targetNotional / approxPrice / 1_000_000) * 1_000_000);

  return { package_id: pkg.package_id, predict_id: pkg.predict_id,
           manager_id: pkg.manager_id, oracle_id: oracle.oracle_id,
           expiry_ms: oracle.expiry_ms, strike, is_up, quantity };
}
```

#### Execution Loop

```
// Spot price management: tracks price + last fetch timestamp.
// On startup: no timestamp → blocks until first fetch completes.
// Then refreshes every 5s. If fetch fails, keeps last value + logs warning.
// If data is >30s stale, logs error (Block Scholes likely down — oracle-updater
// is also down, so mints would fail with EOracleStale anyway).
await refreshSpotPrice()  // blocks until first fetch

const rng = Math.random  // stress mode: independent random mints per package

while (true):
  packages = readPackagesJson().filter(p => p.active)
  tasks: Promise[] = []

  for pkg in packages:
    // Filter to oracles that are active AND have received at least one update
    activeOracles = pkg.oracles.filter(o => o.state === "active" && o.first_update_ts !== null)
    if (activeOracles.length == 0) continue

    // Sample up to ORACLES_PER_PACKAGE oracles
    sampledOracles = sample(activeOracles, ORACLES_PER_PACKAGE)

    for oracle in sampledOracles:
      for i in 0..MINTS_PER_ORACLE:
        mint = generateMint(pkg, oracle, spotPrice, rng)
        tasks.push(executeMint(mint))  // each is exactly 1 tx = 1 mint

  // Fire ALL tasks in parallel — e.g., 3 packages × 3 oracles × 3 mints = 27 txs
  results = await Promise.allSettled(tasks)

  // Batch-write digests PER FILE after all tasks complete (no interleaving)
  digestsByPkg = groupBy(results, r => r.package_id)
  for [pkgId, entries] in digestsByPkg:
    batchAppendToDigestFile(pkgId, entries)  // single write per file

  // Brief pause before next tick
  await sleep(500)
```

**Every tx is exactly 1 mint** — no PTB batching for mints. With 3 packages × 3 oracles × 3 mints = 27 parallel transactions per tick.

**Skip non-ready oracles**: The fuzz worker filters to `state: "active"` AND `first_update_ts !== null`. This skips oracles that are created but not yet activated, pending settlement, settled, or never updated. No wasted gas on guaranteed failures.

**Parallelism note**: `Predict` and `PredictManager` are shared objects passed as `&mut` in mint calls. On Sui, all transactions touching the same `&mut` shared object are sequenced at consensus. Mints within the same package are serialized. Parallelism comes from minting across DIFFERENT packages simultaneously. The gas pool needs enough coins to cover one tick's batch (e.g., 27 coins for 3×3×3).

#### PTB for a single mint

```typescript
function buildMintPtb(mint: FuzzMint): Transaction {
  const tx = new Transaction();
  const dusdcType = `${DUSDC_PACKAGE_ID}::dusdc::DUSDC`;

  const key = tx.moveCall({
    target: `${mint.package_id}::market_key::new`,
    arguments: [
      tx.pure.id(mint.oracle_id),
      tx.pure.u64(mint.expiry_ms),
      tx.pure.u64(mint.strike),
      tx.pure.bool(mint.is_up),
    ],
  });

  tx.moveCall({
    target: `${mint.package_id}::predict::mint`,
    typeArguments: [dusdcType],
    arguments: [
      tx.object(mint.predict_id),
      tx.object(mint.manager_id),
      tx.object(mint.oracle_id),
      key,
      tx.pure.u64(mint.quantity),
      tx.object("0x6"), // Clock
    ],
  });

  return tx;
}
```

#### Digest Storage (`digests/{package_id}.jsonl`)

Log ALL mints (successes and failures). For successful mints, parse `PositionMinted` event from the transaction response's `events` array (`SuiTransactionBlockResponse.events`) for actual cost data. Capture gas from the response's `effects.gasUsed` to avoid needing replay for basic analysis.

```jsonc
{"digest":"ABC123","ts":1742000000,"package_id":"0x...","oracle_id":"0x...","expiry_ms":1774598400000,"strike":100000000000,"is_up":true,"qty":5000000,"status":"success","gas_used":1234,"actual_cost":495000,"ask_price":495000000,"error":null}
{"digest":"DEF456","ts":1742000001,"package_id":"0x...","oracle_id":"0x...","expiry_ms":1774598400000,"strike":120000000000,"is_up":false,"qty":2000000,"status":"failure","gas_used":800,"actual_cost":null,"ask_price":null,"error":"EOracleStale"}
```

### 5. Replay Service (`replay-service.ts`, read-only)

Manually triggered: `tsx src/replay-service.ts [--package <id>]`

For each unprocessed digest in `digests/{package_id}.jsonl`:

1. `sui replay --digest <digest>` → aggregate gas info (computation, storage, rebate)
2. `sui replay --digest <digest> --trace` → generates trace file in `.replay/<digest>/`
3. `sui analyze-trace -p .replay/<digest>/<trace_file> gas-profile` → outputs speedscope-compatible JSON with per-function gas breakdown
4. **For successful mints only**:
   - Parse transaction effects → find the `Predict` object in the `mutated` list by matching against `predict_id` from the package's manifest entry (each digest record includes `package_id`, which maps to exactly one `predict_id` in `packages.json`). Extract the post-tx `version` from the matched mutated object reference.
   - Fetch post-tx vault state via `sui_tryGetPastObject(predict_id, version)` → vault balance, total_mtm
   - Parse `PositionMinted` event from `SuiTransactionBlockResponse.events` (filter by event type `{package_id}::predict::PositionMinted`) → actual cost, ask_price
5. **For failed mints**: `vault` is `null` in replay output (Predict object was not mutated). Gas data still captured.
6. Parse the speedscope JSON to extract per-function gas costs (see Gas Profile Schema below).
7. Append combined result to `replays/{package_id}.jsonl`
8. Clean up `.replay/<digest>/` directory after processing.
9. Track last-processed line number per file in `replays/.cursor.json` (e.g., `{"0xabc...": 142, "0xdef...": 87}`). On restart, resume from saved cursor. If cursor file is missing, start from line 0 (reprocess all — replays are idempotent by digest).

**Note**: `sui_tryGetPastObject` returns the object at a specific version, giving the exact causal post-mint state. Failed transactions don't mutate shared objects, so there's no post-tx version to fetch.

**Events as primary data source**: The `PositionMinted` event emitted on-chain contains `cost`, `ask_price`, `quantity`, `strike`, `is_up`, and `oracle_id`. These are authoritative — more reliable than our fuzz-worker's approximate pricing. The replay service parses events from `SuiTransactionBlockResponse.events` for this transaction only. Cross-transaction correlation (e.g., what oracle state was at the time of minting) is done in the analysis layer by joining on timestamps with `oracle-data/*.jsonl`, not by reading events from other transactions in the same checkpoint.

**Profiling caveat**: `sui replay` requires the local Sui binary's protocol version to match the network's version at the time the transaction was executed. If the Sui binary is upgraded, older transactions may no longer be replayable. Process digests promptly.

#### Gas Profile Schema

The speedscope JSON from `sui analyze-trace` contains per-function gas breakdown. The replay service parses this into a flat per-function summary:

```jsonc
// Raw speedscope format (from `sui analyze-trace`):
{
  "shared": {
    "frames": [
      { "name": "0xpkg::predict::mint", "file": "" },
      { "name": "0xpkg::curve::ask_price", "file": "" },
      { "name": "0xpkg::treap::insert", "file": "" }
    ]
  },
  "profiles": [{
    "type": "evented",
    "unit": "none",
    "endValue": 15000,  // total gas
    "events": [
      { "type": "O", "frame": 0, "at": 0 },      // open predict::mint
      { "type": "O", "frame": 1, "at": 100 },     // open curve::ask_price
      { "type": "C", "frame": 1, "at": 5000 },    // close curve::ask_price (cost: 4900)
      { "type": "O", "frame": 2, "at": 5000 },    // open treap::insert
      { "type": "C", "frame": 2, "at": 12000 },   // close treap::insert (cost: 7000)
      { "type": "C", "frame": 0, "at": 15000 }    // close predict::mint (total: 15000)
    ]
  }]
}

// Parsed into replay output `gas_profile` field:
{
  "total_gas": 15000,
  "functions": [
    { "name": "predict::mint", "total_gas": 15000, "self_gas": 3100 },
    { "name": "curve::ask_price", "total_gas": 4900, "self_gas": 4900 },
    { "name": "treap::insert", "total_gas": 7000, "self_gas": 7000 }
  ]
}
```

`total_gas` = gas consumed by this function including callees. `self_gas` = gas consumed by this function excluding callees. Function names are stripped to `module::function` (package address prefix removed) for cross-package comparison since each package has a different address.

**Note**: The gas profile only tracks total gas units — it does not separate computation vs storage cost at the per-function level. The aggregate `gas` field in replay output (from `sui replay`) provides that split.

#### Replay Output (`replays/{package_id}.jsonl`)

```jsonc
{
  "digest": "ABC123",
  "ts": 1742000000,
  "status": "success",
  "gas": {
    "computation": 1234,
    "storage": 5678,
    "storage_rebate": 900,
    "total": 6012
  },
  "gas_profile": {
    "total_gas": 15000,
    "functions": [
      { "name": "predict::mint", "total_gas": 15000, "self_gas": 3100 },
      { "name": "curve::ask_price", "total_gas": 4900, "self_gas": 4900 },
      { "name": "treap::insert", "total_gas": 7000, "self_gas": 7000 }
    ]
  },
  "vault": {
    "balance": 10000000000000,
    "total_mtm": 500000000
  },
  "mint": {
    "strike": 100000000000,
    "is_up": true,
    "quantity": 5000000,
    "oracle_id": "0x..."
  },
  "error": null
}
```

### 6. Analysis (`analyze.ts`, read-only)

Manually triggered: `tsx src/analyze.ts`

Reads all `replays/{package_id}.jsonl` and `digests/{package_id}.jsonl` and produces:

- **Gas per mint**: distribution (mean, p50, p95, p99) per package — both aggregate and per-function (e.g., `treap::insert` self_gas across packages)
- **Gas vs position count**: does gas increase as positions accumulate? Uses cumulative successful mint count from `digests/*.jsonl` as a proxy for treap size (each successful mint adds a position). Not exact — positions can overlap on the same market key — but directionally correct for detecting O(n) vs O(log n) scaling.
- **Per-function gas comparison**: For key functions (`treap::insert`, `curve::ask_price`, `predict::mint`), compare self_gas distributions across package versions. This is the primary signal for "did the treap rewrite make insert cheaper?"
- **MTM trajectory**: total_mtm over N mints
- **Vault utilization**: balance vs total_mtm over time
- **Failure rate**: % aborted mints, grouped by error type
- **Output**: `analysis/summary.json` + CSV files for plotting

## Deployment Manifest (`packages.json`)

```jsonc
[
  {
    "label": "baseline-v1",
    "commit": "ccc57263",
    "package_id": "0x...",
    "predict_id": "0x...",
    "registry_id": "0x...",
    "admin_cap_id": "0x...",
    "deployer_cap_id": "0x...",
    "oracle_cap_id": "0x...",
    "manager_id": "0x...",
    "oracles": [
      {
        "oracle_id": "0x...",
        "underlying": "BTC",
        "expiry_iso": "2026-03-27T08:00:00.000Z",
        "expiry_ms": 1774598400000,
        "state": "active",
        "first_update_ts": "2026-03-21T12:01:00Z"
      }
    ],
    "deployed_at": "2026-03-21T12:00:00Z",
    "active": true
  }
]
```

## Logging & Observability

### Structured Logging

All services use a shared `logger.ts` that writes structured JSON logs. Each log line:

```jsonc
{"ts":"2026-03-21T12:00:00.123Z","level":"info","service":"oracle-updater","msg":"tick complete","meta":{"oracles_updated":12,"ptb_commands":48,"latency_ms":1200}}
```

Levels: `debug`, `info`, `warn`, `error`. Default level: `info`. Configurable via `.env` `LOG_LEVEL`.

### Per-Service Logs

| Service | Log file | Key metrics logged |
|---------|----------|--------------------|
| oracle-updater | `logs/oracle-updater.jsonl` | oracles_updated, api_fetch_ms, ptb_exec_ms, failures, staleness_gap |
| fuzz-worker | `logs/fuzz-worker.jsonl` | mints_sent, mints_succeeded, mints_failed, avg_gas, gas_pool_available, tick_duration_ms |
| oracle-manager | `logs/oracle-manager.jsonl` | expiries_probed, expiries_discovered, oracles_created, oracles_retired |
| deploy | `logs/deploy.jsonl` | step (1-10), tx_digest per step, objects_created, duration_ms |
| replay-service | `logs/replay-service.jsonl` | digests_processed, replay_failures, avg_replay_ms |

### Oracle Data Log

The oracle-updater also writes raw oracle data to `oracle-data/{date}.jsonl` for analysis correlation:

```jsonc
{"ts":1742000000,"spot":85000.12,"expiry":"2026-03-27T08:00:00Z","forward":85200.50,"svi":{"a":0.04,"b":0.15,"rho":-0.2,"m":0.01,"sigma":0.3},"rfr":0.035}
```

This lets the analysis layer correlate mint costs with the oracle state at the time of minting — essential for understanding why different package versions produce different pricing.

### Health / Heartbeat

Long-running services (oracle-updater, fuzz-worker) write a heartbeat file:
- `logs/oracle-updater.heartbeat` — last successful tick timestamp
- `logs/fuzz-worker.heartbeat` — last successful tick timestamp

A simple `check-health.ts` script reads these and alerts if stale (>60s for oracle-updater, >30s for fuzz-worker).

### Oracle Lifecycle in packages.json

See "Oracle Lifecycle State Machine" section for the full state diagram (`created` → `active` → `pending_settlement` → `settled`). States are managed by oracle-manager (creation) and oracle-updater (first_update_ts, expiry retirement, settlement confirmation).

The fuzz worker only mints against oracles where `state: "active"` AND `first_update_ts` is not null. If ALL oracles for a package are non-mintable, the fuzz worker skips that package entirely. The package remains in `packages.json` with `active: true` at the package level — it becomes active again when oracle-manager adds new expiries.

## Data Files Summary

| File | Written by | Read by | Format | Purpose |
|------|-----------|---------|--------|---------|
| `.env` | init (once) | all services | key=value | Static config |
| `packages.json` | deploy, oracle-manager, oracle-updater (all via manifest lock) | fuzz-worker, replay, analyze | JSON array | Deployment manifest |
| `digests/{pkg_id}.jsonl` | fuzz-worker | replay-service | JSONL | Mint tx records (successes + failures) |
| `replays/{pkg_id}.jsonl` | replay-service | analyze | JSONL | Gas profiles + vault snapshots |
| `oracle-data/{date}.jsonl` | oracle-updater | analyze | JSONL | Raw oracle data for correlation |
| `logs/{service}.jsonl` | each service | human / health check | JSONL | Operational logs |
| `analysis/summary.json` | analyze | human | JSON | Cross-package comparison |

## File Structure

```
predict_fuzz/
├── DESIGN.md
├── .env                          # wallet keys, DUSDC IDs, API key (gitignored)
├── .gitignore
├── packages.json                 # deployment manifest (source of truth)
├── digests/                      # mint tx records per package
│   └── {package_id}.jsonl
├── replays/                      # replay results per package
│   ├── {package_id}.jsonl
│   └── .cursor.json              # last-processed line per digest file
├── oracle-data/                  # raw oracle data from Block Scholes
│   └── {date}.jsonl
├── logs/                         # structured operational logs
│   ├── {service}.jsonl
│   └── {service}.heartbeat
├── analysis/                     # analysis output
│   ├── summary.json
│   └── *.csv
├── src/
│   ├── types.ts                  # PackageEntry, OracleEntry, FuzzMint, ReplayResult, etc.
│   ├── config.ts                 # load .env, constants (FLOAT_SCALING, POOL_SIZE, etc.)
│   ├── logger.ts                 # structured JSON logger with levels + heartbeat
│   ├── manifest.ts               # read/write packages.json (atomic writes)
│   ├── blockscholes.ts           # Block Scholes API client
│   ├── sui-helpers.ts            # getSigner(key), getClient(), DUSDC type string, etc.
│   ├── init.ts                   # one-time: deploy DUSDC, fund wallets
│   ├── deploy.ts                 # deploy a predict package commit (6 txs)
│   ├── oracle-manager.ts         # discover expiries, create/activate oracles
│   ├── oracle-updater.ts         # continuous price feed + oracle data logging
│   ├── gas-pool.ts               # gas coin management for parallel txs
│   ├── fuzz-worker.ts            # generate and send random mints
│   ├── replay-service.ts         # replay digests, extract profiling
│   ├── analyze.ts                # compare across packages
│   └── check-health.ts           # read heartbeat files, alert if stale
├── package.json
└── tsconfig.json
```

## Build Phases & Execution Plan

### Phase 1: Foundation (sequential, single agent)
- `types.ts`, `config.ts`, `logger.ts`, `manifest.ts`, `sui-helpers.ts`
- `package.json`, `tsconfig.json`, `.gitignore`
- Testable: types compile, config loads from .env, manifest reads/writes atomically, logger writes structured JSONL

### Phase 2: External Clients (parallel, 2 agents)
- **Agent A**: `blockscholes.ts` — API client with `fetchSpotPrice`, `fetchForwardPrice`, `fetchSVIParams`
  - Test: call each endpoint, verify response parsing and scaling
- **Agent B**: `gas-pool.ts` — coin splitting and checkout/checkin
  - Test: unit test the queue logic; integration test split/merge on testnet

### Phase 3: Deploy Pipeline (sequential, single agent)
- `init.ts` — deploy DUSDC, mint, fund wallets
- `deploy.ts` — deploy predict package, setup oracles, create manager
- Test: deploy one package on testnet, verify all objects created, packages.json updated

### Phase 4: Live Services (parallel, 2 agents)
- **Agent A**: `oracle-updater.ts` — continuous price feed
  - Test: run for 60s, verify oracles receive updates (check on-chain timestamp)
- **Agent B**: `fuzz-worker.ts` — generate and send mints
  - Test: send 10 mints to one package, verify digests logged, some succeed

### Phase 5: Oracle Management (sequential, single agent)
- `oracle-manager.ts` — expiry discovery, create oracles across packages
- Test: add a second package, run oracle-manager, verify both packages get same oracles

### Phase 6: Post-Processing (parallel, 2 agents)
- **Agent A**: `replay-service.ts`
  - Test: replay 10 digests, verify JSONL output format
- **Agent B**: `analyze.ts`
  - Test: feed sample JSONL, verify summary output

### Independence Between Components

Each component interacts with others ONLY through files on disk:
1. **`.env`** — static config, written once by init
2. **`packages.json`** — manifest, written by deploy + oracle-manager + oracle-updater (all via manifest lock), read by fuzz-worker + replay + analyze
3. **`digests/*.jsonl`** — written by fuzz-worker, read by replay-service
4. **`replays/*.jsonl`** — written by replay-service, read by analyze
5. **`oracle-data/*.jsonl`** — written by oracle-updater, read by analyze
6. **`logs/*.jsonl`** — written by each service, read by humans + check-health

No component imports from another (except shared `types.ts`, `config.ts`, `logger.ts`, `manifest.ts`, `sui-helpers.ts`, `blockscholes.ts`). Each service is a standalone `tsx` entry point.

### Testing Strategy

- **Unit tests**: Types, config parsing, manifest atomic writes, gas pool queue logic, fuzz mint generation (strike range, quantity range)
- **Integration tests** (testnet): Each service tested independently with real RPC
  - init: deploys DUSDC, verifies objects
  - deploy: deploys one predict package, verifies mint dry-run
  - oracle-updater: feeds one oracle for 30s
  - fuzz-worker: sends 10 mints, verifies digests
  - replay: replays 5 digests, verifies output
- **End-to-end**: Deploy 2 packages, run oracle-updater + fuzz-worker for 5 minutes, replay, analyze

## Transaction Types Reference

| Transaction | Wallet | Target | Objects Used | Frequency |
|-------------|--------|--------|--------------|-----------|
| Publish package | deployer | `sui client publish` | — | Manual |
| create_oracle_cap (x2) | deployer | `registry::create_oracle_cap` | AdminCap (owned) | Per deploy |
| share oracle_cap | deployer | `transfer::public_share_object` | oracle_cap (owned by deployer, created in TX2, shared as last step of TX4) | Per deploy |
| create_predict | deployer | `registry::create_predict<DUSDC>` | Registry (shared), AdminCap (owned) | Per deploy |
| admin_deposit | deployer | `registry::admin_deposit<DUSDC>` | Predict (shared), AdminCap (owned) | Per deploy |
| mint DUSDC | deployer | TreasuryCap `mint_and_transfer` | TreasuryCap (owned) | Per deploy |
| create_oracle | deployer | `registry::create_oracle` | Registry (shared), AdminCap (owned), deployer_cap (owned) | Per new expiry |
| register_oracle_cap | deployer | `registry::register_oracle_cap` | Oracle (shared), AdminCap (owned), cap (owned or shared) | Per new oracle, x2 |
| activate | deployer | `oracle::activate` | Oracle (shared), deployer_cap (owned), Clock | Per new oracle |
| update_prices | oracle | `oracle::update_prices` | Oracle (shared), oracle_cap (shared), Clock | ~2/sec |
| update_svi | oracle | `oracle::update_svi` | Oracle (shared), oracle_cap (shared), Clock | ~1/20sec |
| create_manager | minter | `predict::create_manager` | — | Per deploy |
| deposit DUSDC | minter | `predict_manager::deposit` | PredictManager (shared), DUSDC coin (owned) | Per deploy |
| mint (fuzz) | minter | `predict::mint<DUSDC>` | Predict (shared), PredictManager (shared), Oracle (shared), Clock | ~N_pkg × 9/tick |
