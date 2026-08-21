# Architecture

Predict is a per-expiry, range-based options protocol on Sui. Its on-chain state is split across a small set of long-lived shared objects, account-package custody with Predict app data, and a handful of governance and attribution capabilities. This document describes those objects, who owns which capital, the capability and authorization model, how version gating works, and the binding mesh that ties markets to Propbook underlyings and oracle feeds. It documents how the system is structured, not how to call it; for the economics, see the [concepts](../concepts/) docs, and for tunable values see [configuration](./configuration.md).

## Two principles to read this document by

Two design commitments shape everything below; both are stated once here and assumed throughout.

- **One canonical strike interpretation — absolute integer ticks.** Protocol-wide, a strike is an absolute tick from zero, with `raw_strike = tick * tick_size`. There is no second strike representation anywhere: no market-local centered grid, no boundary-relative indices. Public entrypoints and events carry the tick pair `(lower_tick, higher_tick)` directly; order IDs and the payout tree key on ticks (the order ID is the only packed form); raw strikes are recovered only at the pricing/settlement boundary. The `strike_exposure/range_codec` module is the single owner of the tick↔raw conversion.
- **Oracle data lives outside Predict.** The live spot, BS forward, and SVI data come from standalone, Predict-unaware feeds in the separate `propbook` package. Predict holds no oracle object, no writer capability, and no price-ingest path; it stores a Propbook underlying ID and validates passed feeds against Propbook's current canonical binding when live pricing runs.

## Object taxonomy

Sui distinguishes three object dispositions. Predict uses all three deliberately:

- **Shared objects** are usable by any transaction and passed by reference. Predict's protocol-wide and per-market state are shared so that any trader, LP, or keeper can interact with them.
- **Owned objects** belong to a single address and can only be used by that address's transactions. Predict's capabilities are owned objects, which is how delegated authority is granted and held.
- **Derived objects** are created at a deterministic address from a parent's `UID` plus a typed key (`derived_object::claim`). Predict derives `BuilderCode` from the registry's `UID`; the account package derives `AccountWrapper` / `Account` identities from its own `AccountRegistry`.

The protocol is constructed at package publish: the `registry` module's `init` creates and shares the `Registry`, creates and shares the `ProtocolConfig`, and transfers a single `AdminCap` to the deployer. The `plp` module's `init` registers the PLP coin type and creates and shares the `PoolVault`. Per-expiry `ExpiryMarket` objects are created later through a registry entrypoint. The oracle objects (`PythFeed`, `BlockScholesValueStore`, `BlockScholesSVIStore`) are external objects owned by the `propbook` package, not by Predict — the Pyth feed is created permissionlessly, while the Block Scholes store pair is created admin-gated, once per underlying.

## Shared objects

| Object | Module | Owns / holds | Created |
| --- | --- | --- | --- |
| `Registry` | `registry` | Admin-approved Propbook underlyings, cadence deployment configs, expiry uniqueness index, allowed `PauseCap` and `MarketLifecycleCap` IDs | package init |
| `ProtocolConfig` | `protocol_config` | All admin-tunable config structs, the `trading_paused` flag, the emergency `frozen` flag, the monotonic version watermark, the transaction-local valuation lock | package init |
| `PoolVault` | `plp` | Idle LP-owned DUSDC, protocol-reserve DUSDC, the PLP `TreasuryCap`, the per-expiry cash-flow ledger, and the two async LP request queues (supply DUSDC escrow, withdraw PLP escrow) | package init |
| `ExpiryMarket` | `expiry_market` | One expiry's trade execution, strike-exposure state (tick-keyed payout tree), embedded `ExpiryCash` DUSDC custody, EWMA gas-price stats, Propbook underlying ID, tick size | per underlying and expiry |

The `Registry` is the protocol's index and governance anchor. It enforces one approved config row per Propbook underlying ID and one `ExpiryMarket` per `(propbook_underlying_id, expiry)` pair (the version watermark lives on `ProtocolConfig`, not here). It does not hold runtime trading state: pool accounting lives in `PoolVault`, per-expiry risk in `ExpiryMarket`, and positions in Predict app data attached to accounts. It records which Propbook underlyings Predict will build markets on and the cadence deployment policies used to create them; source IDs and canonical oracle object IDs live in `propbook`.

