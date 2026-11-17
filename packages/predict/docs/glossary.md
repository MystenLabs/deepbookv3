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
- **Expiry market** — all contracts sharing one `(underlying, expiry)` pair; code
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
- **Forward** — the model's forecast of the underlying at expiry, the input the range probability is differenced off. Predict builds it as `spot × basis`: the signed Pyth Lazer spot a flow prices at (an order's committed price, or a flush mark's), times the Block Scholes basis from the same flow's signed inputs. Up to package version 5 the admin setting `use_pyth_spot_for_forward` chose between that and the Block Scholes forward for live pricing, and since version 6 no path reads it. Code: built in `pricing::pricer_at`.
- **Basis** — the Block Scholes `forward / spot` ratio for an expiry. It carries the signed Lazer spot to the forward. Code: derived in `pricing` from a `BsVol`'s forward and spot, which share one source time.

## Oracles (signed data)

Oracle data reaches Predict signed and inline: the transaction that needs a price passes values that only `deepbook_predict_math` decodes, and only from updates the providers' on-chain verifiers accepted earlier in the same transaction. See [signed oracle data](./concepts/pricing-and-oracles.md#signed-oracle-data).

- **Oracle binding** — one underlying's `OracleBinding` on `ProtocolConfig`: the Pyth Lazer feed and channel, and the Block Scholes base asset, SVI model, and SVI decimals that price, settle, and value its markets. Admin-set, read live by every flow that takes signed data, and required to create a market. Code `protocol_config::set_oracle_binding`, `oracle_binding`.
- **`BsVol`** — one expiry's Block Scholes inputs: a spot and forward stamped at one source time (`value_ms`) and an SVI tuple stamped at another (`svi_ms`), with the base asset, SVI model, and decimals it was decoded under. Only `deepbook_predict_math` builds one, from `bs_oracle`-verified updates, so holding one proves Block Scholes signed it. Commit and the flush take one. Code `block_scholes::BsVol`, built by `block_scholes::vols` and `vol_at`.
- **`BsSpot`** — a Block Scholes spot and its source time, built the same way, for the settlement fallback. Code `block_scholes::BsSpot`, built by `block_scholes::spot_at`.
- **Propbook** — the standalone source-oracle package whose `PythFeed` and Block Scholes stores earlier Predict versions read. Markets are still keyed by a Propbook underlying ID (`propbook_underlying_id`), and Predict still links the package because its version 5 signatures name Propbook types, but no Predict path reads its objects since package version 6. See [its README](../../propbook/README.md).
- **SVI** — the stochastic-volatility-inspired parameterization of the implied
  volatility smile; the curve range probabilities are
  differenced off. Predict enforces its pricing-safe SVI envelope when it builds
  a `Pricer` (`|rho| <= 1`, bounded `b` and `m`, bounded sigma, positive minimum
  total variance, which is the only constraint on `a`). Code `pricing::PricingSVI`.
- **`fixed_math`** — the standalone, Predict-unaware fixed-point + signed-integer
  (`i64`) math package both Predict and propbook depend on. It was once named
  `predict_math`, which is unrelated to today's `deepbook_predict_math`. Code
  package/address `fixed_math`.
- **`deepbook_predict_math`** — the stateless library, in `packages/predict_math`, that holds Predict's pure pricing math, the order-ID decode, `LazerPrice`, and the Block Scholes decode (`BsVol`, `BsSpot`). It moved out of Predict to keep Predict under Sui's package size limit. See [its README](../../predict_math/README.md).

## Fees

- **Trading fee** — the sum of independently floored, expiry-ramped, and rounded fees for each finite boundary; a transaction cost, never part of the contract's terms. Infinite boundaries contribute zero. See [fees and rebates](./concepts/fees-and-rebates.md).
- **Congestion surcharge** — a flat per-unit penalty the retired immediate
  trades added when the gas-price EWMA flagged abnormal congestion. Retired in
  package version 4: queued fills report `penalty_fee` 0, and the EWMA setters
  abort. Code keeps DeepBook core's penalty vocabulary:
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
  `strike_payout_tree::walk_frozen`, `Σ quantity × P(range)`, with no per-order
  correction), floored at zero. There is no approximation or
  uncertainty band — it is the true per-expiry recoverable value at the
  valuation instant, up to fixed-point dust. Code `current_nav`. Since package version 6, which builds no live `Pricer`, it aborts `EUseV2`, and the flush evaluates the same NAV from its snapshot (`snapshot_nav`).
