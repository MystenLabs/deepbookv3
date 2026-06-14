# Architecture

Predict is a per-expiry, range-based options protocol on Sui. Its on-chain state is split across a small set of long-lived shared objects, a per-trader account object with delegated capabilities, and a handful of governance and attribution capabilities. This document describes those objects, who owns which capital, the capability and authorization model, how version gating works, and the binding mesh that ties markets to their oracle feeds. It documents how the system is structured, not how to call it; for the economics, see the [concepts](../concepts/) docs, and for tunable values see [configuration](./configuration.md).

## Two principles to read this document by

Two design commitments shape everything below; both are stated once here and assumed throughout.

- **One canonical strike interpretation — absolute integer ticks.** Protocol-wide, a strike is an absolute tick from zero, with `raw_strike = tick * tick_size`. There is no second strike representation anywhere: no market-local centered grid, no boundary-relative indices. Public entrypoints and events carry a packed two-tick `range_key`; order IDs, the payout tree, and the liquidation book all key on ticks; raw strikes are recovered only at the pricing/settlement boundary. The `strike_exposure/range_codec` module is the single owner of the tick↔raw conversion. See [tick range encoding](./tick-range-encoding.md).
- **Oracle data lives outside Predict.** The live spot and volatility surface come from two standalone, Predict-unaware feeds in the separate `propbook` package. Predict holds no oracle object, no writer capability, and no price-ingest path; it reads the feeds and validates that the ones passed to a flow are the feeds its market is bound to.

## Object taxonomy

Sui distinguishes three object dispositions. Predict uses all three deliberately:

- **Shared objects** are usable by any transaction and passed by reference. Predict's protocol-wide and per-market state are shared so that any trader, LP, or keeper can interact with them.
- **Owned objects** belong to a single address and can only be used by that address's transactions. Predict's capabilities are owned objects, which is how delegated authority is granted and held.
- **Derived objects** are created at a deterministic address from a parent's `UID` plus a typed key (`derived_object::claim`). Predict derives `PredictManager` and `BuilderCode` from the registry's `UID`, so their addresses can be computed off-chain and uniqueness is enforced structurally.

The protocol is constructed at package publish: the `registry` module's `init` creates and shares the `Registry`, creates and shares the `ProtocolConfig`, and transfers a single `AdminCap` to the deployer. The `plp` module's `init` registers the PLP coin type and creates and shares the `PoolVault`. Per-expiry `ExpiryMarket` objects are created later through a registry entrypoint. The oracle feeds (`PythFeed`, `BlockScholesFeed`) are external objects created permissionlessly in the `propbook` package, not by Predict.

## Shared objects

| Object | Module | Owns / holds | Created |
| --- | --- | --- | --- |
| `Registry` | `registry` | Admin-approved Pyth-feed configs (per-feed strike tick size), expiry uniqueness index, the authoritative `allowed_versions` set, allowed `PauseCap` and `MarketLifecycleCap` IDs | package init |
| `ProtocolConfig` | `protocol_config` | All admin-tunable config structs, the `trading_paused` flag, the transaction-local valuation lock | package init |
| `PoolVault` | `plp` | Idle LP-owned DUSDC, protocol-reserve DUSDC, custody of staked DEEP, the PLP `TreasuryCap`, the per-expiry cash-flow ledger, and the two async LP request queues (supply DUSDC escrow, withdraw PLP escrow) | package init |
| `ExpiryMarket` | `expiry_market` | One expiry's trade execution, strike-exposure state (tick-keyed payout tree + liquidation book), embedded `ExpiryCash` DUSDC custody, EWMA gas-price stats, the binding to its two propbook feeds | per expiry |

The `Registry` is the protocol's index and governance anchor. It enforces one approved config row per Pyth Lazer feed ID, one `ExpiryMarket` per expiry timestamp, and holds the single authoritative `allowed_versions` set that the gated objects mirror. It does not hold runtime trading state: pool accounting lives in `PoolVault`, per-expiry risk in `ExpiryMarket`, and positions in `PredictManager`. It records *which* Pyth feeds Predict will build markets on (admin approval), but the feed objects themselves live in `propbook`.

`ProtocolConfig` is a separate shared object from `Registry`. It owns the global flow gates — `trading_paused` (blocks new risk creation) and `valuation_in_progress` (a transaction-local lock held while a full-pool NAV valuation is assembled) — and the admin-tunable config structs. Two of those are *template* configs (`StrikeExposureConfig`, `ExpiryCashConfig`): their current values are snapshotted into each new `ExpiryMarket` at creation, so changing a template affects only future expiries, not live ones. See [configuration](./configuration.md).

