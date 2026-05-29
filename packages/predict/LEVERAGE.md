# Predict Leverage Model

Predict leverage is modeled as a transformation of the contract being traded, not
as a plain prediction contract plus a separate debt ledger.

A 1x Predict order pays like a range contract:

```text
live_value = quantity * probability(range)
settled_value = quantity if settlement is inside the range, otherwise 0
```

A leveraged Predict order adds a deterministic floor to that same contract:

```text
live_value = quantity * max(probability(range) - floor_probability, 0)
```

![Contract value versus probability](docs/assets/leverage-contract-value.svg)

The floor is the probability threshold where the contract becomes worthless to
the holder. If the current probability is at or below the floor, the contract is
economically liquidated: there is no remaining user value to redeem. For 1x
orders, the floor is always zero, so the contract behaves like the original
range payout.

## Why This Represents Leverage

Leverage lets a user take larger exposure for less upfront contribution. Instead
of tracking that missing contribution as external debt, Predict embeds it into
the contract as a floor.

At mint time:

```text
entry_exposure_value = quantity * entry_probability
user_contribution    = entry_exposure_value / leverage_multiplier

floor_seed_probability = entry_probability * (1 - 1 / leverage_multiplier)
floor_seed_amount      = quantity * floor_seed_probability
```

![Floor seed and user contribution as wedges of the contract](docs/assets/leverage-wedge.svg)

The user owns the upside above the floor. The floor consumes the first part of
the contract's value, which is equivalent to the implied financing cost of the
leveraged exposure. This keeps debt limited-recourse to the order: the floor can
only consume that order's value or payout.

The contract is easiest to reason about in probability terms. The implementation
uses amount terms because cash movement, NAV, payout backing, and settlement are
all amount-denominated. `floor_seed_amount` is only the quantity-scaled form of
`floor_seed_probability`.

Trading fees and builder fees are transaction costs. They are not part of the
contract floor and do not affect the terminal floor-coverage invariant.

## Floor Index

Each expiry snapshots a maximum floor-index premium from `LeverageConfig`. The
floor index starts at `1.0` and rises deterministically as expiry approaches.
The current implementation uses a squared phase over the leverage floor window:

```text
phase        = elapsed_floor_window_time / floor_window
floor_index  = 1.0 + max_expiry_floor_premium * phase^2
```

The current floor window is one year. If an expiry is more than one year away,
the floor index stays at `1.0` until the expiry enters its final one-year
window. Inside that window, the index rises deterministically toward its
terminal value.

![Floor probability over time](docs/assets/leverage-floor-over-time.svg)

Orders store their opening timestamp. That timestamp anchors the initial floor
index used to normalize the order's floor into shares:

```text
floor_shares = floor_seed_amount / floor_index(opened_at)
floor_at_t   = floor_shares * floor_index(t)
```

All floor-bearing orders in an expiry use the same deterministic floor-index
curve. Different orders have different `floor_shares` because they may have
different quantities, entry probabilities, leverage choices, and open times.

This is the same economic role as a borrow index: the financing cost grows
deterministically over time. The code uses floor-index language because the value
is part of the contract's payoff function, not a separate borrow position.

## Order Terms

`Order` is the typed view over the packed `order_id`. It owns immutable contract
terms:

- opened timestamp
- lower and upper strike indices
- fixed-point leverage multiplier
- entry probability
- quantity
- expiry-local sequence

`Order` also derives values that depend only on those immutable terms:

- user contribution
- floor seed amount
- whether the order is leveraged

`StrikeExposure` interprets an `Order` against one expiry's strike grid and
floor-index schedule. It derives:

- decoded strike bounds
- floor shares
- current floor amount
- terminal floor amount
- terminal payout
- max-live backing payout

This split keeps packed order identity at protocol boundaries while internal
flows operate on validated `Order` values.

## Mint

Minting creates the contract terms and inserts the order into the expiry's live
indexes.

Mint admission checks three leverage-specific facts:

```text
entry_probability < 10c  => leverage must be 1x
entry_probability < 20c  => leverage must be <= 2x
entry_probability >= 20c => leverage may be up to the protocol max

gross_entry_value > ceil(current_floor_amount * 1e9 / liquidation_ltv)

terminal_floor < floor(quantity * liquidation_ltv / 1e9)
```

The entry-value check prevents minting an order that would be liquidated
immediately under the expiry's snapshotted LTV policy. The terminal check
guarantees that a winning leveraged contract can never owe a negative settlement
payout and still leaves the configured liquidation buffer at expiry. Trading and
builder fees are transaction costs, not floor value, and do not affect these
checks.

After mint, the expiry tracks two indexed views of the same contract:

- NAV terms for live valuation
- payout terms for live backing and settled liability

## Live Redeem

Live redeem values the closed quantity at the current range probability and the
current floor:

```text
gross_redeem_value = close_quantity * current_probability(range)
closed_floor       = floor_amount_for_closed_quantity(now)
user_payout        = max(gross_redeem_value - closed_floor, 0)
```

The floor is limited to the closed order quantity. If the contract is below its
floor, the user payout is zero, and the order is effectively worthless.

Partial close is handled as cancel-and-replace:

1. Remove the closed quantity from the live indexes.
2. Pay the closed quantity using the current floor.
3. Insert a replacement order for the remaining quantity.

The replacement order preserves the original contract terms that define the
remaining exposure. Fees apply only to the closed quantity. The remaining
quantity is re-indexed as a replacement order without charging a new mint fee or
redeem fee.

## Settlement

At settlement, the range probability collapses to either `0` or `1`:

```text
losing_order_payout = 0
winning_order_payout = quantity - terminal_floor
```

The terminal floor is deterministic from the order's floor shares and the
expiry's terminal floor index. Because the settlement outcome is binary, the
expiry can materialize final payout liability from its payout index and then
redeem settled orders from the cached settled liability.

## Indexes

Predict stores only the atomic values each index needs.

### NAV Matrix

The NAV matrix tracks:

```text
quantity
floor_shares
```

Live NAV is:

```text
aggregate_probability_value - aggregate_floor_value
```

The aggregate NAV path assumes every active floor-bearing order is individually
above its current floor. The liquidation/health flow must enforce this before
valuation uses aggregate floor subtraction.

Aggregate NAV floor conversion rounds down by convention so one-unit fixed-point
dust cannot make valuation abort. Per-order redeem and settlement floors remain
exact for contract accounting.

### Payout Tree

The payout tree tracks:

```text
terminal_payout
max_live_backing_payout
```

`terminal_payout` gives exact settled liability at one terminal settlement
price.

`max_live_backing_payout` gives a conservative live backing requirement without
scanning the tree at runtime. It intentionally does not reuse the terminal floor:
before expiry, the live floor can be lower than the terminal floor, so terminal
payout can understate live backing.

## Liquidation

The economic liquidation condition includes the expiry's snapshotted LTV buffer:

```text
gross_value     = quantity * probability(range)
threshold_value = ceil(floor_amount * 1e9 / liquidation_ltv)

liquidate when gross_value <= threshold_value
```

At that point, the order is below the protocol health threshold. A liquidation
flow removes it from active indexes without paying the holder.

Liquidation is bounded and policy-driven. Trade and valuation flows run a
configured candidate scan before relying on aggregate NAV floor subtraction, and
off-chain simulations are used to tune the priority policy and budget. Because
the scan is bounded, aggregate live NAV should still be read as conditional on
the health policy keeping active leveraged orders above their floor/LTV
thresholds.

## Design Rules

- Model leverage as part of the contract payoff, not as an external debt overlay.
- Store atomic terms that cannot be cheaply derived; derive everything else at
  the leaf that needs it.
- Use packed `order_id` only at entry, exit, and storage boundaries. Use `Order`
  internally.
- Keep contract floors limited-recourse to the order that created them.
- Do not let terminal floor math drive live backing if it can understate
  pre-expiry liability.
- Keep settlement payout exact and live backing conservative.
