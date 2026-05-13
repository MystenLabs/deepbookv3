# Predict Parallel Pool Implementation Plan

## Summary

Predict is moving to a parallel object model:

- `PoolVault` is the global PLP pool and capital allocator.
- `ExpiryMarket` is the hot shared object for one expiry.
- `ProtocolConfig` holds global pricing, risk, and oracle-template configuration.
- `Registry` creates and wires setup objects, Pyth sources, market oracles, and expiry markets.

There is no global `Predict` shared object in this path. Trading should touch one
`ExpiryMarket` at a time so independent expiries can execute in parallel. LP
supply and withdraw happen through `PoolVault`.

The current quote asset is strict single-quote DUSDC. This is a temporary local
stand-in for USDsui and should remain concrete rather than generic until the
real quote dependency is introduced.

The current `StrikeMatrix` and compaction model remain in place for now. We will
revisit the matrix only after the parallel architecture is functional and
benchmarked.

## Core Decisions

- One expiry maps to one `ExpiryMarket` shared object.
- Each `ExpiryMarket` owns its own allocation accounting, LP-owned DUSDC
  balance, strike matrix, fee reserve, max-payout risk state, settlement state,
  and compaction marker.
- `PoolVault` owns idle DUSDC, the PLP treasury cap, total allocated capital,
  and the active expiry index.
- No expiry stores cached MTM. Expiry valuation is a pure read over the current
  strike matrix and oracle state.
- LP supply/withdraw uses a direct full pool valuation in the same transaction
  flow. There is no keeper, no cron, no queued LP flow, and no reusable cached
  share price in V1.
- LP supply/withdraw does not add or remove capital from existing expiry
  markets. It only changes pool idle capital and PLP supply at the current full
  pool valuation.
- Capital can be moved between `PoolVault` idle balance and an existing
  `ExpiryMarket` through public resize functions.
- Expiry capital removal is capped by expiry free capacity and available
  LP-owned cash.
- The pool enforces a global allocation cap with simple capacity accounting:
  `total_allocated_capital / (pool_idle + total_allocated_capital) <= max_total_exposure_pct`.
  This reserve rule does not require full valuation.
- If the global allocation cap is reached, new expiries cannot be deployed and
  existing expiries cannot grow.
- `MarketOracle` remains independent from `ExpiryMarket`. Oracle updates should
  not require mutable access to the expiry market object.
- Full-pool valuation uses a transaction-local global lock on `ProtocolConfig`.
  The lock prevents value-affecting mutation from being interleaved with the LP
  valuation inside the same PTB.

## Module Responsibilities

### `plp.move`

Owns:

- idle DUSDC;
- PLP treasury cap;
- total allocated capital;
- active expiry market IDs;
- LP supply and withdraw;
- global allocation/utilization policy;
- capital allocation into an expiry market;
- free-capital return from an expiry market.

Does not own:

- strike matrix state;
- market oracle state;
- trade mint/redeem state;
- cached MTM or cached share price.

### `expiry_market.move`

Owns:

- market oracle ID;
- Pyth Lazer feed ID snapshotted at creation;
- expiry timestamp;
- `allocated_capital: u64`, the expiry's risk budget;
- LP-owned DUSDC cash balance, the actual assets backing LP NAV and payouts;
- strike matrix;
- expiry-local fee reserve;
- settlement/compaction marker.

Provides:

- mint/redeem entrypoints for the main trade path;
- expiry-local `max_payout`;
- expiry-local `free_capacity`;
- pure live and settled valuation reads for full-pool LP valuation;
- allocation receive/return helpers used by `PoolVault`;
- compaction flow that also performs settled cleanup.

### `protocol_config.move`

Owns:

- pricing config;
- risk config;
- protocol pause flag.
- transaction-local valuation lock flag.

It is read by trade and pool flows. It does not own oracle mappings, rate
limiters, withdrawal queues, or share-price cache state.

### `risk_config.move`

Owns pool and resize policy:

