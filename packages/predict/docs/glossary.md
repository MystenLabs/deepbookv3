# Glossary

Technical definitions for the terms the Predict docs and code use, with the
established options / structured-product term each one maps to and the code
identifier it corresponds to. Mint-economics identifiers (`entry_value`,
`net_premium`) match these terms directly.

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
  `payout_liability`, `net_payout`).
- **Expiry market** — all contracts sharing one `(feed, expiry)` pair; code
  `ExpiryMarket`. Its tick grid is the expiry's option chain.

## Strikes and ticks

There is **one canonical strike representation across the whole protocol —
absolute integer ticks** — and a raw strike is always recovered the same way,
`raw_strike = tick × tick_size`. There is no second representation (no centered
grid, no boundary indices).

- **Tick** — an integer strike index. The public API, order IDs, the payout
  tree and the exposure index all carry ticks; raw
  strikes are reconstructed only at the pricing/settlement boundary. Code
  `lower_tick`, `higher_tick` (two `u30`s per order).
- **`tick_size`** — the fixed raw-price-per-tick factor snapshotted per expiry,
  so `raw_strike = tick × tick_size`. Carried on `MarketCreated`; an indexer or
  SDK reconstructs raw strikes from it. Code `tick_size`.
- **range (`lower_tick`, `higher_tick`)** — a position's strike interval
  `(lower, higher]`, carried at public entrypoints (`mint`) and in events as the
  two absolute ticks directly. There is no standalone packed range key; the only
  packed form is inside the order ID.
- **`pos_inf_tick`** — the sentinel higher tick (`2³⁰ − 1`) that denotes the
  open-ended top (`+∞`); a lower tick of `0` denotes the open-ended bottom
  (`−∞`). These two sentinels are what make a range a digital call or put
  rather than a bounded spread. Code `pos_inf_tick`.
- **`range_codec`** — the module that owns the tick→raw conversion: it maps ticks
  to raw strikes at the pricing/settlement boundary (`strikes_from_ticks`,
  applying the `0`/`pos_inf_tick` sentinels), and computes the settlement prefix
  threshold `prefix_limit_tick = ceil(settlement / tick_size)`. Code module
  `strike_exposure::range_codec`.

## Pricing

- **Premium** — the price of an option. For an undiscounted digital, the
  premium per unit notional **equals the risk-neutral probability** of the
  payout event; Predict quotes and stores that probability directly in 1e9
  fixed point (code `entry_probability`, `range_probability`).
- **Full premium** — the contract's complete entry value,
  `entry_probability × quantity`; code `entry_value`.
- **Net premium** — what the buyer pays upfront, equal to the full premium
  (`entry_probability × quantity`); code `net_premium`. The remainder is
  financed (see below). Fees are charged on top and are never part of the
  contract's terms.
- **Mark value (live value)** — the contract's current model value,
  `quantity × range_probability`. "Live value" in these docs always means this
  mark-to-model value, not a traded price.
- **Forward** — the model's forecast of the underlying at expiry, the input the
  range probability is differenced off. The admin setting
  `use_pyth_spot_for_forward` picks its source: on (the default) Predict builds
  it as `spot × basis` when the Pyth spot is fresh and falls back to the Block
  Scholes forward otherwise; off, it is always the Block Scholes forward.
  Code: built in `pricing` from Pyth spot plus the BS spot/forward/SVI feeds.
- **Basis** — the Block Scholes `forward / spot` ratio for an expiry; it carries
  the spot to the forward when live spot is applied. Code: derived in `pricing`
  from the `BlockScholesValueStore` forward and spot series.

## Oracles (propbook feeds)

Live oracle data lives in the standalone, Predict-unaware `propbook` package;
Predict reads it but does not own it.

- **`PythFeed`** — one global object per Pyth Lazer feed id holding the latest
  source-native spot payload plus a normalized `Option<OracleRead<u64>>` view;
  updated permissionlessly from a verified Lazer payload (`update`). Predict
  reads `normalized_spot()` and the read's `source_timestamp_ms`. Code module
  `propbook::pyth_feed`.
