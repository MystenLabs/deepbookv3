# Predict orders

`deepbook_predict_orders` is the order-flow companion of [Predict](../predict/README.md). It holds Predict's delayed-execution order flow: one queue per expiry market, each queued order's escrow, the policy, every order entry point, the queue reads, and the queue events. Predict keeps the market, pricing, fills, cash backing, and settlement, and this package drives them through Predict's order-flow primitives.

From Predict package version 4, every mint and early sell is a queued order. It waits until Pyth Lazer publishes its signed price for the order's price time τ, a short delay after placement, and then fills at that price or is refunded. [Delayed execution](../predict/docs/concepts/delayed-execution.md) owns the mechanics: τ and cohorts, commit, resolve, refunds, settlement, the policy, the errors, and the events.

The package exists because Sui caps a package at 102,400 bytes, and Predict, which can only grow by compatible upgrade, cannot hold the queue as well. The dependency direction is one way: this package depends on Predict and on [`deepbook_predict_math`](../predict_math/README.md), and Predict never names a type of this package.

## Objects

| Object | Module | Holds | Created |
| --- | --- | --- | --- |
| `OrderDesk` | `desk` | The `DelayedExecutionPolicy` every queue runs under, and the companion's version floor | Once, by the `desk` module's `init` at publish, with the launch policy and no event. Its ID comes from the publish transaction |
| `QueueRegistry` | `desk` | The parent every market's queue ID derives from, bound to the desk | Once, by the same `init`, next to the desk |
| `MarketQueue` | `queue` | One market's `OrderBook`: its records, cohort spans, counters, and payout cursor | `queue::create_and_share(registry, desk, market)`, once per market, at the ID `queue::queue_id(registry_id, market_id)` derives from the registry and the market. Anyone can call it, the caller pays its storage, a second call for the same market aborts, and another desk's registry aborts `EWrongDesk` |
| `QueuedOrder` | `order_queue` | One record: its status, request, timing, escrow terms, position, committed price, and result, Predict's `OrderReceipt` for the order, and the order's own escrow `Balance<USDC>`. Once finished, only funds parked for a denied receive address | Each placement, in the queue's table |

Every trading call reads the desk, and only the admin's policy setters write it. Queue creation writes the registry, which no trading call reads, so creating a queue never contends with trading. Calls on one market serialize on that market's queue.

## Modules

| Module | Owns |
| --- | --- |
| `order_flow` | The witness `OrderFlow`, which Predict's allowlist names. This module is the only place it is built, through package-only wrappers around `admit_mint`, `admit_sell`, `commit`, and `try_fill`. It is never returned |
| `desk` | `OrderDesk`, `QueueRegistry`, the policy setters, and the desk's version floor |
| `delayed_execution_config` | `DelayedExecutionPolicy`, its launch values, its bounds, and its getters |
| `order_queue` | `OrderBook` and its records, τ and deadline planning, the stuck check, cohort spans and counters, the status, kind, and reason codes, and the copyable `OrderView` that reads return |
| `queue` | `MarketQueue` and every entry point: placement, commit, resolve, refunds, settlement, the deny-list catch-up calls, cleanup, and the reads |
| `queue_events` | The queue and policy events |

## Entry points

| Entry point | Caller | Does |
| --- | --- | --- |
| `queue::enqueue_exact_quantity`, `enqueue_exact_amount`, `enqueue_exact_cost` | The account, through its `Auth`, or an authorized app such as Sessions | Places a queued mint, escrows its budget and order fee, and returns the record ID |
| `queue::enqueue_redeem_open` | The account that owns the Open record | Places an early sell of an Open record and escrows the order fee |
| `queue::commit` | Anyone | Attaches verified Pyth Lazer prices to the waiting cohorts they match |
| `queue::resolve` | Anyone | Fills or refunds committed orders. Visits at most 450 records per call, a cap on events, so callers size `max_orders` from measured costs |
| `queue::refund` | Anyone | Refunds waiting orders at or past their deadline, with the same 450-record cap |
| `queue::admin_refund` | Predict's `AdminCap` | Refunds listed waiting orders at once |
| `queue::settle_step` | Anyone, after expiry | Runs one bounded settlement phase: drain the unfinished orders, then pay the Open records |
| `queue::pay_open` | Anyone, after settlement | Pays one Open record the payout walk skipped, because market cash was short or its receive address was denied |
| `queue::claim_parked` | Anyone | Sends a finished record's parked funds to its own receive address once that address is no longer denied |
| `queue::cleanup` | Anyone, after settlement | Deletes finished records with nothing parked and keeps their storage rebate |
| `queue::create_and_share` | Anyone | Creates a market's queue |
| `desk::set_timing`, `set_limits`, `set_order_fee` | Predict's `AdminCap` | Change the policy, while Predict is not frozen |
| `desk::bump_version_watermark` | Predict's `AdminCap` | Advances the desk floor to this package's compiled version |

