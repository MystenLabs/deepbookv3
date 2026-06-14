// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault.
///
/// PoolVault owns the PLP treasury cap, the pooled DEEP staked by managers, idle
/// DUSDC, the protocol reserve, per-expiry cash accounting, and the async LP
/// supply/withdraw queues. It coordinates the full-pool NAV valuation (a hot-potato
/// aggregation over every active market) and the unified per-market cash flow
/// (initial funding, live rebalance/sweep, and settled-market sweep with terminal
/// profit materialization). LPs queue supply/withdraw requests routed through a
/// PredictManager; the daily flush (`finish_flush`) drains them at the frozen pool
/// NAV, minting/burning PLP and delivering fills to each manager via the balance
/// accumulator. Incentives moved to a separate staking contract; DEEP staking is an
/// unrelated trading feature.
module deepbook_predict::plp;

use deepbook_predict::{
    admin::AdminCap,
    constants,
    expiry_market::ExpiryMarket,
    lp_request_queue::{Self, RequestQueue},
    market_lifecycle_cap::MarketLifecycleCap,
    pool_accounting::{Self, Ledger},
    predict_manager::PredictManager,
    protocol_config::ProtocolConfig,
    vault_events
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use propbook::{block_scholes_feed::BlockScholesFeed, pyth_feed::PythFeed};
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry,
    vec_set::{Self, VecSet}
};
use token::deep::DEEP;

const EExpiryMarketNotActive: u64 = 0;
const EExpiryMarketAlreadyValued: u64 = 1;
const EWrongPoolVault: u64 = 2;
const EMissingExpiryValuation: u64 = 3;
const EBelowMinSupplyRequest: u64 = 4;
const EBelowMinWithdrawRequest: u64 = 5;
const ENotRequestOwner: u64 = 6;
const EBootstrapNavNotEmpty: u64 = 7;
const EPackageVersionDisabled: u64 = 9;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Pool-level vault state.
public struct PoolVault has key {
    id: UID,
    /// Protocol-owned DUSDC (the materialized terminal-profit cut) excluded from
    /// PLP redemption.
    protocol_reserve_balance: Balance<DUSDC>,
    /// Pooled DEEP staked by all managers for trading benefits. Per-manager
    /// active/inactive amounts are mirrored on each `PredictManager`.
    staked_deep: Balance<DEEP>,
    /// Treasury cap for the PLP share token: minted on supply fills, burned on
    /// withdraw fills during the flush.
    treasury_cap: TreasuryCap<PLP>,
    /// Idle DUSDC custody, registered expiries, and per-expiry cash-flow rows.
    expiry_accounting: Ledger,
    /// Queued LP supply requests, each escrowing DUSDC until the next flush.
    supply_queue: RequestQueue<DUSDC>,
    /// Queued LP withdraw requests, each escrowing PLP until the next flush.
    withdraw_queue: RequestQueue<PLP>,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
}

/// Transaction-local full-pool NAV valuation hot potato.
///
/// `start_pool_valuation` snapshots the active expiry set; each `value_expiry`
/// runs the per-market cash flush then folds that market's NAV into `total_nav`
/// exactly once (a swept settled market contributes 0); `finish_flush` proves every
/// snapshotted market was valued, returns the LP-attributable pool NAV, and drains
/// the LP queues against it. Has no abilities, so it must be consumed by the finisher.
public struct PoolValuation {
    pool_vault_id: ID,
    /// Active expiry markets snapshotted at start; every one must be valued.
    expected_expiry_markets: vector<ID>,
    /// Markets valued so far this flow; folded against `expected` at finish.
    valued_expiry_markets: vector<ID>,
    /// Running Σ of each valued market's NAV (settled markets contribute 0).
    total_nav: u64,
}

// === Package Initializer ===

/// Register PLP metadata and create the pool vault on package publish.
fun init(witness: PLP, ctx: &mut TxContext) {
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
    create_and_share(treasury_cap, ctx);
    transfer::public_transfer(metadata_cap, ctx.sender());
}

