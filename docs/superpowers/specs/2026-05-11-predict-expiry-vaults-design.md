# Predict Expiry-Local Vaults and Batched PLP Valuation

## Context

The current Predict package routes protocol activity through one shared `Predict` object that owns one `Vault`. That vault stores quote balances, per-oracle strike matrices, cached global MTM, cached global max payout, and the list of exposed unsettled oracles that must be refreshed before LP supply or withdrawal.

This design creates a scaling bottleneck. Minting, redeeming, settlement accounting, LP supply, LP withdrawal, and MTM refreshes all contend on the same shared object even when they affect unrelated expiries.

The goal is to make individual expiries independently mutable so trading activity can parallelize across expiry objects. PLP should remain fungible: every PLP share must represent the same pro-rata claim on the full protocol risk profile, not a claim tied to when a user deposited or which expiries existed during that user's supply lifetime.

## Goals

- Move hot trading state out of the global pool object and into per-expiry objects.
- Preserve fungible PLP semantics.
- Avoid per-user expiry lineage or non-fungible LP tranches.
- Allow the protocol to increase or decrease capital allocated to an existing expiry.
- Ensure allocation decreases are limited to an expiry's free capital.
- Remove live MTM computation from individual mint and redeem paths.
- Compute global share value only when queued LP deposits and withdrawals are flushed.

## Non-Goals

- This design does not attempt immediate LP supply or withdrawal at continuously updated share prices.
- This design does not transfer an exiting LP's active risk to remaining LPs without compensation.
- This design does not track which user funded which expiry.
- This design does not require pausing all trading during normal protocol operation.

## Architecture

### Pool Vault

The pool vault is the parent capital object. It owns:

- idle quote capital
- PLP treasury cap
- deposit queue state
- withdrawal queue state
- latest finalized share price
- registry or index of active expiry vault IDs
- aggregate snapshot state needed to finalize a valuation epoch

The pool vault is cold relative to trading. It is touched by LP requests, allocation changes, and keeper valuation epochs, but not by every market trade.

### Expiry Vault

Each expiry has one shared `ExpiryVault` object. It owns:

- expiry timestamp
- allocated capital
- one strike matrix / exposure surface
- total max payout
- optional cached MTM from the latest valuation epoch
- state needed for settlement and liability compaction

Trades for a given expiry mutate only that expiry's vault, the relevant oracle object, and the trader's manager state.

The core local invariant is:

```text
expiry.total_max_payout <= expiry.allocated_capital
```

Capital can be allocated into an expiry at any time. Capital can be removed only up to:

```text
expiry_free_capital = expiry.allocated_capital - expiry.total_max_payout
```

This lets governance or keeper logic resize active expiries without underfunding existing worst-case liabilities.

## Trade Path

Mint and redeem operations should not compute or maintain global MTM.

On mint, the expiry vault:

1. validates the range key and expiry state
2. computes the user-facing trade price from oracle/pricing inputs
3. inserts the range into the expiry strike matrix
4. recomputes exact `total_max_payout`
5. aborts if the expiry would exceed allocated capital
6. accepts the user's principal payment and routes fees

On live redeem, the expiry vault:

1. validates the position
2. computes the live redeem price from oracle/pricing inputs
3. removes the range from the expiry strike matrix
4. recomputes exact `total_max_payout`
5. pays the user from the expiry's allocated capital

On settled redeem, the expiry vault burns the position against terminal settlement liability and pays the settled amount. Settlement and compaction can remain expiry-local.

MTM is only needed by the pool vault when it prices queued PLP deposits and withdrawals.

## LP Request Model

LP supply and withdrawal are queued.

### Supply Request

The user deposits quote capital and receives a deposit receipt. The request is not immediately priced into PLP. It joins a pending deposit batch.

At the next finalized valuation epoch, the request receives PLP at that epoch's global share price:

```text
deposit_shares = deposit_amount / share_price
```

This means new suppliers buy into the full current protocol risk profile at the same price used for withdrawals.

### Withdrawal Request

The user escrows PLP and receives a withdrawal receipt. The request is not immediately paid. It joins a pending withdrawal batch.

At the next finalized valuation epoch, the request receives quote value at that epoch's global share price:

```text
withdraw_amount = withdrawn_shares * share_price
```

Withdrawals still must respect max-loss solvency. If the withdrawal batch cannot be fully paid without preserving worst-case backing, it should be filled pro-rata and the unfilled shares should remain queued and exposed for the next epoch.

FIFO withdrawal priority should be avoided unless there is a strong reason to accept queue-position games. Pro-rata fill by withdrawal epoch is the safer default.

## Global Valuation Snapshot

