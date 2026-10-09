# Architecture

Predict is a per-expiry, range-based options protocol on Sui. Its on-chain state is split across a small set of long-lived shared objects, account-package custody with Predict app data, and a handful of governance and attribution capabilities. This document describes those objects, who owns which capital, the capability and authorization model, how version gating works, and the binding mesh that ties markets to Propbook underlyings and oracle feeds. It documents how the system is structured, not how to call it; for the economics, see the [concepts](../concepts/) docs, and for tunable values see [configuration](./configuration.md).

## Two principles to read this document by

Two design commitments shape everything below; both are stated once here and assumed throughout.

- **One canonical strike interpretation — absolute integer ticks.** Protocol-wide, a strike is an absolute tick from zero, with `raw_strike = tick * tick_size`. There is no second strike representation anywhere: no market-local centered grid, no boundary-relative indices. Public entrypoints and events carry the tick pair `(lower_tick, higher_tick)` directly; order IDs and the payout tree key on ticks (the order ID is the only packed form); raw strikes are recovered only at the pricing/settlement boundary. The `strike_exposure/range_codec` module is the single owner of the tick↔raw conversion.
- **Oracle data lives outside Predict.** The live spot, BS forward, and SVI data come from standalone, Predict-unaware feeds in the separate `propbook` package. Predict holds no oracle object, no writer capability, and no price-ingest path; it stores a Propbook underlying ID and validates passed feeds against Propbook's current canonical binding when live pricing runs.

## Packages

Sui caps a package at 102,400 bytes, counting its modules, their names, the type-origin table, and the linkage table. Predict can only grow by compatible upgrade, so from package version 4 its delayed-execution order flow and its pure pricing math live in two packages beside it. Predict version 4 measures 98,380 bytes.

| Package | Published | Holds |
| --- | --- | --- |
| `deepbook_predict` | Upgraded in place, so its original ID, shared objects, coin types, and published types stay | The objects below, every flow on them, and the order-flow primitives the companion drives |
| `deepbook_predict_orders` | Fresh | The shared `OrderDesk` with the delayed-execution policy, one `MarketQueue` per market, each queued order's escrow, every order entry point, the queue reads, and the queue events ([README](../../../predict_orders/README.md)) |
| `deepbook_predict_math` | Fresh | Pure functions only: SVI evaluation and roll-down, the pricing-safe input checks, the fee curve, the inventory-impact potential, premium sizing, the builder fee, the cash-need formulas, the order-ID decode, and `LazerPrice` ([README](../../../predict_math/README.md)) |

Dependencies point one way: `deepbook_predict_orders` → `deepbook_predict` → `deepbook_predict_math` → `fixed_math`, and the companion also depends on the library. Predict never names a companion type. Sessions depends on the companion and on Predict. The companion is trusted the way an app is: Predict serves its primitives only to an allowlisted witness type, and every primitive checks its own gates and the order's receipt when it runs (see [delayed execution](../concepts/delayed-execution.md#the-order-flow-boundary)). To fit the limit, Predict's package and private function names are capped at 12 characters, except about 49 that keep a longer name because they share an identifier with a public function or field, or with a dependency. Public functions, structs, fields, and events keep their names.

## Object taxonomy

Sui distinguishes three object dispositions. Predict uses all three deliberately:

- **Shared objects** are usable by any transaction and passed by reference. Predict's protocol-wide and per-market state are shared so that any trader, LP, or keeper can interact with them.
- **Owned objects** belong to a single address and can only be used by that address's transactions. Predict's capabilities are owned objects, which is how delegated authority is granted and held.
- **Derived objects** are created at a deterministic address from a parent's `UID` plus a typed key (`derived_object::claim`). Predict derives `BuilderCode` from the registry's `UID`; the account package derives `AccountWrapper` / `Account` identities from its own `AccountRegistry`. The order-flow companion derives each market's `MarketQueue` from its `QueueRegistry`, keyed by the market's ID.

The protocol is constructed at package publish: the `registry` module's `init` creates and shares the `Registry`, creates and shares the `ProtocolConfig`, and transfers a single `AdminCap` to the deployer. The `plp` module's `init` registers the PLP coin type and creates and shares the `PoolVault`. Per-expiry `ExpiryMarket` objects are created later through a registry entrypoint. Publishing `deepbook_predict_orders` creates and shares its one `OrderDesk` and its `QueueRegistry` in the `desk` module's `init`, and each market's `MarketQueue` is created later by a permissionless call. The oracle objects (`PythFeed`, `BlockScholesValueStore`, `BlockScholesSVIStore`) are external objects owned by the `propbook` package, not by Predict — the Pyth feed is created permissionlessly, while the Block Scholes store pair is created admin-gated, once per underlying.

## Shared objects

| Object | Module | Owns / holds | Created |
| --- | --- | --- | --- |
| `Registry` | `registry` | Admin-approved Propbook underlyings, cadence deployment configs, expiry uniqueness index, allowed `PauseCap`, `MarketLifecycleCap`, and `PoolValuationCap` IDs | package init |
| `ProtocolConfig` | `protocol_config` | All admin-tunable config structs, the `trading_paused` flag, the emergency `frozen` flag, the monotonic version watermark (which also marks the delayed-execution cutover), the cross-transaction valuation flag and flush ordinal, and, in dynamic fields, the order-flow witness allowlist and the settled-redeem keeper and flush-operator allowlists | package init |
| `PoolVault` | `plp` | Idle LP-owned USDC, protocol-reserve USDC, the PLP `TreasuryCap`, the per-expiry cash-flow ledger, and the two async LP request queues (supply USDC escrow, withdraw PLP escrow) | package init |
| `ExpiryMarket` | `expiry_market` | One expiry's trade execution, strike-exposure state (tick-keyed payout tree), embedded `ExpiryCash` USDC custody, EWMA gas-price stats, Propbook underlying ID, tick size, and, in a dynamic field its first queued order creates, the `OrderFlowLedger` of payout-tree pins and waiting cash need | per underlying and expiry |
| `OrderDesk` | `deepbook_predict_orders::desk` | The delayed-execution policy and the companion's version floor | companion package init |
| `QueueRegistry` | `deepbook_predict_orders::desk` | The parent each market's queue ID derives from, bound to the desk. Queue creation writes it, and no trading call reads it | companion package init |
| `MarketQueue` | `deepbook_predict_orders::queue` | One market's queued orders, each with Predict's receipt and its own escrow, the cohort spans, and the settlement payout cursor | per market, derived from the registry |