// === Public Functions ===

/// Return the pool vault object ID.
public fun id(vault: &PoolVault): ID {
    vault.id.to_inner()
}

/// Return this vault's mirrored set of allowed package versions.
public fun allowed_versions(vault: &PoolVault): VecSet<u64> {
    vault.allowed_versions
}

/// Return DEEP staked by managers and held in custody by the pool.
public fun staked_deep(vault: &PoolVault): u64 {
    vault.staked_deep.value()
}

/// Return idle DUSDC held by the pool (available for funding and withdrawals).
public fun idle_balance(vault: &PoolVault): u64 {
    vault.expiry_accounting.idle_balance()
}

/// Return protocol-owned DUSDC excluded from PLP redemption.
public fun protocol_reserve_balance(vault: &PoolVault): u64 {
    vault.protocol_reserve_balance.value()
}

/// Return the total PLP share supply outstanding.
public fun plp_total_supply(vault: &PoolVault): u64 {
    vault.treasury_cap.total_supply()
}

/// Return the count of pending (un-drained) LP supply requests.
public fun supply_requests_pending(vault: &PoolVault): u64 {
    vault.supply_queue.pending()
}

/// Return the count of pending (un-drained) LP withdraw requests.
public fun withdraw_requests_pending(vault: &PoolVault): u64 {
    vault.withdraw_queue.pending()
}

/// Return the expiry markets still contributing active pool valuation/risk.
public fun active_expiry_markets(vault: &PoolVault): &vector<ID> {
    vault.expiry_accounting.active_expiry_markets()
}

/// Return the pricing debit side of the aggregate expiry profit basis.
public fun profit_basis_debits(vault: &PoolVault): u64 {
    vault.expiry_accounting.profit_basis_debits()
}

/// Return the pricing credit side of the aggregate expiry profit basis.
public fun profit_basis_credits(vault: &PoolVault): u64 {
    vault.expiry_accounting.profit_basis_credits()
}

/// Begin a full-pool flush (NAV valuation + LP queue drain) as the protocol
/// operator (`AdminCap`).
///
/// The flush is cron-driven, not permissionless (audit L8): only the operator
/// `AdminCap` here, or a market deployer via `start_pool_valuation_as_deployer`, may
/// start one. Engages the protocol valuation lock — so no NAV-changing op can
/// interleave between value steps — and snapshots the active expiry set every
/// `value_expiry` must cover. The hot potato can only be created here, so gating the
/// start gates the whole flush.
public fun start_pool_valuation(
    config: &mut ProtocolConfig,
    vault: &PoolVault,
    _admin_cap: &AdminCap,
): PoolValuation {
    start_pool_valuation_internal(config, vault)
}

/// Begin a full-pool flush as a market deployer (`MarketLifecycleCap`). This is a
/// PRIVILEGED start, not a permissionless one: the flush prices the pool NAV off the
/// live oracle and `finish_flush` drains the LP queues at that mark, and Pyth updates
/// (`update_from_lazer`) are permissionless — so a flush-capable cap-holder who
/// manipulates the live oracle in a preceding tx, then flushes, could fill their own
/// queued supply/withdraw request at a mark they chose (the keeper's "refresh to true
/// price before flushing" mitigation only protects the honest-keeper flush). The start
/// is therefore gated on trust: every flush-capable cap-holder — the operator
/// `AdminCap` (via `start_pool_valuation`) and the market-deployer `MarketLifecycleCap`
/// (here), both tightly held — is relied on NOT to manipulate the live oracle. `plp`
/// cannot registry-validate the lifecycle cap here anyway (import cycle: `registry`
/// depends on `plp::PoolVault`), and registry validation would only reject a *revoked*
/// cap, not an active malicious holder — so trust, not allowlisting, is the control.
public fun start_pool_valuation_as_deployer(
    config: &mut ProtocolConfig,
    vault: &PoolVault,
    _lifecycle_cap: &MarketLifecycleCap,
): PoolValuation {
    start_pool_valuation_internal(config, vault)
}