The pool vault can compute global share value through a hot-potato snapshot flow instead of maintaining continuously fresh MTM.

### Snapshot Flow

1. A keeper calls `PoolVault::start_snapshot`.
2. The pool vault creates a linear `SnapshotPotato` containing the active expiry set and snapshot epoch ID.
3. The keeper calls a read/snapshot function on each active expiry vault.
4. Each expiry vault returns an unforgeable `ExpiryValuation` receipt.
5. The keeper passes each receipt into `PoolVault::add_expiry_valuation`.
6. The pool vault accumulates allocated capital, MTM, max payout, and marks that expiry as read.
7. `PoolVault::finalize_snapshot` consumes the potato only if every active expiry was included exactly once.
8. Finalization writes the global share price and flushes the LP queues.

The valuation receipt should carry the valuation numbers itself. The API should not accept a separate witness plus caller-provided MTM, because that would let a caller pair a real receipt with fake valuation data.

Example linear receipt fields:

```move
public struct ExpiryValuation {
    snapshot_id: ID,
    expiry_vault_id: ID,
    allocated_capital: u64,
    mtm: u64,
    max_payout: u64,
    exposure_version: u64,
}
```

The exact fields need to be designed for Move linearity. The important property is that only the expiry vault module can create a valid valuation receipt for that expiry and snapshot, and the receipt must be consumed by the pool snapshot flow.

### Share Price

At finalization:

```text
gross_assets = pool_idle_capital + sum(expiry.allocated_capital)
mtm_liability = sum(expiry.mtm)
nav = gross_assets - mtm_liability
share_price = nav / total_plp_supply
```

Deposits and withdrawals in the same epoch use the same share price.

### Withdrawal Capacity

Even if NAV supports a withdrawal by MTM value, the pool cannot release capital needed for worst-case payout.

A conservative capacity formula is:

```text
withdraw_capacity =
    pool_idle_capital
  + pending_deposit_amount
  + sum(expiry.allocated_capital - expiry.total_max_payout)
  - target_buffer
```

The exact formula may need to account for queue ordering, fees, reserved settlement payouts, quote-asset balance availability, and whether pending deposits are immediately deployable in the same epoch.

## Snapshot Consistency

The hot-potato model avoids a dedicated maintenance window, but consistency still needs careful handling.

The simple version assumes all active expiry valuations are collected and finalized in a single PTB. In that case, Sui object versioning gives a coherent transaction-level read of all touched expiry vaults.

If the active expiry set grows too large for a single PTB, a multi-transaction snapshot needs additional machinery. Possible options:

- temporarily lock only the expiry being snapshotted until finalization
- store an `exposure_version` in each expiry and reject finalization if a contributed expiry changed
- allow partial snapshot chunks but require unchanged versions at finalization
- shard the pool into multiple pool vaults by product or expiry family

The first implementation should prefer a single-PTB snapshot if active expiry count is expected to remain modest.

## Invariants

- PLP is fungible: one share equals the same pro-rata claim as every other share.
- Deposits and withdrawals are priced only at finalized valuation epochs.
- Mint and redeem paths do not mutate global pool valuation state.
- Expiry trading is solvency-gated by exact max payout, not live MTM.
- No expiry allocation decrease can violate `allocated_capital >= total_max_payout`.
- Withdrawals cannot release capital required to preserve max-loss backing.
- Unfilled withdrawal shares remain exposed until a future epoch fills them.
- A snapshot can finalize only if every active expiry is valued exactly once.

## Open Questions

- What is the expected upper bound on simultaneously active expiries?
- Should active expiry IDs live in the pool vault, registry, or a dedicated active-expiry index object?
- Should the valuation snapshot use current oracle data directly, or use per-expiry cached oracle state?
- How should queued withdrawal receipts represent partial fills?
- Are pending deposits deployable in the same epoch that prices them, or only after withdrawal settlement completes?
- What target buffer should sit above exact max-payout backing?
- Should fee reserves and insurance reserves participate in NAV or remain outside PLP value?
- How should quote-asset heterogeneity be handled if multiple quote assets remain enabled?
- Can expired but unsettled expiries be included in snapshots at conservative max payout, or must they settle before finalization?

## Recommended First Spec Boundary

The first implementation design should focus on:

1. Splitting the current vault into parent pool state and per-expiry vault state.
2. Making mint/redeem mutate only the relevant expiry vault.
3. Preserving exact per-expiry max-payout solvency.
4. Adding queued LP supply/withdraw requests.
5. Adding a single-PTB hot-potato valuation snapshot that finalizes share price and flushes queues.

Multi-transaction snapshots, instant withdrawals, external exit liquidity, and more complex capital rebalancing should be deferred until the simple sharded model is proven.
