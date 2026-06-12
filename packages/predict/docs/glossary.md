# Glossary

Technical definitions for the terms the Predict docs and code use, with the
established options / structured-product term each one maps to and the code
identifier it corresponds to. Mint-economics identifiers (`entry_value`,
`net_premium`, `financed_amount`) match these terms directly; the floor family
keeps its payoff-oriented code names (`floor_shares`, `floor_index`), bridged
here.

## The product

- **Binary option (digital option)** — a contract that pays a fixed cash amount
  if a condition on the underlying holds, and zero otherwise. The two names are
  exact synonyms. Every Predict contract is a **European cash-or-nothing
  binary**: cash-settled in DUSDC and evaluated only at the terminal settlement
  price — there is no path dependency in the payoff.
- **Range digital** — a binary option on the event
  `settlement ∈ (lower, higher]`. Equivalent to a **digital call spread**: long
  a digital call struck at `lower`, short a digital call struck at `higher`.
  Predict's open-ended ranges (the ±∞ boundary sentinels) are plain **digital
  calls** (`(K, +∞]`) and **digital puts** (`(−∞, K]`). Path-dependent names
  ("one-touch", "double-no-touch", "corridor") do not apply.
- **Notional** — the fixed payout of the digital; code `quantity` (lot-sized,
  DUSDC base units). A winning 1x contract pays exactly its notional.
- **Position** — one held contract. The code type is `Order` and the handle is
  the packed `order_id`; there is no resting order book — every trade executes
  against the pool at the model price.
- **Writer** — the seller of an option, who owes its payout. The pool
  (`PoolVault` plus each expiry's `ExpiryCash`) is the writer of record for
  every Predict contract and fully collateralizes its written payouts (code:
  `payout_liability`, `live_backing_payout`).
- **Expiry market** — all contracts sharing one `(feed, expiry)` pair; code
  `ExpiryMarket`. Its strike grid is the expiry's option chain.

## Pricing

- **Premium** — the price of an option. For an undiscounted digital, the
  premium per unit notional **equals the risk-neutral probability** of the
  payout event; Predict quotes and stores that probability directly in 1e9
  fixed point (code `entry_probability`, `range_probability`).
- **Full premium** — the contract's complete entry value,
  `entry_probability × quantity`; code `entry_value`.
- **Net premium** — what a leveraged buyer pays upfront,
  `full premium / leverage`; code `net_premium`. The unpaid remainder is
  financed (see below). Fees are charged on top and are never part of the
  contract's terms.
- **Mark value (live value)** — the contract's current model value,
  `quantity × range_probability − floor`, clamped at zero. "Live value" in
  these docs always means this mark-to-model value, not a traded price. The
  pre-floor product `quantity × range_probability` is the **gross value**
  (code `gross_value`) — the collateral value securing the financing.

## Leverage and financing

A leveraged Predict contract is a vanilla range digital plus two
modifications: embedded premium financing and a sold knock-out. Economically
it is a **down-and-out digital structured like a turbo warrant / knock-out
certificate**. See [leverage and the floor](./concepts/leverage-and-floor.md).

- **Financed amount** — the slice of the full premium the pool funds at mint,
  `full premium − net premium`; code `financed_amount`. The structured-product
  analogue is a turbo warrant's financing level at issuance.
- **Floor (financing balance)** — the financed amount accreted to time `t`; the
  value the contract must cover before the holder owns anything above it. It
  enters the payoff itself (`payout = quantity − terminal floor` for a winner),
  so it is part of the contract, not a separable debt position. Code
  `floor_amount`.
- **Financing index (floor index)** — the deterministic accrual schedule the
  financing balance grows along (quadratic ramp to a terminal value) — the
  same role a borrow index plays in a money market. Code `floor_index`,
  `terminal_floor_index`.
- **Financing shares (floor shares)** — the financing balance normalized by the
  index at open, so every contract in an expiry accrues along one curve:
  `floor_shares = financed_amount / floor_index(opened_at)` and
  `balance(t) = floor_shares × floor_index(t)`. The same convention as a
  scaled (share-denominated) debt balance in lending protocols. Code
  `floor_shares`.
- **Limited recourse** — the financing is secured by its own contract only: the
  floor can consume that one order's value or payout, capped at it, and never
  creates a claim on the holder's other assets.
- **Leverage** — premium leverage: full premium over net premium, in discrete
  tiers 1x–3x. This is financing leverage on the premium, on top of the high
  gearing a digital already has relative to the underlying. (The symbol λ is
  reserved in these docs for `backing_buffer_lambda`.)

## Knock-out (liquidation)

- **Knock-out** — the extinguishing of a leveraged contract once its gross
  value reaches the knock-out level. Code and event vocabulary: liquidation,
  `OrderLiquidated`. Predict's knock-out pays **zero rebate**: the holder
  receives nothing, and a tombstone remains until cleared.
- **Knock-out level** — `floor_amount / liquidation_ltv`, the gross value at
  which the contract is extinguished. It sits above the financing balance by
  the LTV buffer; that gap is the pool's recovery margin against gap risk.
- **Knock-out probability** — the same barrier in probability space:
  `p*(t) = floor_amount(t) / (liquidation_ltv × quantity)`. The contract knocks
  out when its range probability falls to `p*(t)`. Because the financing
  balance accretes, `p*` rises with time — a position can knock out with no
  price move at all.
- **Liquidation LTV** — the loan-to-value bound that `floor / gross value` may
  reach before knock-out; code `liquidation_ltv`, snapshotted per expiry. A
  smaller value knocks out earlier.
- **Discretely monitored barrier** — the knock-out is enforced by bounded,
  permissionless keeper passes, not continuous monitoring; between checks a
  breached contract can remain in the book. See
  [liquidation](./concepts/liquidation.md) and [risks](./risks.md).

## Fees

- **Trading fee** — the variance-based per-trade fee,
  `max(base_fee × sqrt(p(1−p)), min_fee)` times an expiry ramp multiplier; a
  transaction cost, never part of the contract's terms. See
  [fees and rebates](./concepts/fees-and-rebates.md).
- **Congestion surcharge** — a flat per-unit penalty added when the gas-price
  EWMA flags abnormal congestion. Code keeps DeepBook core's penalty
  vocabulary: the charged amount is `penalty_fee` (event field), the tunable
  per-unit rate is `penalty_rate`.
- **Trading-loss rebate** — a configured fraction of paid trading fees returned
  to a net-losing trader once all their positions in an expiry are closed; code
  `trading_loss_rebate_rate`, backed by the expiry's `rebate_reserve`.

## Trade lifecycle verbs

| Code verb | Options term | Meaning |
| --- | --- | --- |
| `mint` | write / open | The pool writes a new contract to the buyer at the quoted premium. |
| `redeem` (live) | sell to close / close-out | The holder sells the contract back to the writer at the current mark, net of the floor on the closed slice. |
| `redeem_settled` | cash settlement | An expired in-range contract settles for `notional − terminal floor`; an out-of-range contract settles at zero. |
| `liquidate` | knock-out | An under-threshold leveraged contract is extinguished with zero rebate. |
