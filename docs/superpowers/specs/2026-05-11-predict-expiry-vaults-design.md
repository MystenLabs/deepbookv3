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
- registry or index of active expiry vault IDs
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

LP supply and withdrawal require a fresh global PLP valuation. The protocol does not need to compute that value unless an LP flow needs it. A keeper cron can still compute share value periodically, but that periodic job is a cache warmer for LP UX, not an accounting requirement for expiry-local trading.

There are three viable entry/exit modes. The right default depends on how cheap it is to compute full MTM across all active expiries.

### Mode A: Fresh-Cache Immediate Flow

The pool vault stores the latest finalized share calculation and a timestamp. Supply and withdrawal can execute immediately if that calculation is fresh enough.

Example freshness policy:

```text
clock.now_ms - pool.last_share_calculation_ms <= share_price_freshness_ms
```

If the cached calculation is fresh:

- supply mints PLP immediately at the cached share price
- withdrawal burns PLP immediately at the cached share price, subject to max-loss withdrawal capacity
- no full-expiry MTM calculation is needed in that transaction

This gives immediate UX most of the time if a keeper updates the share calculation frequently enough.

### Mode B: On-Demand Immediate Flow

If the cached share calculation is stale, the user can include the full hot-potato valuation in the same PTB as supply or withdrawal.

The transaction shape is:

1. start a valuation snapshot
2. collect valuation receipts from all active expiries
3. finalize the pool share calculation
4. execute the supply or withdrawal against the fresh share price

If full MTM is cheap enough, this can be the only LP path. There would be no deposit or withdrawal queue; every LP action computes or refreshes the share price as part of the flow.

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

The PLP created from inactive supply can be delivered in one of two ways:

- mint and transfer PLP directly to the user's address when the keeper pushes the supply
- keep the minted PLP in protocol-internal settled balances, similar to DeepBook core's `settled_balances`, and let the user claim it later

The internal-balance approach avoids creating separate user-owned deposit objects and keeps the fallback closer to DeepBook's existing inactive-stake and settlement patterns. The direct-transfer approach gives simpler UX if the keeper transaction can safely transfer to each supplier.

Withdrawal payouts should use the same protocol-accounted pattern:

- pay quote directly to the user's address when the keeper pushes the withdrawal
- or record the quote payout in protocol-internal settled balances for later claim

In both cases, the user does not hold a separate withdrawal token or object. Their pending withdrawal is protocol-accounted state until it is pushed.

The protocol-accounted pending state is therefore not fundamental to PLP fungibility. It is a fallback for cases where full valuation is too expensive to run inline with every LP flow.

### Mode C Internalizer

Before minting new PLP for inactive supply or redeeming PLP against pool capital, the pool can internalize opposing LP flows.

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

This is the most conservative way to improve Mode C. It gives suppliers active PLP without minting new shares when there are natural sellers, and it lets withdrawing LPs exit without pulling capital out of the pool when there are natural buyers. Risk is transferred only because the supplier voluntarily receives the withdrawing LP's existing PLP at the finalized share price.

The internalizer can be implemented with protocol-accounted balances rather than separate user-owned deposit or withdrawal objects:

- inactive supply records quote owed into the matching batch
- pending withdrawal records PLP escrowed into the matching batch
- matched suppliers receive PLP directly or through internal settled balances
- matched withdrawers receive quote directly or through internal settled balances

Rounding should bias toward leaving dust in protocol-accounted pending state rather than over-minting PLP or overpaying quote.

### Mode D: Embedded PLP CLOB

A more expressive version is to embed a PLP/quote order book into the pool's LP layer.

Conceptually:

- users supplying place limit bids for PLP with quote
- users withdrawing place limit asks for quote with PLP
- the book matches PLP directly between suppliers, withdrawers, and external searchers
- searchers can buy PLP from impatient withdrawers or sell PLP to suppliers
- users can express `limit_supply` and `limit_withdraw` instead of only market-style supply/withdraw

