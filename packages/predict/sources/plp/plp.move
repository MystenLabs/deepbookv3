// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault.
///
/// PoolVault owns the PLP treasury cap, idle
/// DUSDC, the protocol reserve, sponsor-funded fee incentives, per-expiry cash
/// accounting, and the queued LP supply/withdraw requests. It coordinates the
/// full-pool NAV valuation — an atomic oracle snapshot followed by resumable
/// per-market valuation transactions, with trading live throughout (see
/// `PoolValuation`) — and the unified per-market cash flow (initial funding, live
/// rebalance/sweep, and settled-market sweep with terminal profit
/// materialization). LPs queue supply/withdraw requests routed through a loaded
/// Account; each flush (`finish_flush`) drains the requests that predate its
/// snapshot at the frozen pool NAV, minting/burning PLP and delivering fills to
/// each account via the balance accumulator.
module deepbook_predict::plp;

use account::account::{AccountWrapper, Auth};
use deepbook_predict::{
    admin::AdminCap,
    constants,
    expiry_market::ExpiryMarket,
    lp_book::{Self, LpBook},
    market_lifecycle_cap::MarketLifecycleProof,
    pool_accounting::{Self, Ledger},
    pricing::Pricer,
    protocol_config::ProtocolConfig,
    vault_events
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::{
    accumulator::AccumulatorRoot,
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::{Self, MetadataCap},
    vec_map::{Self, VecMap}
};

const EExpiryMarketAlreadyValued: u64 = 0;
const EMissingExpiryValuation: u64 = 1;
const ENotBootstrapped: u64 = 2;
const EAlreadyBootstrapped: u64 = 3;
const EBelowMinBootstrapLiquidity: u64 = 4;
const EBelowMinFeeIncentiveSponsorship: u64 = 5;
const EMaxLiveExpiryMarketsExceeded: u64 = 6;
const EValuationSnapshotNotSealed: u64 = 7;
const EExpiryPricerAlreadySnapshotted: u64 = 8;
const EIncompleteValuationSnapshot: u64 = 9;
const EExpiredMarketNotSettled: u64 = 10;
const EValuationDeadlineNotReached: u64 = 11;
const ENotValuationStarter: u64 = 12;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Transaction-local proof that the snapshot stage is still open.
///
/// `start_pool_valuation` mints one, every `snapshot_expiry_pricer` borrows it,
/// and `seal_valuation_snapshot` consumes it. It has no abilities, so it cannot
/// be stored, transferred, or dropped — which makes "the whole snapshot stage
/// runs in ONE transaction" a property of the type system rather than a keeper
/// convention. That atomicity is the entire correctness argument for the frozen
/// mark: it is what makes every market's `Pricer` load at the same instant, so
/// the valuation stage can then span as many transactions as it needs (audit
/// L10).
///
/// It also scopes the stage to whoever started the flush: `snapshot_expiry_pricer`
/// and `seal_valuation_snapshot` are otherwise permissionless, and a snapshot
/// taken outside the starter's transaction could pick its own oracle instant per
/// market.
public struct SnapshotStage {}

/// Pool-level vault state.
public struct PoolVault has key {
    id: UID,
    /// Protocol-owned DUSDC excluded from PLP redemption. No package entrypoint
    /// withdraws this balance.
    protocol_reserve_balance: Balance<DUSDC>,
    /// Sponsor-funded DUSDC reserved for taker fee sponsorship, excluded from PLP NAV.
    fee_incentive_reserve: Balance<DUSDC>,
    /// PLP share issuance plus queued supply/withdraw escrow.
    lp: LpBook<PLP>,
    /// Idle DUSDC custody, registered expiries, and per-expiry cash-flow rows.
    expiry_accounting: Ledger,
    /// In-flight full-pool valuation, held across transactions. `Some` exactly
    /// while the `ProtocolConfig` valuation flag is engaged.
    valuation: Option<PoolValuation>,
}

/// Full-pool NAV valuation carried across transactions.
///
/// The flush runs in three stages. **Snapshot (one atomic PTB):**
/// `start_pool_valuation` records the active expiry set and each LP queue's
/// eligibility cutoff, then one `snapshot_expiry_pricer` per market freezes that
/// market's oracle state and stamps the market, and `seal_valuation_snapshot`
/// proves the set is complete. Every `Pricer` is therefore loaded at a single
/// instant, which is what keeps the pool mark exact (audit L10) once valuation
/// spans transactions. **Valuation (resumable):** each `value_expiry` folds one
/// market's snapshot-instant NAV into `total_nav` exactly once, pricing against
/// its frozen `Pricer` over the cash values and payout-tree shadows captured at
/// the snapshot instant (a swept settled market contributes 0). **Finish:**
/// `finish_flush` proves every snapshotted market was valued, prices the pool
/// NAV, and drains the LP queues against it up to the recorded cutoffs.
///
/// Trading is never gated on the flush: a not-yet-valued market's snapshot state
/// is captured — cash eagerly on its stamp, tree boundaries lazily in its nodes
/// — so post-snapshot trades cannot reach the figure being valued, and trades in
/// an already-valued market are invisible to a figure that already exists — both
/// are exactly as-of-snapshot semantics. Splitting the
/// stages is what removes C-1's ceiling: only `value_expiry` walks payout trees
/// (one dynamic-field child per distinct strike tick), and it carries just one
/// market's nodes per transaction under Sui's 1,000-cached-object limit.
public struct PoolValuation has drop, store {
    /// Active expiry markets snapshotted at start; every one must be valued.
    expected_expiry_markets: vector<ID>,
    /// Markets valued so far this flush; folded against `expected` at finish.
    valued_expiry_markets: vector<ID>,
    /// Running Σ of each valued market's snapshot NAV (settled markets contribute 0).
    total_nav: u64,
    /// Oracle state frozen during the snapshot stage, one entry per expected
    /// market. Keyed by market id so a `Pricer` can never be applied to the wrong
    /// market. `none` marks a market that was already settled at snapshot time
    /// and therefore contributes 0. This map is what makes the valuation stage
    /// deterministic: it decides both the mark AND the sweep-vs-value branch, so
    /// no later transaction's clock or oracle state can change a market's
    /// contribution.
    frozen_pricers: VecMap<ID, Option<Pricer>>,
    /// Set by `seal_valuation_snapshot`; no market may be valued before it.
    /// Nothing may be snapshotted after it because sealing consumes the
    /// `SnapshotStage`.
    sealed: bool,
    /// Clock time the flush was started, for the stuck-flush deadline.
    started_at_ms: u64,
    /// Address that started this flush. Only it may value markets and finish, for
    /// as long as the flush is its own — see `assert_valuation_starter`.
    started_by: address,
    /// Each LP queue's `next_index` at the snapshot instant: the drain fills only
    /// requests indexed strictly below these, so nobody can watch the frozen mark
    /// form and then submit against a price they already know is stale.
    supply_request_cutoff: u64,
    withdraw_request_cutoff: u64,
    /// Live-market maintenance cash moved during this flush's window: idle sent
    /// into live markets (top-ups) and live-market surplus returned to idle.
    /// `finish_flush` reverses both out of the pool total and the profit basis,
    /// so the mark is invariant to maintenance timing — a rebalance mid-window
    /// prices identically to no rebalance at all. Settled sweeps are deliberately
    /// NOT here: a swept market contributes 0 and its recoverable cash's counted
    /// location is idle.
    maintenance_sent: u64,
    maintenance_returned: u64,
}

// === Package Initializer ===

/// Register PLP metadata and create the pool vault on package publish.
fun init(witness: PLP, ctx: &mut TxContext) {
    let (_, metadata_cap) = init_plp(witness, ctx);
    transfer_metadata_cap(metadata_cap, ctx);
}

fun init_plp(witness: PLP, ctx: &mut TxContext): (ID, MetadataCap<PLP>) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6,
        b"PLP".to_string(),
        b"Predict LP".to_string(),
        b"LP token representing shares in the Predict pool vault".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    let vault_id = create_and_share_vault(treasury_cap, ctx);
    (vault_id, metadata_cap)
}

