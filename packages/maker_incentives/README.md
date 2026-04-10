# DeepBook Maker Incentives

A system that rewards market makers on DeepBook pools for providing high-quality
liquidity. Scores are computed off-chain in a Nautilus secure enclave and settled
on-chain via cryptographic attestation. Payouts are in DEEP tokens.

## Table of Contents

- [How the Formula Works](#how-the-formula-works)
- [Architecture](#architecture)
- [Infrastructure & Provisioning](#infrastructure--provisioning)
- [Contract Deployment](#contract-deployment)
- [On-Chain Objects Reference](#on-chain-objects-reference)
- [Development Workflow](#development-workflow)
- [Scoring & Epoch Submission](#scoring--epoch-submission)
- [Reviewing Results](#reviewing-results)
- [Pool Health Metrics (Fund Creator ROI)](#pool-health-metrics-fund-creator-roi)
- [Claiming Rewards](#claiming-rewards)
- [Treasury withdrawal (fund owner)](#treasury-withdrawal-fund-owner)
- [Scoring parameter timelock (fund owner)](#scoring-parameter-timelock-fund-owner)
- [Operations](#operations)
- [View Functions & Payout Estimation](#view-functions--payout-estimation)
- [Configuration Reference](#configuration-reference)
- [Scripts Reference](#scripts-reference)

---

## Design Philosophy

The contract is a **permissionless incentive platform**, not a single incentive
program. Anyone can create an incentive fund by depositing reward tokens,
choosing a target DeepBook pool, and setting their own scoring parameters.

### Why permissionless?

The question of "how much should be distributed each epoch" is inherently
subjective. Rather than making that a protocol decision, the contract pushes it
to the people willing to put capital behind their opinion:

- A **token project** behind a new trading pair might create a fund distributing
  10,000 of their token per week to attract initial liquidity
- A **whale** who trades a pair frequently might create a second fund with
  different params and a higher distribution rate
- A **foundation** might run a third fund focused on a major pair with
  conservative params

Each fund operates independently — its own treasury, its own parameters, its
own epoch cadence. The contract is the engine; funds are instances.

### Multiple funds, same pool

Multiple funds can target the same DeepBook pool simultaneously. A maker
providing liquidity on that pool earns from **all** active funds, scored
independently by each fund's parameters. More funds = more reasons to provide
liquidity on that pair.

### Generic reward tokens

All rewards are denominated in **DEEP**. When a fund creator deposits into their
fund, they deposit DEEP. When makers claim, they receive DEEP. This keeps things
simple — one token to track, one token to claim across all funds.

### Roles

| Role | Who | What they do |
|------|-----|-------------|
| **Protocol operator** | Deployer | Manages enclave infrastructure (PCRs, registration) |
| **Fund creator** | Anyone | Creates + funds an `IncentiveFund`, sets params |
| **Fund owner** | Holds `FundOwnerCap` | Schedules scoring-param changes (timelocked), toggles active/inactive, withdraws excess treasury |
| **Relayer** | Anyone | Calls `submit_epoch_results` with enclave-signed scores |
| **Maker** | Anyone | Provides liquidity on DeepBook, claims rewards |

---

## How the Formula Works

See [`crates/incentives/README.md`](../../crates/incentives/README.md) for the
full scoring algorithm documentation, including:

- Per-maker, per-window score computation (effective size, spread factor, time
  fraction, loyalty multiplier)
- Window weighting by fill volume
- Epoch aggregation and payout calculation
- Multi-layer quoting handling
- Order lifecycle reconstruction from event streams
- Eligibility and stake requirements
- Scoring constants and tuning guide

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                         Sui Chain                            │
│                                                              │
│  IncentiveFund          EpochRecord         BalanceManager   │
│  ┌──────────┐          ┌───────────┐        ┌───────────┐   │
│  │treasury  │──tokens─▸│rewards    │──claim──│  maker    │   │
│  │config    │          │scores     │         └───────────┘   │
│  └──────────┘          └───────────┘                         │
│  (many funds can               ▲                             │
│   target same pool)            │ submit_epoch_results        │
│       ▲                        │ (signature verified)        │
│       │ create_fund            │                             │
│       │ fund                   │                             │
└───────┼────────────────────────┼─────────────────────────────┘
        │                     │
┌───────┴─────────────────────┴────────────────────────────────┐
│                    Operator Scripts                           │
│                                                              │
│  deploy.ts → create-fund.ts → submit-epoch.ts               │
│                                  │                           │
│                          POST /process_data                  │
└──────────────────────────────────┼───────────────────────────┘
                                   │
           ┌───────────────────────┼───────────────────────────┐
           │  Same EC2 Instance (Nitro Enclave-capable)        │
           │                       │                           │
           │  ┌────────────────────┼────────────────────┐      │
           │  │  Nitro Enclave (isolated VM)             │      │
           │  │  deepbook-incentives server (port 3000)  │      │
           │  │  - Fetches data via VSOCK → host proxy   │      │
           │  │  - Computes scores                       │      │
           │  │  - Signs results with ephemeral key      │      │
           │  └──────────────────────────────────────────┘      │
           │          ↕ VSOCK                                   │
           │  socat (TCP 3000 ↔ VSOCK 3000)  — inbound         │
           │  vsock-proxy (port 9008)         — outbound        │
           │                                                    │
           │  ┌──────────────────────────────────────────┐      │
           │  │  deepbook-server (port 9008)              │      │
           │  │  PostgreSQL with order/fill/stake data    │      │
           │  └──────────────────────────────────────────┘      │
           └────────────────────────────────────────────────────┘
```

**Key requirement**: The Nautilus enclave runs as an isolated VM *within* the
same EC2 instance as the `deepbook-server`. It is not a separate instance — it
carves off dedicated CPU and memory from the host. The enclave has no network
interface, so all communication goes through VSOCK sockets:

- **Inbound** (scripts → enclave): `socat` on the host bridges TCP port 3000
  to VSOCK port 3000 inside the enclave.
- **Outbound** (enclave → deepbook-server): A `traffic_forwarder.py` inside
  the enclave bridges internal port 9008 to the host's `vsock-proxy`, which
  forwards to `localhost:9008` where `deepbook-server` listens.

---

## Infrastructure & Provisioning

### What must be provisioned manually (one-time)

The following steps are performed once when setting up a new environment. They
are not scripted because they are AWS/OS-level configuration that rarely change.

**1. EC2 instance**

Launch an enclave-capable instance in `us-east-2` (or your preferred region):
- Instance type: `m5.xlarge` or larger (must support Nitro Enclaves)
- AMI: Amazon Linux 2023
- Enable enclave support: `--enclave-options Enabled=true`
- Security group: allow inbound TCP 3000 (enclave API) and SSH

**2. Install system packages**

```bash
sudo yum install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel \
  docker socat jq
sudo systemctl enable --now docker
sudo systemctl enable --now nitro-enclaves-allocator
sudo usermod -aG ne ec2-user
sudo usermod -aG docker ec2-user
```

**3. Configure VSOCK proxy allowlist**

Edit `/etc/nitro_enclaves/vsock-proxy.yaml` to allow the enclave to reach the
deepbook-server on the host:

```yaml
allowlist:
  - {address: 127.0.0.1, port: 9008}
```

**4. Clone Nautilus and build the enclave app**

```bash
git clone <nautilus-repo> ~/nautilus
# The deepbook-incentives app lives in ~/nautilus/src/nautilus-server/src/apps/
```

**5. Start the deepbook-server**

The deepbook-server must be running on the same host, connected to the
PostgreSQL instance that contains the DeepBook indexer data:

```bash
deepbook-server --database-url postgres://... --port 9008
```

### What is fully scripted

Everything you run repeatedly — building the enclave image, starting/restarting
the enclave, updating on-chain config, deploying contracts, submitting epochs —
is handled by scripts. See [Scripts Reference](#scripts-reference).

---

## Contract Deployment

### Step 1: Deploy the Move package

```bash
cd scripts
pnpm incentives:deploy --network testnet
```

This builds and publishes the `maker_incentives` package to Sui. On success it
automatically creates `deployed.<network>.json` in the
`scripts/transactions/maker-incentives/` directory, saving all key object IDs
from the transaction.

### Step 2: Register the enclave

The enclave must be running (see [Development Workflow](#development-workflow)).
This fetches the enclave's attestation document and registers its public key
on-chain:

```bash
pnpm incentives:register-enclave --network testnet \
  --enclave-url http://<ec2-ip>:3000
```

On success, the `Enclave` shared object ID is saved back to `deployed.<network>.json`.

### Step 3: Create an IncentiveFund for a DeepBook pool

Anyone can create a fund — no admin cap required:

```bash
# Create a fund with default params
pnpm incentives:create-fund --network testnet \
  --pool-id 0x48c959... --fund 10000

# Create a fund with custom params
pnpm incentives:create-fund --network testnet \
  --pool-id 0x48c959... --reward 5000 --alpha-bps 7500
```

The new `IncentiveFund` object ID and `FundOwnerCap` ID are saved to
`deployed.<network>.json` under the `funds` mapping.

---

## On-Chain Objects Reference

### Created at deploy time

| Object | Type | Ownership | Purpose |
|--------|------|-----------|---------|
| **Package** | Published package | Immutable | Contains all Move modules |
| **EnclaveCap** | `enclave::Cap` | Owned by deployer | Required to update PCR values on the EnclaveConfig |
| **EnclaveConfig** | `enclave::EnclaveConfig<MAKER_INCENTIVES>` | Shared | Stores expected PCR hashes; used during enclave registration to verify attestations |
| **UpgradeCap** | `sui::package::UpgradeCap` | Owned by deployer | Required for future package upgrades |

### Created per enclave registration

| Object | Type | Ownership | Purpose |
|--------|------|-----------|---------|
| **Enclave** | `enclave::Enclave<MAKER_INCENTIVES>` | Shared | Stores the enclave's verified Ed25519 public key; used by `submit_epoch_results` to verify signatures |

### Created per fund (permissionless)

| Object | Type | Ownership | Purpose |
|--------|------|-----------|---------|
| **IncentiveFund** | `IncentiveFund` | Shared | Per-fund config (reward amount, alpha, durations) + DEEP treasury + submitted epoch tracking |
| **FundOwnerCap** | `FundOwnerCap` | Owned by fund creator | Management rights: schedule/cancel timelocked scoring params, toggle active/inactive, withdraw uncommitted treasury. Transferable. |

### Created per epoch submission

| Object | Type | Ownership | Purpose |
|--------|------|-----------|---------|
| **EpochRecord** | `EpochRecord` | Shared | Stores the epoch's allocation, all maker scores, unclaimed DEEP balance, and claim tracking |

Each `EpochRecord` is a permanent on-chain record. Unclaimed DEEP remains in
the record's `rewards` balance indefinitely — rewards do not expire.

### Deployed config file

All scripts read from and write to `deployed.<network>.json`:

```json
{
  "network": "testnet",
  "packageId": "0x9b0f...",
  "enclaveCapId": "0x7b7c...",
  "enclaveConfigId": "0xbd5c...",
  "upgradeCapId": "0x1098...",
  "enclaveObjectId": "0x5d43...",
  "deployTx": "9moL...",
  "deployedAt": "2026-03-27T21:40:00.000Z",
  "deployedBy": "0x0f97...",
  "funds": {
    "0xd942...": {
      "poolId": "0x48c9...",
      "ownerCapId": "0xf79c..."
    }
  }
}
```

This file is created by `deploy.ts` and updated by `register-enclave.ts` (adds
`enclaveObjectId`) and `create-fund.ts` (adds entries to `funds`). It is
the single source of truth for all other scripts — they never require you to
pass object IDs manually.

---

## Development Workflow

### Debug mode

During development, the enclave is run with `--debug-mode`:

```bash
sudo nitro-cli run-enclave --cpu-count 2 --memory 512M \
  --eif-path out/nitro.eif --debug-mode
```

Debug mode has two effects:

1. **Console access**: You can attach to the enclave's stdout/stderr with
   `nitro-cli console --enclave-id <id>`. Without debug mode, the enclave is a
   complete black box — if something crashes, you see nothing. This is the
   primary reason to use it during development.

2. **All-zero PCRs**: AWS intentionally sets PCR0, PCR1, and PCR2 to zeros in
   the attestation document. This means the attestation no longer proves which
   code is running, but that trade-off is acceptable for development.

Because the on-chain `EnclaveConfig` verifies PCR values during
`register_enclave`, you must update the stored PCRs to match:

```bash
pnpm incentives:update-pcrs --network testnet --debug
```

In production (without `--debug-mode`), the enclave produces real PCR hashes
that cryptographically bind to the exact EIF image. Those hashes are extracted
from the build output and set on-chain:

```bash
pnpm incentives:update-pcrs --network mainnet \
  --pcr0 377b6a16... --pcr1 377b6a16... --pcr2 21b9efbc...
```

### Debugging the enclave

When the enclave is running in debug mode:

```bash
# Get the enclave ID
ENCLAVE_ID=$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveID')

# Attach to console (shows stdout/stderr from the Rust server)
sudo nitro-cli console --enclave-id $ENCLAVE_ID
```

This streams all logs from the enclave in real time. Use it to debug:
- Startup failures (missing dependencies, port conflicts)
- HTTP request/response issues with deepbook-server
- Scoring computation errors
- Signature generation problems

Press Ctrl+C to detach (the enclave keeps running).

### Test endpoint (hardcoded dummy scores)

The enclave includes a `/test_process_data` endpoint that bypasses all data
fetching and scoring computation. It returns hardcoded dummy scores for two
fake makers:

- `0xaaaa...0001` — 70% of total score
- `0xbbbb...0002` — 30% of total score

This is useful for testing the full pipeline (enclave signing → on-chain
signature verification → EpochRecord creation) without needing real data in
the deepbook-server database.

```bash
# Call the test endpoint directly
curl -X POST http://<ec2-ip>:3000/test_process_data \
  -H 'Content-Type: application/json' \
  -d '{"payload":{"pool_id":"0x48c9...","epoch_start_ms":0,"epoch_end_ms":86400000,"alpha":0.5,"window_duration_ms":3600000}}'

# Or use submit-epoch with the --test flag
pnpm incentives:submit-epoch --network testnet \
  --fund-id 0xd942... --enclave-url http://<ec2-ip>:3000 --test
```

The `--test` flag on `submit-epoch.ts` switches to the `/test_process_data`
endpoint. The resulting `EpochRecord` will have a `total_allocation` of 0 if
the pool's treasury is empty, but the signature verification and record
creation still execute fully.

### Full dev setup sequence

```bash
# 1. Deploy contract
pnpm incentives:deploy --network testnet

# 2. Build and start enclave (on EC2)
cd ~/nautilus && make ENCLAVE_APP=deepbook-incentives
sudo nitro-cli run-enclave --cpu-count 2 --memory 512M \
  --eif-path out/nitro.eif --debug-mode

# 3. Set up networking (on EC2)
ENCLAVE_CID=$(nitro-cli describe-enclaves | jq -r '.[0].EnclaveCID')
echo '{}' | socat - VSOCK-CONNECT:$ENCLAVE_CID:7777
nohup socat TCP4-LISTEN:3000,reuseaddr,fork VSOCK-CONNECT:$ENCLAVE_CID:3000 &
nohup vsock-proxy 9008 127.0.0.1 9008 --config /etc/nitro_enclaves/vsock-proxy.yaml &

# 4. Update PCRs for debug mode
pnpm incentives:update-pcrs --network testnet --debug

# 5. Register enclave
pnpm incentives:register-enclave --network testnet \
  --enclave-url http://<ec2-ip>:3000

# 6. Create fund (optionally fund with reward tokens)
pnpm incentives:create-fund --network testnet --pool-id 0x... --fund 10000

# 7. Test the pipeline with dummy scores
pnpm incentives:submit-epoch --network testnet \
  --fund-id 0x... --enclave-url http://<ec2-ip>:3000 --test
```

Steps 2–5 are automated by `upgrade-enclave.sh` for subsequent rebuilds.

---

## Scoring & Epoch Submission

### How it works

Each epoch (24h by default, midnight-to-midnight UTC) is scored and submitted
as a single transaction. The flow:

1. `submit-epoch.ts` POSTs to the enclave with the pool ID and time range
2. The enclave fetches raw order/fill/stake data from `deepbook-server`
3. The enclave filters to eligible makers (those meeting stake requirements)
4. The enclave reconstructs order lifecycles, computes per-maker scores
5. The enclave BCS-serializes the `EpochResults` and signs with its ephemeral
   Ed25519 key
6. The script builds a Sui transaction with the signed `MakerRewardEntry`
   vector
7. On-chain, `submit_epoch_results` verifies the signature against the
   registered `Enclave` object's public key
8. A shared `EpochRecord` object is created with the DEEP allocation

### Running it

```bash
# Submit yesterday's epoch (default)
pnpm incentives:submit-epoch --network testnet \
  --fund-id 0xd942... --enclave-url http://<ec2-ip>:3000

# Submit a specific date range
pnpm incentives:submit-epoch --network testnet \
  --fund-id 0xd942... --enclave-url http://<ec2-ip>:3000 \
  --epoch-start 1711929600000 --epoch-end 1712016000000
```

### Duplicate submission protection

The contract tracks which `epoch_start_ms` values have been submitted per
`IncentiveFund`. Attempting to submit the same epoch twice will abort with
`EEpochAlreadySubmitted (7)`. This prevents accidental double-payouts.

---

## Reviewing Results

After submitting an epoch, you can inspect the results on-chain.

### EpochRecord object

Each submission creates a shared `EpochRecord` object. The `submit-epoch.ts`
script prints its object ID. You can inspect it with:

```bash
sui client object <epoch-record-id>
```

Fields:
- `pool_id` — the DeepBook pool this epoch covers
- `fund_id` — which IncentiveFund this epoch record belongs to
- `epoch_start_ms` / `epoch_end_ms` — the time range
- `total_allocation` — DEEP allocated from treasury for this epoch
- `total_score` — sum of all maker scores
- `rewards` — remaining unclaimed DEEP balance
- `maker_scores` — vector of `(balance_manager_id, score)` entries
- `claimed` — vector of `balance_manager_id`s that have already claimed

### Events

The transaction emits an `EpochResultsSubmitted` event:

```json
{
  "pool_id": "0x48c9...",
  "fund_id": "0xd942...",
  "epoch_start_ms": 1711929600000,
  "epoch_end_ms": 1712016000000,
  "total_allocation": 1000000000,
  "num_makers": 5
}
```

You can query past events with:

```bash
sui client events --query '{"MoveEventType":"<packageId>::maker_incentives::EpochResultsSubmitted"}'
```

### View functions

Use `devInspectTransactionBlock` or the Sui CLI to call read-only functions:

- `record_maker_info(record, balance_manager_id)` → `(score, has_claimed)`
- `record_total_allocation(record)` → DEEP allocated
- `record_remaining_rewards(record)` → unclaimed DEEP
- `record_fund_id(record)` → which fund this record belongs to
- `is_epoch_submitted(fund, epoch_start_ms)` → whether a specific epoch was
  submitted for a given fund

---

## Pool Health Metrics (Fund Creator ROI)

After submitting epochs, a fund creator wants to know: "I spent X DEEP and
median spread went from 50 bps to 12 bps." The deepbook-server exposes
per-epoch pool health metrics so sponsors can track the concrete impact of
their incentive spend over time.

### Architecture

A **materialized view** `pool_epoch_maker_metrics` stores per-maker, per-epoch
statistics. This is the base unit — pool-level aggregates are derived at query
time. The view is keyed on `(pool_id, epoch_start_ms, balance_manager_id)` and
refreshed via an admin endpoint after each epoch finalizes.

```
pool_epoch_maker_metrics (materialized view)
├── pool_id, epoch_start_ms, balance_manager_id   ← composite key
├── order_count, fill_count
├── base_volume, quote_volume
├── net_base_flow, net_quote_flow                  ← signed inventory direction
├── vwap_spread_bps                                ← maker's median VWAP spread
├── quoting_window_mask                            ← 24-bit bitmask (1h windows)
├── avg_bid_depth, avg_ask_depth
└── depth_profile                                  ← JSONB: [{bps, bid, ask}, ...]
```

**Why per-maker as the base?** A fund creator wants "which makers showed up and
how did each perform." Makers want their own stats. Pool-level aggregates are
just `SUM`/`PERCENTILE_CONT` over the per-maker rows — strictly less
flexible if stored pre-aggregated.

**Why JSONB for depth profiles?** Avoids 10+ flat columns (bid/ask × 5 bps
levels). New buckets can be added without a schema migration. The current
profile stores depth at 5, 10, 25, 50, and 100 bps bands.

### Endpoints

#### Pool-level aggregate

```
GET /v1/pool/{pool_id}/epochs/{epoch_start_ms}/metrics
```

Returns aggregate stats for one epoch. `epoch_start_ms` must be aligned to
midnight UTC (divisible by 86400000).

```json
{
  "pool_id": "0x48c9...",
  "epoch_start_ms": 1711929600000,
  "epoch_end_ms": 1712016000000,
  "fill_count": 4821,
  "total_base_volume": 15200000000,
  "total_quote_volume": 3040000000000,
  "unique_maker_count": 7,
  "net_base_flow": -2300000000,
  "net_quote_flow": 460000000000,
  "median_vwap_spread_bps": 8.4,
  "median_bbo_spread_bps": 3.2,
  "quoting_uptime_pct": 0.875,
  "avg_bid_depth": 50000.0,
  "avg_ask_depth": 48000.0,
  "depth_profile": [
    {"bps": 5,   "bid": 12000.0, "ask": 11500.0},
    {"bps": 10,  "bid": 28000.0, "ask": 27000.0},
    {"bps": 25,  "bid": 45000.0, "ask": 43000.0},
    {"bps": 50,  "bid": 48000.0, "ask": 46500.0},
    {"bps": 100, "bid": 50000.0, "ask": 48000.0}
  ]
}
```

#### Pool-level time series

```
GET /v1/pool/{pool_id}/epochs?from={start_ms}&to={end_ms}
```

Returns an array of pool-level metrics across a range. Max 90 days. This is
what a fund creator uses to see the trend across their fund's lifetime without
making 30 individual calls.

#### Per-maker breakdown

```
GET /v1/pool/{pool_id}/epochs/{epoch_start_ms}/makers
```

Returns an array of per-maker rows for one epoch. Each row includes that
maker's individual metrics:

```json
[
  {
    "pool_id": "0x48c9...",
    "epoch_start_ms": 1711929600000,
    "epoch_end_ms": 1712016000000,
    "balance_manager_id": "0xabc1...",
    "order_count": 342,
    "fill_count": 1205,
    "base_volume": 8100000000,
    "quote_volume": 1620000000000,
    "net_base_flow": -1500000000,
    "net_quote_flow": 300000000000,
    "vwap_spread_bps": 6.2,
    "quoting_window_mask": 16777215,
    "avg_bid_depth": 25000.0,
    "avg_ask_depth": 24000.0,
    "depth_profile": [
      {"bps": 5, "bid": 6000.0, "ask": 5800.0},
      {"bps": 10, "bid": 14000.0, "ask": 13500.0},
      {"bps": 25, "bid": 22000.0, "ask": 21500.0},
      {"bps": 50, "bid": 24000.0, "ask": 23200.0},
      {"bps": 100, "bid": 25000.0, "ask": 24000.0}
    ]
  }
]
```

#### Refresh (admin)

```
POST /admin/refresh_epoch_metrics
```

Triggers `REFRESH MATERIALIZED VIEW CONCURRENTLY`. Call this after each epoch
finalizes. Requires admin authentication.

### Key metrics explained

| Metric | Description |
| --- | --- |
| `median_vwap_spread_bps` | Median of per-maker VWAP spreads. Each maker's VWAP spread is the volume-weighted average distance between their bid and ask prices. This is a **maker-weighted** metric — a maker posting huge size at wide spreads pulls the median wider. |
| `median_bbo_spread_bps` | Median of per-window best-bid/best-ask spreads across all makers. This is the "how good was this market" metric — the tightest spread available at any given hour, regardless of who posted it. Only computed at pool level. |
| `quoting_uptime_pct` | Fraction of 1-hour windows where **any** maker had two-sided quotes. Per-maker: stored as a 24-bit `quoting_window_mask` bitmask. Pool-level: `popcount(bit_or(all_maker_masks)) / 24`. |
| `net_base_flow` / `net_quote_flow` | Signed inventory direction. Positive `net_base_flow` = makers net bought the base asset this epoch. Relevant for the seed capital feature — a capital provider wants to know if their inventory is being depleted in one direction. |
| `depth_profile` | JSONB array of `{bps, bid, ask}` objects. Depth within each basis-point band of the maker's VWAP mid, averaged across two-sided windows. Summed across makers for pool-level. |
| `quoting_window_mask` | Per-maker only. 24-bit integer where bit `i` is set if the maker had two-sided quotes in hour `i` (0 = 00:00–01:00 UTC, 23 = 23:00–00:00 UTC). `16777215` (all bits set) = 24/24 uptime. |

---

## Claiming Rewards

Makers claim their DEEP rewards by calling `claim_reward` with their
`BalanceManager`. The function:

1. Looks up the caller's `balance_manager_id` in the `EpochRecord`'s
   `maker_scores` vector
2. Verifies the caller owns the `BalanceManager` (`ctx.sender() == bm.owner()`)
3. Computes the pro-rata payout:
   `payout = total_allocation × maker_score / total_score`
4. Splits the DEEP from the record's `rewards` balance
5. Marks the maker as claimed (prevents double-claiming)
6. Returns the reward as a `Coin<DEEP>`

### Example transaction (TypeScript)

```typescript
const tx = new Transaction();
const payout = tx.moveCall({
  target: `${packageId}::maker_incentives::claim_reward`,
  arguments: [
    tx.object(epochRecordId),
    tx.object(balanceManagerId),
  ],
});
tx.transferObjects([payout], myAddress);
```

### Important notes

- **Rewards never expire.** Unclaimed DEEP stays in the `EpochRecord` forever.
  Makers can claim at any time.
- **One claim per maker per epoch.** Calling `claim_reward` twice aborts with
  `ERewardAlreadyClaimed (4)`.
- **Ownership check.** Only the `BalanceManager` owner can claim. Attempting to
  claim someone else's reward aborts with `ENotBalanceManagerOwner (5)`.

---

## Treasury withdrawal (fund owner)

The fund owner (`FundOwnerCap`) can pull **DEEP that is not earmarked for the
next two full epochs** at the current `reward_per_epoch`. The contract keeps

`locked = min(treasury_balance, 2 × reward_per_epoch)`

in the shared `IncentiveFund` treasury; everything above that is **withdrawable**.
That gives makers a predictable floor (roughly “current + upcoming” epoch
budgets at the configured rate) while still letting sponsors reclaim deep runway
beyond that.

- **Entry point:** `withdraw_treasury(cap, fund, clock, amount, ctx) → Coin<DEEP>` —
  sends to `ctx.sender()`. Aborts if `amount` is zero or larger than the
  withdrawable balance. `clock` is the Sui shared `0x6` clock (also used to
  apply any due delayed param updates before computing the lock).
- **Views:** `fund_locked_treasury`, `fund_withdrawable_treasury` (and
  `fund_funded_epochs` for full-epoch runway).
- **Event:** `TreasuryWithdrawn` (amount, post-withdrawal treasury, locked and
  withdrawable snapshots, `reward_per_epoch`) — indexed into
  `maker_incentive_treasury_withdrawn` and exposed by deepbook-server as
  `GET /maker_incentive_treasury_withdrawn`.

If `reward_per_epoch` is zero, nothing is locked and the owner may withdraw the
entire treasury. The rule is **runway-based** (treasury vs `reward_per_epoch`),
not tied to wall-clock epoch boundaries on-chain.

---

## Scoring parameter timelock (fund owner)

`reward_per_epoch`, `alpha_bps`, and `quality_p` cannot be changed instantly.
The owner calls **`schedule_params_change(cap, fund, clock, reward_per_epoch, alpha_bps, quality_p)`** with the **full** desired future snapshot. It takes effect after **`param_change_delay_epochs()` × 24h** from `clock` at scheduling time (currently **2 epochs**, i.e. ~48h notice). That gives makers time to react, reduces mid-epoch gaming (e.g. tilting weights after observing scores), and lines up with enclave / scoring upgrades that need a published target configuration.

- **`cancel_scheduled_params_change(cap, fund)`** — drops a pending schedule before it activates (no-op if none).
- **`finalize_pending_params(fund, clock)`** — permissionless; applies the pending snapshot once `clock.timestamp_ms()` ≥ the stored effective time. Pending params are also applied automatically at the start of **`submit_epoch_results`** and **`withdraw_treasury`**, so relayers and withdrawals advance state without a separate crank.
- **Emergency:** **`set_fund_active`** is still **immediate** (pause / unpause submissions).
- **Views:** `fund_has_pending_params`, `fund_params_effective_at_ms`, `fund_pending_params_info`, and `fund_effective_*` (read-only “what applies at this clock time” without mutating storage).
- **Events:** `FundParamsChangeScheduled`, `FundParamsChangeApplied`, `FundParamsChangeCancelled`
  — indexed to `maker_incentive_params_{scheduled,applied,cancelled}` and exposed as
  `GET /maker_incentive_params_scheduled`, `GET /maker_incentive_params_applied`,
  `GET /maker_incentive_params_cancelled`.

**Relayers:** `submit_epoch_results` now takes the shared **Clock** (`0x6`) as an argument after the enclave object; `submit-epoch.ts` passes it automatically.

---

## Operations

### Automated daily submission (systemd)

The `automation/` folder contains systemd units for running epoch submissions
on a daily schedule. The `submit-all-epochs.ts` script automatically checks
the last 7 days for each fund and fills any gaps, so missed days are recovered
without manual intervention.

**Backfilling:** If the cron was down for several days, just run:

```bash
# Check last 14 days for all funds (dry-run first to see gaps)
pnpm incentives:submit-all --network testnet \
  --indexer-url http://localhost:3000 --lookback-days 14 --dry-run

# Then submit for real
pnpm incentives:submit-all --network testnet \
  --indexer-url http://localhost:3000 --lookback-days 14
```

**How far back can you backfill?** As far as the deepbook-server's PostgreSQL
database retains order event data. The default lookback is 7 days.

**Setup:**

```bash
cd scripts/transactions/maker-incentives/automation/

# 1. Create your env file from the template
cp epoch-submitter.env.example epoch-submitter.env
# Edit epoch-submitter.env with your NETWORK, POOL_ID, ENCLAVE_URL

# 2. Install and start the timer
sudo ./setup-systemd.sh
```

The timer fires at **00:15 UTC daily** — 15 minutes after the epoch boundary
to allow the deepbook-server database to finish ingesting the last events.
`Persistent=true` ensures that if the machine was off at 00:15, it fires on
next boot.

The service retries up to 3 times on failure with 60-second delays.

**Useful commands:**

```bash
# Check timer status and next firing
systemctl list-timers maker-incentives*

# Tail logs
journalctl -u maker-incentives-epoch -f

# Manual trigger (for testing)
sudo systemctl start maker-incentives-epoch.service

# Uninstall
sudo ./setup-systemd.sh --uninstall
```

### Enclave upgrades

When the enclave code changes (e.g. updated scoring logic), the full upgrade
cycle is automated by a single script:

```bash
# Debug mode (development)
./transactions/maker-incentives/enclave/upgrade-enclave.sh \
  --network testnet --host 3.12.241.119 --key ~/.ssh/enclave.pem --debug

# Production mode (real PCRs)
./transactions/maker-incentives/enclave/upgrade-enclave.sh \
  --network mainnet --host <ec2-ip> --key ~/.ssh/enclave.pem
```

This script:
1. SSHes to the EC2 host and terminates the running enclave
2. Rebuilds the EIF (`make ENCLAVE_APP=deepbook-incentives`)
3. Extracts PCR0/1/2 from the build output
4. Starts the new enclave (with `--debug-mode` if `--debug` flag passed)
5. Sets up networking (socat + vsock-proxy)
6. Verifies the health check
7. Updates on-chain PCRs (all-zeros for debug, real hashes for production)
8. Re-registers the enclave (saves new `enclaveObjectId` to deployed config)

### Ongoing maintenance

- **Fund the pool**: anyone can call `fund_pool` to deposit more DEEP
- **Check funding runway**: `pool_funded_epochs` returns how many full epochs
  the treasury can cover
- **Adjust parameters**: fund owner schedules timelocked `schedule_params_change`
  (or `set_fund_active` for immediate pause)
- **Monitor**: check `journalctl -u maker-incentives-epoch` for submission
  failures, run `incentives:submit-all --dry-run` to spot gaps

---

## View Functions & Payout Estimation

The Move contract exposes read-only functions for UIs and integrators:

### Pool Info

| Function                  | Returns                                         |
| ------------------------- | ----------------------------------------------- |
| `pool_treasury_balance`   | Current DEEP balance in the treasury             |
| `pool_reward_per_epoch`   | DEEP allocated per epoch                         |
| `pool_funded_epochs`      | How many full epochs the treasury can fund        |
| `pool_is_active`          | Whether the pool is accepting submissions         |
| `pool_alpha_bps`          | Spread exponent (scaled by 10000)                |
| `pool_epoch_duration_ms`  | Epoch length                                     |
| `pool_window_duration_ms` | Window length                                    |
| `pool_id`                 | The DeepBook pool address this incentive pool covers |
| `is_epoch_submitted`      | Whether a given `epoch_start_ms` has been submitted |

### Payout Estimation

```move
public fun estimate_payout(
    fund: &IncentiveFund,
    maker_score: u64,
    total_score: u64,
): u64
```

Returns the DEEP a maker would receive given their score and the total score.
Uses the fund's current `reward_per_epoch` and treasury balance
(`min(reward_per_epoch, treasury_balance)`). UIs can use the previous epoch's
total score as a proxy to show makers what their current position would earn.

### Epoch Record Info

| Function                  | Returns                                         |
| ------------------------- | ----------------------------------------------- |
| `record_total_allocation` | DEEP allocated for this epoch                    |
| `record_total_score`      | Sum of all maker scores                          |
| `record_remaining_rewards`| DEEP not yet claimed                             |
| `record_maker_info`       | `(score, has_claimed)` for a specific maker      |

---

## Configuration Reference

### Fund-Specific Parameters

Each `IncentiveFund` has its own configuration. These are set at creation and
can be updated by the fund owner (holder of `FundOwnerCap`).

| Parameter           | Stored as      | Default        | Description |
| ------------------- | -------------- | -------------- | ----------- |
| `reward_per_epoch`  | u64 (raw)      | 1000 DEEP      | DEEP allocated per epoch from the treasury |
| `alpha_bps`         | u64 (× 10 000) | 5000 (= 0.5)  | Spread factor exponent. Higher = more reward for tight spreads |
| `quality_p`         | u64            | 3              | Quality compression root. `quality^(1/p)` — higher values make depth the dominant factor |
| `epoch_duration_ms` | u64            | 86 400 000 (24h) | Length of one epoch (fixed on-chain) |
| `window_duration_ms`| u64            | 3 600 000 (1h)   | Length of one scoring window within an epoch (fixed on-chain) |

### Error Codes

| Code | Name | Description |
|------|------|-------------|
| 0 | `EInvalidSignature` | Enclave signature failed verification |
| 1 | `EFundNotActive` | Fund is deactivated |
| 2 | `EInvalidEpochRange` | `epoch_end_ms <= epoch_start_ms` |
| 3 | `ENoRewardToClaim` | Maker not found in epoch's scores |
| 4 | `ERewardAlreadyClaimed` | Maker already claimed this epoch |
| 5 | `ENotBalanceManagerOwner` | Caller doesn't own the BalanceManager |
| 6 | `EZeroTotalScore` | Epoch has no scores to claim against |
| 7 | `EEpochAlreadySubmitted` | This `epoch_start_ms` was already submitted for this fund |
| 8 | `ENotFundOwner` | `FundOwnerCap.fund_id` does not match the target fund |
| 9 | `EEpochBeforeFundCreation` | Epoch predates the fund's creation timestamp |
| 10 | `EInvalidEpochDuration` | Epoch duration doesn't match `epoch_duration_ms` |
| 11 | `EInvalidQualityP` | `quality_p` must be ≥ 1 |
| 12 | `EWithdrawAmountTooLarge` | Withdrawal exceeds uncommitted treasury balance |
| 13 | `EWithdrawZero` | Withdrawal amount is zero |

### Scoring Constants & Tuning

See the [Scoring Constants](../../crates/incentives/README.md#scoring-constants)
and [Tuning Guide](../../crates/incentives/README.md#tuning-guide) in the
incentives crate README.

| Constant                    | Value | Description |
| --------------------------- | ----- | ----------- |
| `PARAM_CHANGE_DELAY_EPOCHS` | 2     | On-chain delay (in epochs) before a `schedule_params_change` takes effect |

---

## Scripts Reference

All scripts run from the `scripts/` directory. Arguments are passed as CLI flags.

| npm script | Script file | Purpose |
|------------|-------------|---------|
| `incentives:deploy` | `deploy.ts` | Build and publish the Move package |
| `incentives:create-fund` | `create-fund.ts` | Create an IncentiveFund + optionally fund |
| `incentives:register-enclave` | `register-enclave.ts` | Fetch attestation and register enclave on-chain |
| `incentives:update-pcrs` | `update-pcrs.ts` | Update EnclaveConfig PCRs (debug zeros or real hashes) |
| `incentives:submit-epoch` | `submit-epoch.ts` | Score one epoch via enclave and submit on-chain |
| `incentives:submit-all` | `submit-all-epochs.ts` | Submit all funds' epochs, auto-backfilling gaps |
| `incentives:upgrade-enclave` | `upgrade-enclave.sh` | Full enclave rebuild + restart + re-register |

### Project Structure

```
deepbookv3/
├── packages/maker_incentives/          # Move smart contract
│   ├── Move.toml
│   ├── sources/
│   │   └── maker_incentives.move       # IncentiveFund, EpochRecord, claim logic
│   └── tests/
│       └── maker_incentives_tests.move # 20 unit tests
│
├── crates/incentives/                  # Rust scoring engine + enclave server
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                      # AppState, IncentiveError
│       ├── main.rs                     # Axum server: /health_check, /get_attestation, /process_data
│       ├── dry_run.rs                  # Simulation binary for testing against real data
│       ├── scoring.rs                  # Lifecycle-based scoring algorithm
│       └── types.rs                    # Shared types (BCS-compatible, API, scoring)
│
├── crates/server/src/
│   ├── reader.rs                       # get_incentive_pool_data(), epoch metrics from materialized view
│   ├── server.rs                       # /incentives/pool_data, /v1/pool/.../epochs/... endpoints
│   └── admin/
│       ├── handlers.rs                 # refresh_epoch_metrics admin handler
│       └── routes.rs                   # POST /admin/refresh_epoch_metrics
│
├── crates/schema/migrations/
│   └── ..._pool_epoch_maker_metrics/
│       ├── up.sql                      # CREATE MATERIALIZED VIEW pool_epoch_maker_metrics
│       └── down.sql                    # DROP MATERIALIZED VIEW
│
└── scripts/transactions/maker-incentives/
    ├── lib/
    │   └── sui-helpers.ts                # Self-contained Sui client utilities
    ├── setup/
    │   ├── deploy.ts                     # Deploy Move package → deployed.<network>.json
    │   ├── create-fund.ts                # Create IncentiveFund (permissionless) + fund
    │   └── swap-sui-for-deep.ts          # Swap SUI for DEEP tokens
    ├── contract/
    │   ├── submit-epoch.ts               # Score + submit one epoch
    │   ├── submit-all-epochs.ts          # Submit all funds, auto-backfills gaps
    │   ├── register-enclave.ts           # Register enclave on-chain
    │   └── update-pcrs.ts                # Update EnclaveConfig PCRs
    ├── enclave/
    │   ├── create-enclave-ec2.sh         # Spin up EC2 instance
    │   ├── setup-ec2.sh                  # Configure EC2 deps
    │   ├── provision-enclave.sh          # Build & start enclave
    │   └── upgrade-enclave.sh            # Full enclave upgrade orchestrator
    ├── test/
    │   ├── e2e-test.sh                   # End-to-end test
    │   └── setup-testnet-data.sh         # Bootstrap testnet data
    ├── automation/
    │   ├── maker-incentives-epoch.service  # systemd oneshot
    │   ├── maker-incentives-epoch.timer    # systemd daily timer (00:15 UTC)
    │   ├── epoch-submitter.env.example     # Template env file
    │   └── setup-systemd.sh                # Install/uninstall the timer
    └── deployed.testnet.json             # Auto-managed object IDs for testnet
```

### Testing

**Move unit tests** (20 tests covering all contract logic):

```bash
cd packages/maker_incentives
sui move test
```

**Rust unit tests** (scoring algorithm):

```bash
cargo test -p deepbook-incentives
```

**Dry-run simulation** (against real production data, no enclave needed):

```bash
cargo run --bin incentives-dry-run -- \
  --server-url http://your-deepbook-server:8080 \
  --pool-id 0x... \
  --alpha 0.5 \
  --reward-per-epoch 1000
```
