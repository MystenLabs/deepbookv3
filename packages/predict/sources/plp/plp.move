// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault.
///
/// PoolVault owns the PLP treasury cap, the pooled DEEP staked by accounts, idle
/// DUSDC, the protocol reserve, sponsor-funded fee incentives, per-expiry cash
/// accounting, and the queued LP supply/withdraw requests. It coordinates the
/// full-pool NAV valuation (a vault-held aggregation over every active market,
/// resumable across transactions) and the unified per-market cash flow (initial funding, live rebalance/sweep, and
/// settled-market sweep with terminal profit materialization). LPs queue
/// supply/withdraw requests routed through a loaded Account; each flush
/// (`finish_flush`) drains them at the frozen pool NAV, minting/burning PLP and
/// delivering fills to each account via the balance accumulator. DEEP held here
/// provides account trading benefits and is not part of PLP share value.
module deepbook_predict::plp;

use account::{account::{Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook_predict::{
    admin::AdminCap,
    constants,
    expiry_market::ExpiryMarket,
    lp_book::{Self, LpBook},
    market_lifecycle_cap::MarketLifecycleProof,
    pool_accounting::{Self, Ledger},
    predict_account,
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
use token::deep::DEEP;

const EExpiryMarketNotActive: u64 = 0;
const EExpiryMarketAlreadyValued: u64 = 1;
const EMissingExpiryValuation: u64 = 3;
const ENotBootstrapped: u64 = 4;
const EAlreadyBootstrapped: u64 = 5;
const EBelowMinBootstrapLiquidity: u64 = 6;
const EBelowMinFeeIncentiveSponsorship: u64 = 7;
const EMarketNotSettled: u64 = 8;
const EMaxLiveExpiryMarketsExceeded: u64 = 9;
const EValuationSnapshotNotSealed: u64 = 11;
const EExpiryPricerAlreadySnapshotted: u64 = 12;
const EIncompleteValuationSnapshot: u64 = 13;
const EExpiredMarketNotSettled: u64 = 14;
const EValuationDeadlineNotReached: u64 = 15;
const ENotValuationStarter: u64 = 16;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Transaction-local proof that the snapshot stage is still open.
///
/// `start_pool_valuation` mints one, every `snapshot_expiry_pricer` borrows it, and
/// `seal_valuation_snapshot` consumes it. It has no abilities, so it cannot be
/// stored, transferred, or dropped — which makes "the whole snapshot stage runs in
/// ONE transaction" a property of the type system rather than a keeper convention.
/// That atomicity is the entire correctness argument for the frozen mark: it is what
/// makes every market's `Pricer` load at the same instant, so the valuation stage can
/// then span as many transactions as it needs (audit L10).
///
/// It also scopes the stage to whoever started the flush. `snapshot_expiry_pricer`
/// and `seal_valuation_snapshot` are otherwise permissionless, and a snapshot taken
/// outside the starter's transaction could pick its own oracle instant per market.
public struct SnapshotStage {}

/// Pool-level vault state.
public struct PoolVault has key {
    id: UID,
    /// Protocol-owned DUSDC excluded from PLP redemption. No package entrypoint
    /// withdraws this balance.
    protocol_reserve_balance: Balance<DUSDC>,
    /// Sponsor-funded DUSDC reserved for taker fee sponsorship, excluded from PLP NAV.
    fee_incentive_reserve: Balance<DUSDC>,
    /// Pooled DEEP staked by all accounts for trading benefits. Per-account
    /// active/inactive amounts are mirrored in Predict account data.
    staked_deep: Balance<DEEP>,
    /// PLP share issuance plus queued supply/withdraw escrow.
    lp: LpBook<PLP>,
    /// Idle DUSDC custody, registered expiries, and per-expiry cash-flow rows.
    expiry_accounting: Ledger,
    /// In-flight full-pool valuation, held across transactions. `Some` exactly
    /// while the `ProtocolConfig` valuation lock is engaged.
    valuation: Option<PoolValuation>,
}

/// Full-pool NAV valuation carried across transactions.
///
/// The flush runs in three stages. **Snapshot (one atomic PTB):**
/// `start_pool_valuation` records the active expiry set, then one
/// `snapshot_expiry_pricer` per market freezes that market's oracle state, and
/// `seal_valuation_snapshot` proves the set is complete. Every `Pricer` is
/// therefore loaded at a single instant, which is what keeps the pool mark exact
/// (audit L10) once valuation spans transactions. **Valuation (resumable):** each
/// `value_expiry` runs the per-market cash flow and folds that market's NAV into
/// `total_nav` exactly once, pricing against its frozen `Pricer` (a swept settled
/// market contributes 0). **Finish:** `finish_flush` proves every snapshotted
/// market was valued, prices the pool NAV, and drains the LP queues against it.
///
/// Splitting stages this way is what removes C-1's ceiling: only `value_expiry`
/// walks payout trees (one dynamic-field child per distinct strike tick), and it
/// now carries just one market's nodes per transaction instead of the whole
/// pool's under Sui's 1,000-cached-object limit.
public struct PoolValuation has store {
    /// Active expiry markets snapshotted at start; every one must be valued.
    expected_expiry_markets: vector<ID>,
    /// Markets valued so far this flush; folded against `expected` at finish.
    valued_expiry_markets: vector<ID>,
    /// Running Σ of each valued market's NAV (settled markets contribute 0).
    total_nav: u64,
    /// Oracle state frozen during the snapshot stage, one entry per expected
    /// market. Keyed by market id so a `Pricer` can never be applied to the wrong
    /// market. `none` marks a market that was already settled at snapshot time and
    /// therefore contributes 0.
    ///
    /// This map is what makes the valuation stage deterministic: it decides both
    /// the mark AND the sweep-vs-value branch, so no later transaction's clock or
    /// oracle state can change a market's contribution.
    frozen_pricers: VecMap<ID, Option<Pricer>>,
    /// Set by `seal_valuation_snapshot`; no market may be valued before it. Nothing
    /// may be snapshotted after it because sealing consumes the `SnapshotStage`.
    sealed: bool,
    /// Clock time the flush was started, for the stuck-flush deadline.
    started_at_ms: u64,
    /// Address that started this flush. Only it may value markets and finish, for as
    /// long as the flush is its own — see `assert_valuation_starter`.
    started_by: address,
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
        staked_deep: balance::zero(),
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

/// Return pooled DEEP custody for SDK and devInspect state reads.
public fun staked_deep(vault: &PoolVault): u64 {
    vault.staked_deep.value()
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
/// Starting engages the valuation lock and snapshots every active expiry that must
/// be included before the queues can drain.
///
/// The lock is held until `finish_flush` or `abort_valuation`, across transactions,
/// and it gates the whole mutation surface (mint, redeem, liquidate, LP
/// request/cancel, cash rebalance, market creation, settlement) — so the books
/// cannot move while a flush is in flight. `abort_valuation` is the escape if the
/// flush is abandoned; see its deadline.
///
/// Returns the `SnapshotStage` potato: every `snapshot_expiry_pricer` borrows it and
/// `seal_valuation_snapshot` consumes it, so the transaction does not typecheck
/// unless the whole snapshot stage lands in it.
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

/// Freeze one snapshotted market's oracle state for this flush.
///
/// Holding `SnapshotStage` is what admits this call, and that potato cannot leave the
/// transaction `start_pool_valuation` minted it in — so every `Pricer` here is loaded
/// at one instant, which is what lets the valuation stage span transactions without
/// mixing marks (audit L10). This stage reads oracles only — it never walks a payout
/// tree — so all markets fit one PTB regardless of book size.
///
/// The oracle feeding this stage must have been written in an EARLIER transaction:
/// `pricing::resolve_live_pricer` refuses a read stamped with the current transaction
/// digest (RP-24), so a keeper cannot refresh and snapshot in one PTB. Refresh first,
/// then snapshot inside the feeds' freshness windows.
///
/// A market already settled at snapshot time is recorded with no pricer and
/// contributes 0. An expired-but-unsettled market aborts: it has no well-defined
/// mark (the documented `current_nav` liveness precondition), and because this
/// stage is atomic the abort reverts the whole snapshot transaction, so the lock is
/// never left engaged. Settle it first, then start the flush — that ordering is
/// what keeps the settlement gate below from deadlocking against the flush.
public fun snapshot_expiry_pricer(
    vault: &mut PoolVault,
    _stage: &SnapshotStage,
    market: &ExpiryMarket,
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
    assert!(valuation.expected_expiry_markets.contains(&expiry_market_id), EExpiryMarketNotActive);
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
    valuation.frozen_pricers.insert(expiry_market_id, frozen);
}

/// Close the snapshot stage once every expected market has a frozen pricer.
///
/// Consuming `SnapshotStage` is the simultaneity proof: the potato dies here, so no
/// later transaction can add oracle state to this flush, and every market is marked
/// at the instant the snapshot transaction executed. Valuation may then resume across
/// as many transactions as it needs.
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

/// Run the per-market cash flow for one snapshotted market, then fold its NAV into
/// the running total. The market must be sealed into the snapshot and not already
/// valued. A market frozen as settled is swept (deactivated, cash returned, profit
/// materialized) and contributes 0; a market frozen with a pricer is rebalanced to
/// target and valued on its current cash against that frozen mark.
///
/// This is the resumable stage: it may be called in any transaction after the seal,
/// spread across as many as the caller needs. It reads no oracle and no clock — the
/// frozen snapshot alone decides both the branch and the mark, so the result is
/// identical whether the whole pool is valued in one transaction or twenty.
///
/// Only this stage walks payout trees, so each transaction now carries one market's
/// dynamic-field children instead of the entire pool's.
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
        valuation.assert_expiry_ready_to_value(expiry_market_id);
        *valuation.frozen_pricers.get(&expiry_market_id)
    };

    let nav = if (frozen.is_none()) {
        // Frozen as settled at snapshot time. The lock gates `try_settle`, so the
        // market cannot have left that state since.
        vault.sweep_settled_expiry(market, config);
        0
    } else {
        vault.rebalance_live_expiry(market, expiry_market_id);
        market.current_nav(frozen.borrow())
    };

    let valuation = vault.valuation.borrow_mut();
    valuation.valued_expiry_markets.push_back(expiry_market_id);
    valuation.total_nav = valuation.total_nav + nav;
}

/// Finish a full-pool valuation and run the LP flush: prove every snapshotted market
/// was valued exactly once, price the pool NAV, then drain the supply/withdraw queues
/// at that frozen mark (mint PLP for supplies, burn PLP and pay DUSDC for
/// withdrawals), release the valuation lock, retire the in-flight valuation, and return the
/// LP-attributable pool-wide DUSDC NAV (idle + Σ active NAV, net of the
/// pending-protocol-profit exclusion priced from the aggregate profit basis).
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
    let PoolValuation { total_nav, valued_expiry_markets, .. } = valuation;

    let idle_balance_before = vault.expiry_accounting.idle_balance();
    let pool_nav = lp_pool_value(
        vault,
        config.protocol_reserve_profit_share(),
        total_nav,
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
    );
    pool_nav
}

/// Discard an in-flight valuation and release the lock, without draining any queue.
///
/// A resumable flush can be abandoned mid-way (a dead keeper, an exhausted gas
/// budget, a market whose valuation transaction keeps failing), and while the lock
/// is held the entire mutation surface is frozen. The hot-potato flush could not
/// reach that state — the potato had to be consumed in its own transaction — so this
/// escape is what replaces that guarantee.
///
/// Permissionless, but only once the flush has been in flight for longer than
/// `max_valuation_window_ms`: within the window the operator is presumed still
/// working through it, and cancelling would waste the valuation transactions already
/// paid for. `abort_valuation_privileged` is the immediate operator path.
///
/// Partial NAV is discarded rather than reused: the frozen marks are only sound as a
/// simultaneous set, so a later flush must re-snapshot. Cash already moved by
/// `value_expiry`'s rebalance/sweep stays moved — those are invariant-preserving
/// per-market operations that stand on their own.
public fun abort_valuation(vault: &mut PoolVault, config: &mut ProtocolConfig, clock: &Clock) {
    config.assert_version();
    config.assert_valuation_in_progress();
    let deadline = vault.valuation.borrow().started_at_ms + config.max_valuation_window_ms();
    assert!(clock.timestamp_ms() >= deadline, EValuationDeadlineNotReached);
    vault.abort_valuation_internal(config);
}

/// Discard an in-flight valuation immediately, on the same lifecycle authority that
/// started it. Same semantics as `abort_valuation` without the deadline.
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

/// Stake DEEP for trading benefits. The DEEP is held in the pool vault; the new
/// amount is recorded as inactive and becomes eligible after the next epoch
/// boundary. It moves to active only when a later stake, trade, or claim flow calls
/// `predict_account::roll_active_stake`. Callable anytime, any number of times.
public fun stake_deep(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    amount: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    wrapper.settle<DEEP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let deep = account.withdraw<DEEP>(amount, ctx);
    predict_account::roll_active_stake(account, ctx);
    predict_account::add_inactive_stake(account, amount, ctx);
    vault.staked_deep.join(deep.into_balance());
    vault_events::emit_deep_staked(
        vault.id(),
        account.account_id(),
        amount,
        predict_account::active_stake(account),
        predict_account::inactive_stake(account),
    );
}

/// Withdraw all staked DEEP (active and inactive) at any time, no penalty.
public fun unstake_deep(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    wrapper.settle<DEEP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let amount = predict_account::remove_all_stake(account, ctx);
    if (amount > 0) {
        let deep = vault.staked_deep.split(amount).into_coin(ctx);
        account.deposit<DEEP>(deep);
    };
    vault_events::emit_deep_unstaked(vault.id(), account.account_id(), amount);
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
/// (`registry::create_and_share_expiry_market`). Blocked while a full-pool valuation is in
/// progress.
public fun rebalance_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    vault.sweep_or_rebalance_expiry(market, config, clock);
}

/// Resolve a settled trading-loss rebate using valid account authority.
public fun claim_trading_loss_rebate(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    vault.claim_trading_loss_rebate_internal(market, account, config, ctx);
}

/// Permissionlessly resolve one account's settled trading-loss rebate using Predict
/// app auth. `deauthorize_app<PredictApp>` disables this automation; owners can
/// still use `claim_trading_loss_rebate` with owner auth.
public fun claim_trading_loss_rebate_permissionless(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    account_registry: &AccountRegistry,
    config: &ProtocolConfig,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    wrapper.settle<DUSDC>(root, clock);
    let auth = predict_account::generate_auth_as_app(account_registry);
    let account = wrapper.load_account_mut(auth);
    vault.claim_trading_loss_rebate_internal(market, account, config, ctx);
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
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
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

fun claim_trading_loss_rebate_internal(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    ctx: &mut TxContext,
) {
    let vault_id = vault.id();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    assert!(market.is_settled(), EMarketNotSettled);
    let settlement_price = market.settlement_price();
    let account_id = account.account_id();
    let summary = predict_account::resolve_expiry_summary(account, expiry_market_id);
    let trading_fees_paid = summary.fees_paid();
    let gross_profit = summary.gross_profit();
    let (residual_cash, rebate_amount) = market.claim_trading_loss_rebate(
        account,
        &summary,
        ctx,
    );
    let returned_cash_amount = vault
        .expiry_accounting
        .receive_expiry_cash(residual_cash, expiry_market_id);
    if (returned_cash_amount > 0) {
        vault_events::emit_expiry_cash_received(
            vault_id,
            expiry_market_id,
            settlement_price,
            returned_cash_amount,
        );
        vault.materialize_expiry_profit(config, expiry_market_id);
    };
    vault_events::emit_trading_loss_rebate_claimed(
        vault_id,
        expiry_market_id,
        account_id,
        rebate_amount,
        returned_cash_amount,
        trading_fees_paid,
        gross_profit,
    );
}

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
fun lp_pool_value(
    vault: &PoolVault,
    protocol_reserve_profit_share: u64,
    active_expiry_value: u64,
): u64 {
    let idle_balance = vault.expiry_accounting.idle_balance();
    let profit_basis_credits = vault.expiry_accounting.profit_basis_credits();
    let profit_basis_debits = vault.expiry_accounting.profit_basis_debits();
    let pending_protocol_profit = vault.expiry_accounting.pending_protocol_profit();
    let gross_pool_value = idle_balance + active_expiry_value;
    let aggregate_credits = profit_basis_credits + active_expiry_value;
    let exclusion = math::mul_down(
        aggregate_credits.saturating_sub(profit_basis_debits),
        protocol_reserve_profit_share,
    );
    // The realized `credits - debits` term is sticky: it does not shrink when LPs
    // withdraw idle cash, so when an active mark they withdrew against later
    // collapses, the held-out total (`exclusion + pending_protocol_profit`) can
    // exceed gross. LP value can never be negative, so floor it at 0 to keep the
    // subtraction from underflow-aborting. A 0/dust pool NAV makes non-executable
    // LP queue heads refund inside `lp_book::drain`, rather than aborting the flush.
    gross_pool_value.saturating_sub(exclusion + pending_protocol_profit)
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
        vault.top_up_live_expiry_cash(market, expiry_market_id, cash_balance, target_cash);
    } else if (cash_balance > sweep_threshold_cash) {
        vault.sweep_live_expiry_surplus(market, expiry_market_id, cash_balance, target_cash);
    };
}

fun top_up_live_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    expiry_market_id: ID,
    cash_balance: u64,
    target_cash: u64,
) {
    let requested_top_up = target_cash - cash_balance;
    let funding_room = vault.expiry_accounting.available_expiry_funding(expiry_market_id);
    let top_up = requested_top_up.min(vault.expiry_accounting.idle_balance()).min(funding_room);
    if (top_up == 0) return;

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
}

fun sweep_live_expiry_surplus(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    expiry_market_id: ID,
    cash_balance: u64,
    target_cash: u64,
) {
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

/// Engage the valuation lock and snapshot the active expiry set after requiring a
/// bootstrapped pool with nonzero PLP supply.
fun start_pool_valuation_internal(
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    config.begin_valuation();
    vault
        .valuation
        .fill(PoolValuation {
            expected_expiry_markets: vault.expiry_accounting.active_expiry_markets(),
            valued_expiry_markets: vector[],
            total_nav: 0,
            frozen_pricers: vec_map::empty(),
            sealed: false,
            started_at_ms: clock.timestamp_ms(),
            started_by: ctx.sender(),
        });
}

/// Drop the in-flight valuation and release the lock. Emits so an abandoned flush is
/// visible off-chain rather than only inferable from the absent `FlushExecuted`.
fun abort_valuation_internal(vault: &mut PoolVault, config: &mut ProtocolConfig) {
    let valuation = vault.valuation.extract();
    let vault_id = vault.id();
    let PoolValuation { expected_expiry_markets, valued_expiry_markets, .. } = valuation;
    config.end_valuation();
    vault_events::emit_flush_aborted(
        vault_id,
        expected_expiry_markets.length(),
        valued_expiry_markets.length(),
    );
}

/// Abort unless the caller started this flush.
///
/// The hot potato used to carry this: `finish_flush` consumed a `PoolValuation` only
/// `start_pool_valuation` could mint, so a flush could only be completed by whoever
/// started it. Moving the valuation onto the vault made the completion entrypoints
/// reachable by anyone, and a third party finishing a flush is not harmless — it may
/// pass zero drain budgets, which retires the frozen mark with no LP request filled
/// and forces the operator to re-value the whole pool. Cheap to do, expensive to
/// suffer, and repeatable.
///
/// There is no permissionless completion path past the deadline: an abandoned flush is
/// cleared by `abort_valuation`, which discards it rather than retiring a mark nobody
/// audited.
fun assert_valuation_starter(vault: &PoolVault, ctx: &TxContext) {
    assert!(vault.valuation.borrow().started_by == ctx.sender(), ENotValuationStarter);
}

/// Abort unless the market is in the snapshot and not already valued (exactly-once).
fun assert_expiry_ready_to_value(valuation: &PoolValuation, expiry_market_id: ID) {
    assert!(valuation.expected_expiry_markets.contains(&expiry_market_id), EExpiryMarketNotActive);
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