/// Run the per-market cash flow for one snapshotted market, then fold its NAV into
/// the running total. The market must be in the snapshot and not already valued
/// (the exactly-once proof). The flush IS the valuation: a settled market is swept
/// (deactivated, cash returned, profit materialized) and contributes 0; a live
/// market is rebalanced to target and valued on its current cash. The flush uses
/// the lock-free inner, so it does not self-abort under the valuation lock.
///
/// FLUSH-LIVENESS PRECONDITION (settlement-v2): the live branch calls
/// `current_nav`, which asserts the market is pre-expiry. With settlement stubbed
/// (`is_settled()` always false), a past-expiry market is never swept off the
/// active set, so once any active market crosses its expiry `value_expiry` aborts
/// `EMarketNotActive` and bricks the whole flush. Until settlement-v2 lands, the
/// operator MUST settle / avoid letting an active market cross its expiry. See
/// `expiry_market::current_nav` for why no solvency-safe substitute mark exists.
public fun value_expiry(
    valuation: &mut PoolValuation,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    clock: &Clock,
) {
    config.assert_valuation_in_progress();
    let expiry_market_id = market.id();
    valuation.assert_expiry_ready_to_value(expiry_market_id);
    vault.rebalance_expiry_cash_inner(market, config);
    let nav = if (market.is_settled()) {
        0
    } else {
        market.current_nav(config, pyth, bs, clock)
    };
    valuation.valued_expiry_markets.push_back(expiry_market_id);
    valuation.total_nav = valuation.total_nav + nav;
}

/// Finish a full-pool valuation and run the LP flush: prove every snapshotted market
/// was valued exactly once, price the pool NAV, then drain the supply/withdraw queues
/// at that frozen mark (mint PLP for supplies, burn PLP and pay DUSDC for
/// withdrawals, refund degenerate requests), release the valuation lock, consume the
/// potato, and return the LP-attributable pool-wide DUSDC NAV (idle + Σ active NAV,
/// net of the pending-protocol-profit exclusion priced from the aggregate profit
/// basis).
public fun finish_flush(
    valuation: PoolValuation,
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    ctx: &mut TxContext,
): u64 {
    vault.assert_version_allowed();
    config.assert_valuation_in_progress();
    valuation.assert_pool_vault(vault);
    assert_all_expected_valued(
        &valuation.expected_expiry_markets,
        &valuation.valued_expiry_markets,
    );
    let PoolValuation { total_nav, valued_expiry_markets, .. } = valuation;

    let idle = vault.expiry_accounting.idle_balance();
    let pool_nav = lp_pool_value(
        idle,
        vault.expiry_accounting.profit_basis_credits(),
        vault.expiry_accounting.profit_basis_debits(),
        config.protocol_reserve_profit_share(),
        total_nav,
    );
    vault_events::emit_pool_valued(
        vault.id(),
        pool_nav,
        idle,
        total_nav,
        valued_expiry_markets.length(),
    );

    // Snapshot the share price once (frozen pair), drain both queues against it, then
    // release the valuation lock at the very end.
    let total_supply = vault.treasury_cap.total_supply();
    let (supplies_filled, withdrawals_filled, requests_processed) = vault.drain_lp_requests(
        pool_nav,
        total_supply,
        ctx,
    );
    config.end_valuation();
    vault_events::emit_flush_executed(
        vault.id(),
        ctx.epoch(),
        pool_nav,
        total_supply,
        supplies_filled,
        withdrawals_filled,
        requests_processed,
        vault.expiry_accounting.idle_balance(),
    );
    pool_nav
}

/// Stake DEEP for trading benefits. The DEEP is held in the pool vault; the
/// amount is recorded as inactive on the manager and activates next epoch
/// (`PredictManager.update_stake`, run by the trade/claim flows). Callable
/// anytime, any number of times.
public fun stake_deep(
    vault: &mut PoolVault,
    manager: &mut PredictManager,
    deep: Coin<DEEP>,
    ctx: &TxContext,
) {
    vault.assert_version_allowed();
    manager.assert_owner(ctx);
    manager.update_stake(ctx);
    let amount = deep.value();
    manager.add_inactive_stake(amount);
    vault.staked_deep.join(deep.into_balance());
    vault_events::emit_deep_staked(
        vault.id(),
        manager.id(),
        amount,
        manager.active_stake(),
        manager.inactive_stake(),
    );
}

