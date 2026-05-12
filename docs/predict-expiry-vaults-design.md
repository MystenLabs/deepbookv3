# Predict Expiry-Local Vaults and Inline PLP Valuation

## Context

The current Predict package routes protocol activity through one shared `Predict`
object that owns one `Vault`. That vault stores quote balances, per-oracle
strike matrices, cached global MTM, cached global max payout, and the list of
exposed unsettled oracles that must be refreshed before LP supply or withdrawal.

This design creates a scaling bottleneck. Minting, redeeming, settlement
accounting, LP supply, LP withdrawal, and MTM refreshes all contend on the same
shared object even when they affect unrelated expiries.

The target design makes individual expiries independently mutable. Trading for
different expiries should touch different shared objects and execute in
parallel. PLP remains fungible: every PLP share represents the same pro-rata
claim on the full protocol risk profile, not a claim tied to when a user
deposited or which expiries existed during that user's supply lifetime.

## Goals

- Move hot trading state out of the global pool object and into one shared
  expiry vault per expiry.
- Preserve fungible PLP semantics.
- Avoid per-user expiry lineage, LP tranches, queued LP receipts, and
  user-owned withdrawal receipt objects.
- Keep LP supply and withdrawal immediate through the main pool vault.
- Compute full protocol NAV inline for every LP supply and withdrawal.
- Remove persistent MTM from expiry markets and global pool state.
- Keep mint and redeem paths free of MTM computation.
- Allow public, policy-gated increases and decreases to capital allocated to an
  existing expiry.
- Limit allocation decreases to an expiry's free capital.
- Keep enough capital in the main pool vault for withdrawals through a global
  deployment utilization cap.
- Compensate remaining LPs for supply/withdraw adverse selection with an LP
  flow spread.

## Non-Goals

- No cached share price in V1.
- No share-price freshness threshold in V1.
- No keeper or public refresh function in V1.
- No pending LP queues or internalizer in V1.
- No protocol-owned PLP CLOB in V1.
- No per-user accounting of which expiries a deposit funded.
- No multi-quote PLP accounting in V1. The first version assumes one quote
  asset for PLP NAV, supply, withdrawal, and expiry allocation.
- No public valuation helper surface outside LP supply and withdrawal.

## Architecture

### Predict

`Predict` remains the global protocol coordinator. It owns:

- `PoolVault`
- PLP treasury cap
- pricing config
- risk config
- fee config
- oracle/quote config
- withdrawal limiter
- global trading pause state

Trading functions take `&Predict` read-only and `&mut ExpiryVault<Quote>`
mutable. This keeps global config readable without making every trade contend on
the global pool object.

LP supply and withdrawal take `&mut Predict` because they mutate the main pool
vault and PLP supply. They also take the full active expiry set needed for
inline valuation. Sui Move cannot load shared objects from IDs stored in
`PoolVault`; the caller must pass the active expiry vault objects and required
oracle/pricing inputs into the transaction. The pool validates that the passed
set exactly matches the registered active expiry IDs.

### Pool Vault

`PoolVault` is the main LP vault and capital deployer. It owns:

- idle quote capital
- active expiry vault IDs
- total pool-funded capital deployed to active expiries
- global deployment utilization cap
- LP flow spread bps

`PoolVault` does not own:

- strike matrices
- expiry MTM
- global MTM
- cached share price
- share-price timestamp
- snapshot state
- pricing/oracle logic

The global deployment utilization cap preserves withdrawal liquidity by limiting
how much pool capital can be deployed into active expiries:

```text
global_deployment_utilization =
    deployed_capital / (idle_capital + deployed_capital)

deployed_capital <= max_global_deployment_utilization * (idle_capital + deployed_capital)
```

The default target is 80%. With an 80% cap, at least 20% of pool-funded capital
remains idle before considering trade premiums and other non-deployment flows.

LP supply deposits quote into the pool idle balance. LP withdrawal burns PLP and
pays quote from the pool idle balance. LP flows do not resize existing expiry
allocations. Expiry allocation changes are separate public flows.

### Expiry Vault

Each expiry has one shared `ExpiryVault<Quote>` object. It owns:

- market oracle ID
- expiry timestamp
- allocated quote balance
- allocation budget
- allocation hard cap
- one strike matrix / exposure surface
- total max payout
- settlement and compaction state
- expiry-local fee balances if fees cannot be routed globally during trading

`allocation_budget` is the amount of pool capital explicitly made available as
OI capacity for the expiry. Trade premiums and LP fee shares can increase the
expiry's quote balance, but they should not automatically increase OI capacity.
Only explicit allocation resize functions should increase `allocation_budget`.

