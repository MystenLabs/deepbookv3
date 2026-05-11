# Predict Expiry-Local Vaults and Fresh PLP Valuation

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
- Keep MTM out of persistent expiry-vault state; compute it only through explicit valuation endpoints.
- Compute global share value only when LP supply or withdrawal needs a fresh PLP price.

## Non-Goals

- This design does not require continuously maintained share prices in the trade path.
- This design does not transfer an exiting LP's active risk to remaining LPs without compensation.
- This design does not track which user funded which expiry.
- This design does not require pausing all trading during normal protocol operation.

## Architecture

### Pool Vault

The pool vault is the parent capital object. It owns:

- idle quote capital
- PLP treasury cap
- optional inactive-supply accounting
- optional pending-withdrawal accounting
- latest finalized share price
- latest finalized share calculation timestamp
- active expiry vault IDs required for full valuation snapshots
- aggregate snapshot state needed to finalize a valuation epoch

The pool vault is cold relative to trading. It is touched by LP requests, allocation changes, and share valuation epochs, but not by every market trade.

### Expiry Vault

Each expiry has one shared `ExpiryVault` object. It owns:

- expiry timestamp
- allocated capital
- one strike matrix / exposure surface
- total max payout
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

Mint and redeem operations should not compute or maintain MTM, either globally or inside the expiry vault. Their risk responsibility is exact max-payout solvency.

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

MTM is only needed when the pool vault needs a fresh PLP price for supply, withdrawal, or a keeper cache refresh. The expiry vault should expose a valuation endpoint that computes MTM from current expiry exposure and pricing inputs, then returns a linear valuation receipt for the hot-potato snapshot flow. That endpoint is separate from mint and redeem.

## LP Entry and Exit Model

LP supply and withdrawal require a fresh global PLP valuation. The protocol does not need to compute that value unless an LP flow needs it. The hot-potato share calculation should be exposed as a public function that anyone can call to set the latest pool share price and timestamp. A public cron can keep that value fresh and flush queued LP actions, or a user can include the calculation inline with supply/withdraw if the full operation is cheap enough.

There are three viable entry/exit modes. The right default depends on how cheap it is to compute full MTM across all active expiries.

### Mode A: Fresh-Cache Immediate Flow

The pool vault stores the latest finalized share calculation and a timestamp. Supply and withdrawal can execute immediately if that calculation is fresh enough.

Default freshness policy:

```text
clock.now_ms - pool.last_share_calculation_ms <= share_price_freshness_ms
share_price_freshness_ms = 60_000
```

The 60-second default should be configurable. It can be tightened or loosened based on how cheap the full share calculation is and how quickly PLP NAV changes in practice.

If the cached calculation is fresh:

- supply mints PLP immediately at the cached share price
- withdrawal burns PLP immediately at the cached share price, subject to max-loss withdrawal capacity
- no full-expiry MTM calculation is needed in that transaction

This gives immediate UX most of the time if a keeper updates the share calculation frequently enough.

### Mode B: On-Demand Immediate Flow

If the cached share calculation is stale, anyone can call the public hot-potato valuation path to refresh the share price. A user can include that refresh in the same PTB as supply or withdrawal when the full operation is cheap enough.

The transaction shape is:

1. start a valuation snapshot
2. collect valuation receipts from all active expiries
3. finalize the pool share calculation
4. execute the supply or withdrawal against the fresh share price

If full MTM is cheap enough, this can be the only LP path. There would be no deposit or withdrawal queue; every LP action computes or refreshes the share price as part of the flow. If it is not cheap enough, the same public refresh function can be run by crons/searchers to flush protocol-accounted pending actions.

### Mode C: Inactive Supply and Pending Withdrawal Fallback

If full MTM is too expensive for every user-triggered supply or withdrawal, stale-price requests can be queued instead.

Supply request:

- user deposits quote capital
- protocol records the amount as inactive supply keyed by the user's account or address
- inactive supply is not PLP yet and does not participate in active risk until pushed
- a keeper finalizes a valuation epoch and pushes inactive supply into active PLP

Withdrawal request:

- user escrows or burns PLP into protocol-controlled pending withdrawal state
- protocol records the withdrawal shares keyed by the user's account or address
- request waits for the next finalized valuation epoch

At finalization, inactive supplies receive PLP and withdrawals receive quote at the same global share price:

```text
deposit_shares = deposit_amount / share_price
withdraw_amount = withdrawn_shares * share_price
```