- **Pool NAV (`pool_nav`)** — the LP-attributable pool-wide USDC value the flush prices PLP at: `idle + Σ active-market snapshot-instant NAV`, net of the pending-protocol-profit exclusion. Computed once per flush and used for both supply and withdraw. Code `pool_nav` (event `FlushExecuted`, field `pool_value`).
- **Supply / withdraw queue** — the two FIFO request queues on `PoolVault` (`supply_queue` of escrowed USDC, `withdraw_queue` of escrowed PLP). An LP enqueues with `request_supply` / `request_withdraw` (routed through its account, with a minimum-output limit and an index that can be cancelled while no flush is in flight), and the flush fills eligible heads. Code `RequestQueue`, events `SupplyRequested` / `WithdrawRequested`.
- **The flush** — the three-stage valuation-and-drain cycle that marks the whole pool at one snapshot instant and fills eligible queued heads at that mark, with trading live throughout. **Snapshot** (one atomic transaction, scoped by the `SnapshotStage` hot potato): `start_pool_valuation` engages the valuation flag and records the active set, the start time, each queue's eligibility cutoff, and the per-queue drain budgets; `snapshot_expiry_pricer_v2` builds one `Pricer` per live market from a signed Lazer price and Block Scholes inputs stamped at one instant inside the freshness window before the start, freezes it, and stamps the market. `seal_valuation_snapshot` proves completeness. **Valuation** (resumable, one market per transaction): each `value_expiry` folds one market's snapshot-instant NAV, read from the cash values and payout-tree shadows captured at the snapshot instant. **Finish**: `finish_flush` proves every market was valued exactly once, computes `pool_nav`, then `lp_book::drain` mints/burns PLP and delivers fills up to each queue's recorded cutoff (supplies first, then withdrawals FIFO until idle is dry, up to the per-queue `supply_budget`/`withdraw_budget` committed at the snapshot; non-executable queue heads are protocol-cancelled and refunded, as are live request-limit misses at the shipped attempt count of one — above one they carry until their attempts are exhausted). Fills are delivered to each account through the balance accumulator (`send_funds`); the account absorbs them lazily on its next capital op. The flush's **snapshot is privileged** — started only by a pool-valuation operator's `PoolValuationCap` (`start_pool_valuation`). Once it seals, `value_expiry` is permissionless, because the frozen mark and the per-queue budgets are both fixed at the snapshot. `finish_flush` accepts only an address on the flush-operator allowlist, because its fills move idle cash that the keeper funding queued orders relies on. `finish_flush` refuses a flush older than `max_valuation_window_ms` (for everyone, including the operator); a stalled flush is not aborted but superseded by a fresh `start_pool_valuation`, which discards it and re-snapshots (there is no abort or restart entrypoint). Code `PoolValuation` (vault-held valuation state), event `FlushExecuted`.
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
- **Order-flow primitive** — one of Predict's six calls the companion drives: `admit_mint_v2`, `admit_sell_v2`, `commit_v2`, `try_fill`, `release`, and `try_pay_settled`. Each is one complete Predict operation. The earlier `admit_mint` and `admit_sell`, which read Propbook objects, and the Lazer-only `commit` abort `EUseV2` since package version 6.
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
  `commit_v2`, settlement, the reference tick, and the flush take one. Code `lazer_price::LazerPrice`.
- **τ (tau)** — an order's price time: the last tick of the policy's Pyth Lazer
  channel at or before `t₀ + delay_ms`, never earlier than the market's last τ
  and always after its newest committed τ. t₀ is the Sui clock of the placing
  transaction. Launch runs `delay_ms` at 800 ms on the 200 ms channel, so τ
  falls 600 to 800 ms after the order. Code `tau_ms`.
- **Cohort** — every order in one market that shares one τ, and therefore one
  signed update, one set of Block Scholes inputs, one deadline, and one channel. A cohort commits whole or not at
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
- **Commit** — attaching Pyth's verified price stamped exactly τ (or, when the backup tick is switched on, the next tick of the cohort's channel) and the Block Scholes inputs at τ's slots to a waiting cohort. Permissionless. Code `queue::commit_v2`, which calls Predict's `expiry_market::commit_v2` for each order.
- **Block Scholes timing** — the companion's rule for which signed Block Scholes slots price a cohort: spot and forward at the 500 ms boundary at or before `τ − value_lag_ms`, SVI at the 1,000 ms boundary at or before `τ − svi_lag_ms`, and, once `gap_wait_ms` has passed after τ, the next slot of either. Admin-set on the `OrderDesk`. Code `delayed_execution_config::BsTiming`, `desk::set_bs_timing`.
- **Resolve** — filling or refunding committed orders at their τ price from the
  market's own cash, at most 450 records per call, a cap on events that does
  not bound the objects a call loads. Permissionless. Code
  `queue::resolve`, which calls Predict's `try_fill` for each order.
- **Settlement walk** — the companion's `settle_step`, which drains a market's
  unfinished orders and then pays its Open records after Predict's
  `try_settle_v2`, one bounded phase per call. Permissionless.
- **Refund reason** — why an order was refunded: limits (1), admission (2),
  missing node (4), deadline (5), admin (7), no cash (8), recipient denied (9),
  or committed Block Scholes inputs that do not price at the tick (10), with 3
  and 6 reserved. The order fee is kept for reasons 1 and 2 and returned otherwise.
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
| `commit_v2` / `resolve` | — | Anyone attaches the τ price and Block Scholes inputs and fills or refunds the order. |
| `try_settle_v2` / `settle_step` | cash settlement | `try_settle_v2` records the signed Pyth price at exactly expiry when passed, or a signed Block Scholes spot stamped at expiry after the 30-second Pyth-exclusive window, plus terminal payout liability. `settle_step` then refunds waiting orders and pays each Open record the full `notional` in range and zero out of range. |
| `redeem_settled` | cash settlement | The settled redeem of a position an immediate mint left in an account. It aborts `EDelayedExecutionRequired` from package version 5. |
| `mint_exact_*` / `redeem_live` | write / close-out | The retired immediate paths. They abort `EDelayedExecutionRequired` in package version 4. |