- **`BlockScholesValueStore`** — one per-underlying store of the latest BS spot
  and forward observations, keyed by signed series id. Predict reads `spot()` /
  `forward(expiry_ms)` and each read's `published_at_ms` envelope time for
  freshness and trade-event reporting — the model time stays on the stored
  observation as calibration identity. Code
  module `propbook::block_scholes_store`.
- **`BlockScholesSVIStore`** — one per-underlying store of the latest BS SVI
  parameter sets, keyed by signed series id. Predict reads `svi(expiry_ms)` and
  its `published_at_ms`, one clock for freshness, the roll-down anchor, and
  trade-event reporting. Code module `propbook::block_scholes_store`.
- **SVI** — the stochastic-volatility-inspired parameterization of the implied
  volatility smile; the curve range probabilities are
  differenced off. Predict enforces its pricing-safe SVI envelope at read time
  (`|rho| <= 1`, bounded magnitudes, bounded sigma, positive minimum total
  variance). Code `SVIParams`.
- **`fixed_math`** — the standalone, Predict-unaware fixed-point + signed-integer
  (`i64`) math package both Predict and propbook depend on (formerly
  `predict_math`). Code package/address `fixed_math`.

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

## Liquidity, NAV, and the flush

The LP layer is **asynchronous**: liquidity providers queue requests and a
privileged periodic **flush** prices them all at one frozen pool mark. See
[liquidity and NAV](./concepts/liquidity-and-nav.md).

- **PLP** — the pool's liquidity-provider share token (`Coin<PLP>`), minted on a
  filled supply and burned on a filled withdraw; its value tracks pool NAV. The
  fungible claim on `PoolVault`. Code `PLP`.
- **`current_nav`** — an `ExpiryMarket`'s **exact** live NAV: free cash minus the
  live liability (the payout tree's boundary-linear walk
  `strike_payout_tree::walk_linear`, `Σ quantity × P(range)`, with no per-order
  correction), floored at zero. There is no approximation or
  uncertainty band — it is the true per-expiry recoverable value at the
  valuation instant. Code `current_nav`.
- **Pool NAV (`pool_nav`)** — the LP-attributable pool-wide DUSDC value the flush
  prices PLP at: `idle + Σ active-market current_nav`, net of the
  pending-protocol-profit exclusion. Computed once per flush and used for both
  supply and withdraw. Code `pool_nav` (event `FlushExecuted`, field `pool_value`).
- **Supply / withdraw queue** — the two FIFO request queues on `PoolVault`
  (`supply_queue` of escrowed DUSDC, `withdraw_queue` of escrowed PLP). An LP
  enqueues with `request_supply` / `request_withdraw` (routed through its
  account, with a minimum-output limit and a cancellable index), and the flush
  fills eligible heads. Code `RequestQueue`, events `SupplyRequested` /
  `WithdrawRequested`.
- **The flush** — the transaction-local valuation-and-drain cycle that marks the
  whole pool once and fills eligible queued heads at that mark. It is a **hot potato**:
  `start_pool_valuation` opens it (engaging the valuation lock), `value_expiry`
  is called once per active market to accumulate `Σ current_nav`, and
  `finish_flush` computes `pool_nav`, then `lp_book::drain` mints/burns PLP
  and delivers fills (supplies first, then withdrawals FIFO until idle is dry,
  up to the operator-supplied per-queue `supply_budget`/`withdraw_budget`;
  non-executable queue heads are protocol-cancelled and refunded, as are live
  request-limit misses at the shipped attempt count of one — above one they carry
  until their attempts are exhausted).
  Fills are delivered to each account through the balance accumulator
  (`send_funds`); the account absorbs them lazily on its next capital op. The flush is
  **privileged** — started only by a market deployer's `MarketLifecycleCap`
  (`start_pool_valuation`). Code `PoolValuation` (the hot-potato struct), event
  `FlushExecuted`.

## Trade lifecycle verbs

| Code verb | Options term | Meaning |
| --- | --- | --- |
| `mint` | write / open | The pool writes a new contract to the buyer at the quoted premium. |
| `redeem_live` | sell to close / close-out | The holder sells the contract back to the writer at the current mark. |
| `try_settle` / `redeem_settled` | cash settlement | `try_settle` records the exact Propbook Pyth expiry spot and terminal payout liability; `redeem_settled` then pays the full `notional` in range and zero out of range without reading an oracle. |