#[allow(lint(self_transfer))]
fun transfer_metadata_cap(metadata_cap: MetadataCap<PLP>, ctx: &TxContext) {
    transfer::public_transfer(metadata_cap, ctx.sender());
}

fun create_and_share_vault(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): ID {
    let vault = PoolVault {
        id: object::new(ctx),
        protocol_reserve_balance: balance::zero(),
        fee_incentive_reserve: balance::zero(),
        lp: lp_book::new(treasury_cap, ctx),
        expiry_accounting: pool_accounting::new(ctx),
        valuation: option::none(),
    };
    let vault_id = vault.id();
    transfer::share_object(vault);
    vault_id
}

// === Public Functions ===

/// Return the pool vault object ID for external discovery and PTB construction.
public fun id(vault: &PoolVault): ID {
    vault.id.to_inner()
}

/// Return idle DUSDC for SDK and devInspect state reads.
public fun idle_balance(vault: &PoolVault): u64 {
    vault.expiry_accounting.idle_balance()
}

/// Return protocol-owned DUSDC for SDK and devInspect state reads.
public fun protocol_reserve_balance(vault: &PoolVault): u64 {
    vault.protocol_reserve_balance.value()
}

/// Return sponsor-funded fee reserves for SDK and devInspect state reads.
public fun fee_incentive_reserve(vault: &PoolVault): u64 {
    vault.fee_incentive_reserve.value()
}

/// Return total PLP supply for SDK and devInspect state reads.
public fun plp_total_supply(vault: &PoolVault): u64 {
    vault.lp.total_supply()
}

/// Return pending LP supply count for SDK and devInspect queue reads.
public fun supply_requests_pending(vault: &PoolVault): u64 {
    vault.lp.supply_requests_pending()
}

/// Return pending LP withdrawal count for SDK and devInspect queue reads.
public fun withdraw_requests_pending(vault: &PoolVault): u64 {
    vault.lp.withdraw_requests_pending()
}

/// Return active expiry IDs for external PTB construction and pool inspection.
public fun active_expiry_markets(vault: &PoolVault): vector<ID> {
    vault.expiry_accounting.active_expiry_markets()
}

/// Return the pre-expiry active count for SDK and devInspect capacity reads.
public fun active_live_expiry_count(vault: &PoolVault, clock: &Clock): u64 {
    vault.expiry_accounting.active_live_expiry_count(clock.timestamp_ms())
}

/// Return the profit-basis debits for external accounting observability.
public fun profit_basis_debits(vault: &PoolVault): u64 {
    vault.expiry_accounting.profit_basis_debits()
}

/// Return the profit-basis credits for external accounting observability.
public fun profit_basis_credits(vault: &PoolVault): u64 {
    vault.expiry_accounting.profit_basis_credits()
}

/// Return deferred protocol profit for external accounting observability.
public fun pending_protocol_profit(vault: &PoolVault): u64 {
    vault.expiry_accounting.pending_protocol_profit()
}

/// Begin a full-pool valuation using a registry-issued lifecycle proof. The proof
/// grants control over when current oracle state is frozen for queued LP fills.
/// Starting engages the cross-transaction valuation flag, snapshots the active
/// expiry set and each LP queue's eligibility cutoff, and opens the atomic
/// snapshot stage: freeze every active market's pricer under the returned
/// `SnapshotStage`, then seal it in the same transaction.
public fun start_pool_valuation(
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    lifecycle_proof: MarketLifecycleProof,
    clock: &Clock,
    ctx: &TxContext,
): SnapshotStage {
    config.assert_version();
    lifecycle_proof.destroy_proof();
    start_pool_valuation_internal(config, vault, clock, ctx);
    SnapshotStage {}
}

