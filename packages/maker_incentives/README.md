# DeepBook Maker Incentives

A system that rewards market makers on DeepBook pools for providing high-quality
liquidity. Scores are computed off-chain in a Nautilus secure enclave and settled
on-chain via cryptographic attestation. Payouts are in DEEP tokens.

## Table of Contents

- [How the Formula Works](#how-the-formula-works)
- [Eligibility (Stake Requirement)](#eligibility-stake-requirement)
- [Architecture](#architecture)
- [Infrastructure & Provisioning](#infrastructure--provisioning)
- [Contract Deployment](#contract-deployment)
- [On-Chain Objects Reference](#on-chain-objects-reference)
- [Development Workflow](#development-workflow)
- [Scoring & Epoch Submission](#scoring--epoch-submission)
- [Reviewing Results](#reviewing-results)
- [Claiming Rewards](#claiming-rewards)
- [Backfilling Missed Epochs](#backfilling-missed-epochs)
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
| **Fund owner** | Holds `FundOwnerCap` | Updates fund params, toggles active/inactive |
| **Relayer** | Anyone | Calls `submit_epoch_results` with enclave-signed scores |
| **Maker** | Anyone | Provides liquidity on DeepBook, claims rewards |

---

## How the Formula Works

The incentive formula rewards makers who provide the most concentrated,
two-sided liquidity during the busiest trading periods. There are four properties
being measured:

| Property     | What it measures                                            |
| ------------ | ----------------------------------------------------------- |
| **Quantity** | How much two-sided depth is being quoted                    |
| **Position** | How tight the spread is relative to the pool's typical spread |
| **Duration** | How long the orders have been resting                       |
| **Activity** | How much trade demand existed while the maker was present   |

### Per-Maker, Per-Window Score

Each epoch (default 24h) is divided into hourly windows. Within each window,
every maker's resting book state is reconstructed from the `order_updates` and
`order_fills` database tables.

**Effective size** — geometric mean of bid and ask depth. Penalises one-sided
quoting (e.g. $1 asks with $10k bids score near zero):

```
effective_size = sqrt( avg_bid_quantity × avg_ask_quantity )
```

**Spread factor** — rewards makers who quote tighter than the pool median. The
pool-wide median is weighted by each maker's effective size so dust placements
can't distort it. `alpha` (default 0.5) controls how aggressively tight spreads
are rewarded:

```
maker_spread       = size-weighted average spread across all the maker's resting orders
pool_median_spread = effective-size-weighted median of all makers' spreads in this window

spread_factor = (pool_median_spread / maker_spread) ^ alpha
```

**Time fraction** — rewards continuous presence. Active duration is the union
of all intervals where the maker had at least one resting order (no double-
counting for multiple simultaneous orders):

```
time_fraction = active_duration / window_duration
```

The per-maker per-window score combines all three:

```
maker_window_score = effective_size × spread_factor × time_fraction
```

### Window Weighting

Windows with more trading activity are worth more, incentivising makers to stay
present during busy times. A floor ensures credit even in quiet hours:

```
floor = 1 / (2 × num_windows)
window_weight = max( window_volume / total_epoch_volume, floor )
```

### Epoch Aggregation

```
maker_epoch_score = Σ (maker_window_score × window_weight)   across all windows
maker_share       = maker_epoch_score / Σ all_maker_epoch_scores
payout            = pool_allocation × maker_share
```

### Multi-Layer Quoting

Makers who quote at multiple price levels are handled correctly:

- Quantities across all bid (or ask) orders **sum** into total bid/ask depth
- Spread is a **size-weighted average** across all price levels
- Active duration uses **interval merging** — overlapping orders don't inflate
  the time fraction
- Fills are joined by `maker_order_id`, so a fill on one layer only reduces that
  order's quantity

### Order Lifecycle Reconstruction

Each order's full lifecycle is reconstructed by merging two database tables:

1. **`order_updates`** — `Placed`, `Modified`, `Canceled`, `Expired` events with
   the remaining quantity after each event
2. **`order_fills`** — fill events joined to the maker's order via
   `maker_order_id`, each reducing the resting quantity

The merged timeline gives the exact resting quantity at every point in time. No
sampling or approximation — the time-weighted metrics are computed directly from
the event stream.

---

## Eligibility (Stake Requirement)

Not every maker with resting orders gets scored. To be eligible for maker
incentives in a pool, a maker must meet the **same stake requirement** that
DeepBook uses for its volume-based maker rebate system. For example, the
SUI/USDC pool on mainnet requires 100,000 DEEP staked.

### How it works

1. A maker calls `pool::stake()` on a DeepBook pool, locking DEEP against their
   `BalanceManager`. This is the same action used for volume-based rebate
   eligibility — no separate registration needed.
2. The DeepBook indexer records `StakeEvent`s in the `stakes` database table
   with `balance_manager_id`, `amount`, `pool_id`, and whether it was a stake
   or unstake.
3. The pool's `stake_required` threshold is fetched from the `trade_params_update`
   table (set by pool governance).
4. When the enclave computes scores, it fetches all stake events for the pool
   up to the epoch end time and computes the net stake per maker
   (`Σ stakes - Σ unstakes`).
5. Only makers with **net stake >= stake_required** have their orders scored.
   Makers below the threshold are excluded entirely — their orders are filtered
   out before lifecycle reconstruction.

### Edge cases

- A maker who stakes then fully unstakes before the epoch ends gets excluded.
- A maker who stakes mid-epoch is still eligible — the stake check is
  cumulative up to epoch end, not per-window.
- If no stake data exists (e.g. the `stakes` table is empty for the pool),
  all makers are scored (backwards-compatible fallback).
- If `stake_required` is 0 in the governance params, any positive net stake
  qualifies.

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
| **FundOwnerCap** | `FundOwnerCap` | Owned by fund creator | Management rights: update params, toggle active/inactive. Transferable. |

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

## Backfilling Missed Epochs

If the submission cron misses one or more days (e.g. server downtime), the
backfill script catches up automatically:

```bash
# Backfill last 7 days (default range)
pnpm incentives:backfill --network testnet \
  --fund-id 0xd942... --enclave-url http://<ec2-ip>:3000

# Backfill a specific date range
pnpm incentives:backfill --network testnet \
  --fund-id 0xd942... --enclave-url http://<ec2-ip>:3000 \
  --start-date 2026-03-20 --end-date 2026-03-26

# Dry run — see what would be submitted without actually doing it
pnpm incentives:backfill --network testnet \
  --fund-id 0xd942... --dry-run
```

The script:
1. Generates a list of 24h epochs in `[start-date, end-date)`
2. For each epoch, queries the on-chain `IncentiveFund` to check if
   `epoch_start_ms` was already submitted
3. Skips any epoch that's already on-chain
4. Submits missing epochs sequentially via `submit-epoch.ts`

**How far back can you backfill?** As far back as the deepbook-server's
PostgreSQL database retains order event data. The default range is 7 days.

---

## Operations

### Automated daily submission (systemd)

The `automation/` folder contains systemd units for running epoch submissions
on a daily schedule.

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
./transactions/maker-incentives/upgrade-enclave.sh \
  --network testnet --host 3.12.241.119 --key ~/.ssh/enclave.pem --debug

# Production mode (real PCRs)
./transactions/maker-incentives/upgrade-enclave.sh \
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
- **Adjust parameters**: admin can call `update_reward_per_epoch`,
  `update_alpha`, `set_pool_active`
- **Monitor**: check `journalctl -u maker-incentives-epoch` for submission
  failures, run `--dry-run` backfill to spot gaps

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

| Parameter           | Stored as     | Default | Description |
| ------------------- | ------------- | ------- | ----------- |
| `reward_per_epoch`  | u64 (raw)     | 1000 DEEP | DEEP allocated per epoch from the treasury |
| `alpha_bps`         | u64 (× 10000) | 5000 (= 0.5) | Spread factor exponent. Higher = more reward for tight spreads |
| `epoch_duration_ms` | u64           | 86400000 (24h) | Length of one epoch |
| `window_duration_ms`| u64           | 3600000 (1h) | Length of one scoring window within an epoch |

### Error Codes

| Code | Name | Description |
|------|------|-------------|
| 0 | `EInvalidSignature` | Enclave signature failed verification |
| 1 | `EPoolNotActive` | Pool is deactivated |
| 2 | `EInvalidEpochRange` | `epoch_end_ms <= epoch_start_ms` |
| 3 | `ENoRewardToClaim` | Maker not found in epoch's scores |
| 4 | `ERewardAlreadyClaimed` | Maker already claimed this epoch |
| 5 | `ENotBalanceManagerOwner` | Caller doesn't own the BalanceManager |
| 6 | `EZeroTotalScore` | Epoch has no scores to claim against |
| 7 | `EEpochAlreadySubmitted` | This `epoch_start_ms` was already submitted for this fund |
| 8 | `ENotFundOwner` | `FundOwnerCap.fund_id` does not match the target fund |

### Scoring Constants

| Constant       | Value           | Description |
| -------------- | --------------- | ----------- |
| `SCORE_SCALE`  | 1,000,000,000   | Scores are multiplied by this before converting to u64 for BCS |
| `floor`        | 1/(2 × windows) | Minimum window weight (ensures quiet hours still count) |

### Tuning Guide

- **`alpha` = 0** — spread doesn't matter, only size and duration count
- **`alpha` = 0.5** (default) — moderate spread advantage, balanced competition
- **`alpha` = 1.5** — aggressive spread competition, strongly rewards tight quotes
- **`reward_per_epoch`** — higher rewards attract more makers; can be adjusted
  without redeploying
- **`window_duration`** — shorter windows (e.g. 15min) give more granular
  activity weighting but increase computation cost

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
| `incentives:backfill` | `backfill-epochs.ts` | Backfill missed epochs over a date range |
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
│   ├── reader.rs                       # get_incentive_pool_data() — raw DB queries
│   └── server.rs                       # /incentives/pool_data/:pool_id endpoint
│
└── scripts/transactions/maker-incentives/
    ├── sui-helpers.ts                  # Self-contained Sui client utilities
    ├── deploy.ts                       # Deploy Move package → deployed.<network>.json
    ├── create-fund.ts                  # Create IncentiveFund (permissionless) + fund
    ├── register-enclave.ts             # Register enclave on-chain
    ├── update-pcrs.ts                  # Update EnclaveConfig PCRs
    ├── submit-epoch.ts                 # Score + submit one epoch
    ├── backfill-epochs.ts              # Backfill missed epochs
    ├── upgrade-enclave.sh              # Full enclave upgrade orchestrator
    ├── deployed.testnet.json           # Auto-managed object IDs for testnet
    └── automation/
        ├── maker-incentives-epoch.service  # systemd oneshot
        ├── maker-incentives-epoch.timer    # systemd daily timer (00:15 UTC)
        ├── epoch-submitter.env.example     # Template env file
        └── setup-systemd.sh                # Install/uninstall the timer
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