`ProtocolConfig` is a separate shared object from `Registry`. It owns the global flow gates — `trading_paused` (blocks new risk creation), `frozen` (the protocol-wide emergency freeze that halts the whole version-gated surface), and `valuation_in_progress` (a transaction-local lock held while a full-pool NAV valuation is assembled) — and the admin-tunable config structs. One of those is a *template* config (`StrikeExposureConfig`): its current values are snapshotted into each new `ExpiryMarket` at creation, so changing a template affects only future expiries, not live ones. See [configuration](./configuration.md).

`ExpiryMarket` is the hot object for one expiry. It embeds `ExpiryCash` (a `store`-only component, not its own object) which holds that expiry's working DUSDC and its isolated inventory-skew escrow. The market never reaches into the pool directly; cash enters only via pool-driven rebalancing and leaves only via release back to the pool or as payouts to accounts. Because the oracle was extracted, the market stores only the Propbook underlying ID; `pricing::load_live_pricer` validates the passed feed objects against Propbook's current canonical binding before a live price reaches exposure logic.

## DUSDC custody

DUSDC is the protocol's settlement currency and has 6 decimals. Custody is partitioned across three layers, each owned by the module responsible for it:

- **Per-trader funds** live inside the account-package `Account` loaded from an `AccountWrapper`. Deposits, withdrawals, premiums, fees, LP fills, and payouts all flow through this custody.
- **Per-expiry working cash** lives in each `ExpiryMarket`'s embedded `ExpiryCash`. It must always cover the expiry's payout liability plus its inventory-skew escrow; the market re-asserts this backing invariant after every cash movement.
- **Pool capital** lives in `PoolVault`: `idle_balance` (LP-owned DUSDC available for withdrawals and expiry funding) and `protocol_reserve_balance` (protocol-owned profit, excluded from PLP redemption). DUSDC supply requests and PLP withdraw requests are escrowed in two `RequestQueue`s on the vault — pulled from the requesting account under owner auth — until the next flush drains them.

Money flows in one shape: `PoolVault.idle_balance` funds an expiry's `ExpiryCash` during cash rebalancing; traders' premiums and protocol fees flow from account custody into `ExpiryCash`; payouts flow from `ExpiryCash` back into account custody; surplus and settled cash flow from `ExpiryCash` back to `PoolVault.idle_balance`. LP supply/withdraw fills enter and leave idle at the flush and are delivered to account receive addresses. Builder fees leave for the builder-code address, while mint referral shares leave protocol proceeds for the referring Account's receive address and return to ordinary Account custody when settled.

## Accounts and app authorization

Predict uses the reusable `account` package for custody and account-local state. `AccountWrapper` is the shared object passed into Predict entrypoints; it embeds an `Account` that holds coin balances, the dynamic-field root for app data, and optional immutable referral attribution. A referred Account stores both the referrer's canonical Account ID and wrapper receive address: the ID is the attribution identity and the address is the accumulator delivery target. Predict stores its local `PredictData` under the `PredictApp` witness: open positions keyed by `(expiry_market_id, order_id)` and the sticky builder-code attribution.

Account mutation authority is an `Auth` hot potato consumed by `AccountWrapper::load_account_mut`. There are two relevant sources:

| Auth source | Used for | Notes |
| --- | --- | --- |
| Owner auth | live mint/redeem, owner settled redeem, LP request/cancel, builder-code config | generated by the account owner or by an owning object; this is the normal user-authorized path |
| Predict app auth | permissionless settled redeem | generated inside Predict through `account_registry::generate_auth_as_app<PredictApp>`; disabled by `deauthorize_app<PredictApp>` |

Once an entrypoint has a mutable `Account`, coin movement and Predict-data mutation need no extra account-level proof. The mutable borrow is the authority boundary: public entrypoints perform their flow gates and account authorization up front, then internal helpers operate on `&mut Account`.

This is intentionally package-level trust. A whitelisted app can mutably load any account wrapper it is handed, so Predict entrypoints own all user-facing permissioning, solvency, market, and lifecycle checks before they mutate account state. This keeps the account package composable for future cross-product infrastructure such as account margining.

**Capital ops settle first (ambient accumulator).** Account coin reads and writes first sweep funds delivered to the account receive address (`balance::send_funds`) into stored account custody, then proceed. Predict threads `AccumulatorRoot` and `Clock` through trade and PLP entrypoints so Account can do that settlement at the custody boundary. Mint referral shares use the same Account receive-address and settlement flow. Builder fees remain an explicit claim flow because the builder code owner claiming accumulated rewards is the domain action.