/// Freeze one snapshotted market's oracle state for this flush and stamp the
/// market so trades record their deltas from this instant on.
///
/// Holding `SnapshotStage` is what admits this call, and that potato cannot leave
/// the transaction `start_pool_valuation` minted it in — so every `Pricer` here is
/// loaded at one instant, which is what lets the valuation stage span transactions
/// without mixing marks (audit L10). This stage reads oracles only — it never
/// walks a payout tree — so all markets fit one PTB regardless of book size.
///
/// The oracle feeding this stage must have been written in an EARLIER transaction:
/// `pricing::resolve_live_pricer` refuses a read stamped with the current
/// transaction digest (RP-24), so a keeper cannot refresh and snapshot in one PTB.
///
/// A market already settled at snapshot time is recorded with no pricer, gets no
/// stamp (settled flows never touch live NAV), and contributes 0. An
/// expired-but-unsettled market aborts: it has no well-defined mark, and because
/// this stage is atomic the abort reverts the whole snapshot transaction, so the
/// flag is never left engaged. Settle it first, then start the flush — that
/// ordering is what keeps the per-market settlement gate from deadlocking against
/// the flush.
public fun snapshot_expiry_pricer(
    vault: &mut PoolVault,
    _stage: &SnapshotStage,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    clock: &Clock,
    ctx: &TxContext,
) {
    config.assert_version();
    config.assert_valuation_in_progress();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);

    let valuation = vault.valuation.borrow_mut();
    // Not in this flush's active set: skip rather than abort. The caller builds
    // its market list off-chain before submitting, and anything that sweeps a
    // settled market in the meantime — `rebalance_expiry_cash` is permissionless,
    // and the ordinary settle-then-sweep roll calls it — leaves that list holding
    // a market this flush has no business touching. Aborting made a routine race
    // fail the whole flush (RP-31). Skipping is safe because
    // `expected_expiry_markets` is read on-chain here, not supplied: see
    // `seal_valuation_snapshot` for why nothing real can be skipped.
    if (!valuation.expected_expiry_markets.contains(&expiry_market_id)) return;
    assert!(!valuation.frozen_pricers.contains(&expiry_market_id), EExpiryPricerAlreadySnapshotted);

    let frozen = if (market.is_settled()) {
        option::none()
    } else {
        assert!(clock.timestamp_ms() < market.expiry(), EExpiredMarketNotSettled);
        option::some(market.load_live_pricer(
            config,
            propbook_registry,
            pyth,
            bs_values,
            bs_svi,
            clock,
            ctx,
        ))
    };
    let stamp = frozen.is_some();
    valuation.frozen_pricers.insert(expiry_market_id, frozen);
    if (stamp) {
        market.stamp_for_valuation(config.current_flush_seq());
    };
}

/// Close the snapshot stage once every expected market has a frozen pricer.
///
/// Consuming `SnapshotStage` is the simultaneity proof: the potato dies here, so
/// no later transaction can add oracle state to this flush, and every market is
/// marked at the instant the snapshot transaction executed. Valuation may then
/// resume across as many transactions as it needs.
public fun seal_valuation_snapshot(
    vault: &mut PoolVault,
    stage: SnapshotStage,
    config: &ProtocolConfig,
) {
    config.assert_version();
    config.assert_valuation_in_progress();
    let SnapshotStage {} = stage;
    let valuation = vault.valuation.borrow_mut();
    assert!(
        valuation.frozen_pricers.length() == valuation.expected_expiry_markets.length(),
        EIncompleteValuationSnapshot,
    );
    valuation.sealed = true;
}

/// Fold one snapshotted market's SNAPSHOT-INSTANT NAV into the running total. A
/// market frozen as settled is swept (deactivated, cash returned, profit
/// materialized) and contributes 0; a market frozen with a pricer is valued
/// through `expiry_market::snapshot_nav`, which marks the snapshot-captured cash
/// and payout-tree shadows against the frozen pricer, then has its stamp cleared
/// — releasing the tree snapshot and its retained nodes — so later trades and
/// the next flush start from a clean live tree (they are invisible to a figure
/// already folded — as-of-snapshot semantics either way).
///
/// This is the resumable stage: any transaction after the seal, one market per
/// transaction (see `constants::max_payout_tree_nodes`), reading no oracle and no
/// clock — the frozen snapshot alone decides both the branch and the mark. For a
/// live market this stage is MEASUREMENT-ONLY: it moves no cash itself, and cash
/// maintenance stays fully decoupled — `rebalance_expiry_cash` may run at any
/// time, including mid-window, because the snapshot values were captured before
/// any in-window move could touch them, and the flush's maintenance accumulators
/// (reversed at the finish) keep the pool total invariant to maintenance timing;
/// the snapshot formula holds exactly in every regime, including a floor-clamped
/// market. Only the settled sweep moves cash here, and its return lands in idle,
/// which the finish measures. A market that expired mid-window is valued at its
/// frozen pre-expiry mark, and its settlement waits only for this call to clear
/// the stamp.
public fun value_expiry(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    ctx: &TxContext,
) {
    config.assert_version();
    config.assert_valuation_in_progress();
    vault.assert_valuation_starter(ctx);
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);

    let frozen = {
        let valuation = vault.valuation.borrow();
        assert!(valuation.sealed, EValuationSnapshotNotSealed);
        // Same stale-list tolerance as the snapshot stage: a market outside the
        // flush's active set was skipped there too, so it has no frozen pricer and
        // contributes nothing. Returning keeps a stale keeper entry from failing
        // the flush.
        if (!valuation.expected_expiry_markets.contains(&expiry_market_id)) return;
        valuation.assert_expiry_not_already_valued(expiry_market_id);
        *valuation.frozen_pricers.get(&expiry_market_id)
    };

    let nav = if (frozen.is_none()) {
        // Frozen as settled at snapshot time. Settlement is one-way, so the
        // market is still settled and the sweep below is the same operation the
        // snapshot instant would have priced at 0.
        vault.sweep_settled_expiry(market, config);
        0
    } else {
        let nav = market.snapshot_nav(frozen.borrow());
        market.clear_valuation_stamp();
        nav
    };

    let valuation = vault.valuation.borrow_mut();
    valuation.valued_expiry_markets.push_back(expiry_market_id);
    valuation.total_nav = valuation.total_nav + nav;
}