The local expiry utilization is:

```text
expiry_utilization = total_max_payout / allocation_budget
```

The local solvency invariants are:

```text
total_max_payout <= allocation_budget
total_max_payout <= expiry_quote_balance
```

Capital can be removed from an expiry only up to:

```text
expiry_free_allocation = allocation_budget - total_max_payout
```

This lets the protocol resize active expiries without underfunding existing
worst-case liabilities.

## Trade Path

Mint and redeem operations do not compute or maintain MTM, either globally or
inside the expiry vault. Expiry markets hold no MTM fields. Their risk
responsibility is exact max-payout solvency.

On mint, the expiry path:

1. validates the range key, expiry state, and quote asset
2. computes the user-facing trade price from oracle/pricing inputs
3. inserts the range into the expiry strike matrix
4. recomputes exact `total_max_payout`
5. aborts if `total_max_payout > allocation_budget`
6. accepts the user's principal payment and routes fees

On live redeem, the expiry path:

1. validates the position
2. computes the live redeem price from oracle/pricing inputs
3. removes the range from the expiry strike matrix
4. recomputes exact `total_max_payout`
5. pays the user from the expiry's quote balance

On settled redeem, the expiry vault burns the position against terminal
settlement liability and pays the settled amount. Settlement and compaction
remain expiry-local.

Pricing utilization for trades should use expiry-local max payout over
allocation budget, not global MTM:

```text
trade_utilization = expiry.total_max_payout / expiry.allocation_budget
```

## Expiry Capital Allocation

Each expiry starts with an initial allocation, for example 50,000 quote units.
That allocation can be resized through public policy-gated functions.

### Increase Allocation

Anyone can call an increase function when an expiry is highly utilized:

```text
increase_expiry_allocation(predict, expiry, amount)
```

Required checks:

- expiry is registered in the pool
- expiry utilization is at or above the upscale threshold, for example 80%
- `expiry.allocation_budget + amount <= expiry.allocation_hard_cap`
- pool idle capital is at least `amount`
- the global deployment utilization cap still holds after moving capital

State changes:

- pool idle capital decreases by `amount`
- pool deployed capital increases by `amount`
- expiry quote balance increases by `amount`
- expiry allocation budget increases by `amount`

### Decrease Allocation

Anyone can call a decrease function when an expiry is lightly utilized:

```text
decrease_expiry_allocation(predict, expiry, amount)
```

Required checks:

- expiry is registered in the pool
- expiry utilization is at or below the downscale threshold, for example 30%
- `amount <= expiry_free_allocation`

State changes:

- expiry allocation budget decreases by `amount`
- expiry quote balance decreases by `amount`
- pool deployed capital decreases by `amount`
- pool idle capital increases by `amount`

Decreasing allocation improves the global deployment utilization ratio, so it
does not need a global cap check beyond preserving expiry solvency.

## LP Supply and Withdrawal

All LP supply and withdrawal happens through the main pool vault directly. LP
flows do not change the capital allocated to existing expiry vaults.

Every LP supply and withdrawal computes full protocol NAV inline. There is no
cached share price, no freshness threshold, no keeper, and no public valuation
refresh path.

The transaction shape is:

1. Caller passes all active expiry vaults and required oracle/pricing inputs.
2. `Predict` starts an internal valuation accumulator.
3. For each passed expiry:
   - verify the expiry ID is registered
   - verify it has not already been included
   - verify the expiry vault matches its market oracle
   - fail if the expiry is expired but unsettled
   - compute live or settled MTM as a pure read
   - accumulate allocated capital and MTM
4. Verify every active expiry ID was included exactly once.
5. Compute NAV.
6. Apply the LP flow spread.
7. Execute supply or withdrawal immediately.

The inline valuation formula is:

```text
gross_assets = pool_idle_capital + sum(expiry_quote_balance)
mtm_liability = sum(expiry_mtm)
nav = gross_assets - mtm_liability
mid_price = nav / total_plp_supply
```

Supply uses the spread-adjusted supply price:

```text
supply_price = mid_price * (1 + lp_flow_spread_rate)
supply_shares = supply_quote / supply_price
```

Withdrawal uses the spread-adjusted withdrawal price:

```text
withdraw_price = mid_price * (1 - lp_flow_spread_rate)
withdraw_quote = withdrawn_shares * withdraw_price
```

Bootstrap is the only special case. If total PLP supply is zero, the pool can
accept initial supply at a configured initial share price only while there are
no active expiries and no deployed capital. After the first PLP mint, every
supply and withdrawal uses inline full valuation and spread-adjusted prices.