### Settled automation

`redeem_settled` has two public variants. The owner-auth variant lets the account owner exit directly. The permissionless variant uses Predict app auth so a keeper can sweep settled positions into the account without the owner signing. This is the intended trust boundary: app deauthorization stops app-auth automation, while owner-auth settled exits remain available.

## Governance and attribution capabilities

| Capability | Module | Authority | Lifecycle |
| --- | --- | --- | --- |
| `AdminCap` | `admin` | global policy: all admin-tunable config, version-watermark bump, mint pause/unpause, market-lifecycle caps, pause caps, underlying approval, cadence deployment configs; also genesis-bootstraps the pool (`plp::lock_capital`) | one, minted at init, transferred to deployer (multisig) |
| `MarketLifecycleCap` | `market_lifecycle_cap` | create expiry markets (`registry::create_and_share_expiry_market`); also the **sole** authority to start the privileged pool flush (`plp::start_pool_valuation`) | minted and revoked by `AdminCap` against the `Registry` allowlist |
| `PauseCap` | `pause_cap` | emergency kill switch: force `trading_paused = true`, force per-market mint pause, force protocol-wide `frozen = true` | minted/revoked by `AdminCap` against the `Registry` allowlist; cannot unpause anything |
| `BuilderCode` | `builder_code` | builder-fee attribution identity | derived shared object; permanent owner |

**`AdminCap` is a dependency-leaf.** Modules that own admin-tunable state accept the `AdminCap` directly as a parameter rather than routing the mutation through `Registry`. `protocol_config` setters, `expiry_market::set_mint_paused`, and registry-owned flows all take `&AdminCap`. The cap is passed as an unused reference (`_admin_cap`); holding it is the authorization. `Registry` only owns flows that are genuinely registry-scoped: version management, `PauseCap` and `MarketLifecycleCap` lifecycle, uniqueness-indexed creation (`create_and_share_expiry_market`), Propbook underlying admission, and cadence deployment policy.

**`MarketLifecycleCap` is the market-lifecycle key.** Its primary authority is creating an expiry market (`registry::create_and_share_expiry_market`); it is also the sole holder permitted to start the pool flush (`plp::start_pool_valuation`) — the root-`AdminCap` flush path was removed, and admin retains a break-glass route by minting itself a lifecycle cap. It grants no other authority. The allowlist of valid lifecycle caps lives on `Registry` — its only creation call site — where `AdminCap` mints into it (`registry::mint_lifecycle_cap`) and revokes from it (`registry::revoke_lifecycle_cap`). There is no oracle-writer capability in Predict at all: Block Scholes data is written permissionlessly into the external `propbook` feed by anyone holding a verified `Update`, so Predict mints and holds no price-writing authority.

**`PauseCap` is the emergency brake.** `AdminCap` mints `PauseCap`s into the registry's `allowed_pause_caps` set for trusted operators. A valid `PauseCap` can force global trading pause, force per-market mint pause, or force a protocol-wide freeze — all one-way. Unpausing and unfreezing always require `AdminCap`. The pause-cap mint and all three force paths intentionally bypass the version gate, so the kill switch stays available even when admin has misconfigured versions. (There is no version-disable authority anywhere: versioning is the admin-only monotonic watermark described below.)

**`BuilderCode` attributes builder fees.** It is a derived shared object claimed from the registry per `(owner, index)` pair, with a permanent owner. A Predict account can set a sticky `builder_code_id`; trades then add a builder fee (bounded by a per-quantity rate cap — see [fees and rebates](../concepts/fees-and-rebates.md)) and route it to the code's address. The owner claims accumulated builder fees explicitly with `claim_all_builder_fees`. This keeps builder fees out of the pool/expiry custody mesh entirely.

**Account referral attribution routes mint fees.** `account::account_registry::new_with_referrer` snapshots an existing Account's canonical ID and wrapper receive address into the new Account. Predict uses the live protocol referral rate on each mint, reports the canonical ID in `OrderMinted`, and sends the calculated share to the stored receive address. The relation is direct, immutable, and one level; it is Account state rather than a Predict capability.

