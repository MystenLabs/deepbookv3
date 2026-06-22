# Architecture

Predict is a per-expiry, range-based options protocol on Sui. Its on-chain state is split across a small set of long-lived shared objects, a per-trader account object with delegated capabilities, and a handful of governance and attribution capabilities. This document describes those objects, who owns which capital, the capability and authorization model, how version gating works, and the binding mesh that ties markets to Propbook underlyings and oracle feeds. It documents how the system is structured, not how to call it; for the economics, see the [concepts](../concepts/) docs, and for tunable values see [configuration](./configuration.md).

## Two principles to read this document by

Two design commitments shape everything below; both are stated once here and assumed throughout.

- **One canonical strike interpretation — absolute integer ticks.** Protocol-wide, a strike is an absolute tick from zero, with `raw_strike = tick * tick_size`. There is no second strike representation anywhere: no market-local centered grid, no boundary-relative indices. Public entrypoints and events carry the tick pair `(lower_tick, higher_tick)` directly; order IDs, the payout tree, and the liquidation book all key on ticks (the order ID is the only packed form); raw strikes are recovered only at the pricing/settlement boundary. The `strike_exposure/range_codec` module is the single owner of the tick↔raw conversion.
- **Oracle data lives outside Predict.** The live spot and volatility surface come from two standalone, Predict-unaware feeds in the separate `propbook` package. Predict holds no oracle object, no writer capability, and no price-ingest path; it stores a Propbook underlying ID and validates passed feeds against Propbook's current canonical binding when live pricing runs.

## Object taxonomy

Sui distinguishes three object dispositions. Predict uses all three deliberately:

- **Shared objects** are usable by any transaction and passed by reference. Predict's protocol-wide and per-market state are shared so that any trader, LP, or keeper can interact with them.
- **Owned objects** belong to a single address and can only be used by that address's transactions. Predict's capabilities are owned objects, which is how delegated authority is granted and held.
- **Derived objects** are created at a deterministic address from a parent's `UID` plus a typed key (`derived_object::claim`). Predict derives `PredictManager` and `BuilderCode` from the registry's `UID`, so their addresses can be computed off-chain and uniqueness is enforced structurally.

The protocol is constructed at package publish: the `registry` module's `init` creates and shares the `Registry`, creates and shares the `ProtocolConfig`, and transfers a single `AdminCap` to the deployer. The `plp` module's `init` registers the PLP coin type and creates and shares the `PoolVault`. Per-expiry `ExpiryMarket` objects are created later through a registry entrypoint. The oracle feeds (`PythFeed`, `BlockScholesFeed`) are external objects created permissionlessly in the `propbook` package, not by Predict.

## Shared objects

| Object | Module | Owns / holds | Created |
| --- | --- | --- | --- |
| `Registry` | `registry` | Admin-approved Propbook underlyings, cadence deployment configs, expiry uniqueness index, allowed `PauseCap` and `MarketLifecycleCap` IDs | package init |
| `ProtocolConfig` | `protocol_config` | All admin-tunable config structs, the `trading_paused` flag, the monotonic version watermark, the transaction-local valuation lock | package init |
| `PoolVault` | `plp` | Idle LP-owned DUSDC, protocol-reserve DUSDC, custody of staked DEEP, the PLP `TreasuryCap`, the per-expiry cash-flow ledger, and the two async LP request queues (supply DUSDC escrow, withdraw PLP escrow) | package init |
| `ExpiryMarket` | `expiry_market` | One expiry's trade execution, strike-exposure state (tick-keyed payout tree + liquidation book), embedded `ExpiryCash` DUSDC custody, EWMA gas-price stats, Propbook underlying ID, tick size | per underlying and expiry |

The `Registry` is the protocol's index and governance anchor. It enforces one approved config row per Propbook underlying ID and one `ExpiryMarket` per `(propbook_underlying_id, expiry)` pair (the version watermark lives on `ProtocolConfig`, not here). It does not hold runtime trading state: pool accounting lives in `PoolVault`, per-expiry risk in `ExpiryMarket`, and positions in `PredictManager`. It records which Propbook underlyings Predict will build markets on and the cadence deployment policies used to create them; source IDs and canonical oracle object IDs live in `propbook`.

