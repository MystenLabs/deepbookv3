// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault.
///
/// PoolVault owns the PLP treasury cap, idle
/// DUSDC, the protocol reserve, sponsor-funded fee incentives, per-expiry cash
/// accounting, and the queued LP supply/withdraw requests. It coordinates the
/// full-pool NAV valuation (an atomic snapshot followed by resumable per-market
/// liability walks) and
/// the unified per-market cash flow (initial funding, live rebalance/sweep, and
/// settled-market sweep with terminal profit materialization). LPs queue
/// supply/withdraw requests routed through a loaded Account; each flush
/// (`finish_flush`) drains them at the frozen pool NAV, minting/burning PLP and
/// delivering fills to each account via the balance accumulator.
module deepbook_predict::plp;

use account::account::{AccountWrapper, Auth};
use deepbook_predict::{
    admin::AdminCap,
    constants,
    expiry_market::ExpiryMarket,
    lp_book::{Self, LpBook},
    market_lifecycle_cap::MarketLifecycleProof,
    pool_accounting::{Self, Ledger},
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
    coin_registry::{Self, MetadataCap}
};

const EWrongPoolVault: u64 = 0;
const EMissingExpiryValuation: u64 = 1;
const ENotBootstrapped: u64 = 2;
const EAlreadyBootstrapped: u64 = 3;
const EBelowMinBootstrapLiquidity: u64 = 4;
const EBelowMinFeeIncentiveSponsorship: u64 = 5;
const EMaxLiveExpiryMarketsExceeded: u64 = 6;
const EPoolValuationAlreadyStored: u64 = 7;
const EPoolValuationInProgress: u64 = 8;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

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
    /// Canonical flush generation. Snapshot start increments it atomically;
    /// requests record the current value and only earlier generations may drain.
    snapshot_seq: u64,
    /// Durable valuation prepared by one atomic snapshot transaction and filled
    /// by resumable per-market liability walks.
    valuation: Option<PoolValuation>,
}

/// Transaction-local snapshot builder. Its lack of abilities requires every
/// market's pricer and cash state to be prepared atomically before the inner
/// valuation can be stored in `PoolVault`.
public struct PoolSnapshot {
    pool_vault_id: ID,
    unprepared_markets: vector<ID>,
    pending_markets: vector<ID>,
    aggregate_market_cash: u64,
}