The `Registry` is the protocol's index and governance anchor. It enforces one approved config row per Propbook underlying ID and one `ExpiryMarket` per `(propbook_underlying_id, expiry)` pair (the version watermark lives on `ProtocolConfig`, not here). It does not hold runtime trading state: pool accounting lives in `PoolVault`, per-expiry risk in `ExpiryMarket`, and positions in Predict app data attached to accounts. It records which Propbook underlyings Predict will build markets on and the cadence deployment policies used to create them; source IDs and canonical oracle object IDs live in `propbook`.

`ProtocolConfig` is a separate shared object from `Registry`. It owns the global flow gates — `trading_paused` (blocks new risk creation), `frozen` (the protocol-wide emergency freeze that halts the whole version-gated surface), and `valuation_in_progress` (true for the whole multi-transaction span of a full-pool NAV valuation, alongside the flush ordinal `flush_seq`; fee-incentive sponsorship, LP request cancels, and most config setters gate on it — trading flows, cash rebalancing, and market creation do not) — and the admin-tunable config structs. One of those is a *template* config (`StrikeExposureConfig`): its current values are snapshotted into each new `ExpiryMarket` at creation, so changing a template affects only future expiries, not live ones. See [configuration](./configuration.md).

`ExpiryMarket` is the hot object for one expiry. It embeds `ExpiryCash` (a `store`-only component, not its own object) which holds that expiry's working USDC and its isolated inventory-impact escrow. From package version 4 it also owns the order-flow primitives the companion drives: admission, commit, fill, release, and the settled payout of one queued order, each issuing, advancing, or consuming that order's `OrderReceipt` (see [delayed execution](../concepts/delayed-execution.md)). Its ledger lives in a dynamic field because `ExpiryMarket`'s layout is fixed after deploy, and the trader whose order creates it pays its storage. The queue itself lives in the companion's `MarketQueue`, so trading on one market serializes on that queue and on the market. The market never reaches into the pool directly; cash enters only via pool-driven rebalancing and leaves only via release back to the pool or as payouts to accounts. Because the oracle was extracted, the market stores only the Propbook underlying ID; `pricing::load_live_pricer` validates the passed feed objects against Propbook's current canonical binding before a live price reaches exposure logic.

## USDC custody

USDC is the protocol's settlement currency and has 6 decimals. Custody is partitioned across four layers, each owned by the module responsible for it:

- **Per-trader funds** live inside the account-package `Account` loaded from an `AccountWrapper`. Deposits, withdrawals, premiums, fees, LP fills, and payouts all flow through this custody.
- **Per-expiry working cash** lives in each `ExpiryMarket`'s embedded `ExpiryCash`. It must always cover the expiry's payout liability plus its inventory-impact escrow; the market re-asserts this backing invariant after every cash movement.
- **Queued-order escrow** lives in the companion's records: each unfinished order's budget, order fee, and reserved fee subsidy, held with that order's receipt. It sits outside `ExpiryCash`, NAV, and backing until Predict's fill moves it into market cash or a refund returns it.
- **Pool capital** lives in `PoolVault`: `idle_balance` (LP-owned USDC available for withdrawals and expiry funding) and `protocol_reserve_balance` (protocol-owned profit, excluded from PLP redemption). USDC supply requests and PLP withdraw requests are escrowed in two `RequestQueue`s on the vault — pulled from the requesting account under owner auth — until the next flush drains them.

Money flows in one shape. `PoolVault.idle_balance` funds an expiry's `ExpiryCash` during cash rebalancing. Traders' budgets and order fees flow from account custody into a queue record's escrow at placement, and from escrow into `ExpiryCash` at the fill, with unused budget returned to the account's receive address. Payouts flow from `ExpiryCash` to the account's receive address. Surplus and settled cash flow from `ExpiryCash` back to `PoolVault.idle_balance`. LP supply/withdraw fills enter and leave idle at the flush and are delivered to account receive addresses. Builder fees leave for the builder-code address, while mint referral shares leave protocol proceeds for the referring Account's receive address and return to ordinary Account custody when settled.