/// Withdraw all staked DEEP (active and inactive) at any time, no penalty.
public fun unstake_deep(
    vault: &mut PoolVault,
    manager: &mut PredictManager,
    ctx: &mut TxContext,
): Coin<DEEP> {
    vault.assert_version_allowed();
    manager.assert_owner(ctx);
    let amount = manager.remove_all_stake();
    vault_events::emit_deep_unstaked(vault.id(), manager.id(), amount);
    vault.staked_deep.split(amount).into_coin(ctx)
}

/// Move cash between pool idle liquidity and one expiry market.
///
/// Permissionless and standalone: anyone may call it at any cadence. Handles all
/// three per-market cases — initial funding of a freshly registered (unfunded)
/// market, ongoing live rebalance/surplus-sweep toward target, and the
/// settled-market sweep (deactivate, return all free cash, materialize profit).
/// Mint asserts backing but never pulls pool cash, so this is what makes a market
/// mintable. The market must already be registered to this vault
/// (`registry::create_expiry_market`). Blocked while a full-pool valuation is in
/// progress (the flush calls the lock-free inner directly).
public fun rebalance_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
) {
    config.assert_not_valuation_in_progress();
    vault.rebalance_expiry_cash_inner(market, config);
}

/// Queue a supply request: escrow `payment` DUSDC and record the requesting manager
/// as the fill recipient. Routed through `manager` so a composing vault's own
/// manager — not the tx signer — receives the minted PLP at the next flush. Returns
/// the queue index, the handle used to cancel before the flush.
public fun request_supply(
    vault: &mut PoolVault,
    manager: &PredictManager,
    payment: Coin<DUSDC>,
): u64 {
    vault.assert_version_allowed();
    assert!(payment.value() >= constants::min_supply_request!(), EBelowMinSupplyRequest);
    let recipient = manager.id().to_address();
    let amount = payment.value();
    let index = vault.supply_queue.enqueue(recipient, payment.into_balance());
    vault_events::emit_supply_requested(vault.id(), manager.id(), recipient, index, amount);
    index
}

/// Queue a withdraw request: escrow `lp` PLP shares and record the requesting manager
/// as the fill recipient. Returns the queue index used to cancel before the flush.
public fun request_withdraw(vault: &mut PoolVault, manager: &PredictManager, lp: Coin<PLP>): u64 {
    vault.assert_version_allowed();
    assert!(lp.value() >= constants::min_withdraw_request!(), EBelowMinWithdrawRequest);
    let recipient = manager.id().to_address();
    let amount = lp.value();
    let index = vault.withdraw_queue.enqueue(recipient, lp.into_balance());
    vault_events::emit_withdraw_requested(vault.id(), manager.id(), recipient, index, amount);
    index
}

/// Cancel a still-pending supply request, refunding its escrowed DUSDC straight into
/// the requesting manager. The caller must own `manager`, and `manager` must be the
/// request's recorded recipient.
public fun cancel_supply_request(
    vault: &mut PoolVault,
    manager: &mut PredictManager,
    index: u64,
    ctx: &mut TxContext,
) {
    vault.assert_version_allowed();
    let recipient = manager.id().to_address();
    assert!(vault.supply_queue.borrow(index).recipient() == recipient, ENotRequestOwner);
    manager.assert_owner(ctx);
    let refund = vault.supply_queue.remove(index);
    let amount = refund.value();
    manager.deposit_funds(refund, ctx);
    vault_events::emit_request_cancelled(vault.id(), manager.id(), recipient, index, amount, true);
}