- max total exposure/allocation percentage, default 80%;
- `expiry_allocation`, the current DUSDC amount allocated from the pool to each
  newly created expiry market, default 50k;
- expiry grow utilization threshold, default 80%;
- expiry shrink utilization threshold, default 30%;
- grow factor, default 2x;
- shrink factor, default 50%.

These values are admin-changeable through admin-gated registry/config functions.
Allocation constants live in `config_constants.move` as `default_allocation =
50k`, `min_allocation = 50k`, and `max_allocation = 250k`. Runtime app logic
reads `RiskConfig`, not `config_constants`.

### `market_oracle.move`

Remains a separate shared object from `ExpiryMarket`.

Oracle writes mutate `MarketOracle`, not `ExpiryMarket`. Trading and valuation
read the paired oracle when needed. This keeps oracle responsibilities isolated
and avoids making oracle writes take the expiry market as a mutable input. The
exact scheduler behavior for read-only shared oracle inputs versus mutable
oracle writes should be verified when benchmarking, but the module boundary is
still the desired shape.

Oracle writes read `ProtocolConfig` to assert that no full-pool valuation is in
progress. This prevents Block Scholes updates or settlement writes from changing
valuation inputs after one expiry has already produced an `ExpiryValuation`
witness in the same PTB.

### `registry.move`

Owns setup wiring:

- creates `ProtocolConfig`;
- creates `PoolVault`;
- creates `PythSource`;
- creates `MarketOracleCap`;
- creates paired `MarketOracle` and `ExpiryMarket`;
- registers the new expiry market ID in `PoolVault`;
- deploys the current `RiskConfig.expiry_allocation` from pool idle capital
  during expiry creation.

## Public Flows

### Pool Creation

The PLP module registers the LP token and creates the shared `PoolVault` during
package initialization.

### Expiry Creation

`registry::create_expiry_market` creates:

- one `MarketOracle`;
- one `ExpiryMarket`;
- one active expiry registration in `PoolVault`.

Expiry creation allocates the current `RiskConfig.expiry_allocation` from
`PoolVault` idle balance into the new `ExpiryMarket`. Creation fails if the pool
lacks idle DUSDC or if the allocation would violate the global pool allocation
cap. Until LP funding is implemented, this means expiry creation is not usable
on a freshly published package without a separate pool funding path.

### Trading

Mint/redeem functions live on `ExpiryMarket`.

Trade path shape:

- caller passes `&ProtocolConfig` read-only;
- caller passes exactly one `&mut ExpiryMarket`;
- caller passes `&mut PredictManager`;
- caller passes the paired `MarketOracle` and `PythSource`;
- `ExpiryMarket` mutates only expiry-local state and manager balances.

This is the core parallelization boundary.

### LP Supply / Withdraw

LP supply/withdraw lives on `PoolVault`.

Every LP flow computes the full current pool value inline before minting or
burning PLP. The client flow is:

1. Make an off-chain read call to `PoolVault` to get the active expiry IDs.
2. Build a PTB that passes every active expiry market object.
3. In the PTB, create a valuation hot potato from `PoolVault`, which sets the
   `ProtocolConfig` valuation lock.
4. For each active expiry, call the expiry valuation function to produce an
   `ExpiryValuation` witness.
5. Add each expiry valuation into the hot potato through `PoolVault`.
6. Supply or withdraw through `PoolVault`, consuming the valuation hot potato in
   the same call.

The hot potato must prove:

- every active expiry was valued exactly once;
- no inactive expiry was included;
- every expiry valuation came from the `ExpiryMarket` module;
- the active expiry set did not change between hot potato creation and
  finalization.

`PoolVault` proves active-set consistency by copying the active expiry IDs into
the valuation hot potato at creation. Each expiry valuation must match one of
those expected IDs and cannot be inserted twice. Finalization compares the copied
expected ID set against the current active expiry set and requires every expected
expiry to have been valued.