`ProtocolConfig` is a separate shared object from `Registry`. It owns the global flow gates — `trading_paused` (blocks new risk creation) and `valuation_in_progress` (a transaction-local lock held while a full-pool NAV valuation is assembled) — and the admin-tunable config structs. Two of those are *template* configs (`StrikeExposureConfig`, `ExpiryCashConfig`): their current values are snapshotted into each new `ExpiryMarket` at creation, so changing a template affects only future expiries, not live ones. See [configuration](./configuration.md).

`ExpiryMarket` is the hot object for one expiry. It embeds `ExpiryCash` (a `store`-only component, not its own object) which holds that expiry's working DUSDC and tracks the unresolved trading-fee basis used to reserve cash for loss rebates. The market never reaches into the pool directly; cash enters only via pool-driven rebalancing and leaves only via release back to the pool or as payouts/rebates to managers. Because the oracle was extracted, the market stores only the Propbook underlying ID; `pricing::load_live_pricer` validates the passed feed objects against Propbook's current canonical binding before a live price reaches exposure logic.

## DUSDC custody

DUSDC is the protocol's settlement currency and has 6 decimals. Custody is partitioned across three layers, each owned by the module responsible for it:

- **Per-trader funds** live inside each `PredictManager`'s inner `BalanceManager` (a DeepBook core object). Deposits, withdrawals, net premiums, fees, and payouts all flow through this balance.
- **Per-expiry working cash** lives in each `ExpiryMarket`'s embedded `ExpiryCash`. It must always cover the expiry's payout liability plus the unresolved rebate reserve; the market re-asserts this backing invariant after every cash movement.
- **Pool capital** lives in `PoolVault`: `idle_balance` (LP-owned DUSDC available for withdrawals and expiry funding) and `protocol_reserve_balance` (protocol-owned profit, excluded from PLP redemption). The vault also custodies all staked DEEP. DUSDC supply requests and PLP withdraw requests are escrowed in two `RequestQueue`s on the vault — pulled from the requesting manager's internal custody under its `PredictWithdrawCap` — until the next flush drains them.

Money flows in one shape: `PoolVault.idle_balance` funds an expiry's `ExpiryCash` during cash rebalancing; traders' net premiums and fees flow from account custody into `ExpiryCash`; payouts and rebates flow from `ExpiryCash` back into account custody; surplus and settled cash flow from `ExpiryCash` back to `PoolVault.idle_balance`. LP supply/withdraw fills enter and leave idle at the flush and are delivered to account receive addresses. Builder fees are the one outflow that leaves this mesh entirely (see below).

## PredictManager and its capabilities

`PredictManager` is the per-trader account. It wraps an inner DeepBook `BalanceManager` for DUSDC custody and adds Predict-specific state: open positions keyed by `(expiry_market_id, order_id)`, per-expiry trading summaries (open-position count and gross cash flows used for rebate resolution), the sticky builder-code attribution, and the manager's staked-DEEP mirror (`active_stake` / `inactive_stake`, rolled forward lazily on the first interaction in a new epoch).

Authorization mirrors `BalanceManager`. There are two manager shapes, distinguished by who owns the inner `BalanceManager`:

- **Sender-owned** (`new`, derived at slot 0): the transaction sender is the inner `BalanceManager` owner and can mint caps and generate trade proofs directly without holding any cap. Capital movement itself — deposit and withdraw — always goes through a `PredictDepositCap` / `PredictWithdrawCap`; the owner simply mints one for itself.
- **Self-owned** (`new_self_owned`, derived at slot 1): the inner `BalanceManager`'s owner is set to the manager's own object-ID-as-address, which no transaction sender can ever match. The owner-direct paths are permanently unreachable, so the caps minted at construction are the only authority that will ever exist on this manager. This is for contracts (vaults, structured products) that do not want a deployer-key trust anchor. Creating one requires the `PredictApp` witness to have been authorized once on the DeepBook `Registry` via `authorize_app<PredictApp>`.

The manager exposes three capabilities, all tracked in one `allow_listed` ID set so a single revoke path covers them. Capability is split by concern: the trade cap gates *trading*, the deposit/withdraw caps gate *capital movement*. A trade proof is deliberately never accepted for a standalone withdraw — it routes a trade's funds to the protocol, never to the caller, so gating capital-out with it would let a trade-only delegate drain the manager.