Withdrawals must be paid from pool idle quote capital. If more withdrawable
capital is desired, a separate transaction can first decrease allocation on
lightly utilized expiries and move free capital back into the pool. Withdrawal
capacity should not advertise expiry free allocation as immediately withdrawable
unless the same transaction also moves that capital into idle pool balance.

Withdrawal checks:

```text
withdraw_quote <= pool_idle_capital
deployed_capital <= max_global_deployment_utilization * (pool_idle_after_withdraw + deployed_capital)
```

The second check preserves the main-vault global utilization cap after the
withdrawal. This ensures withdrawals cannot drain idle liquidity below the
protocol's configured deployment buffer.

## LP Flow Spread

Even with inline NAV, LP entry and exit transfer exposure between participants.
Suppliers buy the current protocol risk profile; withdrawers sell it. The pool
therefore applies a configurable LP flow spread around NAV:

```text
lp_flow_spread_rate = lp_flow_spread_bps / 10_000
supply_price = mid_price * (1 + lp_flow_spread_rate)
withdraw_price = mid_price * (1 - lp_flow_spread_rate)
```

The configured spread must be bounded below 10,000 bps so withdrawal price
remains positive.

Suppliers receive fewer PLP per quote than pure NAV. Withdrawers receive less
quote per PLP than pure NAV. This does not make entry or exit exposure-neutral;
it prices the exposure transfer that fungible PLP necessarily creates. The
spread accrues to the pool and compensates remaining LPs for flow toxicity,
valuation error, and timing risk.

## Inline Valuation Completeness

The inline valuation flow uses hot-potato-style completeness accounting, but it
is not exposed as a public snapshot object or keeper API.

The accumulator must enforce:

- every active expiry is included exactly once
- no unregistered expiry is included
- no expiry is valued against the wrong oracle
- expired but unsettled expiries fail valuation
- valuation receipts or internal entries cannot be caller-forged

The important constraint is the Sui object model: `PoolVault` can store active
expiry IDs, but it cannot load those shared expiry objects by ID. The caller
must pass the full active expiry object set and oracle inputs to the LP
transaction. The protocol verifies completeness against `PoolVault`'s active ID
list before minting or burning PLP.

## Settlement Cleanup

After settlement, a public cleanup path can compact an expiry and return excess
capital to the pool.

Cleanup should:

1. verify the expiry is registered
2. verify the market oracle is settled
3. compact terminal liability if not already compacted
4. move free allocation back to the pool idle balance
5. preserve only the capital required for remaining settled payouts

Final expiry destruction should be possible only after remaining payout
liability is zero and the expiry is settled/compacted. A live empty expiry
should not be permissionlessly removable, because that would let anyone remove a
valid market from the active set.

## Invariants

- PLP is fungible: one share equals the same pro-rata claim as every other
  share.
- Every LP supply and withdrawal values the complete active expiry set inline.
- No stored share price exists.
- No public valuation refresh path exists.
- Mint and redeem paths do not mutate global pool valuation state.
- Mint and redeem paths do not compute or store expiry MTM.
- Expiry markets hold no MTM fields.
- Expiry trading is solvency-gated by exact max payout, not live MTM.
- `total_max_payout <= allocation_budget` for every active expiry.
- `total_max_payout <= expiry_quote_balance` for every active expiry.
- Allocation increases cannot exceed the expiry hard cap.
- Allocation increases cannot violate the pool's global deployment utilization
  cap.
- Allocation decreases cannot violate `allocation_budget >= total_max_payout`.
- LP supply and withdrawal do not resize existing expiry allocations.
- Withdrawals are paid from pool idle capital.
- Withdrawals cannot violate the pool's global deployment utilization cap.
- Protocol and insurance fee reserves are excluded from PLP NAV.
- V1 PLP accounting uses a single quote asset; multi-quote support is deferred.

## Recommended First Spec Boundary

The first implementation should focus on:

1. Splitting the current vault into parent pool state and per-expiry vault state.
2. Making mint/redeem mutate only the relevant expiry vault.
3. Preserving exact per-expiry max-payout solvency.
4. Adding public expiry allocation increase/decrease paths.
5. Enforcing the pool-level global deployment utilization cap.
6. Adding inline full-portfolio valuation inside LP supply/withdraw.
7. Adding the configurable LP flow spread.
8. Removing cached share price, freshness thresholds, public valuation helpers,
   keeper flows, queues, and internalizers from V1.

Protocol-owned PLP markets, external exit liquidity, multi-quote PLP accounting,
and more complex capital rebalancing should be deferred until the simple
expiry-local model is proven.