`ExpiryMarket` is the hot object for one expiry. It embeds `ExpiryCash` (a `store`-only component, not its own object) which holds that expiry's working DUSDC and tracks the unresolved trading-fee basis used to reserve cash for loss rebates. The market never reaches into the pool directly; cash enters only via pool-driven rebalancing and leaves only via release back to the pool or as payouts/rebates to managers. Because the oracle was extracted, this market now *also* owns the binding of itself to its propbook Pyth and Block Scholes feeds (`assert_feeds`) and its own liveness (`assert_active`, derived from its `expiry` and the clock); it stores the two feed IDs and revalidates them on every priced flow.

## DUSDC custody

DUSDC is the protocol's settlement currency and has 6 decimals. Custody is partitioned across three layers, each owned by the module responsible for it:

- **Per-trader funds** live inside each `PredictManager`'s inner `BalanceManager` (a DeepBook core object). Deposits, withdrawals, net premiums, fees, and payouts all flow through this balance.
- **Per-expiry working cash** lives in each `ExpiryMarket`'s embedded `ExpiryCash`. It must always cover the expiry's payout liability plus the unresolved rebate reserve; the market re-asserts this backing invariant after every cash movement.
- **Pool capital** lives in `PoolVault`: `idle_balance` (LP-owned DUSDC available for withdrawals and expiry funding) and `protocol_reserve_balance` (protocol-owned profit, excluded from PLP redemption). The vault also custodies all staked DEEP. DUSDC supply requests and PLP withdraw requests are escrowed in two `RequestQueue`s on the vault until the next flush drains them.

Money flows in one shape: `PoolVault.idle_balance` funds an expiry's `ExpiryCash` during cash rebalancing; traders' net premiums and fees flow from a `PredictManager` into `ExpiryCash`; payouts and rebates flow from `ExpiryCash` back into a `PredictManager`; surplus and settled cash flow from `ExpiryCash` back to `PoolVault.idle_balance`. LP supply/withdraw fills enter and leave idle at the flush and are delivered to managers through the balance accumulator. Builder fees are the one outflow that leaves this mesh entirely (see below).

## PredictManager and its capabilities

`PredictManager` is the per-trader account. It wraps an inner DeepBook `BalanceManager` for DUSDC custody and adds Predict-specific state: open positions keyed by `(expiry_market_id, order_id)`, per-expiry trading summaries (open-position count and gross cash flows used for rebate resolution), the sticky builder-code attribution, and the manager's staked-DEEP mirror (`active_stake` / `inactive_stake`, rolled forward lazily on the first interaction in a new epoch).

Authorization mirrors `BalanceManager`. There are two manager shapes, distinguished by who owns the inner `BalanceManager`:

- **Sender-owned** (`new`, derived at slot 0): the transaction sender is the inner `BalanceManager` owner and can deposit, withdraw, mint caps, and generate trade proofs directly without holding any cap.
- **Self-owned** (`new_self_owned`, derived at slot 1): the inner `BalanceManager`'s owner is set to the manager's own object-ID-as-address, which no transaction sender can ever match. The owner-direct paths are permanently unreachable, so the caps minted at construction are the only authority that will ever exist on this manager. This is for contracts (vaults, structured products) that do not want a deployer-key trust anchor. Creating one requires the `PredictApp` witness to have been authorized once on the DeepBook `Registry` via `authorize_app<PredictApp>`.

The manager exposes three delegated capabilities, all tracked in one `allow_listed` ID set so a single revoke path covers them:

| Capability | Grants | Notes |
| --- | --- | --- |
| `PredictTradeCap` | generate a `PredictTradeProof` to mint/redeem | owned object; concurrent proof generation risks equivocation, so high-frequency callers should trade as the owner |
| `PredictDepositCap` | deposit DUSDC for a non-owner | |
| `PredictWithdrawCap` | withdraw DUSDC for a non-owner | |

The inner `BalanceManager`'s own `DepositCap` and `WithdrawCap` are held inside `PredictManager` and never exposed. Every custody operation routes through them, so the inner `BalanceManager`'s owner check never fires from a Predict cap holder's call — the Predict-level cap check is the real gate.

### PredictTradeProof — ephemeral trade authorization

`PredictTradeProof` is a hot-potato proof (`has drop`, no `key`/`store`, so it cannot persist past the transaction). The manager owner generates one with `generate_proof_as_owner`, or a `PredictTradeCap` holder generates one with `generate_proof_as_trader`. It records the manager ID.