The PLP created from inactive supply should stay in protocol-internal balances, similar to DeepBook core's `settled_balances`, and the user can claim it later. This avoids creating separate user-owned deposit objects and keeps the fallback closer to DeepBook's inactive-stake and settlement patterns.

Withdrawal payouts should use the same protocol-accounted pattern. Quote payouts should settle into protocol-internal balances for later claim, held alongside the same accounting surface that tracks escrowed PLP for pending withdrawers. The user does not hold a separate withdrawal token or object; their pending withdrawal is protocol-accounted state until it is pushed.

The protocol-accounted pending state is therefore not fundamental to PLP fungibility. It is a fallback for cases where full valuation is too expensive to run inline with every LP flow.

### Mode C Internalizer

Before minting new PLP for inactive supply or redeeming PLP against pool capital, the pool must internalize opposing LP flows.

At a finalized share price:

```text
withdraw_quote_demand = pending_withdraw_shares * share_price
matched_quote = min(inactive_supply_quote, withdraw_quote_demand)
matched_plp = matched_quote / share_price
```

For the matched portion:

- suppliers' quote goes to withdrawing LPs
- withdrawing LPs' escrowed PLP goes to suppliers
- total PLP supply does not change
- pool idle capital does not change
- expiry allocations do not change
- withdrawal capacity is not consumed

Only the unmatched net flow reaches the pool:

- unmatched inactive supply mints new PLP at the finalized share price
- unmatched pending withdrawal burns/redeems PLP against pool capital, subject to withdrawal capacity

This gives suppliers active PLP without minting new shares when there are natural sellers, and it lets withdrawing LPs exit without pulling capital out of the pool when there are natural buyers. Risk is transferred only because the supplier voluntarily receives the withdrawing LP's existing PLP at the finalized share price.

The internalizer can be implemented with protocol-accounted balances rather than separate user-owned deposit or withdrawal objects:

- inactive supply records quote owed into the matching batch
- pending withdrawal records PLP escrowed into the matching batch
- matched suppliers receive PLP through internal settled balances
- matched withdrawers receive quote through internal settled balances

Rounding should bias toward leaving dust in protocol-accounted pending state rather than over-minting PLP or overpaying quote.

### External PLP Liquidity

PLP does not need a protocol-owned order book. Because PLP is fungible and transferable, limit-style supply and withdrawal can be handled by external PLP markets.

Conceptually:

- users who want to supply can bid for existing PLP on an external venue
- users who want to withdraw can ask for quote by selling PLP externally
- searchers can fill those orders when the price is attractive relative to NAV
- external markets can support limit-supply and limit-withdraw UX without adding order-book logic to the pool vault

The protocol's responsibility is to expose fresh NAV/share-price data and preserve normal mint, redeem, and internalization flows. External PLP market prices must not define protocol NAV or the share price used for protocol mint/burn. The pool should expose the latest share price and timestamp through public views and emit a share-price-updated event whenever the hot-potato calculation finalizes, so external markets and searchers have a canonical reference.

### Withdrawal Capacity

Immediate and queued withdrawals both must respect max-loss solvency. Even if NAV supports a withdrawal by MTM value, the pool cannot release capital needed for worst-case payout.

A conservative capacity formula is:

```text
withdraw_capacity =
    pool_idle_capital
  + unmatched_inactive_supply_quote
  + sum(expiry.allocated_capital - expiry.total_max_payout)
  - target_buffer
```

The exact formula may need to account for queue ordering, fees, reserved settlement payouts, quote-asset balance availability, and whether unmatched inactive supply is immediately deployable in the same epoch. Internalized matched quote should not count toward withdrawal capacity because it pays withdrawing LPs directly and never becomes pool capital.

If a queued withdrawal batch cannot be fully paid without preserving worst-case backing, it should be filled pro-rata and the unfilled shares should remain queued and exposed for the next epoch. FIFO withdrawal priority should be avoided unless there is a strong reason to accept queue-position games.

## Global Valuation Snapshot

The pool vault can compute global share value through a hot-potato snapshot flow instead of maintaining continuously fresh MTM.

### Snapshot Flow