## Capability and ownership diagram

```mermaid
graph TD
    subgraph Shared
        REG[Registry]
        CFG[ProtocolConfig]
        VAULT[PoolVault<br/>idle + reserve DUSDC,<br/>PLP cap,<br/>LP request queues]
        EM[ExpiryMarket<br/>embeds ExpiryCash DUSDC]
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
    end

    subgraph AccountPkg[account package]
        AREG[AccountRegistry<br/>app whitelist]
        AW[AccountWrapper<br/>embeds Account + PredictData]
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
    MOLC -->|starts pool flush| VAULT
    PAUSE -->|one-way pause| CFG
    PAUSE -->|one-way mint pause| EM

    AW <-->|DUSDC trade flows| EM
    AW <-->|LP requests| VAULT
    VAULT <-->|funding / settled cash| EM
    VAULT -->|LP fill via accumulator| AW
    EM -->|builder fee via accumulator| BC
```

## The binding mesh

A priced trade composes an `ExpiryMarket`, Propbook's `OracleRegistry`, the current propbook oracle objects (`PythFeed`, `BlockScholesValueStore`, `BlockScholesSVIStore`), and an account loaded from `AccountWrapper`; the protocol must guarantee they belong together:

- **Underlying approval.** Predict's `Registry`, through its `MarketManager.underlying_configs`, records each admin-approved Propbook underlying ID and deployment watermarks. This row gates which underlyings Predict will build markets on; Propbook owns source IDs, source-object discovery, and canonical source-to-underlying binding.
- **Creation-time coverage.** `create_and_share_expiry_market` takes Propbook's `&OracleRegistry` and a `propbook_underlying_id`, then asserts that Propbook currently has canonical Pyth, BS value store, and BS SVI store bindings for that underlying and deployable expiry. It snapshots the underlying ID, cadence tick size, and admission tick size (plus the deployable expiry and reference-tick source timestamp). Pairing spot, forward, and SVI to one underlying/expiry is therefore a Propbook registry claim, not a market-deployer claim.
- **Live priced-flow binding.** Every priced flow passes the current Propbook registry plus oracle objects to `pricing::load_live_pricer`, which checks the object IDs against Propbook's current canonical bindings for the market's underlying and expiry.
- **Live pricing liveness.** `pricing::load_live_pricer` rejects a live price for a market whose expiry has passed. The keeper composes `expiry_market::try_settle` before settlement-dependent consumers; it records the exact Propbook Pyth spot when available, or the exact Block Scholes minute-boundary spot after the 30-second Pyth-exclusive window, together with terminal payout liability. If both exact sources are absent, the past-expiry market remains pending settlement, standalone rebalance moves no cash, and the market cannot be live-valued.
- **Market → pool.** `create_and_share_expiry_market` registers the new expiry in `PoolVault`'s active-expiry ledger as a zero-cash accounting row. The market is not mintable until `plp::rebalance_expiry_cash` funds it from idle; the expiry never pulls from the pool itself.
- **Account → market.** Positions are keyed by `(expiry_market_id, order_id)` inside Predict account data, so an order minted by one expiry can only be redeemed against that same expiry's market. Owner auth or Predict app-auth controls who can load the account for the flow; the position key controls which market/order pair the loaded account may mutate.

`ExpiryMarket` owns market flow sequencing and state mutation; `pricing` owns the oracle-read boundary that turns Propbook objects into a live `Pricer` or an exact-history spot read; the propbook oracle objects own their stored payloads and version. This division keeps flow gates, oracle trust checks, and leaf data storage separate.

## Oracle feeds (external, in `propbook`)

The live oracle data is fully outside Predict, in standalone, Predict-unaware shared objects in the `propbook` package. Predict reads them; it owns no oracle object, writer capability, or ingest path.

- **`propbook::pyth_feed::PythFeed`** — one global source-native Pyth payload per Pyth Lazer feed ID plus exact timestamp inserts. Updated permissionlessly by anyone holding a verified `pyth_lazer::Update` (`update`); the verified update is its own provenance proof, so there is no writer cap. Predict reads `normalized_spot()` and the read's `source_timestamp_ms`, while raw source fields remain available through raw getters.
- **`propbook::block_scholes_store::BlockScholesValueStore`** — one per-underlying store of the latest BS spot and per-expiry forward observations, keyed by signed series id, plus exact minute-boundary spot history. Updated permissionlessly through a verified `bs_oracle` value batch — the batch type is the provenance proof, so there is no writer cap.
- **`propbook::block_scholes_store::BlockScholesSVIStore`** — one per-underlying store of the latest per-expiry BS SVI parameter sets, same signed-batch gating.