/// Cancel a still-pending withdraw request, refunding its escrowed PLP straight into
/// the requesting manager. The caller must own `manager`, and `manager` must be the
/// request's recorded recipient.
public fun cancel_withdraw_request(
    vault: &mut PoolVault,
    manager: &mut PredictManager,
    index: u64,
    ctx: &mut TxContext,
) {
    vault.assert_version_allowed();
    let recipient = manager.id().to_address();
    assert!(vault.withdraw_queue.borrow(index).recipient() == recipient, ENotRequestOwner);
    manager.assert_owner(ctx);
    let refund = vault.withdraw_queue.remove(index);
    let amount = refund.value();
    manager.deposit_funds(refund, ctx);
    vault_events::emit_request_cancelled(vault.id(), manager.id(), recipient, index, amount, false);
}

// === Public-Package Functions ===

/// Create an empty pool vault from the PLP treasury cap.
public(package) fun new(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): PoolVault {
    PoolVault {
        id: object::new(ctx),
        protocol_reserve_balance: balance::zero(),
        staked_deep: balance::zero(),
        treasury_cap,
        expiry_accounting: pool_accounting::new(ctx),
        supply_queue: lp_request_queue::new(ctx),
        withdraw_queue: lp_request_queue::new(ctx),
        allowed_versions: vec_set::singleton(constants::current_version!()),
    }
}

/// Create and share an empty pool vault from the PLP treasury cap.
public(package) fun create_and_share(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): ID {
    let vault = new(treasury_cap, ctx);
    let id = vault.id();
    transfer::share_object(vault);
    id
}

/// Overwrite this vault's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_pool_vault_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(vault: &mut PoolVault, allowed_versions: VecSet<u64>) {
    vault.allowed_versions = allowed_versions;
}

/// Register a freshly created expiry market with the pool as an accounting row.
/// No cash moves: the market is not mintable until `rebalance_expiry_cash` funds
/// it. Called by `registry::create_expiry_market`.
public(package) fun register_expiry(vault: &mut PoolVault, expiry_market_id: ID) {
    vault.assert_version_allowed();
    vault.expiry_accounting.register_expiry(expiry_market_id);
}

/// Borrow the supply queue (DUSDC escrow). Package-internal for cursor/escrow reads.
public(package) fun supply_queue(vault: &PoolVault): &RequestQueue<DUSDC> {
    &vault.supply_queue
}

/// Borrow the withdraw queue (PLP escrow). Package-internal for cursor/escrow reads.
public(package) fun withdraw_queue(vault: &PoolVault): &RequestQueue<PLP> {
    &vault.withdraw_queue
}

/// Lock-free per-market cash flow shared by the public entrypoint and the
/// valuation flush. A settled market is swept (deactivated, free cash returned,
/// profit materialized) — idempotent, so a second pass is a safe no-op. A live
/// market is topped up from idle toward target, or has its surplus over target
/// swept back to idle. The valuation lock is owned by the public wrapper, not
/// here, so the flush can call this under the lock without self-aborting.
public(package) fun rebalance_expiry_cash_inner(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
) {
    vault.assert_version_allowed();
    market.assert_version_allowed();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);

    if (market.is_settled()) {
        vault.unregister_settled_expiry(market, config);
        return
    };

    let (cash_balance, target_cash, sweep_threshold_cash) = expiry_rebalance_cash_terms(market);
    if (cash_balance < target_cash) {
        let requested_top_up = target_cash - cash_balance;
        let funding_room = vault
            .expiry_accounting
            .available_expiry_funding(expiry_market_id, constants::expiry_max_funding!());
        let top_up = requested_top_up.min(vault.expiry_accounting.idle_balance()).min(funding_room);
        if (top_up > 0) {
            let cash = vault
                .expiry_accounting
                .send_expiry_cash(expiry_market_id, constants::expiry_max_funding!(), top_up);
            market.receive_pool_cash(cash);
            vault.emit_expiry_cash_rebalanced(market, expiry_market_id, top_up, true, target_cash);
        };
    } else if (cash_balance > sweep_threshold_cash) {
        let returned_cash = market.release_pool_cash(cash_balance - target_cash);
        let returned_cash_amount = vault
            .expiry_accounting
            .receive_expiry_cash(expiry_market_id, returned_cash);
        vault.emit_expiry_cash_rebalanced(
            market,
            expiry_market_id,
            returned_cash_amount,
            false,
            target_cash,
        );
    };
}