/// Finish a full-pool valuation and run the LP flush: prove every snapshotted market
/// was valued exactly once, price the pool NAV, then drain the supply/withdraw queues
/// at that frozen mark (mint PLP for supplies, burn PLP and pay DUSDC for
/// withdrawals), release the valuation flag, retire the in-flight valuation, and
/// return the LP-attributable pool-wide DUSDC NAV (idle + Σ active NAV, net of
/// the pending-protocol-profit exclusion priced from the aggregate profit basis).
/// Each drain fills only requests submitted before the flush's snapshot instant
/// (the recorded queue cutoffs); younger requests wait for the next mark.
///
/// `supply_budget` and `withdraw_budget` bound how many requests each queue may
/// process this flush (`None` = unbounded). Fills — whole or partial — and
/// protocol-refunded heads — non-executable, or quoting below the request's own
/// minimum output — all count as processed. At `ProtocolConfig`'s shipped attempt
/// count of one, a head that misses its limit is refunded by the flush that reaches
/// it; above one it stays queued and stops that queue for the flush. The budgets are
/// independent, so a supply backlog does not consume withdrawal capacity.
///
/// Capacity bounds each pass on top of the budgets and refunds nothing: supplies fill
/// only up to `ProtocolConfig`'s LP pool-value cap, withdrawals only up to idle. A head
/// larger than the room left fills to the room, spends flush budget, and keeps its
/// remainder queued at a rescaled limit; a head with no usable room carries untouched
/// and spends none. Either way the pass stops, so an unbounded budget does not mean
/// every queued request is processed (RP-23).
///
/// Because queueing is permissionless and a refunded request returns its escrow in the
/// same transaction, an operator should bound both budgets in production rather than
/// rely on queue length staying small — see RP-12.
public fun finish_flush(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
    ctx: &mut TxContext,
): u64 {
    config.assert_version();
    config.assert_valuation_in_progress();
    vault.assert_valuation_starter(ctx);
    let valuation = vault.valuation.extract();
    assert_all_expected_valued(
        &valuation.expected_expiry_markets,
        &valuation.valued_expiry_markets,
    );
    let PoolValuation {
        total_nav,
        valued_expiry_markets,
        supply_request_cutoff,
        withdraw_request_cutoff,
        started_at_ms,
        maintenance_sent,
        maintenance_returned,
        ..,
    } = valuation;

    let idle_balance_before = vault.expiry_accounting.idle_balance();
    let pool_nav = lp_pool_value(
        vault,
        config.protocol_reserve_profit_share(),
        total_nav,
        maintenance_sent,
        maintenance_returned,
    );
    let total_supply = vault.lp.total_supply();
    let market_count = valued_expiry_markets.length();

    // Snapshot the share price once (frozen pair), drain both queues against it, then
    // release the valuation lock at the very end. The flush IS the full-pool
    // valuation, so the single FlushExecuted event carries the priced mark and its
    // idle + active-NAV breakdown.
    let vault_id = vault.id();
    let mark = lp_book::new_flush_mark(pool_nav, total_supply);
    let fees = lp_book::new_fee_rates(
        config.plp_supply_fee_rate(),
        config.plp_withdraw_fee_rate(),
    );
    // The frozen `FeeRates` is the only source for these: the config reads are inlined
    // above so no local survives that the event could report instead of what the drain
    // was handed, and each read is named per leg so a transposition cannot compile into
    // a silently-swapped event.
    let frozen_supply_fee_rate = fees.supply_fee_rate();
    let frozen_withdraw_fee_rate = fees.withdraw_fee_rate();
    let drain_summary = vault
        .lp
        .drain(
            &mut vault.expiry_accounting,
            mark,
            fees,
            vault_id,
            supply_request_cutoff,
            withdraw_request_cutoff,
            supply_budget,
            withdraw_budget,
            config.lp_request_limit_flush_attempts(),
            config.max_lp_pool_value(),
            ctx,
        );
    let total_supply_after = vault.lp.total_supply();
    config.end_valuation();
    vault_events::emit_flush_executed(
        vault_id,
        ctx.epoch(),
        pool_nav,
        total_supply,
        frozen_supply_fee_rate,
        frozen_withdraw_fee_rate,
        total_nav,
        market_count,
        idle_balance_before,
        drain_summary.supplies_filled(),
        drain_summary.withdrawals_filled(),
        drain_summary.requests_processed(),
        vault.expiry_accounting.idle_balance(),
        total_supply_after,
        supply_request_cutoff,
        withdraw_request_cutoff,
        started_at_ms,
    );
    pool_nav
}

/// Discard an in-flight valuation and release the flag, without draining any
/// queue.
///
/// A resumable flush can be abandoned mid-way (a dead keeper, a market whose
/// valuation transaction keeps failing). While one is in flight, trading
/// continues — the cost of abandonment is queued LP fills waiting and the
/// flush-set markets' settlement deferred — so this escape bounds LP-fill
/// latency, not a protocol pause.
///
/// Permissionless, but only once the flush has been in flight for longer than
/// `max_valuation_window_ms`: within the window the operator is presumed still
/// working through it, and cancelling would waste the valuation transactions
/// already paid for. `abort_valuation_privileged` is the immediate operator path.
///
/// Partial NAV is discarded rather than reused: the frozen marks are only sound
/// as a simultaneous set, so a later flush must re-snapshot. Cash already moved
/// by `value_expiry`'s settled sweeps and by any in-window maintenance stays
/// moved — each is an invariant-preserving per-market operation that stands on
/// its own, and the discarded accumulators only ever affected the mark. Market
/// stamps are not visited: releasing the flag makes every one of them stale, and
/// the next trade or settle on each market discards it.
public fun abort_valuation(vault: &mut PoolVault, config: &mut ProtocolConfig, clock: &Clock) {
    config.assert_version();
    config.assert_valuation_in_progress();
    let deadline = vault.valuation.borrow().started_at_ms + config.max_valuation_window_ms();
    assert!(clock.timestamp_ms() >= deadline, EValuationDeadlineNotReached);
    vault.abort_valuation_internal(config);
}