1. A keeper or user flow calls `PoolVault::start_snapshot`.
2. The pool vault creates a linear `SnapshotPotato` containing the active expiry set and snapshot epoch ID.
3. The transaction calls a read/snapshot function on each active expiry vault.
4. Each expiry vault computes MTM for that call and returns an unforgeable `ExpiryValuation` receipt.
5. The transaction passes each receipt into `PoolVault::add_expiry_valuation`.
6. The pool vault accumulates allocated capital, MTM, max payout, and marks that expiry as read.
7. `PoolVault::finalize_snapshot` consumes the potato only if every active expiry was included exactly once.
8. Finalization writes the global share price and timestamp.
9. The same transaction can immediately execute one LP supply or withdrawal, or a keeper can use the finalized price to flush queued LP requests.

The valuation receipt should carry the valuation numbers itself. The API should not accept a separate witness plus caller-provided MTM, because that would let a caller pair a real receipt with fake valuation data.

Example linear receipt fields:

```move
public struct ExpiryValuation {
    snapshot_id: ID,
    expiry_vault_id: ID,
    allocated_capital: u64,
    mtm: u64,
    max_payout: u64,
}
```

The exact fields need to be designed for Move linearity. The important property is that only the expiry vault module can create a valid valuation receipt for that expiry and snapshot, and the receipt must be consumed by the pool snapshot flow.

The receipt is the MTM output. The expiry vault should not persist the MTM value after creating the receipt.

### Valuation Inputs

The snapshot valuation endpoint should compute MTM from the current pricing inputs passed into the snapshot transaction. In practice, that means reading the active expiry vault, its market oracle, and the same live pricing/oracle sources used by the trade quote path. The expiry vault should not maintain a separate cached oracle curve or cached valuation state just for snapshots.

### Share Price

At finalization:

```text
gross_assets = pool_idle_capital + sum(expiry.allocated_capital)
mtm_liability = sum(expiry.mtm)
nav = gross_assets - mtm_liability
share_price = nav / total_plp_supply
```

Deposits and withdrawals that use the same finalized valuation epoch use the same share price.

## Snapshot Consistency

The hot-potato model avoids a dedicated maintenance window because a full share-price calculation is a single PTB. The transaction reads every active expiry vault, consumes one valuation receipt for each expiry, and finalizes only when the full active set has been included exactly once.

This design assumes the keeper or user can pay enough gas to value the active expiry set, including 100+ expiries if necessary. The base protocol should keep one full-snapshot path and avoid additional consistency machinery unless a concrete execution limit proves it necessary.

Share-price calculation must fail if any active expiry is expired but unsettled. Expired markets need to settle first, then the snapshot can include their settled liability. This avoids introducing a second conservative valuation rule for pending-settlement expiries.

## Invariants

- PLP is fungible: one share equals the same pro-rata claim as every other share.
- Deposits and withdrawals are priced only against a fresh finalized valuation.
- Mint and redeem paths do not mutate global pool valuation state.
- Mint and redeem paths do not compute or store expiry MTM.
- Expiry trading is solvency-gated by exact max payout, not live MTM.
- No expiry allocation decrease can violate `allocated_capital >= total_max_payout`.
- Withdrawals cannot release capital required to preserve max-loss backing.
- Internalized LP flow transfers existing PLP and quote between participants; it does not change pool NAV, total PLP supply, or expiry allocations.
- External PLP markets must not define NAV/share price for protocol mint/burn.
- If queues are used, unfilled withdrawal shares remain exposed until a future epoch fills them.
- A snapshot can finalize only if every active expiry is valued exactly once.
- Share-price calculation fails if any active expiry is expired but unsettled.
- Protocol and insurance fee reserves are excluded from PLP NAV.

## Open Questions

- How should protocol-accounted pending withdrawals represent partial fills?
- What target buffer should sit above exact max-payout backing?
- How should quote-asset heterogeneity be handled if multiple quote assets remain enabled?

## Recommended First Spec Boundary

The first implementation design should focus on:

1. Splitting the current vault into parent pool state and per-expiry vault state.
2. Making mint/redeem mutate only the relevant expiry vault.
3. Preserving exact per-expiry max-payout solvency.
4. Adding a fresh-cache share calculation path for LP supply/withdraw.
5. Adding a single-PTB hot-potato valuation snapshot that finalizes share price.
6. Treating LP queues as an optional fallback if inline valuation is too expensive.
7. Adding simple Mode C internalization before pool mint/burn if fallback queues are used.
8. Benchmarking full-expiry MTM cost to decide whether LP supply/withdraw should refresh share price inline by default.

Protocol-owned PLP markets, external exit liquidity, and more complex capital rebalancing should be deferred until the simple sharded model is proven.