The proof is used by `mint` (which borrows it) and consumed by the live branch of `redeem` (which takes it by value). It does two things at once: it authorizes the trade for that manager (`validate_proof` aborts unless the proof's manager ID matches), and it authorizes routing the DUSDC withdraw (mint net premium + fees) and deposit (live payout) through the manager's inner caps. Because mint fees are withdrawn via the proof, the proof is required even for owner-initiated mints. `redeem` takes the proof by value; the live branch consumes it, while the settled and already-liquidated branches drop it (the proof has `drop`). `redeem_settled` takes no proof at all — settling a resolved order credits the order's own manager and any caller may run it, so it is permissionless; it aborts if asked to close a still-live order.

## Governance and attribution capabilities

| Capability | Module | Authority | Lifecycle |
| --- | --- | --- | --- |
| `AdminCap` | `admin` | global policy: all admin-tunable config, version enable/disable, mint pause/unpause, market-lifecycle caps, pause caps, per-feed strike tick size; also starts the privileged pool flush | one, minted at init, transferred to deployer (multisig) |
| `MarketLifecycleCap` | `market_lifecycle_cap` | create expiry markets (`registry::create_expiry_market`); also a second, trusted way to start the privileged pool flush (`plp::start_pool_valuation_as_deployer`) | minted and revoked by `AdminCap` against the `Registry` allowlist |
| `PauseCap` | `registry` | emergency kill switch: disable a version, force `trading_paused = true`, force per-market mint pause | minted/revoked by `AdminCap`; cannot unpause anything |
| `BuilderCode` | `builder_code` | claim accumulated builder fees | derived shared object; permanent owner |

**`AdminCap` is a dependency-leaf.** Modules that own admin-tunable state accept the `AdminCap` directly as a parameter rather than routing the mutation through `Registry`. `protocol_config` setters, `expiry_market::set_mint_paused`, and registry-owned flows all take `&AdminCap`. The cap is passed as an unused reference (`_admin_cap`); holding it is the authorization. `Registry` only owns flows that are genuinely registry-scoped: version management, `PauseCap` and `MarketLifecycleCap` lifecycle, uniqueness-indexed creation (`create_expiry_market`), per-feed tick size, and Pyth-feed approval.

**`MarketLifecycleCap` is the market-lifecycle key.** Its primary authority is creating an expiry market (`registry::create_expiry_market`); it also serves as the second, trusted holder permitted to start the pool flush (`plp::start_pool_valuation_as_deployer`). It grants no other authority. The allowlist of valid lifecycle caps lives on `Registry` — its only creation call site — where `AdminCap` mints into it (`registry::mint_lifecycle_cap`) and revokes from it (`registry::revoke_lifecycle_cap`). There is no oracle-writer capability in Predict at all: Block Scholes data is written permissionlessly into the external `propbook` feed by anyone holding a verified `Update`, so Predict mints and holds no price-writing authority.

**`PauseCap` is the emergency brake.** `AdminCap` mints `PauseCap`s into the registry's `allowed_pause_caps` set for trusted operators. A valid `PauseCap` can disable a package version, force global trading pause, or force per-market mint pause — all one-way. Unpausing always requires `AdminCap`. The pause-cap mint and the version-disable paths intentionally bypass the version gate, so the kill switch stays available even when admin has misconfigured versions.

**`BuilderCode` attributes builder fees.** It is a derived shared object claimed from the registry per `(owner, index)` pair, with a permanent owner. A `PredictManager` can set a sticky `builder_code_id`; trades then add a builder fee (bounded by a per-quantity rate cap — see [fees and rebates](../concepts/fees-and-rebates.md)) and route it to the code's address. Custody uses Sui's accumulator-address mechanism: builder fees are sent to the `BuilderCode` object's address (`balance::send_funds`), accrue against the shared `AccumulatorRoot`, and the owner later withdraws the settled funds with `claim_all_builder_fees`. This keeps builder fees out of the pool/expiry custody mesh entirely.

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

    EM -->|bound to| PF
    EM -->|bound to| BSF
    EM -.->|reads spot / surface| PF
    EM -.->|reads forward / svi| BSF

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

A trade composes four objects — an `ExpiryMarket`, its two propbook feeds (`PythFeed`, `BlockScholesFeed`), and a `PredictManager` — and the protocol must guarantee they belong together. The bindings are anchored at creation and re-checked at every use:

- **Feed approval.** `Registry.pyth_feed_configs` records each admin-approved Pyth Lazer feed ID together with the strike tick size its future markets will use. This row only gates *which* feeds Predict will build markets on; the propbook feed objects are created independently and permissionlessly in `propbook`.
- **Market → feeds.** `create_expiry_market` takes the two feed *objects* (`&PythFeed`, `&BlockScholesFeed`), reads the Pyth feed's ID off the object, checks it is approved, and stores both feed object IDs on the new `ExpiryMarket`. Pairing a Pyth spot feed and a Block Scholes surface feed to the same underlying is a creation-time trust held by the market-deployer cap. Every priced flow (`mint`, live `redeem`, `liquidate`, `current_nav`) calls `assert_feeds`, which checks the passed feed objects' IDs equal the stored pair. `pricing` is handed already-bound feeds and trusts them.
- **Market liveness.** The market owns its own liveness now that the oracle no longer carries lifecycle: `assert_active` rejects a market whose `expiry` has passed (using the clock). Settlement is stubbed (see below), so a past-expiry market is "pending settlement, unsettleable."
- **Market → pool.** `create_expiry_market` registers the new expiry in `PoolVault`'s active-expiry ledger as a zero-cash accounting row. The market is not mintable until `plp::rebalance_expiry_cash` funds it from idle; the expiry never pulls from the pool itself.
- **Manager → market.** Positions are keyed by `(expiry_market_id, order_id)` inside `PredictManager`, so an order minted by one expiry can only be redeemed against that same expiry's market and is authorized by a proof bound to that manager.

`ExpiryMarket` is the module that composes these objects, so it owns the cross-object binding checks (`assert_feeds`) and market liveness (`assert_active`); the leaf modules own only their local preconditions — `pricing` owns surface freshness and the SVI math, the propbook feeds own their own data validity and version. This division — flow gates and bindings at the composing module, local invariants at the leaf — is the protocol's general validation rule.

## Oracle feeds (external, in `propbook`)

The live oracle data is fully outside Predict, in two standalone, Predict-unaware shared objects in the `propbook` package. Predict reads them; it owns no oracle object, writer capability, or ingest path.

- **`propbook::pyth_feed::PythFeed`** — one global normalized spot per Pyth Lazer feed ID. Updated permissionlessly by anyone holding a verified `pyth_lazer::Update` (`update_from_lazer`); the verified update is its own provenance proof, so there is no writer cap. Predict reads `spot()` and `freshness_timestamp_ms()`.
- **`propbook::block_scholes_feed::BlockScholesFeed`** — one per underlying, holding a per-expiry `Table<expiry, Surface>` of `{spot, forward, SVI, timestamps}` plus a shared minute-bucket history. Because each expiry carries its own contemporaneous spot, `basis(expiry) = forward / spot` is exact. Updated permissionlessly from a verified `Update`; the feed enforces math validity at ingest (`spot > 0`, `forward > 0`, `|rho| ≤ 1` for SVI no-arbitrage, a sigma band). Predict reads `forward(expiry)`, `basis(expiry)`, `svi(expiry)`, `surface_freshness_timestamp_ms(expiry)`, and `has_expiry(expiry)`.

`pricing.move` resolves the live forward from these two feeds: if Pyth spot is fresh, `forward = pyth.spot() * bs.basis(expiry)`; otherwise it falls back to `bs.forward(expiry)`. A stale Pyth spot is a *fallback*, not an abort. The Block Scholes surface (basis + forward + SVI, written together as one row) must be fresh either way — a stale surface is the hard abort `EBlockScholesSurfaceStale`. `pricing` owns only surface freshness and the SVI binary-pricing math; feed binding and market liveness are the market's, as above. The feeds carry their own package version and a forward-only `migrate`; Predict does **not** gate them under its version set. See [pricing and oracles](../concepts/pricing-and-oracles.md).

## The pool, NAV, and the async LP layer

LP supply and withdraw are **asynchronous**. An LP queues a request (`request_supply` / `request_withdraw`, routed through a `PredictManager` so a composing vault's own manager — not the tx signer — is the fill recipient); the input is escrowed in one of two `RequestQueue`s on `PoolVault`, and a pending request can be cancelled for an immediate refund. A daily **flush** drains both queues at one frozen mark.

The per-expiry NAV primitive is `expiry_market::current_nav`: the **exact** live recoverable value of one expiry — free cash minus the exact per-order live liability, floored at zero. The liability is `walk_linear` (the payout tree's full linear walk, `Σ qty·P`) minus `correction_value` (the leveraged-book floor-correction scan), so an underwater leveraged order nets to zero with no liquidation pass needed. There is no approximation and no uncertainty band; the deleted approximate-NAV matrix and its band/withdraw-fee superstructure are gone.

The flush is a transaction-local **hot potato** (`PoolValuation`), assembled in three phases over one PTB:

1. `start_pool_valuation` (or `start_pool_valuation_as_deployer`) engages the valuation lock and snapshots the active-expiry set.
2. `value_expiry` runs once per snapshotted market: it rebalances that market's cash, then folds the market's NAV (`current_nav`, or 0 for a swept settled market) into the running total, proving the market is in the snapshot and valued exactly once.
3. `finish_flush` proves every snapshotted market was valued, computes `pool_nav = idle + Σ current_nav` (net of the pending-protocol-profit exclusion priced from the aggregate profit basis), then `drain_lp_requests` mints/burns PLP and delivers fills at that one frozen mark — supplies first, then withdrawals FIFO until idle is dry, at most 100 requests per flush, with per-request failure isolation (a degenerate request is refunded rather than aborting the flush). Fills are delivered to each manager through the balance accumulator (`balance::send_funds`), which the manager absorbs lazily on its next capital op.

The flush is **privileged**, not permissionless: the hot potato can only be created by the operator `AdminCap` or a market-deployer `MarketLifecycleCap`. Both cap-holders are trusted not to manipulate the live oracle before flushing — the single frozen mark prices both supply and withdraw, so it must equal true recoverable value, which `current_nav`'s exactness guarantees. Cash rebalancing, the settled-market sweep, and liquidation are decoupled from the potato: each is a standalone, permissionless, per-market entrypoint, because none needs the exactly-once completeness proof. See [liquidity and NAV](../concepts/liquidity-and-nav.md).

## Settlement (deferred to settlement-v2)

Settlement is currently **stubbed**: `expiry_market::is_settled()` always returns `false` and `settlement_price()` aborts `ENotImplemented`. The settled-redeem and settled-sweep paths remain in the code, gated on `is_settled()`, and are therefore unreachable under the stub; they are kept for settlement-v2, which will read the terminal price from the propbook feeds' minute history.

A consequence to know: because no market ever settles, a market that crosses its expiry is never swept off the active set, and `value_expiry → current_nav → assert_active` then aborts, bricking the flush pool-wide. Until settlement-v2, the operator must not let an active market cross its expiry across a flush — create only far-dated markets. This is a documented, deferred flush-liveness precondition, not a bug; settlement-v2 restores the sweep that drops settled markets. See [decisions](./decisions.md) and [invariants](./invariants.md).

## Version gating

Package upgrades are gated by a single authoritative set, `Registry.allowed_versions`, which lists the package versions permitted to mutate state. At publish it contains the current version; admin adds versions with `enable_version` and removes them with `disable_version`, which refuses to leave the set empty.

Because Sui shared objects are read and mutated independently, each gated Predict shared object — `ExpiryMarket` and `PoolVault` — carries its own mirror of `allowed_versions`. The mirror is refreshed permissionlessly: the registry exposes one `sync_*` entry per gated object type (`sync_expiry_market_allowed_versions`, `sync_pool_vault_allowed_versions`) that copies the registry's current set into the target. The underlying `set_allowed_versions` setters are package-internal and reachable only through those sync entries, so a user cannot inject an arbitrary version set into a mirror. Every mutating flow asserts the running package version is in its object's mirror before mutating; `ProtocolConfig.assert_trading_allowed` deliberately omits the version check, leaving it to each per-object flow that already mirrors the set. Version management itself (enable/disable, including the `PauseCap` disable) bypasses the gate so admin can always recover from a disabled state. The external propbook feeds carry their *own* version and forward-only `migrate`; Predict does not gate them, so there is no oracle/Pyth-source version sync. See [versioning and loaders](./versioning-and-loaders.md).

A `PauseCap` can disable a version one-way, which is the fastest kill switch: disabling the active version halts every gated flow at once until admin re-enables a version.

## Where this leads

- Tunable values, templates, and the snapshot-at-creation model: [configuration](./configuration.md).
- The one canonical tick strike encoding: [tick range encoding](./tick-range-encoding.md).
- Settled design decisions and what they superseded: [decisions](./decisions.md); the invariants they preserve: [invariants](./invariants.md).
- Version gating, loaders, and the dropped oracle version syncs: [versioning and loaders](./versioning-and-loaders.md).
- Admin powers, oracle trust, the privileged flush, and version-disable risk: [risks](../risks.md).
- How prices are formed from the propbook feeds: [pricing and oracles](../concepts/pricing-and-oracles.md).
- How positions, fees, and the pool behave economically: [markets and positions](../concepts/markets-and-positions.md), [fees and rebates](../concepts/fees-and-rebates.md), [liquidity and NAV](../concepts/liquidity-and-nav.md).