/// Immediately discard an in-flight valuation on lifecycle authority, without
/// waiting out the permissionless deadline.
public fun abort_valuation_privileged(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    lifecycle_proof: MarketLifecycleProof,
) {
    config.assert_version();
    config.assert_valuation_in_progress();
    lifecycle_proof.destroy_proof();
    vault.abort_valuation_internal(config);
}

/// Move cash between pool idle liquidity and one expiry market.
///
/// Permissionless and standalone: anyone may call it at any cadence. Handles all
/// three per-market cases — initial funding of a freshly registered (unfunded)
/// market, ongoing live rebalance/surplus-sweep toward target, and the
/// settled-market sweep (deactivate, return all free cash, materialize profit).
/// Call `expiry_market::try_settle` first in the same PTB when settlement may be due.
/// An expired unsettled market is a no-op until that transition succeeds.
/// Mint asserts backing but never pulls pool cash, so this is what makes a market
/// mintable. The market must already be registered to this vault
/// (`registry::create_and_share_expiry_market`). Runs at any time, including while
/// a flush is in flight: a pending market's snapshot cash was captured before
/// any in-window move could touch it, and the move is reversed out of the
/// flush's pool total and profit basis, so the mark is invariant to maintenance
/// timing and a market can always be topped back into its mintable band
/// mid-flush.
public fun rebalance_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    clock: &Clock,
) {
    config.assert_version();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    vault.sweep_or_rebalance_expiry(market, config, clock);
}

/// Sponsor taker fee incentives with DUSDC. Anyone may contribute; the payment
/// joins a pool-level reserve that is excluded from PLP NAV and later allocated to
/// expiry markets by the normal rebalance flow.
public fun sponsor_fee_incentives(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    payment: Coin<DUSDC>,
    ctx: &mut TxContext,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    let amount = payment.value();
    assert!(
        amount >= constants::min_fee_incentive_sponsorship!(),
        EBelowMinFeeIncentiveSponsorship,
    );
    vault.fee_incentive_reserve.join(payment.into_balance());
    vault_events::emit_fee_incentives_sponsored(
        vault.id(),
        ctx.sender(),
        amount,
        vault.fee_incentive_reserve.value(),
    );
}

/// Bootstrap the pool exactly once: permanently lock `payment` DUSDC of minimum
/// liquidity. Mints matching PLP (1:1) into the book's locked balance — never
/// withdrawable, so the caller receives no shares — and joins the DUSDC into idle.
/// This keeps `total_supply > 0` while the vault exists and gives rounding dust a
/// non-withdrawable PLP holder.
/// Requires root authority and zero existing supply. Supply, withdrawal, and flush
/// flows remain disabled until the locked liquidity has been created.
public fun lock_capital(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    payment: Coin<DUSDC>,
) {
    config.assert_version();
    assert!(vault.lp.total_supply() == 0, EAlreadyBootstrapped);
    let amount = payment.value();
    assert!(amount >= constants::min_bootstrap_liquidity!(), EBelowMinBootstrapLiquidity);
    vault.expiry_accounting.receive_idle(payment.into_balance());
    vault.lp.mint_locked_liquidity(amount);
    vault_events::emit_capital_locked(vault.id(), amount);
}

/// Queue a supply request: pull `amount` DUSDC from account custody into queue
/// escrow, recording the account's receive address as the fill recipient. The pull
/// auto-settles any flush-delivered DUSDC first. The flush charges the protocol's
/// supply fee — zero by default — on the DUSDC it takes in and prices shares on the
/// remainder, so `min_plp_out` is measured after that fee. The account receives minted PLP
/// only at a mark that mints at least `min_plp_out` for the whole `amount` — a **price
/// floor**, not a promise of that many shares: if the pool cap leaves room for only
/// part of the deposit, the fill is proportionally smaller at the same price and the
/// remainder stays queued with its limit rescaled. At the shipped attempt count of one,
/// a flush whose mark quotes less cancels and refunds the request there and then; a
/// higher configured count lets it rest and retry that many flushes first. Returns the
/// queue index, the handle used to cancel before the flush.
public fun request_supply(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    amount: u64,
    min_plp_out: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    config.assert_version();
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let payment = account.withdraw<DUSDC>(amount, ctx);
    let vault_id = vault.id();
    let account_id = account.account_id();
    let recipient = account.receive_address();
    let index = vault.lp.request_supply(payment, account_id, recipient, min_plp_out);
    vault_events::emit_supply_requested(
        vault_id,
        account_id,
        recipient,
        index,
        amount,
        min_plp_out,
        vault.lp.supply_requests_pending(),
    );
    index
}

/// Queue a withdraw request: pull `amount` PLP shares from account custody into
/// queue escrow, recording the account's receive address as the fill recipient.
/// The pull auto-settles any flush-delivered PLP first. The flush withholds the
/// protocol's withdraw fee from the marked payout, so `min_dusdc_out` is measured
/// after the fee. The account is paid only at a
/// mark that quotes at least `min_dusdc_out` for the whole `amount` — a **price
/// floor**, not a promise of that much DUSDC: if idle liquidity covers only part of the
/// payout, only the shares idle affords are burned, the fill is proportionally smaller
/// at the same price, and the remainder stays queued with its limit rescaled. At the
/// shipped attempt count of one, a flush whose mark quotes less cancels and refunds the
/// request there and then; a higher configured count lets it rest and retry that many
/// flushes first. Returns the queue index used to cancel before the flush.
public fun request_withdraw(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    amount: u64,
    min_dusdc_out: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    config.assert_version();
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    wrapper.settle<PLP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let lp = account.withdraw<PLP>(amount, ctx);
    let vault_id = vault.id();
    let account_id = account.account_id();
    let recipient = account.receive_address();
    let index = vault.lp.request_withdraw(lp, account_id, recipient, min_dusdc_out);
    vault_events::emit_withdraw_requested(
        vault_id,
        account_id,
        recipient,
        index,
        amount,
        min_dusdc_out,
        vault.lp.withdraw_requests_pending(),
    );
    index
}