Propbook creates an underlying's store pair once through its registry and records it as canonical; Predict checks the stores it is handed against that binding. `pricing.move` owns all raw oracle ingress: it issues exact-history Pyth reads for reference tick and Pyth-preferred settlement, exact-history Block Scholes reads for settlement fallback, and resolves the live forward from the full feed set. Which source builds the live forward is the admin setting `use_pyth_spot_for_forward`. While it is set (the default), a present and fresh normalized Pyth spot gives `forward = pyth_spot * (bs.forward / bs.spot)`, a missing, stale, or non-positive/unrepresentable spot falls back to the normalized Block Scholes `forward` for the market expiry, and an oversized normalized Pyth spot aborts under Predict's pricing envelope. While it is clear, that Block Scholes `forward` is used on every load and the Pyth spot is read for provenance only — so the envelope's *Pyth* spot ceiling is never reached, because nothing consumes the value (the envelope's other bounds, including the same ceiling applied to the Block Scholes forward, still run on every load). BS spot and forward must be fresh under `block_scholes_price_freshness_ms`, and SVI must be fresh under the looser `block_scholes_svi_freshness_ms` — freshness, the SVI roll-down anchor, and the timestamps trade events report all key on each observation's batch-envelope time (`source_timestamp_ms`), so a republished unchanged value stays current for as long as the provider keeps publishing it; the model time stays on the stored observation as calibration identity. The stores carry their own package version and a forward-only `migrate`; Predict does **not** gate them under its version set. See [pricing and oracles](../concepts/pricing-and-oracles.md).

## The pool, NAV, and the async LP layer