The CLOB is a secondary PLP market, not the PLP accounting oracle. The pool's NAV/share-price calculation still comes from the hot-potato MTM snapshot. CLOB trades can clear at user-specified prices, but protocol mint/burn should still use fresh NAV.

A useful interaction model is:

- `limit_supply(max_price, quote_amount, fallback_to_mint)` places a PLP bid.
- `limit_withdraw(min_price, plp_amount, fallback_to_pool_redeem)` places a PLP ask.
- Matching transfers quote and PLP between escrowed protocol-accounted balances.
- If `fallback_to_mint` is enabled and fresh NAV is at or below the user's max price, unmatched quote can mint new PLP from the pool.
- If `fallback_to_pool_redeem` is enabled and fresh NAV is at or above the user's min price, unmatched PLP can redeem from the pool, subject to withdrawal capacity.

Embedding the book directly inside the pool vault would make PLP order placement and matching contend on the pool object. That may be acceptable because it does not affect expiry trading parallelism, but a separate pool-owned `PLPBook` object may be cleaner if PLP market activity becomes high. The book should not sit inside any expiry object.

Mode D has materially more design surface than Mode C:

- order priority and cancellation
- lot sizes, ticks, and rounding
- direct transfer versus internal settled balances
- partial fills across many accounts
- stale NAV handling for fallback mint/redeem
- whether searchers need a separate account object
- whether multiple quote assets imply one PLP book per quote asset

The recommended path is to design Mode C internalization first and treat the embedded CLOB as a follow-on extension.

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
    exposure_version: u64,
}
```

The exact fields need to be designed for Move linearity. The important property is that only the expiry vault module can create a valid valuation receipt for that expiry and snapshot, and the receipt must be consumed by the pool snapshot flow.

The receipt is the MTM output. The expiry vault should not persist the MTM value after creating the receipt.

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
- Deposits and withdrawals are priced only against a fresh finalized valuation.
- Mint and redeem paths do not mutate global pool valuation state.
- Mint and redeem paths do not compute or store expiry MTM.
- Expiry trading is solvency-gated by exact max payout, not live MTM.
- No expiry allocation decrease can violate `allocated_capital >= total_max_payout`.
- Withdrawals cannot release capital required to preserve max-loss backing.
- Internalized LP flow transfers existing PLP and quote between participants; it does not change pool NAV, total PLP supply, or expiry allocations.
- The PLP CLOB, if added, is a secondary market and must not define NAV/share price for protocol mint/burn.
- If queues are used, unfilled withdrawal shares remain exposed until a future epoch fills them.
- A snapshot can finalize only if every active expiry is valued exactly once.

## Open Questions

- What is the expected upper bound on simultaneously active expiries?
- Is full-expiry MTM cheap enough to run inline with every LP supply or withdrawal?
- What freshness threshold should let users rely on cached share calculation?
- Should stale-price LP flows require an inline hot-potato calculation, fall back to queueing, or let users choose?
- If inactive supply is used, should activated PLP transfer directly to users or settle into protocol-internal balances?
- If pending withdrawals are used, should quote payouts transfer directly to users or settle into protocol-internal balances?
- Should Mode C internalization always run before pool mint/burn, or should users be able to opt out?
- Should Mode D be embedded in the pool vault or split into a separate pool-owned `PLPBook` object?
- What limit-order semantics are needed for `limit_supply` and `limit_withdraw`?
- Should external searchers interact through the same internal-balance account model as LP users?
- Should active expiry IDs live in the pool vault, registry, or a dedicated active-expiry index object?
- Should the valuation snapshot use current oracle data directly, or use per-expiry cached oracle state?
- How should protocol-accounted pending withdrawals represent partial fills?
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
4. Adding a fresh-cache share calculation path for LP supply/withdraw.
5. Adding a single-PTB hot-potato valuation snapshot that finalizes share price.
6. Treating LP queues as an optional fallback if inline valuation is too expensive.
7. Adding simple Mode C internalization before pool mint/burn if fallback queues are used.

Multi-transaction snapshots, the embedded PLP CLOB, external exit liquidity, and more complex capital rebalancing should be deferred until the simple sharded model is proven.