The `ProtocolConfig` valuation lock proves same-PTB freshness. `start_valuation`
sets the lock. `ExpiryMarket::read_valuation` requires the lock to be active.
Value-affecting mutations assert the lock is not active, including trade
mutations, Pyth source updates, MarketOracle updates/settlement, protocol config
updates, expiry creation, and future resize/compaction flows.

LP supply/withdraw consumes the valuation hot potato directly. Internally it
checks the copied active set, verifies every expected expiry was valued, uses the
computed pool value, and clears the valuation lock. There is no second finalized
valuation witness and no standalone successful finalization step. Stored latest
values are not an authoritative reusable price.

The pool value includes:

- pool idle DUSDC;
- each active expiry's LP-owned cash balance;
- minus each active expiry's current option liability/value;
- excluding protocol and insurance fee reserves.

The active expiry ID vector is an invariant, not an object loader. Sui
transactions must still pass the active expiry market objects needed for full
valuation.

### Pool Value Formula

`allocated_capital` is capacity accounting, not PLP NAV.

Each expiry should track:

- `allocated_capital: u64`, the risk budget assigned by the pool;
- `lp_cash_balance: Balance<DUSDC>`, the LP-owned cash held by the expiry;
- `fee_reserve`, protocol and insurance fee balances that are excluded from LP
  NAV.

For LP valuation:

`expiry_nav = lp_cash_balance - current_option_value`

For the whole pool:

`pool_nav = pool_idle_balance + sum(expiry_nav)`

For active markets, `current_option_value` is the live value of open exposure
against the current oracle inputs. For settled markets, it is the exact settled
remaining payout liability. Expired but unsettled markets fail valuation, which
blocks LP supply/withdraw until settlement is available.

Solvency and capacity checks are separate from NAV:

- trade minting must keep `max_payout <= allocated_capital`;
- actual LP-owned expiry cash must be sufficient for payouts;
- capital removal must not violate either capacity or cash solvency.

### Dynamic Capital Allocation

An expiry starts with the current `RiskConfig.expiry_allocation`, currently
50k DUSDC by default.

Anyone can trigger a valid resize. Admin can update:

- expiry allocation used for newly created expiries;
- global max allocation percentage;
- grow utilization threshold;
- shrink utilization threshold;
- grow factor;
- shrink factor.

Public resize functions can:

- increase allocation when expiry utilization reaches the high watermark;
- decrease allocation when expiry utilization drops to the low watermark;
- never increase above `config_constants::max_allocation`;
- never remove more than expiry free capacity or available LP-owned cash;
- never violate the global pool allocation cap.

V1 uses clamped vector-like resize behavior:

- grow target starts as `allocated_capital * grow_factor`;
- grow target is clamped to the max allocation constant and the maximum allocation
  allowed by the pool's global allocation cap;
- shrink target starts as `allocated_capital * shrink_factor`;
- shrink target is clamped up to at least the current
  `RiskConfig.expiry_allocation` and `max_payout`;
- shrink return amount is clamped by available LP-owned cash;
- if the clamped target equals the current allocation, the resize aborts with a
  named no-op error.

Definitions:

- expiry utilization = `max_payout / allocated_capital`;
- expiry free capacity = `allocated_capital - max_payout`;
- global allocation utilization = total allocated expiry capital divided by
  `pool_idle + total_allocated_capital`.

### Settlement Cleanup And Compaction

Keep the existing compaction model for now. It remains a semantic flow, not just
optional storage maintenance.

When compaction is wired into `ExpiryMarket`, it should also perform settled
cleanup:

- compute or preserve remaining settled liability;
- return free allocated capital to `PoolVault`;
- sweep expiry-local protocol/insurance fees to the pool-level accounting path;
- leave the compacted expiry with the capital needed for settled redemptions;
- keep the compacted redeem path supported.

Valuation behavior by state:

- active: use live option value;
- expired but unsettled: abort valuation;
- settled and uncompacted: use exact settled liability from the strike matrix;
- compacted: use the compacted remaining liability.