/// LP-attributable DUSDC pool value used to price PLP supply/withdraw.
///
/// `gross = idle_balance + active_expiry_value`. NAV prices the protocol's
/// not-yet-materialized profit share before terminal materialization and excludes
/// it from LP value: `exclusion = share * max(0, (credits + active) - debits)`
/// (live cash returns update credits, but reserve custody waits for terminal
/// profit).
public(package) fun lp_pool_value(
    idle_balance: u64,
    profit_basis_credits: u64,
    profit_basis_debits: u64,
    protocol_reserve_profit_share: u64,
    active_expiry_value: u64,
): u64 {
    let gross_pool_value = idle_balance + active_expiry_value;
    let aggregate_credits = profit_basis_credits + active_expiry_value;
    let exclusion = math::mul(
        aggregate_credits.saturating_sub(profit_basis_debits),
        protocol_reserve_profit_share,
    );
    // The realized `credits - debits` term is sticky: it does not shrink when LPs
    // withdraw idle cash, so when an active mark they withdrew against later
    // collapses, the exclusion can exceed gross. LP value can never be negative —
    // floor it at 0, which also prevents the subtraction from underflowing and
    // bricking all PLP supply/withdraw.
    gross_pool_value.saturating_sub(exclusion)
}

/// PLP minted for `amount` DUSDC at the frozen flush mark. Bootstrap (no shares yet)
/// mints 1:1 and requires an empty pool NAV — otherwise the mark is ill-defined and a
/// supplier would be mispriced. Otherwise `amount * total_supply / pool_value`,
/// rounded down. A wiped pool (value 0 with shares outstanding) yields 0, which the
/// caller refunds.
public(package) fun supply_shares(amount: u64, total_supply: u64, pool_value: u64): u64 {
    if (total_supply == 0) {
        assert!(pool_value == 0, EBootstrapNavNotEmpty);
        amount
    } else if (pool_value == 0) {
        0
    } else {
        math::mul_div_down(amount, total_supply, pool_value)
    }
}

/// DUSDC owed for `shares` PLP at the frozen flush mark: `shares * pool_value /
/// total_supply`, rounded down. Zero supply yields 0 (no shares can exist to redeem);
/// a dust redemption that rounds to 0 is refunded its PLP by the caller.
public(package) fun withdraw_dusdc(shares: u64, total_supply: u64, pool_value: u64): u64 {
    if (total_supply == 0) {
        0
    } else {
        math::mul_div_down(shares, pool_value, total_supply)
    }
}

// === Private Functions ===