| Capability | Grants | Notes |
| --- | --- | --- |
| `PredictTradeCap` | generate a `PredictTradeProof` to mint/redeem | owned object; concurrent proof generation risks equivocation, so high-frequency callers should trade as the owner |
| `PredictDepositCap` | deposit `DUSDC` or `PLP` into the manager | required for every deposit, owner included |
| `PredictWithdrawCap` | withdraw `DUSDC` or `PLP`; also queue and cancel LP supply/withdraw requests | the sole capital-out authority |

The inner `BalanceManager`'s own `DepositCap` and `WithdrawCap` are held inside `PredictManager` and never exposed. Every custody operation routes through them, so the inner `BalanceManager`'s owner check never fires from a Predict cap holder's call — the Predict-level cap check is the real gate.

**Capital ops settle first (ambient accumulator).** Account coin reads and writes
first sweep funds delivered to the account receive address (`balance::send_funds`)
into stored account custody, then proceed. Predict threads `AccumulatorRoot` and
`Clock` through trade and PLP entrypoints so Account can do that settlement at the
custody boundary. Builder fees remain an explicit claim flow because the builder
code owner claiming accumulated rewards is the domain action.

### PredictTradeProof — ephemeral trade authorization

`PredictTradeProof` is a hot-potato proof (`has drop`, no `key`/`store`, so it cannot persist past the transaction). The manager owner generates one with `generate_proof_as_owner`, or a `PredictTradeCap` holder generates one with `generate_proof_as_trader`. It records the manager ID.