## Current Implementation Status

Completed:

- legacy `predict.move` removed;
- legacy `vault.move` removed;
- `oracle_config.move` removed;
- `rate_limiter.move` removed;
- old tracked simulation harness removed;
- `PLP` moved out of the old `sources/vault` folder;
- `PoolVault` skeleton created;
- `ExpiryMarket` skeleton created;
- `ProtocolConfig` created;
- `RiskConfig.expiry_allocation` added with 50k default/min and 250k max bounds;
- `Registry` creates protocol config, pool vault, Pyth sources, and paired
  expiry markets;
- expiry creation allocates current `RiskConfig.expiry_allocation` from
  `PoolVault` idle DUSDC into the new `ExpiryMarket`;
- `PoolVault` tracks total allocated capital and enforces the global allocation
  cap during expiry creation;
- valuation hot potato skeleton added with transaction-local expiry valuations,
  copied active expiry IDs, and direct pool-value consumption by LP flows;
- `ProtocolConfig` valuation lock added to prevent same-PTB value mutations
  during full-pool valuation;
- dynamic capital resize skeleton added with permissionless grow/shrink entry
  points on `PoolVault` and package-only cash movement helpers on
  `ExpiryMarket`;
- `StrikeMatrix` no longer stores cached MTM;
- `StrikeMatrix` updates `max_payout` on range changes and exposes pure live and
  settled valuation reads.

Not yet implemented:

- `ExpiryMarket::mint`;
- `ExpiryMarket::redeem`;
- settled redeem and compaction wiring in `ExpiryMarket`;
- full-pool inline valuation for LP supply/withdraw;
- PLP mint/burn math;
- settlement cleanup through compaction;
- updated benchmark/simulation path for the new architecture.

## Implementation Sequence

1. Add capital allocation skeletons.
   - `PoolVault` package function to allocate idle DUSDC into a new expiry.
   - `allocated_capital` as a u64 risk budget, separate from LP-owned cash.
   - Total allocated capital on `PoolVault`.
   - `RiskConfig.expiry_allocation` as the admin-changeable value used for new
     expiry creation.

2. Add the valuation hot-potato skeleton.
   - `PoolVault::start_valuation`.
   - `ExpiryMarket::read_valuation`.
   - `PoolVault::add_expiry_valuation`.
   - `PoolVault::consume_valuation` private helper used by LP flows.

3. Rewire mint/redeem into `ExpiryMarket`.
   - Move range insertion/removal, pricing, fees, manager settlement, and
     max-payout solvency checks into the expiry-local trade path.
   - Use expiry utilization for trade fee inputs.

4. Add direct full-pool LP valuation.
   - Compute pool value from idle capital plus all active expiry values.
   - Keep valuation transaction-local.
   - Do not let `PoolVault` stored latest value authorize LP operations.

5. Implement LP supply/withdraw.
   - Supply mints PLP against full current pool value.
   - Withdraw burns PLP against full current pool value.
   - Enforce global allocation cap and idle withdrawal buffer.

6. Wire settlement cleanup through compaction.
   - Return free allocated capital and available cash.
   - Sweep expiry-local protocol/insurance fees.
   - Keep compacted redemption behavior.

7. Rebuild simulations/benchmarks around the parallel architecture.

8. Revisit `StrikeMatrix` only after benchmarking the functional parallel path.

## Verification Plan

- Run `sui move build --path packages/predict`.
- Run `sui move test --path packages/predict --gas-limit 100000000000`.
- Add focused tests as each skeleton gains behavior:
  - allocation cannot exceed idle pool capital;
  - deallocation cannot exceed expiry free capacity or available LP-owned cash;
  - mint cannot push max payout above allocated capital;
  - resize clamps to max allocation and global allocation cap;
  - resize clamps shrink to current expiry allocation and max payout;
  - LP supply/withdraw requires a full active-expiry valuation;
  - compaction cleanup cannot strand remaining payout liability.