/// Cancel a still-pending supply request, refunding its escrowed DUSDC straight into
/// the requesting account. `account` must be the request's recorded recipient.
public fun cancel_supply_request(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    index: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    // Cancels stay gated during a flush (requests do not): the frozen mark is
    // on-chain readable once the snapshot lands, so an ungated cancel of an
    // already-eligible request would be a free look at a stale price — keep the
    // fill if the mark favors you, cancel if it does not. Requests are safe
    // ungated because the drain's eligibility cutoff quarantines them to the
    // next mark.
    config.assert_not_valuation_in_progress();
    let vault_id = vault.id();
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let recipient = account.receive_address();
    let (account_id, amount, refund) = vault.lp.cancel_supply_request(recipient, index);
    account.deposit<DUSDC>(refund.into_coin(ctx));
    vault_events::emit_request_cancelled(
        vault_id,
        account_id,
        recipient,
        index,
        amount,
        true,
        constants::request_cancel_reason_user!(),
        vault.lp.supply_requests_pending(),
    );
}

/// Cancel a still-pending withdraw request, refunding its escrowed PLP straight into
/// the requesting account. `account` must be the request's recorded recipient.
public fun cancel_withdraw_request(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    index: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    // Cancels stay gated during a flush (requests do not): the frozen mark is
    // on-chain readable once the snapshot lands, so an ungated cancel of an
    // already-eligible request would be a free look at a stale price — keep the
    // fill if the mark favors you, cancel if it does not. Requests are safe
    // ungated because the drain's eligibility cutoff quarantines them to the
    // next mark.
    config.assert_not_valuation_in_progress();
    let vault_id = vault.id();
    wrapper.settle<PLP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let recipient = account.receive_address();
    let (account_id, amount, refund) = vault.lp.cancel_withdraw_request(recipient, index);
    account.deposit<PLP>(refund.into_coin(ctx));
    vault_events::emit_request_cancelled(
        vault_id,
        account_id,
        recipient,
        index,
        amount,
        false,
        constants::request_cancel_reason_user!(),
        vault.lp.withdraw_requests_pending(),
    );
}

/// Register a freshly created expiry market with the pool as an accounting row.
/// No cash moves: the market is not mintable until `rebalance_expiry_cash` funds
/// it. Called by `registry::create_and_share_expiry_market`.
public(package) fun register_expiry(
    vault: &mut PoolVault,
    expiry_market_id: ID,
    expiry_ms: u64,
    max_expiry_allocation: u64,
    initial_expiry_cash: u64,
    clock: &Clock,
) {
    let now_ms = clock.timestamp_ms();
    if (expiry_ms > now_ms) {
        assert!(
            vault
                .expiry_accounting
                .active_live_expiry_count(now_ms) < constants::max_live_expiry_markets!(),
            EMaxLiveExpiryMarketsExceeded,
        );
    };
    vault
        .expiry_accounting
        .register_expiry(expiry_market_id, expiry_ms, max_expiry_allocation, initial_expiry_cash);
}

// === Private Functions ===

/// LP-attributable DUSDC pool value used to price PLP supply/withdraw.
///
/// `gross = idle_balance + active_expiry_value`. NAV prices the protocol's
/// not-yet-materialized profit share before terminal materialization and excludes
/// it from LP value: `exclusion = share * max(0, (credits + active) - debits)`
/// (live cash returns update credits, but reserve custody waits for terminal
/// profit). A cut already materialized but not yet physically moved (idle was
/// deployed elsewhere) has left that debit-basis exclusion, so the carried
/// `pending_protocol_profit` is subtracted separately to keep it out of LP value
/// until it is drained into the reserve.
///
/// The flush's mark must be the SNAPSHOT-instant pool value, and per-market NAVs
/// are as-of-snapshot, so every in-window live-maintenance move is reversed out
/// of the other terms too: idle gets the sent/returned net added back (idle at
/// finish is short by exactly that net relative to the snapshot), and the profit
/// basis drops the debits/credits those same moves recorded (`send_expiry_cash`
/// records each sent amount as a debit and `receive_expiry_cash` each returned
/// amount as a credit, so the basis subtractions below cannot underflow). The
/// returned-side reversal lives inside the final policy clamp rather than in
/// `gross_pool_value`: a mid-window sweep's return can leave idle again in the
/// same call (`realize_pending_protocol_profit`), so `idle + sent` may be
/// smaller than `returned` even though the fully-reduced mark is representable —
/// the clamp form is algebraically identical wherever the split form would not
/// abort, and floors at zero where it would. With all three terms corrected,
/// the mark is invariant to maintenance timing. Settled-sweep returns are not
/// reversed and the standalone settled sweep is deferred while a flush is in
/// flight (see `sweep_or_rebalance_expiry`): the flush's own sweep keeps idle
/// the counted location for a frozen-settled market's cash, while a market
/// valued as LIVE this flush must not have its cash swept into idle mid-window
/// on top of its folded NAV.
fun lp_pool_value(
    vault: &PoolVault,
    protocol_reserve_profit_share: u64,
    active_expiry_value: u64,
    maintenance_sent: u64,
    maintenance_returned: u64,
): u64 {
    let idle_balance = vault.expiry_accounting.idle_balance();
    let profit_basis_credits = vault.expiry_accounting.profit_basis_credits();
    let profit_basis_debits = vault.expiry_accounting.profit_basis_debits();
    let pending_protocol_profit = vault.expiry_accounting.pending_protocol_profit();
    let gross_pool_value = idle_balance + active_expiry_value + maintenance_sent;
    let aggregate_credits = profit_basis_credits + active_expiry_value - maintenance_returned;
    let exclusion = math::mul_down(
        aggregate_credits.saturating_sub(profit_basis_debits - maintenance_sent),
        protocol_reserve_profit_share,
    );
    // The realized `credits - debits` term is sticky: it does not shrink when LPs
    // withdraw idle cash, so when an active mark they withdrew against later
    // collapses, the held-out total (`exclusion + pending_protocol_profit`) can
    // exceed gross. LP value can never be negative, so floor it at 0 to keep the
    // subtraction from underflow-aborting. A 0/dust pool NAV makes non-executable
    // LP queue heads refund inside `lp_book::drain`, rather than aborting the flush.
    gross_pool_value.saturating_sub(maintenance_returned + exclusion + pending_protocol_profit)
}