/// Frozen pool-price function awaiting zero or more per-market liability walks.
public struct PoolValuation has store {
    assets_remaining: u64,
    profit_remaining: u64,
    pending_markets: vector<ID>,
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
        snapshot_seq: 0,
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

/// Begin the atomic snapshot stage using a registry-issued lifecycle proof. The
/// returned hot potato fixes the active market set and increments the vault's
/// canonical snapshot sequence. Every market must be prepared before its valuation
/// can become durable.
public fun start_pool_valuation(
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    lifecycle_proof: MarketLifecycleProof,
): PoolSnapshot {
    config.assert_version();
    lifecycle_proof.destroy_proof();
    start_pool_valuation_internal(config, vault)
}

/// Prepare one market inside the atomic snapshot transaction. A stale market that
/// is no longer in the active set is skipped. A settled market is swept out of the
/// set; a live market contributes its cash to the aggregate and stores its bound
/// pricer in the payout tree, leaving only the expensive liability walk unfilled.
///
/// Settlement is a separate PTB step through `expiry_market::try_settle`. An
/// expired unsettled market cannot produce the live pricer required here.
public fun snapshot_expiry(
    snapshot: &mut PoolSnapshot,
    vault: &mut PoolVault,
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
    config.assert_snapshot_in_progress();
    let expiry_market_id = market.id();
    snapshot.assert_pool_vault(vault);
    let index = snapshot.unprepared_markets.find_index!(|id| *id == expiry_market_id);
    if (index.is_none()) return;
    let index = index.destroy_some();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    let settled = vault.sweep_or_rebalance_expiry(market, config, clock);
    if (!settled) {
        let pricer = market.load_live_pricer(
            config,
            propbook_registry,
            pyth,
            bs_values,
            bs_svi,
            clock,
            ctx,
        );
        market.set_snapshot_pricer(pricer, vault.snapshot_seq);
        snapshot.aggregate_market_cash = snapshot.aggregate_market_cash + market.free_cash();
        snapshot.pending_markets.push_back(expiry_market_id);
    };
    snapshot.unprepared_markets.swap_remove(index);
}

/// Consume the atomic snapshot builder after every market has frozen its cash and
/// pricer. All pool and queue inputs are reduced to the constants needed to finish
/// pricing as each market liability arrives, then the snapshot lock is released.
public fun finish_pool_snapshot(
    snapshot: PoolSnapshot,
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
) {
    config.assert_version();
    config.assert_snapshot_in_progress();
    snapshot.assert_pool_vault(vault);
    assert!(vault.valuation.is_none(), EPoolValuationAlreadyStored);
    let PoolSnapshot {
        unprepared_markets,
        pending_markets,
        aggregate_market_cash,
        ..,
    } = snapshot;
    assert!(unprepared_markets.is_empty(), EMissingExpiryValuation);
    unprepared_markets.destroy_empty();

    let assets_remaining = (
        vault.expiry_accounting.idle_balance() + aggregate_market_cash,
    ).saturating_sub(vault.expiry_accounting.pending_protocol_profit());
    let profit_remaining = (
        vault.expiry_accounting.profit_basis_credits() + aggregate_market_cash,
    ).saturating_sub(vault.expiry_accounting.profit_basis_debits());
    vault
        .valuation
        .fill(PoolValuation {
            assets_remaining,
            profit_remaining,
            pending_markets,
        });
    config.end_snapshot();
}

/// Consume one pending market's frozen liability into the pool aggregate. Calls
/// without a current valuation, markets outside it, and repeated calls are no-ops.
public fun value_expiry(vault: &mut PoolVault, market: &mut ExpiryMarket, config: &ProtocolConfig) {
    config.assert_version();
    if (vault.valuation.is_none()) return;
    let valuation = vault.valuation.borrow_mut();
    let index = valuation.pending_markets.find_index!(|id| *id == market.id());
    if (index.is_none()) return;
    let index = index.destroy_some();
    let liability = market.consume_snapshot_marked_liability();
    valuation.assets_remaining = valuation.assets_remaining.saturating_sub(liability);
    valuation.profit_remaining = valuation.profit_remaining.saturating_sub(liability);
    valuation.pending_markets.swap_remove(index);
}

/// Finish the stored full-pool valuation: prove every snapshotted liability is
/// filled, price the pool NAV, drain the supply/withdraw queues at that frozen
/// mark, clear the durable valuation, and return the LP-attributable pool-wide
/// DUSDC NAV. Returns `none` when no valuation remains to finalize. Only requests
/// from generations strictly older than the snapshot are eligible.
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
    config: &ProtocolConfig,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
    ctx: &mut TxContext,
): Option<u64> {
    config.assert_version();
    if (vault.valuation.is_none()) return option::none();
    let valuation = vault.valuation.extract();
    let PoolValuation {
        assets_remaining,
        profit_remaining,
        pending_markets,
    } = valuation;
    assert!(pending_markets.is_empty(), EMissingExpiryValuation);
    pending_markets.destroy_empty();

    let protocol_exclusion = math::mul_down(
        profit_remaining,
        config.protocol_reserve_profit_share(),
    );
    let pool_value = assets_remaining.saturating_sub(protocol_exclusion);
    // Only this drain can mint or burn PLP while a valuation is stored, so supply
    // is unchanged from the snapshot and needs only one pre-drain sample.
    let total_supply = vault.lp.total_supply();
    let vault_id = vault.id();
    let snapshot_seq = vault.snapshot_seq;
    let mark = lp_book::new_flush_mark(pool_value, total_supply);
    let fee_rates = lp_book::new_fee_rates(
        config.plp_supply_fee_rate(),
        config.plp_withdraw_fee_rate(),
    );
    let supply_fee_rate = fee_rates.supply_fee_rate();
    let withdraw_fee_rate = fee_rates.withdraw_fee_rate();
    let drain_summary = vault
        .lp
        .drain(
            &mut vault.expiry_accounting,
            mark,
            fee_rates,
            vault_id,
            snapshot_seq,
            supply_budget,
            withdraw_budget,
            config.lp_request_limit_flush_attempts(),
            config.max_lp_pool_value(),
            ctx,
        );
    let total_supply_after = vault.lp.total_supply();
    vault_events::emit_flush_executed(
        vault_id,
        ctx.epoch(),
        snapshot_seq,
        pool_value,
        total_supply,
        supply_fee_rate,
        withdraw_fee_rate,
        drain_summary.supplies_filled(),
        drain_summary.withdrawals_filled(),
        drain_summary.requests_processed(),
        vault.expiry_accounting.idle_balance(),
        total_supply_after,
    );
    option::some(pool_value)
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
/// (`registry::create_and_share_expiry_market`). Blocked only while the atomic
/// snapshot is being assembled.
public fun rebalance_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_snapshot_in_progress();
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
    config.assert_not_snapshot_in_progress();
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
    config.assert_not_snapshot_in_progress();
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let payment = account.withdraw<DUSDC>(amount, ctx);
    let vault_id = vault.id();
    let account_id = account.account_id();
    let recipient = account.receive_address();
    let request_seq = vault.snapshot_seq;
    let index = vault.lp.request_supply(payment, account_id, recipient, min_plp_out, request_seq);
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
    config.assert_not_snapshot_in_progress();
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    wrapper.settle<PLP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let lp = account.withdraw<PLP>(amount, ctx);
    let vault_id = vault.id();
    let account_id = account.account_id();
    let recipient = account.receive_address();
    let request_seq = vault.snapshot_seq;
    let index = vault.lp.request_withdraw(lp, account_id, recipient, min_dusdc_out, request_seq);
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
/// Cancellation is blocked while a frozen valuation is readable on-chain.
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
    config.assert_not_snapshot_in_progress();
    vault.assert_no_pending_valuation();
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
/// Cancellation is blocked while a frozen valuation is readable on-chain.
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
    config.assert_not_snapshot_in_progress();
    vault.assert_no_pending_valuation();
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

fun assert_no_pending_valuation(vault: &PoolVault) {
    assert!(vault.valuation.is_none(), EPoolValuationInProgress);
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

/// Engage the snapshot lock and collect the active expiries the transaction must
/// prepare before it can persist the aggregate valuation.
fun start_pool_valuation_internal(
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
): PoolSnapshot {
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    assert!(vault.valuation.is_none(), EPoolValuationAlreadyStored);
    config.begin_snapshot();
    vault.snapshot_seq = vault.snapshot_seq + 1;
    PoolSnapshot {
        pool_vault_id: vault.id(),
        unprepared_markets: vault.expiry_accounting.active_expiry_markets(),
        pending_markets: vector[],
        aggregate_market_cash: 0,
    }
}

fun assert_pool_vault(snapshot: &PoolSnapshot, vault: &PoolVault) {
    assert!(snapshot.pool_vault_id == vault.id(), EWrongPoolVault);
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext): ID {
    let (vault_id, metadata_cap) = init_plp(PLP {}, ctx);
    transfer_metadata_cap(metadata_cap, ctx);
    vault_id
}