The proof is used by `mint` (which borrows it) and consumed by the live branch of `redeem` (which takes it by value). It does two things at once: it authorizes the trade for that manager (`validate_proof` aborts unless the proof's manager ID matches), and it authorizes routing the DUSDC withdraw (mint net premium + fees) and deposit (live payout) through the manager's inner caps. Because mint fees are withdrawn via the proof, the proof is required even for owner-initiated mints. `redeem` takes the proof by value; the live branch consumes it, while the settled and already-liquidated branches drop it (the proof has `drop`). `redeem_settled` takes no proof at all — settling a resolved order credits the order's own manager and any caller may run it, so it is permissionless; it aborts if asked to close a still-live order.

## Governance and attribution capabilities

| Capability | Module | Authority | Lifecycle |
| --- | --- | --- | --- |
| `AdminCap` | `admin` | global policy: all admin-tunable config, version enable/disable, mint pause/unpause, market-lifecycle caps, pause caps, underlying approval, cadence deployment configs; also genesis-bootstraps the pool (`plp::lock_capital`) | one, minted at init, transferred to deployer (multisig) |
| `MarketLifecycleCap` | `market_lifecycle_cap` | create expiry markets (`registry::create_expiry_market`); also the **sole** authority to start the privileged pool flush (`plp::start_pool_valuation`) | minted and revoked by `AdminCap` against the `Registry` allowlist |
| `PauseCap` | `registry` | emergency kill switch: disable a version, force `trading_paused = true`, force per-market mint pause | minted/revoked by `AdminCap`; cannot unpause anything |
| `BuilderCode` | `builder_code` | builder-fee attribution identity | derived shared object; permanent owner |

**`AdminCap` is a dependency-leaf.** Modules that own admin-tunable state accept the `AdminCap` directly as a parameter rather than routing the mutation through `Registry`. `protocol_config` setters, `expiry_market::set_mint_paused`, and registry-owned flows all take `&AdminCap`. The cap is passed as an unused reference (`_admin_cap`); holding it is the authorization. `Registry` only owns flows that are genuinely registry-scoped: version management, `PauseCap` and `MarketLifecycleCap` lifecycle, uniqueness-indexed creation (`create_expiry_market`), Propbook underlying admission, and cadence deployment policy.

**`MarketLifecycleCap` is the market-lifecycle key.** Its primary authority is creating an expiry market (`registry::create_expiry_market`); it is also the sole holder permitted to start the pool flush (`plp::start_pool_valuation`) — the root-`AdminCap` flush path was removed, and admin retains a break-glass route by minting itself a lifecycle cap. It grants no other authority. The allowlist of valid lifecycle caps lives on `Registry` — its only creation call site — where `AdminCap` mints into it (`registry::mint_lifecycle_cap`) and revokes from it (`registry::revoke_lifecycle_cap`). There is no oracle-writer capability in Predict at all: Block Scholes data is written permissionlessly into the external `propbook` feed by anyone holding a verified `Update`, so Predict mints and holds no price-writing authority.

**`PauseCap` is the emergency brake.** `AdminCap` mints `PauseCap`s into the registry's `allowed_pause_caps` set for trusted operators. A valid `PauseCap` can disable a package version, force global trading pause, or force per-market mint pause — all one-way. Unpausing always requires `AdminCap`. The pause-cap mint and the version-disable paths intentionally bypass the version gate, so the kill switch stays available even when admin has misconfigured versions.

**`BuilderCode` attributes builder fees.** It is a derived shared object claimed from the registry per `(owner, index)` pair, with a permanent owner. A Predict account can set a sticky `builder_code_id`; trades then add a builder fee (bounded by a per-quantity rate cap — see [fees and rebates](../concepts/fees-and-rebates.md)) and route it to the code's address. The owner claims accumulated builder fees explicitly with `claim_all_builder_fees`. This keeps builder fees out of the pool/expiry custody mesh entirely.

## Capability and ownership diagram

```mermaid
graph TD
    subgraph Shared
        REG[Registry]
        CFG[ProtocolConfig]
        VAULT[PoolVault<br/>idle + reserve DUSDC,<br/>staked DEEP, PLP cap,<br/>LP request queues]
        EM[ExpiryMarket<br/>embeds ExpiryCash DUSDC]
        BC[BuilderCode]
    end

    subgraph propbook (external oracle package)
        OR[OracleRegistry<br/>canonical bindings]
        PF[PythFeed<br/>global spot]
        BSF[BlockScholesFeed<br/>per-expiry surface]
    end

    subgraph Owned caps
        ADMIN[AdminCap]
        PAUSE[PauseCap]
        MOLC[MarketLifecycleCap]
    end

    subgraph Per-trader
        PM[PredictManager<br/>inner BalanceManager DUSDC]
        TC[PredictTradeCap]
        DC[PredictDepositCap]
        WC[PredictWithdrawCap]
    end

    REG -. derives .-> PM
    REG -. derives .-> BC
    REG -->|one market per expiry| EM

    OR -->|canonical Pyth| PF
    OR -->|canonical BS| BSF
    EM -.->|stores underlying id| OR
    EM -.->|live pricing reads| PF
    EM -.->|live pricing reads| BSF

    ADMIN --> CFG
    ADMIN --> REG
    ADMIN -->|mints into registry allowlist| MOLC
    ADMIN --> PAUSE
    ADMIN -->|starts pool flush| VAULT
    MOLC -->|creates markets| REG
    MOLC -->|starts pool flush| VAULT
    PAUSE -->|one-way pause| CFG
    PAUSE -->|disable version| REG

    PM --> TC
    PM --> DC
    PM --> WC
    TC -->|proof authorizes| EM
    EM <-->|DUSDC flows| PM
    VAULT <-->|funding / settled cash| EM
    VAULT -->|LP fill via accumulator| PM
    EM -->|builder fee via accumulator| BC
```

## The binding mesh

A trade composes five objects — an `ExpiryMarket`, Propbook's `OracleRegistry`, the two propbook feeds (`PythFeed`, `BlockScholesFeed`), and a `PredictManager` — and the protocol must guarantee they belong together:

- **Underlying approval.** Predict `Registry.underlying_configs` records each admin-approved Propbook underlying ID and deployment watermarks. This row gates which underlyings Predict will build markets on; Propbook owns source IDs, source-object discovery, and canonical source-to-underlying binding.
- **Creation-time coverage.** `create_expiry_market` takes Propbook's `&OracleRegistry` and a `propbook_underlying_id`, then asserts that Propbook currently has both canonical Pyth and Block Scholes bindings for that underlying. It snapshots only the underlying ID and cadence tick size. Pairing spot and surface to one underlying is therefore a Propbook registry claim, not a market-deployer claim.
- **Live priced-flow binding.** Every priced flow passes the current Propbook registry plus feed objects to `pricing::load_live_pricer`, which checks the feed object IDs against Propbook's current canonical binding for the market's underlying. A Propbook rebind affects existing markets on the next priced flow.
- **Live pricing liveness.** `pricing::load_live_pricer` rejects a live price for a market whose expiry has passed. Flows that can take a settled branch first call `expiry_market::ensure_settled`, which passively records the exact Propbook Pyth spot at expiry when available; if exact data is still absent, the past-expiry market remains pending settlement and cannot be live-valued.
- **Market → pool.** `create_expiry_market` registers the new expiry in `PoolVault`'s active-expiry ledger as a zero-cash accounting row. The market is not mintable until `plp::rebalance_expiry_cash` funds it from idle; the expiry never pulls from the pool itself.
- **Manager → market.** Positions are keyed by `(expiry_market_id, order_id)` inside `PredictManager`, so an order minted by one expiry can only be redeemed against that same expiry's market and is authorized by a proof bound to that manager.

`ExpiryMarket` owns market flow sequencing and state mutation; `pricing` owns the live oracle-read boundary that turns Propbook objects into a value-typed `Pricer`; the propbook feeds own their source payloads and version. This division keeps flow gates, oracle trust checks, and leaf data storage separate.

## Oracle feeds (external, in `propbook`)

The live oracle data is fully outside Predict, in two standalone, Predict-unaware shared objects in the `propbook` package. Predict reads them; it owns no oracle object, writer capability, or ingest path.

- **`propbook::pyth_feed::PythFeed`** — one global source-native Pyth payload per Pyth Lazer feed ID plus exact timestamp inserts. Updated permissionlessly by anyone holding a verified `pyth_lazer::Update` (`update`); the verified update is its own provenance proof, so there is no writer cap. Predict reads `normalized_spot()` and the read's `source_timestamp_ms`, while raw source fields remain available through raw getters.
- **`propbook::block_scholes_feed::BlockScholesFeed`** — one per source ID, holding per-expiry raw `{spot, forward, SVI}` observations plus exact timestamp inserts. Because each expiry carries its own contemporaneous spot, `basis = forward / spot` is exact when Predict computes it. Updated permissionlessly from a verified `Update`; the feed stores source-native facts and Predict applies its pricing-safe envelope at read time. Predict reads `normalized_surface(expiry)`, the surface getters, and the read's `source_timestamp_ms`.

`pricing.move` resolves the live forward from these two feeds: if the normalized Pyth spot is present and fresh, `forward = pyth_spot * (bs.forward / bs.spot)`; otherwise it falls back to the normalized Block Scholes `forward`. Missing, stale, or non-positive/unrepresentable Pyth spot is a fallback; an oversized normalized Pyth spot still aborts under Predict's pricing envelope. The Block Scholes surface (spot + forward + SVI, written together as one row) must be fresh either way — a stale or missing surface is the hard abort `EBlockScholesSurfaceStale`. `pricing` owns current Propbook binding, pre-expiry live-pricing liveness, surface freshness, the pricing-safe envelope, and the SVI binary-pricing math. The feeds carry their own package version and a forward-only `migrate`; Predict does **not** gate them under its version set. See [pricing and oracles](../concepts/pricing-and-oracles.md).

## The pool, NAV, and the async LP layer

LP supply and withdraw are **asynchronous**. An LP queues a request (`request_supply` / `request_withdraw`, routed through a `PredictManager` so a composing vault's own manager — not the tx signer — is the fill recipient); the input is escrowed in one of two `RequestQueue`s on `PoolVault`, and a pending request can be cancelled for an immediate refund. A daily **flush** drains both queues at one frozen mark.

The per-expiry NAV primitive is `expiry_market::current_nav`: the **exact** live recoverable value of one expiry — free cash minus the exact per-order live liability, floored at zero. The liability is `walk_linear` (the payout tree's full linear walk, `Σ qty·P`) minus `correction_value` (the leveraged-book floor-correction scan), so an underwater leveraged order nets to zero with no liquidation pass needed. There is no approximation and no uncertainty band; the deleted approximate-NAV matrix and its band/withdraw-fee superstructure are gone.

The flush is a transaction-local **hot potato** (`PoolValuation`), assembled in three phases over one PTB:

1. `start_pool_valuation` (started with a market-deployer `MarketLifecycleCap` proof) engages the valuation lock and snapshots the active-expiry set.
2. `value_expiry` runs once per snapshotted market: it rebalances that market's cash, then folds the market's NAV (`current_nav`, or 0 for a swept settled market) into the running total, proving the market is in the snapshot and valued exactly once.
3. `finish_flush` proves every snapshotted market was valued, computes `pool_nav = idle + Σ current_nav` (net of the pending-protocol-profit exclusion priced from the aggregate profit basis), then `drain_lp_requests` mints/burns PLP and delivers fills at that one frozen mark — supplies first, then withdrawals FIFO until idle is dry, up to the operator-supplied per-queue budgets (`supply_budget`/`withdraw_budget`, `None` = drain fully; independent so a supply backlog can't starve withdrawals), with per-request failure isolation (a degenerate request is refunded rather than aborting the flush). Fills are delivered to the account receive address through `balance::send_funds` and passively settled into account custody by later Account balance operations.

The flush is **privileged**, not permissionless: the hot potato can only be created by a market-deployer `MarketLifecycleCap` (the sole flush authority; the root-`AdminCap` path was removed). The cap-holder is trusted not to manipulate the live oracle before flushing — the single frozen mark prices both supply and withdraw, so it must equal true recoverable value, which `current_nav`'s exactness guarantees. Cash rebalancing, the settled-market sweep, and liquidation are decoupled from the potato: each is a standalone, permissionless, per-market entrypoint, because none needs the exactly-once completeness proof. See [liquidity and NAV](../concepts/liquidity-and-nav.md).

## Settlement

Settlement is passive and internal to normal flows. `ExpiryMarket` stores `settlement_price: Option<u64>`. The package-level `ensure_settled` helper is the single branch gate: if the market is past expiry, it validates the supplied `PythFeed` against Propbook's current canonical binding for the market's underlying, reads `normalized_spot_at(expiry)`, records the price if present, and returns whether the market is settled.

There is deliberately no standalone public settle entrypoint. `redeem` / `redeem_settled` and `plp::rebalance_expiry_cash` / `value_expiry` call `ensure_settled` immediately before choosing settled vs live behavior. If exact timestamp data is absent after expiry, live valuation still aborts; no approximate mark is substituted because the flush uses one mark for both PLP supply and withdraw. Once settlement is recorded, settled redeem and the settled-market sweep use the existing materialization flow. See [decisions](./decisions.md) and [invariants](./invariants.md).

## Version gating

Package upgrades are gated by a single monotonic **version watermark** stored on `ProtocolConfig` (`version_watermark`). Every gated flow asserts `current_version!() >= protocol_config.version_watermark`; everything below the watermark is dead. `current_version!()` is an upgrade-required code constant bumped on each upgrade, and the watermark is the runtime floor.

`ProtocolConfig` is threaded into every version-gated public entrypoint, and `config.assert_version()` is its first line. There are no per-object version sets and no sync entrypoints: one central watermark replaces the former `Registry.allowed_versions` set and its `ExpiryMarket`/`PoolVault` mirrors. (`assert_trading_allowed` still omits the version check — version and trading-pause are independent gates that each public flow applies as needed.)

Raising the floor is admin-only and footgun-free: `protocol_config::bump_version_watermark` takes no target — it sets the watermark to the running `current_version!()`. Because that value is whatever package binary is executing, the floor can only ever advance to a version a published binary actually embeds; admin can never set it above the running package and brick it, and retiring old versions requires executing the bump against the upgraded package. The watermark is monotonic (it cannot be lowered), so a disabled running version is recovered by upgrading, not by lowering the floor. The setter itself, the `PauseCap` / `MarketLifecycleCap` mint-and-revoke entries, and all reads are deliberately ungated. The external propbook feeds carry their *own* version and forward-only `migrate`; Predict does not gate them.

Reversible emergency stops are separate from the watermark: `trading_paused` (global) and per-expiry `mint_paused`, both admin-settable and `PauseCap`-forceable one-way.

## Where this leads

- Tunable values, templates, and the snapshot-at-creation model: [configuration](./configuration.md).
- Settled design decisions and what they superseded: [decisions](./decisions.md); the invariants they preserve: [invariants](./invariants.md).
- Admin powers, oracle trust, the privileged flush, and version-disable risk: [risks](../risks.md).
- How prices are formed from the propbook feeds: [pricing and oracles](../concepts/pricing-and-oracles.md).
- How positions, fees, and the pool behave economically: [markets and positions](../concepts/markets-and-positions.md), [fees and rebates](../concepts/fees-and-rebates.md), [liquidity and NAV](../concepts/liquidity-and-nav.md).