/// Sweep a settled market, rebalance a live market, or leave an expired unsettled
/// market unchanged. Returns true when the market is settled and swept.
fun sweep_or_rebalance_expiry(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    clock: &Clock,
): bool {
    let expiry_market_id = market.id();
    if (market.is_settled()) {
        // Deferred while a flush is in flight: a settled sweep moves cash to
        // idle with no maintenance recording, and for a market already valued
        // as LIVE this flush (expired and settled mid-window after its stamp
        // cleared) that return would sit in idle ON TOP of the market's folded
        // NAV, inflating the mark by the swept amount. The flush's own
        // `value_expiry` still sweeps its frozen-settled members; the
        // standalone sweep is idempotent, so deferral costs one keeper retry
        // after the finish.
        if (config.valuation_in_progress()) return true;
        vault.sweep_settled_expiry(market, config);
        true
    } else if (clock.timestamp_ms() >= market.expiry()) {
        false
    } else {
        vault.rebalance_live_expiry(market, expiry_market_id);
        false
    }
}

fun rebalance_live_expiry(vault: &mut PoolVault, market: &mut ExpiryMarket, expiry_market_id: ID) {
    vault.sync_fee_incentives(market, expiry_market_id);

    let initial_expiry_cash = vault.expiry_accounting.initial_expiry_cash(expiry_market_id);
    let (target_cash, sweep_threshold_cash) = expiry_rebalance_cash_terms(
        market,
        initial_expiry_cash,
    );
    let cash_balance = market.cash_balance();
    if (cash_balance < target_cash) {
        let sent = vault.top_up_live_expiry_cash(
            market,
            expiry_market_id,
            cash_balance,
            target_cash,
        );
        vault.record_live_maintenance(sent, 0);
    } else if (cash_balance > sweep_threshold_cash) {
        let returned = vault.sweep_live_expiry_surplus(
            market,
            expiry_market_id,
            cash_balance,
            target_cash,
        );
        vault.record_live_maintenance(0, returned);
    };
}

/// Record one live-market maintenance move on the in-flight flush's pool-level
/// accumulators, which `finish_flush` reverses out of idle and the profit basis.
/// The market side needs no record: a pending market's `snapshot_nav` reads cash
/// values captured at the snapshot instant, so any later movement — maintenance
/// included — is structurally invisible to it. Outside a flush the record is a
/// no-op and the move is ordinary maintenance.
fun record_live_maintenance(vault: &mut PoolVault, sent: u64, returned: u64) {
    if (sent == 0 && returned == 0) return;
    if (vault.valuation.is_none()) return;
    // Inside the still-open snapshot PTB nothing may record: the whole PTB is
    // the snapshot instant, so a move there is part of the baseline the frozen
    // pricers and stamps measure — recording it too would count it twice.
    if (!vault.valuation.borrow().sealed) return;
    let valuation = vault.valuation.borrow_mut();
    valuation.maintenance_sent = valuation.maintenance_sent + sent;
    valuation.maintenance_returned = valuation.maintenance_returned + returned;
}

fun top_up_live_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    expiry_market_id: ID,
    cash_balance: u64,
    target_cash: u64,
): u64 {
    let requested_top_up = target_cash - cash_balance;
    let funding_room = vault.expiry_accounting.available_expiry_funding(expiry_market_id);
    let top_up = requested_top_up.min(vault.expiry_accounting.idle_balance()).min(funding_room);
    if (top_up == 0) return 0;

    let cash = vault.expiry_accounting.send_expiry_cash(expiry_market_id, top_up);
    market.receive_pool_cash(cash);
    vault_events::emit_expiry_cash_rebalanced(
        vault.id(),
        expiry_market_id,
        top_up,
        true,
        target_cash,
        0,
    );
    top_up
}

fun sweep_live_expiry_surplus(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    expiry_market_id: ID,
    cash_balance: u64,
    target_cash: u64,
): u64 {
    let returned_cash = market.release_pool_cash(cash_balance - target_cash);
    let returned_cash_amount = vault
        .expiry_accounting
        .receive_expiry_cash(returned_cash, expiry_market_id);
    // Surplus just returned to idle — realize any protocol cut a prior settled
    // sweep could not cover because idle was deployed in other active markets.
    let realized_profit = vault.expiry_accounting.realize_pending_protocol_profit();
    let protocol_profit_realized = realized_profit.value();
    vault.protocol_reserve_balance.join(realized_profit);
    vault_events::emit_expiry_cash_rebalanced(
        vault.id(),
        expiry_market_id,
        returned_cash_amount,
        false,
        target_cash,
        protocol_profit_realized,
    );
    returned_cash_amount
}

fun sync_fee_incentives(vault: &mut PoolVault, market: &mut ExpiryMarket, expiry_market_id: ID) {
    let max_expiry_allocation = vault.expiry_accounting.max_expiry_allocation(expiry_market_id);
    let requested_allocation = math::mul_down(
        max_expiry_allocation,
        constants::fee_incentive_live_target_rate!(),
    )
        .saturating_sub(market.fee_incentive_balance())
        .min(vault.fee_incentive_reserve.value());
    if (requested_allocation == 0) return;

    let (allocation, allocated_after) = vault
        .expiry_accounting
        .record_fee_incentives_allocated_up_to(expiry_market_id, requested_allocation);
    if (allocation == 0) return;

    let incentives = vault.fee_incentive_reserve.split(allocation);
    market.receive_fee_incentives(incentives);
    vault_events::emit_fee_incentives_allocated(
        vault.id(),
        expiry_market_id,
        allocation,
        vault.fee_incentive_reserve.value(),
        market.fee_incentive_balance(),
        allocated_after,
    );
}

