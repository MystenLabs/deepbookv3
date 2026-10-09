# Glossary

Technical definitions for the terms the Predict docs and code use, with the
established options / structured-product term each one maps to and the code
identifier it corresponds to. The mint-economics identifier `premium` matches
these terms directly.

## The product

- **Binary option (digital option)** — a contract that pays a fixed cash amount
  if a condition on the underlying holds, and zero otherwise. The two names are
  exact synonyms. Every Predict contract is a **European cash-or-nothing
  binary**: cash-settled in USDC and evaluated only at the terminal settlement
  price — there is no path dependency in the payoff.
- **Range digital** — a binary option on the event
  `settlement ∈ (lower, higher]`. Equivalent to a **digital call spread**: long
  a digital call struck at `lower`, short a digital call struck at `higher`.
  Predict's open-ended ranges (the ±∞ boundary sentinels) are plain **digital
  calls** (`(K, +∞]`) and **digital puts** (`(−∞, K]`). Path-dependent names
  ("one-touch", "double-no-touch", "corridor") do not apply.
- **Notional** — the fixed payout of the digital; code `quantity` (lot-sized,
  USDC base units). A winning 1x contract pays exactly its notional.
- **Position** — one held contract. The code type is `Order` and the handle is
  the packed `order_id`. There is no resting order book: every trade executes
  against the pool at the model price, and a queued order waits only for the
  price at its τ (see [Delayed execution](#delayed-execution)).
- **Writer** — the seller of an option, who owes its payout. The pool
  (`PoolVault` plus each expiry's `ExpiryCash`) is the writer of record for
  every Predict contract and fully collateralizes its written payouts (code:
  `payout_liability`).
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
  `(lower, higher]`, carried at public entrypoints (`enqueue_*`) and in events as the
  two absolute ticks directly. There is no standalone packed range key; the only
  packed form is inside the order ID.
- **`pos_inf_tick`** — the sentinel higher tick (`2³⁰ − 1`) that denotes the
  open-ended top (`+∞`); a lower tick of `0` denotes the open-ended bottom
  (`−∞`). These two sentinels are what make a range a digital call or put
  rather than a bounded spread. Code `pos_inf_tick`.
- **`range_codec`** — the module that owns the tick→raw conversion: it maps ticks
  to raw strikes at the pricing/settlement boundary (`strikes_from_ticks`,
  applying the `0`/`pos_inf_tick` sentinels), and computes the settlement prefix
  threshold `limit_tick = ceil(settlement / tick_size)`. Code module
  `strike_exposure::range_codec`.

## Pricing

- **Premium** — the price of an option. For an undiscounted digital, the
  premium per unit notional **equals the risk-neutral probability** of the
  payout event; Predict quotes and stores that probability directly in 1e9
  fixed point (code `entry_probability`, `range_probability`).
- **Premium** — the contract's complete entry value, `entry_probability ×
  quantity`, paid upfront in full; code `premium`, floored at
  `constants::min_premium`. Nothing is financed. Fees are charged on top and are
  never part of the contract's terms.
- **Mark value (live value)** — the contract's current model value,
  `quantity × range_probability`. "Live value" in these docs always means this
  mark-to-model value, not a traded price.
- **Forward** — the model's forecast of the underlying at expiry, the input the
  range probability is differenced off. The admin setting
  `use_pyth_spot_for_forward` picks its source: on (the default) Predict builds
  it as `spot × basis` when the Pyth spot is fresh and falls back to the Block
  Scholes forward otherwise; off, it is always the Block Scholes forward.
  Valuation and the mint quotes use that fallback, and the retired immediate
  trades refused it. A queued fill re-anchors the basis on the committed Pyth
  price for its τ instead.
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
- **`BlockScholesValueStore`** — one per-underlying store of ten recent BS spots in an inline ring, latest forwards keyed by signed series id, and separate insert-only exact minute-boundary spot history. Predict reads `forward(expiry_ms)` then `recent_spot_at(forward_source_timestamp_ms)` to select an exact source-time pair; each read retains its own landing time and writer digest. The selected source timestamp gates freshness and is reported in trade events. `spot_at(expiry_ms)` remains the settlement fallback. Code module `propbook::block_scholes_store`.
- **`BlockScholesSVIStore`** — one per-underlying store of the latest BS SVI
  parameter sets, keyed by signed series id. Predict reads `svi(expiry_ms)` and
  its `source_timestamp_ms`, one clock for freshness, the roll-down anchor, and
  trade-event reporting. Code module `propbook::block_scholes_store`.
- **SVI** — the stochastic-volatility-inspired parameterization of the implied
  volatility smile; the curve range probabilities are
  differenced off. Predict enforces its pricing-safe SVI envelope at read time
  (`|rho| <= 1`, bounded `b` and `m`, bounded sigma, positive minimum total
  variance, which is the only constraint on `a`). Code `SVIParams`.
- **`fixed_math`** — the standalone, Predict-unaware fixed-point + signed-integer
  (`i64`) math package both Predict and propbook depend on. It was once named
  `predict_math`, which is unrelated to today's `deepbook_predict_math`. Code
  package/address `fixed_math`.
- **`deepbook_predict_math`** — the stateless library, in `packages/predict_math`,
  that holds Predict's pure pricing math, the order-ID decode, and
  `LazerPrice`. It moved out of Predict to keep Predict under Sui's package
  size limit. See [its README](../../predict_math/README.md).

## Fees

- **Trading fee** — the sum of independently floored, expiry-ramped, and rounded fees for each finite boundary; a transaction cost, never part of the contract's terms. Infinite boundaries contribute zero. See [fees and rebates](./concepts/fees-and-rebates.md).
- **Congestion surcharge** — a flat per-unit penalty the retired immediate
  trades added when the gas-price EWMA flagged abnormal congestion. Retired in
  package version 4: queued fills and the mint quotes report `penalty_fee` 0,
  and the EWMA setters abort. Code keeps DeepBook core's penalty vocabulary:
  the charged amount is `penalty_fee` (event field), the per-unit rate is
  `penalty_rate`.
- **Order fee** — a flat USDC fee per queued order, not per contract, escrowed
  at placement. Kept on a fill and on a limits or admission refund, returned on
  every other refund. Code `order_fee`.

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
- **Pool NAV (`pool_nav`)** — the LP-attributable pool-wide USDC value the flush prices PLP at: `idle + Σ active-market snapshot-instant NAV`, net of the pending-protocol-profit exclusion. Computed once per flush and used for both supply and withdraw. Code `pool_nav` (event `FlushExecuted`, field `pool_value`).
- **Supply / withdraw queue** — the two FIFO request queues on `PoolVault` (`supply_queue` of escrowed USDC, `withdraw_queue` of escrowed PLP). An LP enqueues with `request_supply` / `request_withdraw` (routed through its account, with a minimum-output limit and an index that can be cancelled while no flush is in flight), and the flush fills eligible heads. Code `RequestQueue`, events `SupplyRequested` / `WithdrawRequested`.
- **The flush** — the three-stage valuation-and-drain cycle that marks the whole pool at one snapshot instant and fills eligible queued heads at that mark, with trading live throughout. **Snapshot** (one atomic transaction, scoped by the `SnapshotStage` hot potato): `start_pool_valuation` engages the valuation flag and records the active set, the start time, each queue's eligibility cutoff, and the per-queue drain budgets; `snapshot_expiry_pricer` freezes one `Pricer` per live market and stamps it; `seal_valuation_snapshot` proves completeness. **Valuation** (resumable, one market per transaction): each `value_expiry` folds one market's snapshot-instant NAV, read from the cash values and payout-tree shadows captured at the snapshot instant. **Finish**: `finish_flush` proves every market was valued exactly once, computes `pool_nav`, then `lp_book::drain` mints/burns PLP and delivers fills up to each queue's recorded cutoff (supplies first, then withdrawals FIFO until idle is dry, up to the per-queue `supply_budget`/`withdraw_budget` committed at the snapshot; non-executable queue heads are protocol-cancelled and refunded, as are live request-limit misses at the shipped attempt count of one — above one they carry until their attempts are exhausted). Fills are delivered to each account through the balance accumulator (`send_funds`); the account absorbs them lazily on its next capital op. The flush's **snapshot is privileged** — started only by a pool-valuation operator's `PoolValuationCap` (`start_pool_valuation`). Once it seals, `value_expiry` is permissionless, because the frozen mark and the per-queue budgets are both fixed at the snapshot. `finish_flush` accepts only an address on the flush-operator allowlist, because its fills move idle cash that the keeper funding queued orders relies on. `finish_flush` refuses a flush older than `max_valuation_window_ms` (for everyone, including the operator); a stalled flush is not aborted but superseded by a fresh `start_pool_valuation`, which discards it and re-snapshots (there is no abort or restart entrypoint). Code `PoolValuation` (vault-held valuation state), event `FlushExecuted`.
- **Valuation stamp / book snapshot** — the per-market capture that keeps trading live during a flush. The snapshot stage stamps each live market with its flush ordinal, copying the two cash rows NAV reads at that instant; the payout tree holds its own snapshot, each node copying its boundary quantities into a shadow before its first mutation under that flush (an emptied node is retained as a live-zero husk until `value_expiry` reads and releases the snapshot). Trades record nothing and have no budget; a stamp left by an aborted flush is stale and lazily discarded by the next trade or settle attempt. Code `ValuationStamp`, `strike_payout_tree::snap_on`/`walk_frozen`/`snap_done`.

## Delayed execution

From package version 4, mints and early sells wait in a per-market queue and
fill at Pyth's signed price for a fixed instant after placement. The queue lives
in the order-flow companion package. See
[delayed execution](./concepts/delayed-execution.md).

- **Order-flow companion** — `deepbook_predict_orders`, the package that holds
  the queues, each queued order's escrow, the policy, the order entry points,
  and the queue events. It depends on Predict, and Predict never names it. See
  [its README](../../predict_orders/README.md).
- **Order-flow primitive** — one of Predict's six calls the companion drives:
  `admit_mint`, `admit_sell`, `commit`, `try_fill`, `release`, and
  `try_pay_settled`. Each is one complete Predict operation.
- **Witness** — the companion's `OrderFlow` type. Predict serves admission,
  commit, and fills only to a witness type an admin allowlisted with
  `set_order_flow<W>`. Code `protocol_config::is_order_flow`.
- **Receipt** — Predict's `OrderReceipt` for one queued order, held in the
  order's queue record. It cannot be copied or dropped, and only Predict changes
  or unpacks it. Its stage is a mint admitted (1), an open position (2), or a
  sell admitted (3).
- **Order-flow ledger** — a market's `OrderFlowLedger`: the payout-tree ticks
  waiting mints pin and the waiting cash need. Code `order_flow_state`.
- **`OrderDesk`** — the companion's one shared object, created when it is
  published, holding the delayed-execution policy and the companion's version
  floor. Code `deepbook_predict_orders::desk`.
- **`MarketQueue`** — one market's queue in the companion, at an ID derived from
  the `QueueRegistry` and the market. Code `deepbook_predict_orders::queue`.
- **`QueueRegistry`** — the companion's shared parent of every market's queue
  ID, created with the desk at publish. Queue creation writes it, and no
  trading call reads it. Code `deepbook_predict_orders::desk::QueueRegistry`.
- **`LazerPrice`** — a Pyth Lazer price that only `deepbook_predict_math` builds,
  and only from a Pyth-verified update, so holding one proves Pyth signed it.
  `commit` takes one. Code `lazer_price::LazerPrice`.
- **τ (tau)** — an order's price time: the last tick of the policy's Pyth Lazer
  channel at or before `t₀ + delay_ms`, never earlier than the market's last τ
  and always after its newest committed τ. t₀ is the Sui clock of the placing
  transaction. Launch runs `delay_ms` at 800 ms on the 200 ms channel, so τ
  falls 600 to 800 ms after the order. Code `tau_ms`.
- **Cohort** — every order in one market that shares one τ, and therefore one
  signed update, one deadline, and one channel. A cohort commits whole or not at
  all, and each cohort fills on its own. Code `CohortSpan`.
- **Deadline** — `min(τ + stall_timeout_ms, expiry)`, never earlier than the
  market's last deadline. At or past it an order can only be refunded in full.
  Code `deadline_ms`.
- **Cutoff** — `expiry − max(no_trade_window_ms, stall_timeout_ms + 5_000)`. An
  order whose τ would land at or past it is refused. At launch, with a 10-second
  no-trade window, it is 10 seconds before expiry, so new orders stop about 11
  seconds before expiry. Code `cutoff_ms`.
- **Record ID** — the sequential `u64` ID of one queue record in a market. It is
  not a position's packed `u256` order ID. Code `record_id`.
- **Open record** — a filled order that stays in the market's queue, owned by
  the placing account and holding a live position in its open receipt. A
  queued fill never enters the account. It is sold with `enqueue_redeem_open`
  or paid by `settle_step` or `pay_open`. Code `order_queue::status_open`.
- **Commit** — attaching Pyth's verified price stamped exactly τ (or, when the
  backup tick is switched on, the next tick of the cohort's channel) to a
  waiting cohort. Permissionless. Code `queue::commit`, which calls Predict's
  `expiry_market::commit` for each order.
- **Resolve** — filling or refunding committed orders at their τ price from the
  market's own cash, at most 450 records per call, a cap on events that does
  not bound the objects a call loads. Permissionless. Code
  `queue::resolve`, which calls Predict's `try_fill` for each order.
- **Settlement walk** — the companion's `settle_step`, which drains a market's
  unfinished orders and then pays its Open records after Predict's
  `try_settle`, one bounded phase per call. Permissionless.
- **Refund reason** — why an order was refunded: limits (1), admission (2),
  missing node (4), deadline (5), admin (7), no cash (8), or recipient denied
  (9), with 3 and 6 reserved. The order fee is kept for reasons 1 and 2 and returned otherwise.
  Code `order_queue::reason_*`.
- **Spare cash** — market cash minus required cash.
- **Cash need** — the most an order's fill could take out of spare cash.
  Admission checks a mint's own need against spare cash, and the rebalance
  target covers the summed need of waiting orders. Code `cash_need`,
  `waiting_cash_need`.
- **Pin** — a payout-tree boundary node a waiting mint will use. Admission
  creates it, and no deletion path removes it while pinned, so a fill never
  creates a node. Code `OrderFlowLedger.pins`.
- **Stuck gate** — the check that refuses new orders while commits have stalled.
  Code `EQueueStuck`, `queue_stuck`.
- **Cutover** — the version-watermark bump to Predict package version 4. It
  opens admission, and stays fixed at 4 for later upgrades. Code
  `constants::cutover_version`, `ECutoverNotReached`.
- **Denied recipient** — an address Sui refuses to credit with USDC: on USDC's
  deny list for the current epoch, or any address while USDC is globally
  paused. The order flow never sends to one. Code `sui::deny_list::DenyList`.
- **Parked funds** — a refund or change a finished record could not send to
  its denied receive address, kept in the record until `claim_parked` sends
  it. Code `RecordFundsParked`, `RecordFundsClaimed`.
- **Relink** — publishing an upgrade of a package that depends on Predict, so it
  links the new Predict version. The companion and Sessions are relinked before
  every Predict watermark bump.
- **Flush operator** — an address on the admin-managed allowlist that may call
  `finish_flush`. Code `add_flush_operator`, `is_flush_operator`.

## Trade lifecycle verbs

| Code verb | Options term | Meaning |
| --- | --- | --- |
| `enqueue_exact_quantity` / `enqueue_exact_amount` / `enqueue_exact_cost` | write / open | The buyer queues an order. The pool writes the contract at the τ premium when the order fills. |
| `enqueue_redeem_open` | sell to close / close-out | The holder queues a sale of an Open record back to the writer at the τ mark. |
| `commit` / `resolve` | — | Anyone attaches the τ price and fills or refunds the order. |
| `try_settle` / `settle_step` | cash settlement | `try_settle` records exact Pyth at expiry when available, or exact Block Scholes after the 30-second Pyth-exclusive window, plus terminal payout liability. `settle_step` then refunds waiting orders and pays each Open record the full `notional` in range and zero out of range. |
| `redeem_settled` | cash settlement | Pays a position an immediate mint left in an account, without reading an oracle. |
| `mint_exact_*` / `redeem_live` | write / close-out | The retired immediate paths. They abort `EDelayedExecutionRequired` in package version 4. |