Mainnet USDC is a regulated coin, and Sui aborts any transaction that credits USDC to an address on its deny list or to anyone while it is globally paused. The queued-order flow reads Sui's `DenyList` and never makes such a send: a fill for a denied receive address is refused, a denied builder or referral fee stays in market cash, a refund the address cannot take is parked in its queue record, and a denied winner's payout waits in its Open record. Permissionless calls pay both once the address clears (see [delayed execution](../concepts/delayed-execution.md#denied-recipients)). The LP flush does not yet do this: a denied LP recipient makes `finish_flush` abort ([S-10](../../predeploy/open-items.md#s-10-a-denied-lp-recipient-aborts-the-flush)).

## Accounts and app authorization

Predict uses the reusable `account` package for custody and account-local state. `AccountWrapper` is the shared object passed into Predict entrypoints; it embeds an `Account` that holds coin balances, the dynamic-field root for app data, and optional immutable referral attribution. A referred Account stores both the referrer's canonical Account ID and wrapper receive address: the ID is the attribution identity and the address is the accumulator delivery target. Predict stores its local `PredictData` under the `PredictApp` witness: positions from immediate mints keyed by `(expiry_market_id, order_id)` and the sticky builder-code attribution. A queued fill never enters the account: it stays in its market's queue as an Open record, whose receipt names the placing account and its receive address.

Account mutation authority is an `Auth` hot potato consumed by `AccountWrapper::load_account_mut`. There are two relevant sources:

| Auth source | Used for | Notes |
| --- | --- | --- |
| Owner auth | placing queued mints and early sells through the companion, owner settled redeem, LP request/cancel, builder-code config | generated by the account owner or by an owning object; this is the normal user-authorized path. An authorized app such as Sessions can supply app auth for the same placement calls |
| Predict app auth | keeper settled redeem (`redeem_settled_permissionless`) | generated inside Predict through `account_registry::generate_auth_as_app<PredictApp>` only for a sender on `ProtocolConfig`'s settled-redeem keeper allowlist; disabled by `deauthorize_app<PredictApp>` |

Once an entrypoint has a mutable `Account`, coin movement and Predict-data mutation need no extra account-level proof. The mutable borrow is the authority boundary: public entrypoints perform their flow gates and account authorization up front, then internal helpers operate on `&mut Account`.

This is intentionally package-level trust. A whitelisted app can mutably load any account wrapper it is handed, so Predict entrypoints own all user-facing permissioning, solvency, market, and lifecycle checks before they mutate account state. This keeps the account package composable for future cross-product infrastructure such as account margining.

**Capital ops settle first (ambient accumulator).** Account coin reads and writes first sweep funds delivered to the account receive address (`balance::send_funds`) into stored account custody, then proceed. Predict threads `AccumulatorRoot` and `Clock` through trade and PLP entrypoints so Account can do that settlement at the custody boundary. Mint referral shares use the same Account receive-address and settlement flow. Builder fees remain an explicit claim flow because the builder code owner claiming accumulated rewards is the domain action.

### Settled automation

`redeem_settled` has two public variants. The owner-auth variant lets the account owner exit directly. The keeper variant, `redeem_settled_permissionless`, uses Predict app auth so a keeper can sweep settled positions into the account without the owner signing. Despite its name it is not open to everyone: the sender must be on the settled-redeem keeper allowlist that `AdminCap` manages on `ProtocolConfig` (`add_settled_redeem_keeper` / `remove_settled_redeem_keeper`), which ships empty. This is the intended trust boundary: removing a keeper or deauthorizing the app stops app-auth automation, while owner-auth settled exits remain available and never consult the allowlist.

## Governance and attribution capabilities

| Capability | Module | Authority | Lifecycle |
| --- | --- | --- | --- |
| `AdminCap` | `admin` | global policy: all admin-tunable config, version-watermark bump (which is also the delayed-execution cutover), mint pause/unpause, market-lifecycle caps, pool-valuation caps, pause caps, the order-flow witness allowlist, the settled-redeem keeper and flush-operator allowlists, underlying approval, cadence deployment configs, and in the companion the delayed-execution policy, the desk's version floor, and refunding queued orders by ID (`queue::admin_refund`); also genesis-bootstraps the pool (`plp::lock_capital`) | one, minted at init, transferred to deployer (multisig) |
| `MarketLifecycleCap` | `market_lifecycle_cap` | create expiry markets (`registry::create_and_share_expiry_market`) | minted and revoked by `AdminCap` against the `Registry` allowlist |
| `PoolValuationCap` | `pool_valuation_cap` | the **sole** authority to start the pool flush (`plp::start_pool_valuation`, on a registry-issued proof); a fresh start discards any in-flight flush, so there is no separate abort entrypoint | minted and revoked by `AdminCap` against the `Registry` allowlist |
| `PauseCap` | `pause_cap` | emergency kill switch: force `trading_paused = true`, force per-market mint pause, force protocol-wide `frozen = true` | minted/revoked by `AdminCap` against the `Registry` allowlist; cannot unpause anything |
| `BuilderCode` | `builder_code` | builder-fee attribution identity | derived shared object; permanent owner |

**`AdminCap` is a dependency-leaf.** Modules that own admin-tunable state accept the `AdminCap` directly as a parameter rather than routing the mutation through `Registry`. `protocol_config` setters, `expiry_market::set_mint_paused`, and registry-owned flows all take `&AdminCap`. The cap is passed as an unused reference (`_admin_cap`); holding it is the authorization. `Registry` only owns flows that are genuinely registry-scoped: version management, `PauseCap`, `MarketLifecycleCap`, and `PoolValuationCap` lifecycle, uniqueness-indexed creation (`create_and_share_expiry_market`), Propbook underlying admission, and cadence deployment policy.

**`MarketLifecycleCap` is the market-creation key.** Its authority is creating an expiry market (`registry::create_and_share_expiry_market`); it grants no other authority. The allowlist of valid lifecycle caps lives on `Registry` — its only creation call site — where `AdminCap` mints into it (`registry::mint_lifecycle_cap`) and revokes from it (`registry::revoke_lifecycle_cap`).

**`PoolValuationCap` is the flush key.** It is the sole holder permitted to start the pool flush (`plp::start_pool_valuation`), which consumes a transaction-local `PoolValuationProof` that `registry::generate_pool_valuation_proof` issues only while the cap is allowlisted — the root-`AdminCap` flush path was removed, and admin retains a break-glass route by minting itself a pool-valuation cap. Starting a fresh flush discards any in-flight one, so recovery needs no separate abort entrypoint. `value_expiry` is permissionless once the snapshot seals, and `finish_flush` takes an address on the flush-operator allowlist rather than a capability. It grants no other authority. Its allowlist lives on `Registry` beside the lifecycle-cap allowlist, where `AdminCap` mints into it (`registry::mint_pool_valuation_cap`) and revokes from it (`registry::revoke_pool_valuation_cap`). There is no oracle-writer capability in Predict at all: Block Scholes data is written permissionlessly into the external `propbook` feed by anyone holding a verified `Update`, so Predict mints and holds no price-writing authority.

**Flush operators finish the flush.** From package version 4, `plp::finish_flush` aborts `ENotFlushOperator` unless the sender is on a `VecSet<address>` that `AdminCap` edits on `ProtocolConfig` (`add_flush_operator` / `remove_flush_operator`). LP fills move idle cash, so restricting who completes a flush keeps idle predictable for the keeper that funds markets for queued orders. The set starts empty. Granting is version-gated and revoking is not, so an admin can drop an operator under the emergency freeze, as with the settled-redeem keeper allowlist.

**The order-flow witness admits the companion.** Predict's order-flow primitives that admit, commit, or fill an order take a witness value and abort `EOrderFlowNotAllowed` unless an admin allowlisted its type with `protocol_config::set_order_flow<W>(true)`. The companion's witness, `deepbook_predict_orders::order_flow::OrderFlow`, exists only inside companion code, so there is no bearer object to leak or rotate. Enabling is version-gated and disabling is not, so an admin can stop new fills under the freeze while refunds and settled payouts, which need only a receipt, keep running.

**`PauseCap` is the emergency brake.** `AdminCap` mints `PauseCap`s into the registry's `allowed_pause_caps` set for trusted operators. A valid `PauseCap` can force global trading pause, force per-market mint pause, or force a protocol-wide freeze — all one-way. Unpausing and unfreezing always require `AdminCap`. The pause-cap mint and all three force paths intentionally bypass the version gate, so the kill switch stays available even when admin has misconfigured versions. (There is no version-disable authority anywhere: versioning is the admin-only monotonic watermark described below.)

**`BuilderCode` attributes builder fees.** It is a derived shared object claimed from the registry per `(owner, index)` pair, with a permanent owner. A Predict account can set a sticky `builder_code_id`; trades then add a builder fee (bounded by a per-quantity rate cap — see [fees and rebates](../concepts/fees-and-rebates.md)) and route it to the code's address. The owner claims accumulated builder fees explicitly with `claim_all_builder_fees`. This keeps builder fees out of the pool/expiry custody mesh entirely.

**Account referral attribution routes mint fees.** `account::account_registry::new_with_referrer` snapshots an existing Account's canonical ID and wrapper receive address into the new Account. Predict uses the live protocol referral rate on each mint, reports the canonical ID in `OrderMinted`, and sends the calculated share to the stored receive address. The relation is direct, immutable, and one level; it is Account state rather than a Predict capability.

## Capability and ownership diagram

```mermaid
graph TD
    subgraph Shared
        REG[Registry]
        CFG[ProtocolConfig]
        VAULT[PoolVault<br/>idle + reserve USDC,<br/>PLP cap,<br/>LP request queues]
        EM[ExpiryMarket<br/>embeds ExpiryCash USDC]
        BC[BuilderCode]
    end

    subgraph propbook (external oracle package)
        OR[OracleRegistry<br/>canonical bindings]
        PF[PythFeed<br/>global spot]
        BVS[BlockScholesValueStore<br/>spot + forward series]
        BSV[BlockScholesSVIStore<br/>SVI series]
    end

    subgraph Owned caps
        ADMIN[AdminCap]
        PAUSE[PauseCap]
        MOLC[MarketLifecycleCap]
        PVC[PoolValuationCap]
    end

    subgraph AccountPkg[account package]
        AREG[AccountRegistry<br/>app whitelist]
        AW[AccountWrapper<br/>embeds Account + PredictData]
    end

    subgraph OrdersPkg[deepbook_predict_orders]
        DESK[OrderDesk<br/>policy + desk floor]
        MQ[MarketQueue<br/>records: receipt + escrow]
    end

    REG -. derives .-> BC
    REG -->|one market per expiry| EM
    AREG -. derives .-> AW
    AREG -->|Predict app-auth<br/>for settled automation| AW

    OR -->|canonical Pyth| PF
    OR -->|canonical BS value store| BVS
    OR -->|canonical BS SVI store| BSV
    EM -.->|stores underlying id| OR
    EM -.->|live pricing reads| PF
    EM -.->|live pricing reads| BVS
    EM -.->|live pricing reads| BSV

    ADMIN --> CFG
    ADMIN --> REG
    ADMIN -->|mints into registry allowlist| MOLC
    ADMIN --> PAUSE
    MOLC -->|creates markets| REG
    ADMIN -->|mints into registry allowlist| PVC
    PVC -->|starts pool flush| VAULT
    PAUSE -->|one-way pause| CFG
    PAUSE -->|one-way mint pause| EM

    DESK -. derives .-> MQ
    ADMIN -->|policy, desk floor| DESK
    ADMIN -->|allowlists OrderFlow witness| CFG
    AW -->|budget + fee escrow at placement| MQ
    MQ <-->|order-flow primitives: admit, commit, fill, release, pay| EM
    MQ -->|refunds via accumulator| AW
    EM -->|proceeds and payouts via accumulator| AW
    AW <-->|LP requests| VAULT
    VAULT <-->|funding / settled cash| EM
    VAULT -->|LP fill via accumulator| AW
    EM -->|builder fee via accumulator| BC
```

## The binding mesh

A priced trade composes an `ExpiryMarket`, Propbook's `OracleRegistry`, the current propbook oracle objects (`PythFeed`, `BlockScholesValueStore`, `BlockScholesSVIStore`), and an account loaded from `AccountWrapper`; the protocol must guarantee they belong together:

- **Underlying approval.** Predict's `Registry`, through its `MarketManager.underlying_configs`, records each admin-approved Propbook underlying ID and deployment watermarks. This row gates which underlyings Predict will build markets on; Propbook owns source IDs, source-object discovery, and canonical source-to-underlying binding.
- **Creation-time coverage.** `create_and_share_expiry_market` takes Propbook's `&OracleRegistry` and a `propbook_underlying_id`, then asserts that Propbook currently has canonical Pyth, BS value store, and BS SVI store bindings for that underlying and deployable expiry. It snapshots the underlying ID, cadence tick size, and admission tick size (plus the deployable expiry and reference-tick source timestamp). Pairing spot, forward, and SVI to one underlying/expiry is therefore a Propbook registry claim, not a market-deployer claim.
- **Live priced-flow binding.** Every priced flow passes the current Propbook registry plus oracle objects to `pricing::load_live_pricer`, which checks the object IDs against Propbook's current canonical bindings for the market's underlying and expiry. A queued order's admission runs the same check when it copies the order's volatility snapshot. Commit and fills read no Propbook object: commit takes a `LazerPrice` built from a verified Pyth Lazer update, and a fill prices from the receipt's stored snapshot.
- **Live pricing liveness.** `pricing::load_live_pricer` rejects a live price for a market whose expiry has passed. The keeper composes `expiry_market::try_settle` before settlement-dependent consumers; it records the exact Propbook Pyth spot when available, or the exact Block Scholes minute-boundary spot after the 30-second Pyth-exclusive window, together with terminal payout liability. If both exact sources are absent, the past-expiry market remains pending settlement, standalone rebalance moves no cash, and the market cannot be live-valued.
- **Market → pool.** `create_and_share_expiry_market` registers the new expiry in `PoolVault`'s active-expiry ledger as a zero-cash accounting row. The market is not mintable until `plp::rebalance_expiry_cash` funds it from idle; the expiry never pulls from the pool itself.
- **Account → market.** A queued order's receipt names its market, and Predict refuses it on any other market (`EWrongMarket`). An Open record's receipt names its account, and a sell admission requires that account (`ENotRecordOwner`). Each `MarketQueue` names its desk and market, and the companion refuses it with any other (`EWrongDesk`, `EWrongMarket`). Positions from immediate mints are keyed by `(expiry_market_id, order_id)` inside Predict account data, so an order minted by one expiry can only be redeemed against that same expiry's market. Owner auth or Predict app-auth controls who can load the account for the flow; the position key controls which market/order pair the loaded account may mutate.

`ExpiryMarket` owns market flow sequencing and state mutation; `pricing` owns the oracle-read boundary that turns Propbook objects into a live `Pricer` or an exact-history spot read; the propbook oracle objects own their stored payloads and version. This division keeps flow gates, oracle trust checks, and leaf data storage separate.

## Oracle feeds (external, in `propbook`)

The live oracle data is fully outside Predict, in standalone, Predict-unaware shared objects in the `propbook` package. Predict reads them; it owns no oracle object, writer capability, or ingest path.

- **`propbook::pyth_feed::PythFeed`** — one global source-native Pyth payload per Pyth Lazer feed ID plus exact timestamp inserts. Updated permissionlessly by anyone holding a verified `pyth_lazer::Update` (`update`); the verified update is its own provenance proof, so there is no writer cap. Predict reads `normalized_spot()` and the read's `source_timestamp_ms`, while raw source fields remain available through raw getters.
- **`propbook::block_scholes_store::BlockScholesValueStore`** — one per-underlying store of the latest BS spot and per-expiry forward observations, keyed by signed series id, plus exact minute-boundary spot history. Updated permissionlessly through a verified `bs_oracle` value batch — the batch type is the provenance proof, so there is no writer cap.
- **`propbook::block_scholes_store::BlockScholesSVIStore`** — one per-underlying store of the latest per-expiry BS SVI parameter sets, same signed-batch gating.

Propbook creates an underlying's store pair once through its registry and records it as canonical; Predict checks the stores it is handed against that binding. `pricing.move` owns all raw oracle ingress: it issues exact-history Pyth reads for reference tick and Pyth-preferred settlement, exact-history Block Scholes reads for settlement fallback, and resolves the live forward from the full feed set. Which source builds the live forward is the admin setting `use_pyth_spot_for_forward`. While it is set (the default), a present and fresh normalized Pyth spot gives `forward = pyth_spot * (bs.forward / bs.spot)`, a missing, stale, or non-positive/unrepresentable spot falls back to the normalized Block Scholes `forward` for the market expiry (valuation and the mint quotes price on that fallback; before package version 4 retired them, the immediate mints and live redeem aborted `EPythSpotUnavailable` or `EPythSpotStale` rather than execute on it), and an oversized normalized Pyth spot aborts under Predict's pricing envelope. While it is clear, that Block Scholes `forward` is used on every load and the Pyth spot is read for provenance only — so the envelope's *Pyth* spot ceiling is never reached, because nothing consumes the value (the envelope's other bounds, including the same ceiling applied to the Block Scholes forward, still run on every load). BS spot and forward must be fresh under `block_scholes_price_freshness_ms`, and SVI must be fresh under the looser `block_scholes_svi_freshness_ms` — spot and forward use the provider's `value_timestamp`, SVI uses `svi_timestamp`, and each is exposed as `source_timestamp_ms` for freshness and trade-event provenance; the SVI source timestamp also anchors roll-down. Batch timestamps are transport observability only. The stores carry their own package version and a forward-only `migrate`; Predict does **not** gate them under its version set. See [pricing and oracles](../concepts/pricing-and-oracles.md).

## The pool, NAV, and the async LP layer

LP supply and withdraw are **asynchronous**. An LP queues a request (`request_supply` with `min_plp_out` / `request_withdraw` with `min_usdc_out`, routed through an account so a composing vault's own account — not necessarily the tx signer — is the fill recipient); the input is escrowed in one of two `RequestQueue`s on `PoolVault`, and a pending request can be cancelled for an immediate refund while no flush is in flight — cancels are gated during one, because the frozen mark is on-chain readable and an ungated cancel would be a free look at it. A periodic **flush** fills eligible queued heads at one frozen mark; requests submitted after a flush's snapshot instant are quarantined to the next mark by the recorded queue cutoffs.

The per-expiry NAV primitive is `expiry_market::current_nav`: the **exact** live recoverable value of one expiry — free cash minus the exact live liability, floored at zero. The liability is `walk_linear` alone — the payout tree's full boundary-linear walk, `Σ quantity × P(range)`, with no per-order correction. The flush folds the same quantity as of its snapshot instant (`snapshot_nav`, the same walk over the cash values and tree shadows captured at that instant). There is no approximation and no uncertainty band; the deleted approximate-NAV matrix and its band/withdraw-fee superstructure are gone.

The flush runs in three stages, carried across transactions as vault-held state (`PoolValuation`), and never pauses trading:

1. **Snapshot — one atomic transaction.** `start_pool_valuation` (started with a `PoolValuationCap` proof) engages the cross-transaction valuation flag and records the active-expiry set, the start time, and each LP queue's eligibility cutoff. One `snapshot_expiry_pricer` per market freezes that market's oracle state as a `Pricer` and stamps the market (`ValuationStamp`); `seal_valuation_snapshot` proves the set is complete. A `SnapshotStage` hot potato confines the stage to the starting transaction, so every pricer is loaded at one instant. A market already settled at snapshot time is recorded with no pricer; an expired-but-unsettled market aborts the snapshot — it must be settled first. PLP caps the active pre-expiry market count at market registration; expired or settled markets can also be swept independently before a flush.
2. **Valuation — resumable.** One `value_expiry` per transaction (never batched) folds one market's snapshot-instant NAV into the running total, reading no oracle: a market frozen as settled was already swept in the snapshot stage and contributes 0; a still-live market is read from its captured snapshot — the stamp's cash rows copied at the snapshot instant, and the payout tree's per-node shadows, priced by the same linear walk as the live read (this stage moves no cash; the standalone rebalance may run at any time post-seal and cannot reach the mark, every figure of which was frozen at the seal); one that expired mid-window is valued at its frozen pre-expiry mark. The stamp is then cleared, releasing the tree snapshot and any nodes retained for it. Trading on a stamped market stays live, unrecorded, and unbudgeted — each tree node captures its own shadow before its first mutation under the flush, so no volume of trading can outgrow the valuation.
3. **Finish.** `finish_flush`, called by a flush operator, proves every snapshotted market was valued, computes `pool_nav = idle + Σ snapshot-instant NAV` (net of the pending-protocol-profit exclusion priced from the aggregate profit basis), then `lp_book::drain` mints/burns PLP and delivers fills at that one frozen mark, each queue drained only up to its recorded cutoff — supplies first, then withdrawals FIFO until idle is dry, up to the operator-supplied per-queue budgets (`supply_budget`/`withdraw_budget`, `None` = unbounded; independent so a supply backlog can't starve withdrawals). A head request whose mark or quote is non-executable is protocol-cancelled and refunded instead of aborting the flush; a live request whose frozen-mark quote misses its request-time limit is protocol-cancelled and refunded the same way at the shipped attempt count of one, so the drain moves straight on (`lp_request_limit_flush_attempts` is admin-tunable; above one such a request instead stays queued and stops that queue until its attempts are exhausted); a withdrawal whose quote is valid and limit-satisfying but exceeds idle is paid what idle covers, keeps its unfilled balance queued, and stops the withdrawal pass; a supply is likewise bounded by `max_lp_pool_value` and keeps any unfilled balance at the head. Fills and refunds are delivered to the account receive address through `balance::send_funds` and passively settled into account custody by later Account balance operations.

The flush's **snapshot is privileged**: only a `PoolValuationCap` proof starts one (the sole flush-start authority; the root-`AdminCap` path was removed). Once the snapshot seals, `value_expiry` is permissionless — the frozen mark is committed at the snapshot, so a stranger cannot reprice a fill, and `value_expiry` is idempotent. `finish_flush` is restricted to the flush-operator allowlist, and the per-queue drain budgets are committed at the snapshot, so even an operator cannot finish with a zero budget (finish takes no budget). The cap-holder is trusted not to manipulate the live oracle around the snapshot — the single frozen mark prices both supply and withdraw, so it must equal true recoverable value, which the exact snapshot-instant reconstruction guarantees. A stalled flush is not aborted but superseded: a fresh `start_pool_valuation` discards the in-flight valuation and re-snapshots (folding stop into start), and `finish_flush` refuses past `max_valuation_window_ms` for everyone including the operator, so recovery past the window is a fresh start; the discard bumps the flush ordinal, so stamps go stale and are lazily dropped by the next trade. While a flush is in flight, fee-incentive sponsorship, LP request cancels, and most config setters are gated; trading, new LP requests, cash rebalancing, and market creation are not (a new market is outside the flush's frozen expected set and joins the next snapshot) — a post-seal rebalance cannot reach the mark, every figure of which was frozen at the seal, so a market can always be topped back into its mintable band mid-flush; the one refusal is inside the still-open snapshot stage. Cash rebalancing and the settled-market sweep are standalone, permissionless, per-market entrypoints, because neither needs the exactly-once completeness proof. See [liquidity and NAV](../concepts/liquidity-and-nav.md).

## Settlement

Settlement is one permissionless public transition. After expiry, `try_settle` asks `pricing` for the canonical exact-history Pyth read first. If it remains unavailable at least 30 seconds after expiry, the same transition asks for the canonical Block Scholes exact spot. It passes the selected price to `StrikeExposure::set_settled`, which records the exposure phase and exact terminal payout liability together; the event records the selected source. The market's public settlement getters delegate to the exposure, while idempotent repeat calls remain owned by `try_settle`.

`try_settle` reads nothing from the delayed-execution queue. Every queued order's deadline is at least 5 seconds before expiry, so at expiry a waiting order can only be refunded, and the settled liability already covers every queue-held position, because those positions live in the payout tree. The companion drains and pays its queue afterwards with `queue::settle_step`, one bounded phase per call: it refunds the unfinished orders, then, once Predict has settled, pays each Open record its settled payout through Predict's `try_pay_settled` (see [delayed execution](../concepts/delayed-execution.md#settlement-and-cleanup)). The keeper's order is `try_settle`, `settle_step` until the payout walk completes, `cleanup`, then `rebalance_expiry_cash`.

`redeem_settled`, `redeem_settled_permissionless`, `plp::rebalance_expiry_cash`, and `value_expiry` do not read settlement oracles; they consume the recorded phase (for `value_expiry`, the sweep-vs-value branch frozen at the flush snapshot). Transaction builders call `try_settle` first when settlement may be due; it no longer refuses a market stamped by an in-flight flush: settlement is never blocked by a flush, because the frozen mark is settlement-invariant. If both exact sources are absent after expiry, standalone rebalance is a no-op and the flush's snapshot stage refuses the market, so a flush cannot start over it; no approximate mark is substituted because the flush uses one mark for both PLP supply and withdraw. See [decisions](./decisions.md) and [invariants](./invariants.md).

## Version gating

Package upgrades are gated by a single monotonic **version watermark** stored on `ProtocolConfig` (`version_watermark`). Every gated flow asserts `current_version!() >= protocol_config.version_watermark`; everything below the watermark is dead. `current_version!()` is an upgrade-required code constant bumped on each upgrade, and the watermark is the runtime floor.

`ProtocolConfig` is threaded into every version-gated public entrypoint, and `config.chk_version()` is its first line. There are no per-object version sets and no sync entrypoints: one central watermark replaces the former `Registry.allowed_versions` set and its `ExpiryMarket`/`PoolVault` mirrors. (`chk_trading` still omits the version check — version and trading-pause are independent gates that each public flow applies as needed.)

Raising the floor is admin-only and footgun-free: `protocol_config::bump_version_watermark` takes no target — it sets the watermark to the running `current_version!()`. Because that value is whatever package binary is executing, the floor can only ever advance to a version a published binary actually embeds; admin can never set it above the running package and brick it, and retiring old versions requires executing the bump against the upgraded package. The watermark is monotonic (it cannot be lowered), so a disabled running version is recovered by upgrading, not by lowering the floor. The setter itself, the `PauseCap` mint, both revocations, and all reads are deliberately ungated; the lifecycle-cap and pool-valuation-cap **mints** are the exception — they are version-gated (`registry::mint_lifecycle_cap`, `registry::mint_pool_valuation_cap`), because granting privileged operator authority under a version freeze is risky. The external propbook feeds carry their *own* version and forward-only `migrate`; Predict does not gate them.

The watermark also marks the delayed-execution cutover. Admission asserts `version_watermark >= 4`, the fixed cutover version (`constants::cutover_version!()`, `ECutoverNotReached`), so no package version that knows nothing about the queue can run while an order waits. The cutover is fixed rather than `current_version!()`, so a later upgrade keeps placement open before its own floor bump. A second, weaker gate, `chk_floor`, checks the watermark but not the emergency freeze. Predict's `release` and `try_pay_settled` use it, so the companion's refunds, settlement drain, and settled payouts keep running while frozen.

Reversible emergency stops are separate from the watermark: `trading_paused` (global), per-expiry `mint_paused`, and the protocol-wide `frozen` (which halts the whole version-gated surface, folded into `chk_version`) — all admin-settable and `PauseCap`-forceable one-way, and all liftable by `AdminCap` without an upgrade.

### Floors across the three packages

| Package | Floor | Bumped by | What a bump retires |
| --- | --- | --- | --- |
| `deepbook_predict` | `ProtocolConfig.version_watermark` | `protocol_config::bump_version_watermark(&AdminCap)` | Old Predict code, and every caller's calls into it |
| `deepbook_predict_orders` | `OrderDesk.version_watermark` | `desk::bump_version_watermark(&mut OrderDesk, &AdminCap)` | Old companion code. It is the lever for a companion-only fix |
| `deepbook_sessions` | `SessionsConfig.version_watermark` | `session_config::bump_version_watermark(&SessionsAdminCap)` | Old Sessions code |
| `deepbook_predict_math` | none | none | A fix takes effect when Predict relinks |

Floors compare logical versions (`current_version!()`), not publication numbers. A package runs the dependency versions it linked when it was published, so a dependent must be relinked to a new Predict before Predict's floor retires the version it calls.

**Relink rule.** Before any Predict watermark bump, publish an upgrade of `deepbook_predict_orders` and of Sessions relinked to the new Predict, whether or not anything they call changed. A companion still linked to the retired version aborts on every call into Predict, the drain included, so its escrow and receipts are held until its relink is published, and a Sessions package linked to it aborts its queued wrappers.

**First rollout (package version 4), per network.** Trading stays paused (`trading_paused`) from step 0 until step 11. `packages/predict/deployment/upgrade_v4.ts` runs it: steps 1 to 7 by default, step 9 with `--cutover`, and step 11 with `--reopen`, and on Mainnet it emits unsigned transactions for the multisig (`--emit-unsigned`).

0. Pause trading with `protocol_config::set_trading_paused(true)` if it is open. Both networks' Predict and Sessions watermarks are still at 1, so the step 9 bump retires every older version at once.
1. Publish `deepbook_predict_math` and register it in MVR. It emits no events.
2. Upgrade Predict (Mainnet version 3 to 4, Testnet version 4 to 5), linked to the library, and register the new Predict version with transaction monitoring (Blockaid) right away. Leave the watermark alone. No witness is allowlisted and admission refuses before the cutover, so nothing can be queued.
3. Publish `deepbook_predict_orders`, linked to the new Predict and the library. The `desk` module's `init` creates and shares the one `OrderDesk` with the launch policy, and its `QueueRegistry`. Record the desk and registry IDs and the publish checkpoint from that transaction. Register the companion's version 1 in Blockaid and MVR, and move both new UpgradeCaps to the Predict multisig.
4. Start the indexer with `--first-checkpoint` at the step 2 upgrade checkpoint, and no later than the step 3 publish, so it records `FlushOperatorUpdated`, `OrderFlowUpdated`, and the policy event. The v4 indexer needs the companion's package ID and the v4 type origins, so it cannot be deployed on a network before step 3, and the servers follow once the indexer has applied its migrations.
5. In one admin transaction:
   - allowlist the companion with `protocol_config::set_order_flow<deepbook_predict_orders::order_flow::OrderFlow>(true)`,
   - re-state the launch order fee with `desk::set_order_fee` (20,000, which is 0.02 USDC), so `DelayedExecutionPolicyUpdated` records the launch policy and the desk ID, because the desk's `init` emits no event,
   - add the market keeper's signer as a flush operator with `protocol_config::add_flush_operator`, unless it already is one. The v4 `finish_flush` admits only flush operators, and an empty allowlist rejects everyone.

   Nothing can be placed before this transaction, because every Predict primitive the queue calls checks the allowlist.
6. Create a queue for every live market with `queue::create_and_share(registry, desk, market)`. The market keeper also backfills a missing queue for any unexpired market when it starts, and creates one for each new market. The fill keeper never creates queues.
7. Upgrade Sessions (`current_version!()` 3), linked to the new Predict and the companion, and register Sessions version 3 in Blockaid.
8. Move the services to the new IDs: the fill keeper, the market keeper, the indexer and servers, the SDK configuration, and the operations configuration, which gains the companion's package ID and the desk and registry IDs. The alert rules (balances, heartbeats, keeper liveness, gas aborts, payout skips, and queue creation failures) go live before the fill keeper starts writing.
9. Bump the watermarks: Predict's to 4 (the cutover) and Sessions' to 3. The desk floor stays at 1.
10. Measure full-batch gas (DBU-892): `settle_step` at its 450 drain and 900 payout batches, `resolve` and `refund` at their 450 cap, and a full 100-mint cohort resolved at the keeper's `resolve_max_orders`. Queued admission checks the trading pause, so Testnet measures right after step 11 reopens trading, and Mainnet waits for the Testnet numbers.
11. Reopen trading.

Types the v4 upgrade introduces, such as `OrderReceipt`, `OrderFlowUpdated`, and `ExpiryPnlRealized`, carry the v4 upgrade's package ID as their type origin. Predict's original types keep the original ID, and the companion's types carry the companion's own original ID.

**Later upgrades.**

| Change | Order |
| --- | --- |
| Predict vN to vN+1 | Publish Predict, publish the companion relink, publish the Sessions relink, move the keeper, SDK, and indexer, bump Predict's floor, then the desk and Sessions floors |
| Companion only | Publish the companion, publish the Sessions relink, move the keeper and SDK, bump the desk floor, then Sessions' |
| Library fix | Upgrade the library, then follow the Predict row, including both relinks |
| Pyth Lazer format change | Upgrade the library with a new `LazerPrice` constructor, then follow the companion row. Predict is untouched |

Before every bump, rehearse the exact sequence on localnet with published packages, including a placement, a commit, a fill, a refund, and a settled payout through the relinked companion and Sessions. The first rollout passed that rehearsal on localnet, and its live Testnet run is tracked in [S-9](../../predeploy/open-items.md#s-9-the-v4-upgrade-sequence-still-needs-its-live-testnet-run).

## Where this leads

- Tunable values, templates, and the snapshot-at-creation model: [configuration](./configuration.md).
- Settled design decisions and what they superseded: [decisions](./decisions.md); the invariants they preserve: [invariants](./invariants.md).
- Admin powers, oracle trust, the privileged flush, and version-freeze risk: [risks](../risks.md).
- How prices are formed from the propbook feeds: [pricing and oracles](../concepts/pricing-and-oracles.md).
- How queued orders move through the order-flow companion and Predict's primitives: [delayed execution](../concepts/delayed-execution.md).
- How positions, fees, and the pool behave economically: [markets and positions](../concepts/markets-and-positions.md), [fees and rebates](../concepts/fees-and-rebates.md), [liquidity and NAV](../concepts/liquidity-and-nav.md).