/// Current cash, the target cash to hold, and the upper sweep band for one expiry.
///
/// `target_cash` adds one buffer above the expiry-cash required backing and
/// `sweep_threshold_cash` adds two, both floored at the per-expiry initial cash
/// target. Below target the pool tops up to target; above the sweep band it
/// returns the excess over target.
fun expiry_rebalance_cash_terms(market: &ExpiryMarket, initial_expiry_cash: u64): (u64, u64) {
    let required_cash = market.required_cash();
    let target_buffer = math::mul_down(required_cash, constants::expiry_rebalance_pct!());
    let target_cash = (required_cash + target_buffer).max(initial_expiry_cash);
    let sweep_threshold_cash = (required_cash + target_buffer + target_buffer).max(
        initial_expiry_cash,
    );
    (target_cash, sweep_threshold_cash)
}

/// Settled-market sweep: deactivate the expiry, return its free cash to idle,
/// materialize its terminal profit, and return unused fee incentives to the pool
/// reserve. Idempotent — a settled market already swept returns zero cash and
/// recognizes no further profit, so a second pass is a no-op.
fun sweep_settled_expiry(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
) {
    let expiry_market_id = market.id();
    let deactivated = vault.expiry_accounting.deactivate_expiry_if_present(expiry_market_id);
    let returned_cash = market.release_settled_pool_cash();
    let returned_cash_amount = vault
        .expiry_accounting
        .receive_expiry_cash(returned_cash, expiry_market_id);
    if (deactivated || returned_cash_amount > 0) {
        vault_events::emit_expiry_cash_received(
            vault.id(),
            expiry_market_id,
            market.settlement_price(),
            returned_cash_amount,
        );
    };
    vault.materialize_expiry_profit(config, expiry_market_id);
    let returned_incentives = market.release_fee_incentives();
    let returned_incentive_amount = returned_incentives.value();
    vault.fee_incentive_reserve.join(returned_incentives);

    if (returned_incentive_amount > 0) {
        vault_events::emit_fee_incentives_returned(
            vault.id(),
            expiry_market_id,
            returned_incentive_amount,
            vault.fee_incentive_reserve.value(),
        );
    };
}

/// Materialize one terminal expiry's unapplied profit and split it: the protocol
/// cut is realized from idle into the protocol reserve — capped at available idle,
/// with any remainder carried in `pending_protocol_profit` and realized on a later
/// sweep — while the LP cut stays in idle.
fun materialize_expiry_profit(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    expiry_market_id: ID,
) {
    let profit = vault.expiry_accounting.materialize_expiry_profit(expiry_market_id);
    if (profit == 0) {
        return
    };
    let protocol_profit = math::mul_down(profit, config.protocol_reserve_profit_share());
    let lp_profit = profit - protocol_profit;
    let realized = vault.expiry_accounting.realize_protocol_profit(protocol_profit);
    vault.protocol_reserve_balance.join(realized);
    vault_events::emit_expiry_profit_materialized(
        vault.id(),
        expiry_market_id,
        lp_profit,
        protocol_profit,
        vault.protocol_reserve_balance.value(),
        vault.expiry_accounting.profit_basis_debits(),
        vault.expiry_accounting.pending_protocol_profit(),
    );
}

/// Engage the valuation flag, mint this flush's ordinal, and record its frozen
/// facts — the active expiry set, the starter, the start time, and each LP
/// queue's eligibility cutoff — after requiring a bootstrapped pool with nonzero
/// PLP supply.
fun start_pool_valuation_internal(
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    config.begin_valuation();
    vault.valuation =
        option::some(PoolValuation {
            expected_expiry_markets: vault.expiry_accounting.active_expiry_markets(),
            valued_expiry_markets: vector[],
            total_nav: 0,
            frozen_pricers: vec_map::empty(),
            sealed: false,
            started_at_ms: clock.timestamp_ms(),
            started_by: ctx.sender(),
            supply_request_cutoff: vault.lp.next_supply_request_index(),
            withdraw_request_cutoff: vault.lp.next_withdraw_request_index(),
            maintenance_sent: 0,
            maintenance_returned: 0,
        });
}

/// Discard the in-flight valuation, release the flag, and report how far it got.
fun abort_valuation_internal(vault: &mut PoolVault, config: &mut ProtocolConfig) {
    let valuation = vault.valuation.extract();
    config.end_valuation();
    vault_events::emit_flush_aborted(
        vault.id(),
        valuation.expected_expiry_markets.length(),
        valuation.valued_expiry_markets.length(),
    );
}

/// Abort unless `ctx.sender()` started the in-flight flush.
///
/// With the valuation held on the vault rather than in a hot potato only the
/// starter could hold, `value_expiry` and `finish_flush` would otherwise be
/// permissionless — and a third party could finish an operator's flush with zero
/// drain budgets, retiring the frozen mark with no LP request filled. There is
/// deliberately no permissionless completion path: an abandoned flush is
/// discarded (`abort_valuation`), never finished by a stranger.
fun assert_valuation_starter(vault: &PoolVault, ctx: &TxContext) {
    assert!(vault.valuation.borrow().started_by == ctx.sender(), ENotValuationStarter);
}

/// Abort when the market was already valued this flush (exactly-once);
/// set membership is the caller's skip decision, not an abort.
fun assert_expiry_not_already_valued(valuation: &PoolValuation, expiry_market_id: ID) {
    assert!(
        !valuation.valued_expiry_markets.contains(&expiry_market_id),
        EExpiryMarketAlreadyValued,
    );
}

/// The exactly-once completeness proof: the valued set must equal the snapshot
/// (a missed market means a wrong pool NAV). `value_expiry` already rejects
/// non-snapshot and duplicate ids, so equal lengths plus full coverage suffice.
fun assert_all_expected_valued(expected: &vector<ID>, valued: &vector<ID>) {
    assert!(valued.length() == expected.length(), EMissingExpiryValuation);
    expected.do_ref!(|id| assert!(valued.contains(id), EMissingExpiryValuation));
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext): ID {
    let (vault_id, metadata_cap) = init_plp(PLP {}, ctx);
    transfer_metadata_cap(metadata_cap, ctx);
    vault_id
}