Every call that can send USDC (`resolve`, `refund`, `admin_refund`, `settle_step`, `pay_open`, `claim_parked`) takes Sui's shared `DenyList`, because Mainnet USDC is a regulated coin and Sui aborts a transaction that credits a denied address. This package never makes such a send: it parks the funds in the record or leaves the record Open for later ([denied recipients](../predict/docs/concepts/delayed-execution.md#denied-recipients)).

Reads: `queue::order`, `queue_id`, `queue_heads`, `payout_progress`, `waiting_cohorts`, `queue_stuck`, `pending_counts`, `waiting_orders`, `oldest_unfinished_tau_ms`, and `quote_redeem_open`, plus `desk::policy`, `desk::version_watermark`, and `desk::registry_id`. A record holds a receipt and a balance and cannot be copied, so `queue::order` returns an `OrderView`.

## Trust boundary

Every money-moving step runs inside one of Predict's primitives, which checks its own gates, the receipt's market and stage, and the caller's witness or receipt when it runs. Whatever this package does, Predict decides who owns a position and where its proceeds go, prices every fill from the receipt's own volatility snapshot and committed price, enforces cash backing, bounds τ and the deadline, accepts only a `LazerPrice` for the receipt's feed and channel stamped at τ or one tick later, and pays or closes a position once. See [the order-flow boundary](../predict/docs/concepts/delayed-execution.md#the-order-flow-boundary).

This package is still trusted with:

- **The tick.** It chooses between a cohort's exact τ tick and its one backup tick, which moves a fill's price by at most one channel tick.
- **Timing and order.** It sets τ and the deadline within Predict's bounds, applies the queue limits, and orders fills and refunds.
- **Escrow.** It holds each order's escrow and routes refunds.
- **Events and reads.** Queue state reaches indexers and the app only through this package.
- **Exits.** Only this package can sell an Open record or start its payout. If it breaks, those positions wait for an upgrade of this package, and their value stays backed in market cash.
- **Confinement.** No function returns the witness, forwards caller-chosen values into a Predict primitive without its own checks, or hands out a receipt by value.

## Authority and recovery

Predict serves this package only while an admin has allowlisted its witness with `protocol_config::set_order_flow<OrderFlow>(true)`, which is version-gated.

| State | Admission, commit, fills | Refunds, settlement drain and payout, cleanup |
| --- | --- | --- |
| Witness allowlisted | Run | Run |
| Witness disabled | Refused (`EOrderFlowNotAllowed`) | Run |
| Predict frozen | Refused | Run |

Refunds and the settlement walk reach only Predict's `release` and `try_pay_settled`, which need no witness and check only Predict's version floor. Disabling the witness is ungated, so it works while frozen, and it stops new fills while keeping every exit. To recover from a bug in this package, publish an upgrade, bump the desk floor, then re-enable the witness. Predict's `PauseCap` freeze stops every admission, commit, and fill at once.

## Versions and upgrades

`desk::current_version!()` is 1, and `OrderDesk.version_watermark` is the floor every entry point checks. `desk::bump_version_watermark` advances it to the running package's version, retiring older code of this package. It is the lever for a fix that touches only this package.

This package runs the Predict and library versions it linked at publish. Before any Predict watermark bump, publish an upgrade of this package relinked to the new Predict, and relink Sessions too, whether or not anything they call changed. Otherwise every call into Predict aborts after the bump, the drain included, and escrow and receipts wait for the relink. The first rollout pauses trading first and keeps it paused until the end. It publishes the library, upgrades Predict, and publishes this package, recording the desk and registry IDs and the publish checkpoint. It starts the indexer from the Predict upgrade's checkpoint. In one admin transaction it allowlists the witness, re-states the launch order fee so the policy event records the launch policy, and adds the market keeper's signer as a flush operator. It then creates a queue for each live market, upgrades Sessions, moves the services to the new IDs, bumps the Predict and Sessions watermarks, and reopens trading, and Testnet measures full-batch gas before Mainnet activates. `packages/predict/deployment/upgrade_v4.ts` runs it. [Architecture](../predict/docs/design/architecture.md#version-gating) owns every step, including the monitoring and registry registrations.

`Move.toml` copies Predict's `[dep-replacements.mainnet]` block, so both packages resolve one dependency graph on Mainnet. Struct layouts, public signatures, events, and the status, kind, and reason codes freeze at this package's first Mainnet publish.

## Build and test

From the repository root:

```sh
sui move build --path packages/predict_orders --warnings-are-errors
sui move test --path packages/predict_orders --gas-limit 100000000000 --package-size 64
sui move test --path packages/predict_orders --build-env mainnet --gas-limit 100000000000 --package-size 64
```

Run this suite, and the Predict and Sessions suites, after changing any Predict order-flow primitive or anything this package calls in Predict. The tests cover placement, commit, resolve, refunds, settlement, the policy, the queue bindings, and the event layouts. Predict's own primitive tests live in `packages/predict/tests/flows/order_flow_tests.move`.
