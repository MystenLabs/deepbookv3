# Delayed execution

From package version 4, Predict fills mints and early sells after a short delay, 800 ms at launch, instead of inside the trader's own transaction. A trader places an order with its limits and its money. The order waits in its market's queue until Pyth Lazer publishes its signed price for the order's price time, τ. Anyone can then attach that price and fill the order, or refund it. This page describes the three packages that share the work, how orders queue, commit, and resolve, what a filled order becomes, how refunds work, how settlement pays and cleans up the queue, and the policy that governs all of it.

The immediate paths this replaces are described in [markets and positions](./markets-and-positions.md). The trust assumptions and failure modes are in [risks](../risks.md#delayed-execution). Decision identifiers such as DX-13 refer to the delayed-execution decision records.

## Why orders wait

An immediate trade prices at the on-chain Pyth spot of its own transaction. That spot reaches the chain a moment after the price moved on faster venues, so a trader who watches those venues can know the fill price is stale before sending the trade. A queued order is priced at Pyth's signed price for a fixed instant after it is placed. Nobody picks that instant or that price, and by τ the price already reflects what the trader could see when placing the order.

## Three packages

Delayed execution spans three packages, because Sui caps a package at 102,400 bytes and Predict, which can only grow by compatible upgrade, is close to it. Predict package version 4 measures 97,876 bytes.

| Package | Role |
| --- | --- |
| `deepbook_predict` (Predict) | Upgraded in place. Keeps the market, pricing, fills, fees, cash backing, settlement, and the LP pool. Adds the order-flow primitives the queue drives, one `OrderReceipt` per queued order, and a per-market `OrderFlowLedger` |
| [`deepbook_predict_orders`](../../../predict_orders/README.md) | Published fresh. Holds the shared `OrderDesk` with the policy, one `MarketQueue` per market, each record's escrow, every order entry point, the queue reads, and the queue events |
| [`deepbook_predict_math`](../../../predict_math/README.md) | Published fresh. A pure library: the pricing math Predict calls, the order-ID decode, and `LazerPrice`, a price built only from a Pyth-verified Lazer update |

The dependency direction is one way: `deepbook_predict_orders` depends on Predict, and Predict depends on `deepbook_predict_math`. The companion also depends on the library directly. Predict never names a companion type, so there is no cycle and Predict's own surface does not change when the companion does.

Predict makes every pricing, fill, and solvency decision itself. Each order-flow primitive is one complete Predict operation: it checks its own gates and the receipt when it runs, makes the accounting decision, and moves the cash in the same call. The companion owns what Predict leaves to it: τ and the deadline, the stuck gate, capacities and per-account caps, cohort order, the exact-or-backup tick choice, escrow custody, refund routing, and the events. See [The order-flow boundary](#the-order-flow-boundary).

## The cutover and what retired

Predict version 4 compiles `current_version!() == 4`. `ProtocolConfig.version_watermark` is also the delayed-execution cutover (DX-21).

- Predict refuses every admission (`protocol_config::ECutoverNotReached`) until the watermark reaches `current_version!()`. The bump also retires every older Predict version, so no package that knows nothing about the queue can run while an order waits.
- Predict serves the queue only for an allowlisted witness type. An admin runs `protocol_config::set_order_flow<OrderFlow>(true)` once the companion is published, where `OrderFlow` is the companion's witness. Until then every admission, commit, and fill aborts `EOrderFlowNotAllowed`.
- `mint_exact_quantity`, `mint_exact_amount`, `mint_exact_cost`, and `redeem_live` keep their signatures and abort `EDelayedExecutionRequired` at any watermark. Trading is paused before the upgrade, so no window needs them.
- The mint quotes (`quote_mint`, `quote_mint_for_account`, `quote_mint_exact_cost_for_account`) keep their signatures and are re-bodied on the queued fill's pricing at the clock. See [Reads](#reads).
- The EWMA setters `set_ewma_params` and `set_ewma_enabled` abort `EEwmaRetired`. The congestion surcharge no longer applies anywhere. Each market still seeds its EWMA state at creation, because that layout is published.
- `redeem_settled` and `redeem_settled_permissionless` are unchanged. They pay positions that immediate mints left in accounts before the cutover. A queued fill never enters an account, so they never pay one.
- `finish_flush` accepts only flush operators in package version 4, so the flush keeper's address goes on the [flush-operator allowlist](#the-flush-operator-allowlist) before the keeper moves to it.

The watermark only moves up, so the cutover cannot be undone.

## Who calls what

A trader, or a session acting for the trader, places orders through the companion's `queue` module. Everything after placement is open to anyone: the companion's `commit`, `resolve`, `refund`, `settle_step`, and `cleanup`, and Predict's `rebalance_expiry_cash` and `try_settle` (DX-5). Creating a market's queue is open to anyone too. The protocol's fill keeper normally runs all of them, but it has no special rights. Only an admin holding Predict's `AdminCap` can allowlist the companion, change the policy, refund orders by ID, bump the companion's version floor, or edit the flush-operator allowlist, and only a flush operator can finish an LP flush.

## The order-flow boundary

Predict's primitives are the only way the queue moves money or positions. Each takes the companion's witness, a receipt, or both.

| Primitive | Authority | What it does |
| --- | --- | --- |
| `admit_mint` | witness | Admits one queued mint: gates, timing, the volatility snapshot, the dry run, the cash-need check, and node pins. Returns a new receipt |
| `admit_sell` | witness | Admits an early sell of an open receipt's position, in place on that receipt |
| `commit` | witness | Stores the `LazerPrice` the order fills at and reserves a mint's fee subsidy |
| `try_fill` | witness | Fills the order at its committed price, or returns the refund reason before anything moves |
| `release` | receipt only | Takes an admitted order out without filling it, for deadline, admin, and settlement refunds, keeping the order fee for reasons 1 and 2 as a fill's refund does |
| `try_pay_settled` | receipt only | Pays an open receipt its settled payout after settlement |

**The witness.** The companion defines `public struct OrderFlow() has drop` in its `order_flow` module and never returns it. `set_order_flow<W>` keys the allowlist by type in a dynamic field on `ProtocolConfig` and emits `OrderFlowUpdated`. Enabling a witness is version-gated. Disabling is not, so it works while frozen and from any package version. `is_order_flow<W>` reads it.

**The receipt.** `OrderReceipt` has `store` and nothing else. The companion can store and move it, but cannot copy, forge, or drop it, and only Predict can unpack it, so each receipt is consumed exactly once. A queue record that still holds a receipt cannot be deleted. A receipt names its market, and Predict refuses it on any other market. Its `stage` is a mint admitted (1), an open position (2), or a sell of that position admitted (3), and every primitive checks the stage it needs. A sell admission rewrites the open receipt it closes, so a sell can never present a different position than the one it admitted. The receipt has 29 fields, with the six account fields grouped into one `OrderParties` value, because Sui's verifier caps a struct at 32 fields.

**The ledger.** Each market keeps an `OrderFlowLedger` in a dynamic field: the payout-tree ticks waiting mints pin, and `waiting_cash_need`. The first admission on a market creates it, so the trader pays its storage. Pins and cash need enter the ledger only through an admission and leave only through the receipt that added them.

Whatever the companion does, Predict enforces:

- **Ownership.** An admission takes a mutable `Account`, which exists only after the account's `Auth` was consumed. A sell admission requires the receipt's account to be that account.
- **Recipients.** Sell proceeds and settled payouts go only to the receive address the receipt recorded at its latest admission.
- **Pricing and solvency.** A fill prices from the receipt's own volatility snapshot and committed price, charges the fees, checks cash backing and the inventory-impact reserve, and applies admission and the trader's limits as recorded.
- **Time.** τ is on a supported channel's grid and at most one of its ticks before the clock, τ is before the deadline and before the no-trade window, and the deadline is at least 5 seconds before expiry.
- **Price provenance.** The committed price comes from a Pyth-verified update for the receipt's feed and channel, stamped at τ or one channel tick later, generated no earlier than τ (see [Commit](#commit)).
- **Incentives.** One subsidy reservation per mint, at most the receipt's subsidy bound times the rate, from that market's balance. Unused subsidy returns at the fill or refund.
- **Replay.** A payout or a full close consumes the receipt, so a position is paid or closed once.

The companion is still trusted with the exact-or-backup tick choice (one channel tick of price drift at most), the timing policy within Predict's bounds, escrow custody and refund routing, the order of fills and refunds, queue limits, the events and reads, and the exits of positions it holds: only companion code can sell an Open record or start its payout. If the companion breaks, those positions wait for a companion upgrade, and their value stays backed in market cash.

## Records and statuses

Each market has one `MarketQueue`, a shared object at an ID derived from the desk and the market (`queue::queue_id(desk_id, expiry_market_id)`). `queue::create_and_share(desk, market)` creates it. Anyone can call it, the caller pays its storage, and a second call for the same market aborts. The fill keeper creates each market's queue after creating the market. Only queue creation takes the desk mutably, so trading never serializes on the desk.

The queue's `OrderBook` keeps each order as one `QueuedOrder` record in a table, keyed by a sequential `u64` record ID. A record ID is not the packed `u256` order ID of a position. Each record holds Predict's receipt for its order and that order's own escrow `Balance<USDC>`, so one record is one dynamic child, and a refund pays exactly that record's escrow.

| Status | Code | Meaning | Leaves the status by |
| --- | --- | --- | --- |
| Pending | 0 | Waiting for its cohort's price | Commit, or a refund |
| Committed | 1 | Priced, waiting for resolve | A fill or a refund |
| Open | 2 | Holds a position: a filled mint, the rest of a partial sell, or a refunded sell | An early sell, or the settlement payout |
| Refunded | 3 | A refunded mint | `cleanup` after settlement |
| Closed | 4 | Its position was sold, moved to a sell, or paid at settlement | `cleanup` after settlement |
| RefundDue | 5 | Reserved. Nothing sets it at launch. A record holding it is refunded with its stored reason | A refund |

```mermaid
stateDiagram-v2
  [*] --> Pending: enqueue (OrderEnqueued)
  Pending --> Committed: commit attaches the τ price (CohortCommitted)
  Committed --> Open: resolve fills a mint or part of a sell (QueuedOrderFilled)
  Committed --> Closed: resolve fills a whole sell
  Pending --> Refunded: mint refunded (QueuedOrderRefunded)
  Committed --> Refunded: mint refunded
  Pending --> Open: sell refunded, position returned
  Committed --> Open: sell refunded, position returned
  Open --> Closed: enqueue_redeem_open moves the position out
  Open --> Closed: settle_step pays it (OpenRecordSettled)
  Refunded --> [*]: cleanup after settlement
  Closed --> [*]: cleanup after settlement
```

Pending, Committed, and RefundDue records are unfinished, and their receipts are admitted. Refunded and Closed records are finished (DX-25). An Open record is neither: it no longer waits, but it holds an open receipt and is a live position until it is sold or paid.

The kind codes are `0` exact quantity, `1` exact amount, `2` exact cost, and `4` early sell of an Open record. Code `3` is reserved and never used, so no later kind reuses it. Status, kind, and reason codes are never renumbered. New codes may be added later, so consumers must tolerate codes they do not know. The kind and reason codes equal Predict's `constants` macros.

## Placing an order

Four companion entrypoints place orders. Each takes the market's queue, the market, the account wrapper and its `Auth`, the desk, `ProtocolConfig`, the Propbook registry, and the canonical Pyth and Block Scholes objects, and returns the new record ID.

| Entrypoint | Sizing at τ | Trader limits |
| --- | --- | --- |
| `enqueue_exact_quantity` | Exactly `quantity` | `max_cost` caps the all-in cost, `max_probability` caps the entry probability |
| `enqueue_exact_amount` | The largest lot-rounded quantity whose premium fits `max_premium` | `min_quantity`, and `max_cost` caps the all-in cost |
| `enqueue_exact_cost` | The largest lot-rounded quantity whose all-in cost fits `max_cost` | `min_quantity` |
| `enqueue_redeem_open` | `close_quantity` of an Open record | `min_probability` and `min_proceeds` |

Every queued mint requires a finite `max_cost`: zero and `u64::MAX` abort `EMintCostCapRequired`. The immediate `mint_exact_quantity` accepted `u64::MAX` as no cap.

Placement runs these steps in order, and an abort charges nothing:

1. **Queue checks (companion).** The desk's version floor and the queue's own desk and market (`EWrongDesk`, `EWrongMarket`). The stuck gate (`EQueueStuck`), the side's capacity (`EQueueFull`), and the account's waiting-order cap in this market (`EAccountOrderCap`). See [Queue limits](#queue-limits).
2. **Timing (companion).** The order gets its τ, deadline, and cutoff. τ must fall before the cutoff (`EPastCutoff`).
3. **Source record (sells only, companion).** The source record must be Open (`ERecordNotOpen`, also for a missing ID) and belong to the placing account (`ENotRecordOwner`). `close_quantity` must be at least `min_sell_quantity`, and a partial sell must leave at least that much (`EBelowMinSell`).
4. **Budget and fee (companion).** A mint needs a finite `max_cost` (`EMintCostCapRequired`) and an available balance above the order fee (`EFeeNotCovered`). Its budget is `min(max_cost, available − order_fee)`, and an exact-quantity mint also caps it at `quantity`, because a fill never costs more than its quantity. A sell needs a balance of at least the order fee and escrows nothing else.
5. **Gates (Predict).** The witness allowlist, the version gate (so the emergency freeze blocks placement), and the cutover. For mints, the trading pause and the market's mint pause. Then the atomic flush snapshot stage. An early sell is open during both pauses.
6. **Timing bounds (Predict).** `EInvalidOrderTiming` unless the channel is a supported fixed-rate channel, τ is on its grid and at most one tick before the clock, τ is before the deadline and before `expiry − no_trade_window_ms`, and the deadline is at least 5 seconds before expiry. The policy's SVI age limit must be within Predict's 120-second ceiling (`EInvalidOrderTerms`).
7. **Volatility snapshot (Predict).** Placement validates the oracle inputs as a live pricer does and copies the Block Scholes spot, forward, and SVI into the receipt. It requires `use_pyth_spot_for_forward` (`pricing::EPythForwardRequired`) and an SVI no older than `svi_max_age_ms`. It does not require a fresh on-chain Pyth spot (DX-4). See [pricing and oracles](./pricing-and-oracles.md#queued-orders).
8. **The t₀ dry run (Predict).** Placement prices the order at the placement clock with the same predicate a fill uses, without subsidy. An order that would already be refunded for its limits or for admission aborts `EOrderFailsLimits`. A sell above the held quantity fails here too.
9. **Spare cash (mints only, Predict).** The mint's [cash need](#pool-cash-for-queued-orders) must fit the market's spare cash (`EInsufficientMarketCash`). Other waiting orders are not counted (DX-6). Sells skip this check.
10. **Pins (mints only, Predict).** Admission creates both finite boundary nodes of the range in the payout tree if they are missing, and pins them in the ledger. A fill therefore never creates a node. The payout tree's node cap still applies here.
11. **Append (companion).** The budget and the order fee move from the account into the record's escrow, the record is stored with its receipt, and `OrderEnqueued` reports it with the market's cash, required cash, and waiting cash need after the call.

An early sell moves the whole position, with its receipt, out of its source record into the new record and marks the source Closed (DX-14). `OrderEnqueued.source_record_id` names the source. There is no cancel: once placed, an order fills or is refunded.

### τ, cohorts, deadline, and cutoff

τ is the last tick of the policy's Pyth channel at or before `t₀ + delay_ms`, where t₀ is the Sui clock of the placing transaction. τ is never below the market's last τ. Two pushes can move it later:

- If the market's previous order used another channel, τ moves to the first tick of the new channel after the last τ, so one cohort never mixes channels.
- If τ is at or below the newest committed τ, it moves to the next tick after it, so no order joins a price already on chain and a committed cohort never grows.

A cohort is all the orders in a market that share one τ. Orders that land within one tick share one signed update and one commit. A cohort also shares one deadline and one channel. Each order stores its own τ, deadline, and channel, so a later policy change reaches only new orders.

The deadline is `min(τ + stall_timeout_ms, expiry)`, never earlier than the market's last deadline. An order that joins an existing cohort takes that cohort's deadline. At or past its deadline an order can only be refunded in full (DX-9). τ and the deadline never decrease along record IDs.

The cutoff is `expiry − max(no_trade_window_ms, stall_timeout_ms + 5_000)`. An order whose τ is at or past the cutoff aborts `EPastCutoff`. Every deadline therefore falls at least 5 seconds before expiry, and every waiting order is due before the market can settle. Predict checks the same 5-second margin on every admission, whatever the companion plans.

Launch runs at the 800 ms delay and a 10-second no-trade window, which an admin sets over its 2-second compiled default. On the 200 ms channel with the 5-second stall timeout, τ then falls 600 to 800 ms after placement, the deadline falls 5 seconds after τ, and the cutoff is 10 seconds before expiry, so new orders stop about 11 seconds before expiry.

## Commit

`queue::commit(queue, market, desk, config, updates, clock, ctx)` attaches verified Pyth Lazer prices to waiting cohorts. Each update in `updates` must come from the Pyth Lazer verifier earlier in the same PTB. Their order does not matter, and an update that matches no waiting cohort is skipped. A repeated commit changes nothing. A settled market matches nothing.

A cohort accepts one update: the one stamped exactly τ on the cohort's own channel (DX-1). An envelope that is not a whole millisecond matches no cohort. `pyth_price_buffer_ms` switches a backup tick on or off. While it is above zero and the clock is at least `gap_wait_ms` past τ, a cohort also accepts the update stamped one tick of its own channel after τ. The buffer is not a window, and the setter keeps it at zero or exactly one tick. The default is zero, so only the exact τ update counts. The backup always follows the cohort's stored channel, so a later change of the policy channel cannot widen the choice of price. A cohort at or past its deadline is never committed.

For each matched cohort, the companion decodes one `LazerPrice` per feed through `deepbook_predict_math::lazer_price::from_update`, then checks every Pending order against it before any is written. A cohort commits whole or not at all. An empty price or update time, a price that does not normalize to a pricing-safe spot, a price generated before τ, or an envelope after the clock leaves the whole cohort waiting for a later commit or its deadline refund (DX-10). A cohort without a price never holds back another cohort (DX-24).

Predict's `commit` then checks each order's price against its receipt and stores it. The price must carry the receipt's Pyth feed and channel, an envelope at exactly τ or one tick of that channel later, a generation time between τ and the envelope, an envelope at or before the clock, and a pricing-safe spot (`EWrongPrice`). Holding a `LazerPrice` proves Pyth signed it, because only the library builds one and only from a verified update. The companion's pre-check makes a cohort commit stay all or nothing, and Predict's check makes a wrong price impossible to store whatever the companion does.

Commit aborts when the caller passes an update the decode cannot read: the order's feed is missing (`lazer_price::EFeedMissing`), the price, exponent, or update-time property was not requested (`lazer_price::EPropertyNotRequested`), or the feed claims an update time after the envelope that carries it (`lazer_price::EGenerationAfterEnvelope`).

Committing a mint reserves its fee subsidy: `min(subsidy_bound × fee_incentive_subsidy_rate, the market's incentive balance)` moves from the market's incentive balance into the record's escrow. `subsidy_bound` is the t₀ dry run's trading fee, capped at the order's budget, so one order cannot soak up a market's incentives (DX-18). The subsidy rate is read at commit.

Commit emits `CohortCommitted` with the committed spot of the cohort's first order, normalized to 1e9, its tick and generation time, the feed, the channel, and the sender. It uses Pyth Lazer's v1 `Update` type, which Pyth has deprecated on Mainnet but still serves. A new format arrives as a new library constructor and a companion upgrade, with no Predict upgrade.

## Resolve

`queue::resolve(queue, market, desk, config, max_orders, clock, ctx)` fills or refunds committed orders from the market's own cash. It walks cohorts in τ order and loads only cohorts that are committed or past their deadline. A cohort still waiting for its price is skipped without loading a record. Within a cohort it visits records in placement order. Every visited record counts against `max_orders`, finished and missing ones included, so one call stays inside Sui's per-transaction object limit. Resolve visits at most 450 records per call whatever `max_orders` asks, because a fill emits two events (Predict's `OrderMinted` or `LiveOrderRedeemed`, and `QueuedOrderFilled`) and Sui allows 1,024 events per transaction. It returns how many orders it finished, and it returns 0 on a settled market.

For each record:

- An order at or past its deadline is refunded with reason 5 through Predict's `release`, never filled.
- A Committed order goes to Predict's `try_fill` with its receipt and escrow. Predict rebuilds a pricer from the receipt's volatility snapshot, re-anchored on the committed Pyth price and rolled to the committed tick. The trading fee is charged at the tick, not at the resolve transaction's clock, and no congestion surcharge applies.
- An order that fails at its tick is refunded with the reason it failed on, before anything moves. `try_fill` never aborts on a value that depends on τ (DX-12). It aborts only on a companion bookkeeping error or a gate: the witness, the version gate, the flush snapshot stage, another market's receipt, a receipt without a price, or escrow below the order's budget, order fee, and reserved subsidy (`EEscrowMismatch`).
- A fill must leave market cash at or above required cash. An order the market cannot cover is refunded with reason 8 and its fee returned, and resolve moves on to the next order. Fills never draw on the pool.

Orders usually fill in the order they were placed, but not always. Each cohort is priced and filled on its own, and a caller holding two updates can commit and resolve a later cohort before an earlier one (decided 10-08). Each order keeps its own τ price, so fill order changes only which order reaches scarce market cash first.

**A mint fill** pays from the record's escrow. Market cash receives the premium, the trading fee net of any referral share, the used subsidy, and the order fee. The inventory-impact charge goes into its reserve. The builder fee and the referral share leave for their addresses. Unused subsidy returns to the market's incentive balance, and unused budget returns to the trader's receive address. The receipt becomes open, and the record becomes Open holding the new position. Predict emits the unchanged `OrderMinted`, with `penalty_fee` 0, and the companion emits `QueuedOrderFilled`.

**A sell fill** pays the trader the redeem value plus the inventory-impact rebate, less the trading and builder fees. The order fee and the trading fee stay in market cash. A full close consumes the receipt and marks the record Closed. A partial close returns the receipt open, holding the replacement position, which keeps the original root ID and open time, and the record stays Open. Predict emits the unchanged `LiveOrderRedeemed`, with `penalty_fee` 0, and the companion emits `QueuedOrderFilled`. A boundary that a waiting mint pins survives the close.

## Open records

A queued fill never enters the trader's account (DX-13). It stays in the market's queue as an Open record owned by the placing account. The record holds the open receipt, with the position's packed order ID, its root ID, its open time, and its held quantity. The position itself sits in the market's payout tree like any other, so it is backed, valued in NAV, and settled the same way.

An Open record leaves the Open status in one of two ways:

- **Sold early.** `enqueue_redeem_open` sells some or all of it before the cutoff. The whole position moves into the sell's own record, and the source record becomes Closed. The sell's record holds the rest after a partial fill, and it becomes Open again if the sell is refunded. After any sell, the trader's position therefore lives under the sell's record ID.
- **Paid at settlement.** The `settle_step` payout phase pays it in cash (see [Settlement and cleanup](#settlement-and-cleanup)).

`queue::quote_redeem_open(queue, market, wrapper, pricer, record_id, close_quantity, clock)` returns a `RedeemQuote` for a prospective early sell. It goes through Predict's `quote_close`, which prices the close at a live `Pricer` from `load_live_pricer` with the wrapper account's builder code, the way a sell fill prices, but with the trading fee at the clock instead of at a committed tick. `proceeds` is before the order fee and carries no congestion surcharge. It changes nothing. It aborts `ERecordNotOpen` for a missing or non-Open record, and otherwise as `quote_close` does: the pricer binding (`EWrongPricer`), a receipt that is not open (`EWrongStage`), the clock at or past expiry (`EInvalidOrderTiming`), or a close that cannot be priced (`EOrderFailsLimits`). It does not check that the account owns the record.

Position reads such as `live_order_value` and `settled_order_payout` take the packed order ID, which `queue::order(record_id)` returns in the record's `OrderView`.

## Refunds

Every refund returns the record's own escrow to the trader's receive address, less an order fee kept for reasons 1 and 2, and returns any reserved subsidy to the market's incentive balance. A refunded mint consumes its receipt and becomes Refunded. A refunded sell gets its receipt back open and returns to Open, holding its position. Each refund emits `QueuedOrderRefunded`.

| Reason | Code | When | Order fee |
| --- | --- | --- | --- |
| Limits | 1 | The order misses its own limits at its tick | Kept, into market cash |
| Admission | 2 | A mint fails admission at its tick, or the order cannot be priced at it | Kept, into market cash |
| No price | 3 | Reserved, unused | Returned |
| Missing node | 4 | A pinned payout-tree node is missing at the fill. Admission pins both nodes, so this is a backstop | Returned |
| Deadline | 5 | The order reached its deadline unfinished, or settlement refunded it | Returned |
| Freeze | 6 | Reserved, unused | Returned |
| Admin | 7 | `admin_refund` | Returned |
| No cash | 8 | Market cash could not cover the fill | Returned |

A mint misses its limits when its size is zero or below `min_quantity`, when an exact-quantity order's probability is above `max_probability`, or when its all-in cost is above `min(max_cost, budget)`. A sell misses its limits when its probability is below `min_probability` or its proceeds are below `min_proceeds`. A mint fails admission when its range cannot be priced, leaves the entry-probability band, misses the minimum premium, or costs more than its maximum payout (DX-17).

Reasons 1, 2, 4, and 8 come from `try_fill`. Reasons 5 and 7, a RefundDue record's stored reason, and the settlement drain go through Predict's `release`, which needs no witness and checks only the version floor, so it works while frozen and after the witness is removed. Both take the record's whole escrow and apply one refund rule: keep the order fee in market cash for reasons 1 and 2, return the reserved subsidy to the incentive balance, take the order's cash need out of the ledger, unpin a mint's boundary ticks, and hand the rest of the escrow back for the companion to send to the trader. A mint's emptied, unpinned node is removed only when the caller asks and the market is unsettled. Keeping a fee moves market cash, so a refund that keeps one aborts inside the flush's atomic snapshot stage, as a fill does. Besides the settlement drain, three companion calls refund waiting orders:

- `resolve` refunds as described above.
- `refund(queue, market, desk, config, max_orders, clock, ctx)` refunds waiting orders at or past their deadline with reason 5. It walks cohorts in τ order and stops at the first one not yet due, since deadlines never decrease. Every visited record counts against `max_orders`, and like `resolve` it visits at most 450 records per call. It returns how many it refunded, and 0 without aborting when none is due.
- `admin_refund(queue, market, admin_cap, desk, config, record_ids, clock, ctx)` refunds the listed waiting orders at once with reason 7, wherever they sit in the queue. It takes Predict's `AdminCap`. Missing and finished IDs are skipped.

A RefundDue record keeps its stored reason on every path, and with it the fee rule. When `refund`, `admin_refund`, or `resolve` refunds a mint, they also remove its boundary nodes if the nodes are empty and no other waiting order pins them.

Each record holds exactly its own escrow, so a refund pays exactly what that order escrowed, less a kept fee, and no shortfall or pooled residue can arise. Predict refuses an escrow below the order's budget, order fee, and reserved subsidy at a fill or a release (`EEscrowMismatch`). There is no `EscrowShortfall` or `QueueEscrowSwept` event.

## Queue limits

- **Capacity.** `mint_capacity` and `sell_capacity` bound unfinished mints and sells per market. A full side aborts `EQueueFull`, and the other side still accepts orders. The first resolve or refund that finishes an order frees a slot. Lowering a capacity below the current count only blocks new orders.
- **Per-account cap.** `per_account_cap` bounds one account's unfinished orders in one market (`EAccountOrderCap`).
- **Stuck gate.** Placement aborts `EQueueStuck` while an uncommitted cohort is at least `stuck_threshold_ms` past its τ and no later cohort is committed, or while two or more uncommitted cohorts are each that far past their τ (DX-11). A single missing tick does not stop new orders while later cohorts are priced. Orders resume once commits move again, or once the stale cohorts are refunded at their deadlines. `queue_stuck` reads the same check.
- **Cutoff and minimum sell size.** See [Placing an order](#placing-an-order).

## Pool cash for queued orders

Spare cash is market cash minus required cash. Each order records its cash need, the most its fill could take out of spare cash. Predict computes it at admission with the library's formulas, where `p` is the market's minimum entry probability:

```text
exact quantity:        ceil(quantity × (1 − p)) + 1
premium or all-in:     ceil((budget + 1) × (1 / p − 1)) + 1
early sell:            ceil(close_quantity × (1 − backing_buffer_lambda)) + 1
```

An exact-amount mint uses `min(max_premium, budget)` as its budget, since it buys no more than its premium cap allows.

Admission checks a mint's own cash need against spare cash. Nothing is reserved while the order waits. Predict's ledger keeps a running total, `waiting_cash_need`. `rebalance_expiry_cash` funds a live market to at least required cash plus that total, and its sweep never takes the market below it (DX-8). Anyone can call it, and the contract sets the level. The fill keeper calls it after each new order. A market can still run short when pool idle or the market's allocation runs out, and resolve then refunds the orders it cannot cover with reason 8. See [liquidity and NAV](./liquidity-and-nav.md#pool--expiry-cash-flow).

Escrow sits in the companion's records, outside market cash, NAV, and backing. A waiting order adds nothing to the pool mark until it fills.

## Settlement and cleanup

Settlement is two separate jobs in two packages, and neither waits on the other (DX-19).

**Predict settles from the oracle.** `try_settle` records the settlement price as before: exact Pyth, or exact Block Scholes after the grace period. It reads nothing from the queue, refunds nothing, and pays nothing. Repeated calls return true with no effect. It stays freeze-gated. Settling while orders still wait is safe: every deadline is at least 5 seconds before expiry, so at expiry a waiting order can only be refunded. `try_fill` refuses past the deadline, escrow is not market cash, and the settled liability already includes every queue-held position, because those positions live in the payout tree.

**The companion drains and pays its queue.** `queue::settle_step(queue, market, desk, config, clock, ctx)` runs one bounded phase per call and returns the phase the next call runs. Anyone can call it, and it aborts `EMarketNotExpired` before expiry.

| Phase | Code | Runs when | Does | Bound per call |
| --- | --- | --- | --- | --- |
| DRAIN | 0 | Unfinished records remain | Refunds them in τ order with reason 5 through `release` (a RefundDue record keeps its stored reason), without node pruning and without updating per-account counts | `settle_refund_batch` records visited (450 at most) |
| PAY | 1 | Nothing is unfinished and Predict has settled | Pays each Open record from a stored cursor through `try_pay_settled`, zero for a loser, to the receipt's receive address, marks it Closed, and emits `OpenRecordSettled`. A record the market cannot pay stays Open with `OpenRecordPayoutSkipped` for a later upgrade to pay, and the walk moves on | `settle_payout_batch` records visited (900 at most) |
| DONE | 2 | The cursor reached the last record | The call that gets there emits `MarketPayoutsCompleted` once. Later calls change nothing | none |

Before Predict settles, DRAIN still runs and a PAY call changes nothing. DRAIN and PAY run while Predict is frozen and after the witness is disabled, because `release` and `try_pay_settled` check only the version floor, but PAY needs Predict to have settled first. `settle_step` reports the transaction's real sender on its refunds. Because the drain skips per-account counts, `waiting_orders` stays stale after expiry.

The batch bounds come from Sui's limit of 1,000 dynamic-field loads per transaction. A drain refund or a payout visit loads one record, and the bounds leave room for the queue, the market, and Predict's ledger. Calls on one queue serialize on the shared queue object, and several calls in one PTB share one transaction's limit, so the keeper sends one `settle_step` per transaction. A larger batch could exceed the limit on every call and leave the queue unable to drain, which would leave its positions unpaid.

The fill keeper owns settlement, in this order: `try_settle` until the market is settled, then `settle_step` until it returns `phase_done()` or `MarketPayoutsCompleted` fires, then `cleanup`, then `rebalance_expiry_cash`. A drain after the first settled sweep returns reserved subsidies to the market's incentive balance, and every settled sweep returns whatever incentive balance the market holds, so the rebalance after cleanup collects them. Incentives are outside NAV, so the order does not move the mark.

`queue::cleanup(queue, market, desk, record_ids, clock)` deletes Refunded and Closed records of a settled market (`EMarketNotSettled` before settlement). Anyone can call it, and the caller keeps the storage rebate. It skips missing IDs, other statuses, and records that still hold a receipt or escrow, and emits `QueuedOrdersCleaned` only when it deleted a record. Open records are never deleted.

## Pauses and the freeze

- **Trading pause and market mint pause.** They block queued mints only. Early sells, commit, resolve, refunds, and settlement keep running.
- **Witness disabled.** `set_order_flow<OrderFlow>(false)` stops every admission, commit, and fill. Committed orders pass their deadlines and refund, and until then a `resolve` that reaches one aborts. Open records keep their positions, and the settlement drain and payout continue. Re-enabling is version-gated.
- **Emergency freeze.** It halts admission, commit, fills, `try_settle`, and the desk's policy setters, so nothing fills. `refund`, `admin_refund`, `settle_step`, and `cleanup` reach only Predict's `release` and `try_pay_settled`, which check the version floor and not the freeze, so a waiting order is still refunded at its deadline (DX-20). A `resolve` that reaches a fill aborts while frozen. An Open record is paid only if its market settled before the freeze.
- **Flush snapshot stage.** Admission, fills, and refunds that keep an order fee abort inside the atomic snapshot transaction, as other trades do. Deadline and admin refunds still run there.

## The delayed-execution policy

`DelayedExecutionPolicy` lives in the companion's shared `OrderDesk`. Publishing `deepbook_predict_orders` creates and shares the one `OrderDesk` with the launch policy, so its ID comes from the publish transaction, and desk uniqueness holds by construction. The publish emits no `DelayedExecutionPolicyUpdated`, because the launch policy is the desk's state at publish. Trading still waits for the admin to allowlist the companion's witness, because every Predict primitive the queue calls checks it. Three setters change the policy. Each takes Predict's `AdminCap`, checks the desk's version floor, refuses while Predict is frozen (`desk::EProtocolFrozen`), and emits `DelayedExecutionPolicyUpdated` with the complete policy. None of them is gated on an open LP valuation, so a stalled flush cannot block them (DX-22).

| Field | Launch value | Bound | What it does |
| --- | --- | --- | --- |
| `delay_ms` | 800 | 0 to 5,000 | The latest τ may fall after placement |
| `pyth_channel` | `3` (`fixed_rate@200ms`) | `2` (`fixed_rate@50ms`) or `3` | The tick grid for new orders' τ |
| `stall_timeout_ms` | 5,000 | 2,000 to 10,000 | Time from τ to the deadline |
| `stuck_threshold_ms` | 1,500 | 50 to 10,000, and at least one tick | When the stuck gate refuses new orders |
| `gap_wait_ms` | 2,000 | 50 to 10,000 | How long past τ before a backup tick is allowed |
| `pyth_price_buffer_ms` | 0 | 0 or exactly one tick of the policy channel | Switches the backup tick on or off |
| `svi_max_age_ms` | 60,000 | 1 to 120,000 | The oldest SVI an admission accepts |
| `mint_capacity` | 100 | 1 to 300 | Unfinished mints per market |
| `sell_capacity` | 100 | 1 to 300 | Unfinished sells per market |
| `per_account_cap` | 5 | 1 to 300, and at most the smaller capacity | Unfinished orders per account per market |
| `min_sell_quantity` | One position lot | Positive whole lots, at most an order's maximum quantity | The smallest early sell and the smallest remainder |
| `order_fee` | 0.02 USDC | 0 to 1 USDC | The flat fee per order |
| `settle_refund_batch` | 450 | 1 to 450 | Records one `settle_step` call visits while draining |
| `settle_payout_batch` | 900 | 1 to 900 | Records one `settle_step` call visits while paying |

Times are milliseconds and USDC amounts are base units. Launch runs `no_trade_window_ms` on Predict's `ProtocolConfig`, which also bounds the cutoff, at 10 seconds.

- `desk::set_timing` sets the delay, stall timeout, stuck threshold, gap wait, price buffer, channel, and SVI age together, so the relational rules are checked on the final state. The channel must be a fixed-rate Lazer channel (`EUnsupportedPythChannel`). The buffer must be zero or one tick, the stuck threshold at least one tick, and `pyth_price_buffer_ms < stuck_threshold_ms <= gap_wait_ms < stall_timeout_ms` (`EInvalidTiming`). `gap_wait_ms < stall_timeout_ms` leaves commit room to take a backup tick before the deadline refund.
- `desk::set_limits` sets both capacities, the per-account cap, the minimum sell, and both settle batches. The per-account cap may not exceed the smaller capacity (`EInvalidLimits`).
- `desk::set_order_fee` sets the order fee.

Each field also has its own bound error in `delayed_execution_config`. The 300 capacity ceiling keeps a full commit of 300 mints and 300 sells inside Sui's per-transaction object limit. Predict bounds what admission accepts whatever the policy says: the 5-second deadline margin and the 120-second SVI-age ceiling.

Waiting orders keep the τ, deadline, channel, and order fee from their placement. Commit reads the buffer and the gap wait when it runs, so a change to those also reaches cohorts already waiting. `desk::policy(desk)` returns the policy.

## Versions and upgrades

Three version floors govern the three packages, and the library has none.

| Package | Floor | Bumped by | What a bump retires |
| --- | --- | --- | --- |
| Predict | `ProtocolConfig.version_watermark` | `protocol_config::bump_version_watermark(&AdminCap)` | Old Predict code, and every caller's calls into it |
| `deepbook_predict_orders` | `OrderDesk.version_watermark` | `desk::bump_version_watermark(&mut OrderDesk, &AdminCap)` | Old companion code. It is the lever for a companion-only fix |
| Sessions | `SessionsConfig.version_watermark` | `session_config::bump_version_watermark(&SessionsAdminCap)` | Old Sessions code |
| `deepbook_predict_math` | none | none | A fix takes effect when Predict relinks |

A package runs the dependency versions it linked when it was published. Before any Predict watermark bump, relink `deepbook_predict_orders` and Sessions to the new Predict, whether or not anything they call changed. A companion still linked to the retired Predict version aborts on every call into Predict, the drain included, so its escrow and receipts are held until its relink is published. A Sessions package linked to it aborts its queued wrappers, while direct placement keeps working. See [architecture](../design/architecture.md#version-gating) for the publish order of the first rollout and of later upgrades.

## The flush-operator allowlist

In package version 4, only an address on the flush-operator allowlist may call `plp::finish_flush` (`protocol_config::ENotFlushOperator`). LP fills move idle cash, so restricting who completes a flush keeps idle predictable for the keeper that funds markets for queued orders. The allowlist is a dynamic field on `ProtocolConfig` and starts empty, which rejects every caller. `add_flush_operator` is admin-only and version-gated. `remove_flush_operator` is admin-only and bypasses the version gate, so an admin can revoke an operator under the emergency freeze. Both emit `FlushOperatorUpdated`, and `is_flush_operator` reads the allowlist. Starting a flush still needs a `PoolValuationCap`, and `value_expiry` stays permissionless. See [liquidity and NAV](./liquidity-and-nav.md#the-flush-is-privileged-not-permissionless).

## Reads

| Read | Returns |
| --- | --- |
| `queue::order(queue, record_id)` | One record as a copyable `OrderView`, or `none` for a missing or deleted ID |
| `queue::queue_id(desk_id, expiry_market_id)` | A market's queue ID, whether or not the queue exists yet |
| `queue::queue_heads(queue)` | `(resolve_head, next_id, last_tau_ms, last_committed_tau_ms)` |
| `queue::payout_progress(queue)` | `(payout_cursor, next_id, payouts_completed)`. The payout walk is finished once `payouts_completed` is set |
| `queue::waiting_cohorts(queue)` | The cohort count, the oldest uncommitted τ, and the oldest uncommitted τ above the newest committed τ |
| `queue::queue_stuck(queue, desk, clock)` | Whether placement would refuse a new order as stuck now |
| `queue::pending_counts(queue)` | `(pending_mints, pending_sells)` |
| `queue::waiting_orders(queue, account_id)` | The account's unfinished orders in this market. Stale after expiry |
| `queue::oldest_unfinished_tau_ms(queue)` | τ of the oldest cohort with an unfinished order |
| `desk::policy(desk)`, `desk::version_watermark(desk)` | The policy, and the companion's version floor |
| `expiry_market::order_flow_state(market)` | `(waiting_cash_need, payout_tree_node_count, min_entry_probability)` |
| `expiry_market::receipt_info(receipt)` | A receipt's market, stage, account, order ID, Pyth feed, cash need, subsidy bound, and volatility snapshot |
| `protocol_config::is_order_flow<W>`, `is_flush_operator`, `version_watermark` | Witness allowlisting, flush-operator membership, and the watermark that marks the cutover |

A record holds a receipt and a balance, so it cannot be copied. `OrderView` carries the record's status, kind, request, account and receive address, timing, escrow terms, position, committed price, result, the receipt's stage (0 when the record holds none), and the escrow it holds. Owner, referrer, and builder fields live in the receipt and the events instead. `order_queue` exposes getters for every view field and for every status, kind, and reason code, so the SDK and indexer never hard-code numbers. The `VolSnapshot` getters are package-only in Predict, so SDK reads decode the snapshot's BCS.

The mint quotes are priced like a queued fill at the clock: `quote_mint`, `quote_mint_for_account`, and `quote_mint_exact_cost_for_account` keep their signatures, use the configured subsidy rate capped by the market's incentive balance, and always report `penalty_fee` 0. They check only the pricer binding and `now < expiry` (`EInvalidOrderTiming`), and abort `EOrderFailsLimits` when the mint would be refused at the clock. They have no trade-window or Pyth-freshness gate. The exact-quantity form quotes `min_quantity` exactly, and the account forms cap at the account's balance and charge its builder fee.

## Errors

| Package and module | Error | Raised by |
| --- | --- | --- |
| Predict `expiry_market` | `EDelayedExecutionRequired` | The retired immediate mints and `redeem_live`, always |
| Predict `expiry_market` | `EOrderFailsLimits` | An order the t₀ dry run would refund, a quote the clock would refuse |
| Predict `expiry_market` | `EInsufficientMarketCash` | A mint whose cash need exceeds spare cash |
| Predict `expiry_market` | `EInvalidOrderTiming`, `EInvalidOrderTerms` | An admission outside Predict's timing bounds or SVI-age ceiling, a commit at or past the deadline, a quote at or past expiry |
| Predict `expiry_market` | `EWrongMarket`, `EWrongStage`, `ENotRecordOwner`, `EEscrowMismatch` | A receipt from another market, at the wrong stage, sold by another account, or presented with the wrong escrow or subsidy |
| Predict `expiry_market` | `EWrongPrice` | A `LazerPrice` that does not match the receipt |
| Predict `expiry_market` | `EMintCostCapRequired` (existing) | A mint admission with a zero budget |
| Predict `protocol_config` | `ECutoverNotReached`, `EOrderFlowNotAllowed` | Admission before the cutover, an order-flow call from a witness not allowlisted |
| Predict `protocol_config` | `EEwmaRetired` | The retired EWMA setters |
| Predict `protocol_config` | `EFlushOperatorAlreadyAdded`, `EFlushOperatorNotFound`, `ENotFlushOperator` | The flush-operator allowlist |
| Predict `pricing` | `EPythForwardRequired` | Admission while `use_pyth_spot_for_forward` is off |
| `deepbook_predict_orders` `queue` | `EWrongDesk`, `EWrongMarket` | A queue used with another desk or market |
| `deepbook_predict_orders` `queue` | `EQueueStuck`, `EQueueFull`, `EAccountOrderCap`, `EPastCutoff` | Placement refused by the [queue limits](#queue-limits) or the cutoff |
| `deepbook_predict_orders` `queue` | `EMintCostCapRequired`, `EFeeNotCovered`, `EBelowMinSell` | A zero or unlimited `max_cost`, a balance that cannot pay the order fee (mints need more than the fee), a sell or remainder below `min_sell_quantity` |
| `deepbook_predict_orders` `queue` | `ERecordNotOpen`, `ENotRecordOwner` | Selling or quoting a record that is not Open, or selling another account's record |
| `deepbook_predict_orders` `queue` | `EMarketNotSettled`, `EMarketNotExpired` | `cleanup` before settlement, `settle_step` before expiry |
| `deepbook_predict_orders` `desk` | `EPackageVersionDisabled`, `EVersionWatermarkNotAdvanced`, `EProtocolFrozen` | The desk floor, a bump that does not advance it, a policy change while Predict is frozen |
| `deepbook_predict_orders` `delayed_execution_config` | `EUnsupportedPythChannel`, `EInvalidTiming`, `EInvalidLimits`, and one bound error per field | The policy setters |
| `deepbook_predict_math` `lazer_price` | `EFeedMissing`, `EPropertyNotRequested`, `EGenerationAfterEnvelope` | `commit` given an update the decode cannot read |

The queue's own checks run before Predict's gates, so when several apply, the companion's error fires first. A settled market is not an error for commit or resolve: they return without change.

## Events

| Event | Package and module | Emitted by |
| --- | --- | --- |
| `OrderMinted` | Predict `order_events` | A mint fill, unchanged, with `penalty_fee` 0 |
| `LiveOrderRedeemed` | Predict `order_events` | A sell fill, unchanged, with `penalty_fee` 0 |
| `OrderFlowUpdated` | Predict `config_events` | `set_order_flow`, with the witness type name and the new state |
| `FlushOperatorUpdated` | Predict `config_events` | `add_flush_operator` and `remove_flush_operator` |
| `OrderEnqueued` | `deepbook_predict_orders` `queue_events` | Each `enqueue_*`, with the request, timing, volatility snapshot, escrow terms, the source record of a sell, and the market's cash, required cash, and waiting cash need after the call |
| `CohortCommitted` | `deepbook_predict_orders` `queue_events` | `commit`, once per cohort, with the normalized spot, the tick, the generation time, the feed, the channel, and the sender |
| `QueuedOrderFilled` | `deepbook_predict_orders` `queue_events` | `resolve`, next to Predict's `OrderMinted` or `LiveOrderRedeemed` |
| `QueuedOrderRefunded` | `deepbook_predict_orders` `queue_events` | Every refund, with the reason, what was returned, and whether a position went back to Open |
| `QueuedOrdersCleaned` | `deepbook_predict_orders` `queue_events` | `cleanup`, when it deleted at least one record |
| `OpenRecordSettled` | `deepbook_predict_orders` `queue_events` | The `settle_step` payout walk, once per Open record it pays, with `payout` 0 for a loser |
| `OpenRecordPayoutSkipped` | `deepbook_predict_orders` `queue_events` | The `settle_step` payout walk, once per Open record it cannot pay |
| `MarketPayoutsCompleted` | `deepbook_predict_orders` `queue_events` | The `settle_step` call that finishes the payout walk, once per queue |
| `DelayedExecutionPolicyUpdated` | `deepbook_predict_orders` `queue_events` | Every policy setter, with the complete policy. The publish that creates the desk emits none |

Every queue event comes from the companion package, so an indexer subscribes to both packages. `OrderMinted` and `LiveOrderRedeemed` keep their Predict type and layout, but a fill transaction calls the companion, so filters keyed on the called package must match on the event type instead. `OrderEnqueued`, `QueuedOrderFilled`, and `QueuedOrderRefunded` carry the market's cash, required cash, and waiting cash need after the call, so a keeper can track spare cash from events alone (DX-23). `CohortCommitted`, `QueuedOrderFilled`, and `QueuedOrderRefunded` carry the transaction sender, so monitoring sees fills by third parties.