LP supply and withdraw are **asynchronous**. An LP queues a request (`request_supply` with `min_plp_out` / `request_withdraw` with `min_dusdc_out`, routed through an account so a composing vault's own account — not necessarily the tx signer — is the fill recipient); the input is escrowed in one of two `RequestQueue`s on `PoolVault`, and a pending request can be cancelled for an immediate refund. A daily **flush** fills eligible queued heads at one frozen mark.

The per-expiry NAV primitive is `expiry_market::current_nav`: the **exact** live recoverable value of one expiry — free cash minus the exact live liability, floored at zero. The liability is `walk_linear` alone — the payout tree's full boundary-linear walk, `Σ quantity × P(range)`, with no per-order correction. There is no approximation and no uncertainty band; the deleted approximate-NAV matrix and its band/withdraw-fee superstructure are gone.

The flush is a transaction-local **hot potato** (`PoolValuation`), assembled in three phases over one PTB:

1. `start_pool_valuation` (started with a market-deployer `MarketLifecycleCap` proof) engages the valuation lock and snapshots the active-expiry set. PLP caps the active pre-expiry market count at market registration; expired or settled markets can also be swept independently before a flush.
2. `value_expiry` runs once per snapshotted market: it sweeps a settled market or rebalances a live market, then folds the market's NAV (`current_nav`, or 0 for a swept settled market) into the running total, proving the market is in the snapshot and valued exactly once. An expired unsettled market moves no cash and aborts when live pricing is attempted.
3. `finish_flush` proves every snapshotted market was valued, computes `pool_nav = idle + Σ current_nav` (net of the pending-protocol-profit exclusion priced from the aggregate profit basis), then `lp_book::drain` mints/burns PLP and delivers fills at that one frozen mark — supplies first, then withdrawals FIFO until idle is dry, up to the operator-supplied per-queue budgets (`supply_budget`/`withdraw_budget`, `None` = unbounded; independent so a supply backlog can't starve withdrawals). A head request whose mark or quote is non-executable is protocol-cancelled and refunded instead of aborting the flush; a live request whose frozen-mark quote misses its request-time limit is protocol-cancelled and refunded the same way at the shipped attempt count of one, so the drain moves straight on (`lp_request_limit_flush_attempts` is admin-tunable; above one such a request instead stays queued and stops that queue until its attempts are exhausted); a withdrawal whose quote is valid and limit-satisfying but exceeds idle is paid what idle covers, keeps its unfilled balance queued, and stops the withdrawal pass; a supply is likewise bounded by `max_lp_pool_value` and keeps any unfilled balance at the head. Fills and refunds are delivered to the account receive address through `balance::send_funds` and passively settled into account custody by later Account balance operations.

The flush is **privileged**, not permissionless: the hot potato can only be created by a market-deployer `MarketLifecycleCap` (the sole flush authority; the root-`AdminCap` path was removed). The cap-holder is trusted not to manipulate the live oracle before flushing — the single frozen mark prices both supply and withdraw, so it must equal true recoverable value, which `current_nav`'s exactness guarantees. Cash rebalancing and the settled-market sweep are decoupled from the potato: each is a standalone, permissionless, per-market entrypoint, because neither needs the exactly-once completeness proof. See [liquidity and NAV](../concepts/liquidity-and-nav.md).

## Settlement

Settlement is one permissionless public transition. After expiry, `try_settle` asks `pricing` for the canonical exact-history Pyth read first. If it remains unavailable at least 30 seconds after expiry, the same transition asks for the canonical Block Scholes exact spot. It passes the selected price to `StrikeExposure::record_settlement`, which records the exposure phase and exact terminal payout liability together; the event records the selected source. The market's public settlement getters delegate to the exposure, while idempotent repeat calls remain owned by `try_settle`.

`redeem_settled`, `redeem_settled_permissionless`, `plp::rebalance_expiry_cash`, and `value_expiry` do not read settlement oracles; they consume the recorded phase. Transaction builders call `try_settle` first when settlement may be due. If both exact sources are absent after expiry, standalone rebalance is a no-op and live valuation still aborts; no approximate mark is substituted because the flush uses one mark for both PLP supply and withdraw. See [decisions](./decisions.md) and [invariants](./invariants.md).

## Version gating

Package upgrades are gated by a single monotonic **version watermark** stored on `ProtocolConfig` (`version_watermark`). Every gated flow asserts `current_version!() >= protocol_config.version_watermark`; everything below the watermark is dead. `current_version!()` is an upgrade-required code constant bumped on each upgrade, and the watermark is the runtime floor.

`ProtocolConfig` is threaded into every version-gated public entrypoint, and `config.assert_version()` is its first line. There are no per-object version sets and no sync entrypoints: one central watermark replaces the former `Registry.allowed_versions` set and its `ExpiryMarket`/`PoolVault` mirrors. (`assert_trading_allowed` still omits the version check — version and trading-pause are independent gates that each public flow applies as needed.)

Raising the floor is admin-only and footgun-free: `protocol_config::bump_version_watermark` takes no target — it sets the watermark to the running `current_version!()`. Because that value is whatever package binary is executing, the floor can only ever advance to a version a published binary actually embeds; admin can never set it above the running package and brick it, and retiring old versions requires executing the bump against the upgraded package. The watermark is monotonic (it cannot be lowered), so a disabled running version is recovered by upgrading, not by lowering the floor. The setter itself, the `PauseCap` mint, both revocations, and all reads are deliberately ungated; lifecycle-cap **mint** is the exception — it is version-gated (`registry::mint_lifecycle_cap`), because granting privileged lifecycle authority under a version freeze is risky. The external propbook feeds carry their *own* version and forward-only `migrate`; Predict does not gate them.

Reversible emergency stops are separate from the watermark: `trading_paused` (global), per-expiry `mint_paused`, and the protocol-wide `frozen` (which halts the whole version-gated surface, folded into `assert_version`) — all admin-settable and `PauseCap`-forceable one-way, and all liftable by `AdminCap` without an upgrade.

## Where this leads

- Tunable values, templates, and the snapshot-at-creation model: [configuration](./configuration.md).
- Settled design decisions and what they superseded: [decisions](./decisions.md); the invariants they preserve: [invariants](./invariants.md).
- Admin powers, oracle trust, the privileged flush, and version-freeze risk: [risks](../risks.md).
- How prices are formed from the propbook feeds: [pricing and oracles](../concepts/pricing-and-oracles.md).
- How positions, fees, and the pool behave economically: [markets and positions](../concepts/markets-and-positions.md), [fees and rebates](../concepts/fees-and-rebates.md), [liquidity and NAV](../concepts/liquidity-and-nav.md).