/// Abort if the running package version is not allowed for this vault.
fun assert_version_allowed(vault: &PoolVault) {
    assert!(
        vault.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Current cash, the target cash to hold, and the upper sweep band for one expiry.
///
/// `required_cash` is payout liability plus rebate reserve; `target_cash` adds one
/// buffer above it and `sweep_threshold_cash` adds two, both floored at
/// `expiry_cash_floor`. Below target the pool tops up to target; above the sweep
/// band it returns the excess over target.
fun expiry_rebalance_cash_terms(market: &ExpiryMarket): (u64, u64, u64) {
    let required_cash = market.payout_liability() + market.rebate_reserve();
    let target_buffer = math::mul(required_cash, constants::expiry_rebalance_pct!());
    let target_cash = (required_cash + target_buffer).max(constants::expiry_cash_floor!());
    let sweep_threshold_cash = (required_cash + target_buffer + target_buffer).max(
        constants::expiry_cash_floor!(),
    );
    (market.cash_balance(), target_cash, sweep_threshold_cash)
}

/// Settled-market sweep: deactivate the expiry, return its free cash to idle, and
/// materialize its terminal profit. Idempotent — a settled market already swept
/// returns zero cash and recognizes no further profit, so a second pass is a
/// no-op. Emits only when something actually moved (cash returned or it was still
/// active).
fun unregister_settled_expiry(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
) {
    let expiry_market_id = market.id();
    let deactivated = vault.expiry_accounting.deactivate_expiry_if_present(expiry_market_id);
    let returned_cash = market.release_settled_pool_cash();
    let returned_cash_amount = vault
        .expiry_accounting
        .receive_expiry_cash(expiry_market_id, returned_cash);
    vault.materialize_expiry_profit(config, expiry_market_id);

    if (deactivated || returned_cash_amount > 0) {
        vault.emit_expiry_cash_received(market, returned_cash_amount);
    };
}

/// Materialize one terminal expiry's unapplied profit and split it: the protocol
/// cut is withdrawn from idle into the protocol reserve, the LP cut stays in idle.
fun materialize_expiry_profit(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    expiry_market_id: ID,
) {
    let profit = vault.expiry_accounting.materialize_expiry_profit(expiry_market_id);
    if (profit == 0) {
        return
    };
    let protocol_profit = math::mul(profit, config.protocol_reserve_profit_share());
    let lp_profit = profit - protocol_profit;
    if (protocol_profit > 0) {
        let protocol_profit_balance = vault.expiry_accounting.withdraw_idle(protocol_profit);
        vault.protocol_reserve_balance.join(protocol_profit_balance);
    };
    vault_events::emit_expiry_profit_materialized(
        vault.id(),
        expiry_market_id,
        lp_profit,
        protocol_profit,
        vault.expiry_accounting.idle_balance(),
        vault.protocol_reserve_balance.value(),
        vault.expiry_accounting.profit_basis_debits(),
    );
}

fun emit_expiry_cash_received(vault: &PoolVault, market: &ExpiryMarket, amount: u64) {
    let expiry_market_id = market.id();
    let (sent_to_expiry_after, received_from_expiry_after) = vault
        .expiry_accounting
        .expiry_flow_amounts(expiry_market_id);
    vault_events::emit_expiry_cash_received(
        vault.id(),
        expiry_market_id,
        market.settlement_price(),
        amount,
        vault.expiry_accounting.idle_balance(),
        sent_to_expiry_after,
        received_from_expiry_after,
    );
}

/// Emit an `ExpiryCashRebalanced` for a live top-up (`to_expiry = true`) or
/// surplus-sweep (`to_expiry = false`), reading the post-move expiry cash, idle, and
/// cumulative flow watermarks.
fun emit_expiry_cash_rebalanced(
    vault: &PoolVault,
    market: &ExpiryMarket,
    expiry_market_id: ID,
    amount: u64,
    to_expiry: bool,
    target_cash: u64,
) {
    let (sent_to_expiry_after, received_from_expiry_after) = vault
        .expiry_accounting
        .expiry_flow_amounts(expiry_market_id);
    vault_events::emit_expiry_cash_rebalanced(
        vault.id(),
        expiry_market_id,
        amount,
        to_expiry,
        target_cash,
        market.cash_balance(),
        vault.expiry_accounting.idle_balance(),
        sent_to_expiry_after,
        received_from_expiry_after,
    );
}

/// Engage the valuation lock and snapshot the active expiry set. Shared by both
/// cap-gated flush entrypoints.
fun start_pool_valuation_internal(config: &mut ProtocolConfig, vault: &PoolVault): PoolValuation {
    vault.assert_version_allowed();
    config.begin_valuation();
    PoolValuation {
        pool_vault_id: vault.id(),
        expected_expiry_markets: *vault.expiry_accounting.active_expiry_markets(),
        valued_expiry_markets: vector[],
        total_nav: 0,
    }
}

/// Abort unless this valuation belongs to `vault`.
fun assert_pool_vault(valuation: &PoolValuation, vault: &PoolVault) {
    assert!(valuation.pool_vault_id == vault.id(), EWrongPoolVault);
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

/// Drain both LP queues at the frozen flush mark (`pool_value` over `total_supply`),
/// supplies first then withdrawals, advancing the head cursor over at most
/// `max_requests_per_flush` entries total (fills, refunds, and cancelled-hole skips
/// all count; the rest carry to the next flush).
///
/// Each supply mints PLP and joins its escrowed DUSDC into idle (replenishing the
/// cash withdrawals then draw from); a dust supply that prices to zero shares is
/// refunded its DUSDC instead. Withdrawals are FIFO-until-dry: the first whose payout
/// exceeds idle stops the pass, leaving it and the rest to reprice next flush; a dust
/// withdraw that prices to zero DUSDC is refunded its PLP. Per-request degeneracies
/// take the refund path, never aborting the whole flush. Returns (supplies filled,
/// withdrawals filled, cursor advances spent).
fun drain_lp_requests(
    vault: &mut PoolVault,
    pool_value: u64,
    total_supply: u64,
    ctx: &mut TxContext,
): (u64, u64, u64) {
    let max = constants::max_requests_per_flush!();
    let mut processed = 0;
    let mut supplies_filled = 0;
    let mut withdrawals_filled = 0;

    while (processed < max && !vault.supply_queue.is_empty()) {
        let index = vault.supply_queue.head();
        if (vault.supply_queue.contains(index)) {
            let request = *vault.supply_queue.borrow(index);
            let recipient = request.recipient();
            let amount = request.amount();
            let shares = supply_shares(amount, total_supply, pool_value);
            if (shares == 0) {
                let refund = vault.supply_queue.remove(index);
                balance::send_funds(refund, recipient);
                vault_events::emit_supply_refunded(vault.id(), recipient, index, amount);
            } else {
                let escrowed = vault.supply_queue.remove(index);
                vault.expiry_accounting.receive_idle(escrowed);
                let shares_minted = vault.treasury_cap.mint_balance(shares);
                balance::send_funds(shares_minted, recipient);
                vault_events::emit_supply_filled(vault.id(), recipient, index, amount, shares);
                supplies_filled = supplies_filled + 1;
            };
        };
        vault.supply_queue.advance_head();
        processed = processed + 1;
    };

    while (processed < max && !vault.withdraw_queue.is_empty()) {
        let index = vault.withdraw_queue.head();
        if (vault.withdraw_queue.contains(index)) {
            let request = *vault.withdraw_queue.borrow(index);
            let recipient = request.recipient();
            let shares = request.amount();
            let payout = withdraw_dusdc(shares, total_supply, pool_value);
            if (payout == 0) {
                let refund = vault.withdraw_queue.remove(index);
                balance::send_funds(refund, recipient);
                vault_events::emit_withdraw_refunded(vault.id(), recipient, index, shares);
            } else if (vault.expiry_accounting.idle_balance() < payout) {
                // FIFO-until-dry: idle can't cover the head request, so stop and carry
                // this and every later withdrawal to reprice next flush.
                break
            } else {
                let escrowed_plp = vault.withdraw_queue.remove(index);
                let payout_cash = vault.expiry_accounting.withdraw_idle(payout);
                vault.treasury_cap.burn(escrowed_plp.into_coin(ctx));
                balance::send_funds(payout_cash, recipient);
                vault_events::emit_withdraw_filled(vault.id(), recipient, index, shares, payout);
                withdrawals_filled = withdrawals_filled + 1;
            };
        };
        vault.withdraw_queue.advance_head();
        processed = processed + 1;
    };

    (supplies_filled, withdrawals_filled, processed)
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext) {
    init(PLP {}, ctx);
}

#[test_only]
/// Seed idle DUSDC directly. The production supply flow is pruned, so this is the
/// only way to fund idle in tests (mirrors `expiry_market::receive_cash_for_testing`).
public fun receive_idle_for_testing(vault: &mut PoolVault, funds: Coin<DUSDC>) {
    vault.expiry_accounting.receive_idle(funds.into_balance());
}
