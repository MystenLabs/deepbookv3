// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault.
///
/// PoolVault owns the PLP treasury cap, the pooled DEEP staked by accounts, idle
/// DUSDC, the protocol reserve, sponsor-funded fee incentives, per-expiry cash
/// accounting, and the async LP supply/withdraw queues. It coordinates the
/// full-pool NAV valuation (a hot-potato aggregation over every active market) and
/// the unified per-market cash flow (initial funding, live rebalance/sweep, and
/// settled-market sweep with terminal profit materialization). LPs queue
/// supply/withdraw requests routed through a loaded Account; the daily flush
/// (`finish_flush`) drains them at the frozen pool NAV, minting/burning PLP and
/// delivering fills to each account via the balance accumulator. PLP incentives
/// moved to a separate staking contract; DEEP staking is an unrelated trading
/// feature.
module deepbook_predict::plp;

use account::account::{AccountWrapper, Auth};
use deepbook_predict::{
    admin::AdminCap,
    constants,
    expiry_market::ExpiryMarket,
    lp_book::{Self, LpBook},
    market_lifecycle_cap::MarketLifecycleProof,
    pool_accounting::{Self, Ledger},
    predict_account,
    protocol_config::ProtocolConfig,
    vault_events
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use propbook::{block_scholes_feed::BlockScholesFeed, pyth_feed::PythFeed, registry::OracleRegistry};
use sui::{
    accumulator::AccumulatorRoot,
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry
};
use token::deep::DEEP;

const EExpiryMarketNotActive: u64 = 0;
const EExpiryMarketAlreadyValued: u64 = 1;
const EWrongPoolVault: u64 = 2;
const EMissingExpiryValuation: u64 = 3;
const ENotBootstrapped: u64 = 4;
const EPlpPriceBelowCircuitBreaker: u64 = 5;
const EPlpPriceAboveCircuitBreaker: u64 = 6;
const EAlreadyBootstrapped: u64 = 7;
const EPoolNavDust: u64 = 8;
const EBelowMinBootstrapLiquidity: u64 = 9;
const EBelowMinFeeIncentiveSponsorship: u64 = 10;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Pool-level vault state.
public struct PoolVault has key {
    id: UID,
    /// Protocol-owned DUSDC (the materialized terminal-profit cut) excluded from
    /// PLP redemption.
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

/// Return DEEP staked by accounts and held in custody by the pool.
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

/// Return sponsor-funded DUSDC available for future fee-incentive allocation.
public fun fee_incentive_reserve(vault: &PoolVault): u64 {
    vault.fee_incentive_reserve.value()
}

/// Return the total PLP share supply outstanding.
public fun plp_total_supply(vault: &PoolVault): u64 {
    vault.lp.total_supply()
}

/// Return the count of pending (un-drained) LP supply requests.
public fun supply_requests_pending(vault: &PoolVault): u64 {
    vault.lp.supply_requests_pending()
}

/// Return the count of pending (un-drained) LP withdraw requests.
public fun withdraw_requests_pending(vault: &PoolVault): u64 {
    vault.lp.withdraw_requests_pending()
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

/// Return the materialized protocol cut still awaiting a physical move to the reserve.
public fun pending_protocol_profit(vault: &PoolVault): u64 {
    vault.expiry_accounting.pending_protocol_profit()
}

/// Begin a full-pool flush (NAV valuation + LP queue drain) as a market deployer,
/// using a registry-generated `MarketLifecycleProof`. This is the sole flush start:
/// it is cron-driven and PRIVILEGED, not permissionless (audit L8). Engages the
/// protocol valuation lock — so no NAV-changing op can interleave between value
/// steps — and snapshots the active expiry set every `value_expiry` must cover. The
/// hot potato can only be created here, so gating the start gates the whole flush.
///
/// The flush prices the pool NAV off the live oracle and `finish_flush` drains the
/// LP queues at that mark, and Pyth updates (`pyth_feed::update`) are permissionless
/// — so a flush-capable cap-holder who manipulates the live oracle in a preceding
/// tx, then flushes, could fill their own queued supply/withdraw request at a mark
/// they chose. The start is therefore gated on both current registry allowlisting
/// and trust in every flush-capable holder not to manipulate the live oracle. The
/// revocable `MarketLifecycleCap` (not the root `AdminCap`) carries this authority;
/// admin retains a break-glass route by minting itself a lifecycle cap.
public fun start_pool_valuation(
    config: &mut ProtocolConfig,
    vault: &PoolVault,
    lifecycle_proof: MarketLifecycleProof,
): PoolValuation {
    config.assert_version();
    lifecycle_proof.destroy_proof();
    start_pool_valuation_internal(config, vault)
}

/// Run the per-market cash flow for one snapshotted market, then fold its NAV into
/// the running total. The market must be in the snapshot and not already valued
/// (the exactly-once proof). The flush IS the valuation: a settled market is swept
/// (deactivated, cash returned, profit materialized) and contributes 0; a live
/// market is rebalanced to target and valued on its current cash. The flush uses
/// the lock-free inner, so it does not self-abort under the valuation lock.
///
/// Before branching, this passively records terminal settlement from Propbook's
/// exact Pyth timestamp if available: a past-expiry market is normally settled here
/// and swept (contributing 0), so `current_nav` is only reached for a still-live
/// market. Only in the bounded pending-settlement window (past expiry but the
/// exact-expiry spot not yet inserted) does the live branch still abort through
/// `current_nav`; there is no solvency-safe substitute mark for an unsettled expired
/// market, and the abort clears once anyone lands the exact spot.
public fun value_expiry(
    valuation: &mut PoolValuation,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_valuation_in_progress();
    let expiry_market_id = market.id();
    valuation.assert_expiry_ready_to_value(expiry_market_id);
    let settled = vault.rebalance_expiry_cash_inner(market, config, propbook_registry, pyth, clock);
    let nav = if (settled) {
        0
    } else {
        market.current_nav(config, propbook_registry, pyth, bs, clock)
    };
    valuation.valued_expiry_markets.push_back(expiry_market_id);
    valuation.total_nav = valuation.total_nav + nav;
}

/// Finish a full-pool valuation and run the LP flush: prove every snapshotted market
/// was valued exactly once, price the pool NAV, then drain the supply/withdraw queues
/// at that frozen mark (mint PLP for supplies, burn PLP and pay DUSDC for
/// withdrawals), release the valuation lock, consume the potato, and return the
/// LP-attributable pool-wide DUSDC NAV (idle + Σ active NAV, net of the
/// pending-protocol-profit exclusion priced from the aggregate profit basis).
///
/// `supply_budget` / `withdraw_budget` bound how many requests each queue may fill
/// this flush (`None` = drain it fully); the operator sizes them to the gas left
/// after valuing the snapshotted markets. The budgets are independent, so a supply
/// backlog never starves withdrawals.
public fun finish_flush(
    valuation: PoolValuation,
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
    ctx: &mut TxContext,
): u64 {
    config.assert_version();
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
        vault.expiry_accounting.pending_protocol_profit(),
    );
    let total_supply = vault.lp.total_supply();
    assert_plp_price_in_bounds(pool_nav, total_supply);
    let market_count = valued_expiry_markets.length();

    // Snapshot the share price once (frozen pair), drain both queues against it, then
    // release the valuation lock at the very end. The flush IS the full-pool
    // valuation, so the single FlushExecuted event carries the priced mark and its
    // idle + active-NAV breakdown.
    let vault_id = vault.id();
    let (supplies_filled, withdrawals_filled) = vault
        .lp
        .drain(
            vault_id,
            &mut vault.expiry_accounting,
            pool_nav,
            total_supply,
            supply_budget,
            withdraw_budget,
            ctx,
        );
    config.end_valuation();
    vault_events::emit_flush_executed(
        vault_id,
        ctx.epoch(),
        pool_nav,
        total_supply,
        total_nav,
        market_count,
        idle,
        supplies_filled,
        withdrawals_filled,
        supplies_filled + withdrawals_filled,
        vault.expiry_accounting.idle_balance(),
    );
    pool_nav
}

/// Stake DEEP for trading benefits. The DEEP is held in the pool vault; the
/// amount is recorded as inactive on the account and activates next epoch
/// (`predict_account::active_stake_mut`, run by trade/claim flows). Callable
/// anytime, any number of times.
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
    predict_account::active_stake_mut(account, ctx);
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
/// Mint asserts backing but never pulls pool cash, so this is what makes a market
/// mintable. The market must already be registered to this vault
/// (`registry::create_expiry_market`). Blocked while a full-pool valuation is in
/// progress (the flush calls the lock-free inner directly).
public fun rebalance_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    vault.rebalance_expiry_cash_inner(market, config, propbook_registry, pyth, clock);
}

/// Sponsor taker fee incentives with DUSDC. Anyone may contribute; the payment
/// joins a pool-level reserve that is excluded from PLP NAV and later allocated to
/// expiry markets by the normal rebalance flow.
public fun sponsor_fee_incentives(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    payment: Coin<DUSDC>,
    ctx: &TxContext,
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
/// This keeps `total_supply > 0` for the life of the pool, making the supply==0
/// bootstrap branch unreachable and the residual-idle re-bootstrap brick impossible.
/// Callable only by the operator and only while the pool is pristine
/// (`total_supply == 0`), so it runs exactly once; all supply/withdraw/flush flows
/// abort `ENotBootstrapped` until it has.
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
/// auto-settles any flush-delivered DUSDC first. The account receives the minted PLP
/// at the next flush. Returns the queue index, the handle used to cancel before
/// the flush.
public fun request_supply(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    amount: u64,
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
    let index = vault.lp.request_supply(account_id, recipient, payment);
    vault_events::emit_supply_requested(vault_id, account_id, recipient, index, amount);
    index
}

/// Queue a withdraw request: pull `amount` PLP shares from account custody into
/// queue escrow, recording the account's receive address as the fill recipient.
/// The pull auto-settles any flush-delivered PLP first. Returns the queue index
/// used to cancel before the flush.
public fun request_withdraw(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    amount: u64,
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
    let index = vault.lp.request_withdraw(account_id, recipient, lp);
    vault_events::emit_withdraw_requested(vault_id, account_id, recipient, index, amount);
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
    vault_events::emit_request_cancelled(vault_id, account_id, recipient, index, amount, true);
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
    vault_events::emit_request_cancelled(vault_id, account_id, recipient, index, amount, false);
}

// === Public-Package Functions ===

/// Create an empty pool vault from the PLP treasury cap.
public(package) fun new(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): PoolVault {
    PoolVault {
        id: object::new(ctx),
        protocol_reserve_balance: balance::zero(),
        fee_incentive_reserve: balance::zero(),
        staked_deep: balance::zero(),
        lp: lp_book::new(treasury_cap, ctx),
        expiry_accounting: pool_accounting::new(ctx),
    }
}

/// Create and share an empty pool vault from the PLP treasury cap.
public(package) fun create_and_share(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): ID {
    let vault = new(treasury_cap, ctx);
    let id = vault.id();
    transfer::share_object(vault);
    id
}

/// Register a freshly created expiry market with the pool as an accounting row.
/// No cash moves: the market is not mintable until `rebalance_expiry_cash` funds
/// it. Called by `registry::create_expiry_market`.
public(package) fun register_expiry(
    vault: &mut PoolVault,
    expiry_market_id: ID,
    max_expiry_allocation: u64,
) {
    vault.expiry_accounting.register_expiry(expiry_market_id, max_expiry_allocation);
}

/// Lock-free per-market cash flow shared by the public entrypoint and the
/// valuation flush. A settled market is swept (deactivated, free cash returned,
/// profit materialized) — idempotent, so a second pass is a safe no-op. A live
/// market is topped up from idle toward target, or has its surplus over target
/// swept back to idle. The valuation lock and version gate are owned by the public
/// wrappers, not here, so the flush can call this under the lock without self-aborting.
public(package) fun rebalance_expiry_cash_inner(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
): bool {
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);

    if (market.ensure_settled(propbook_registry, pyth, clock)) {
        vault.unregister_settled_expiry(market, config);
        return true
    };

    vault.sync_fee_incentives(market, expiry_market_id);

    let (cash_balance, target_cash, sweep_threshold_cash) = expiry_rebalance_cash_terms(market);
    if (cash_balance < target_cash) {
        let requested_top_up = target_cash - cash_balance;
        let funding_room = vault.expiry_accounting.available_expiry_funding(expiry_market_id);
        let top_up = requested_top_up.min(vault.expiry_accounting.idle_balance()).min(funding_room);
        if (top_up > 0) {
            let cash = vault.expiry_accounting.send_expiry_cash(expiry_market_id, top_up);
            market.receive_pool_cash(cash);
            vault.emit_expiry_cash_rebalanced(market, expiry_market_id, top_up, true, target_cash);
        };
    } else if (cash_balance > sweep_threshold_cash) {
        let returned_cash = market.release_pool_cash(cash_balance - target_cash);
        let returned_cash_amount = vault
            .expiry_accounting
            .receive_expiry_cash(expiry_market_id, returned_cash);
        // Surplus just returned to idle — realize any protocol cut a prior settled
        // sweep could not cover because idle was deployed in other active markets.
        // Drain before emitting so the event's reserve/pending/idle reflect it.
        vault
            .protocol_reserve_balance
            .join(vault.expiry_accounting.realize_pending_protocol_profit());
        vault.emit_expiry_cash_rebalanced(
            market,
            expiry_market_id,
            returned_cash_amount,
            false,
            target_cash,
        );
    };
    false
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
public(package) fun lp_pool_value(
    idle_balance: u64,
    profit_basis_credits: u64,
    profit_basis_debits: u64,
    protocol_reserve_profit_share: u64,
    active_expiry_value: u64,
    pending_protocol_profit: u64,
): u64 {
    let gross_pool_value = idle_balance + active_expiry_value;
    let aggregate_credits = profit_basis_credits + active_expiry_value;
    let exclusion = math::mul(
        aggregate_credits.saturating_sub(profit_basis_debits),
        protocol_reserve_profit_share,
    );
    // The realized `credits - debits` term is sticky: it does not shrink when LPs
    // withdraw idle cash, so when an active mark they withdrew against later
    // collapses, the held-out total (`exclusion + pending_protocol_profit`) can
    // exceed gross. LP value can never be negative — floor it at 0, which also
    // prevents the subtraction from underflowing and bricking all PLP supply/withdraw.
    gross_pool_value.saturating_sub(exclusion + pending_protocol_profit)
}

// === Private Functions ===

fun sync_fee_incentives(vault: &mut PoolVault, market: &mut ExpiryMarket, expiry_market_id: ID) {
    let max_expiry_allocation = vault.expiry_accounting.max_expiry_allocation(expiry_market_id);
    let requested_allocation = math::mul(
        max_expiry_allocation,
        constants::fee_incentive_live_target_rate!(),
    )
        .saturating_sub(market.fee_incentive_balance())
        .min(vault.fee_incentive_reserve.value());
    if (requested_allocation == 0) return;

    let (allocation, allocated_after) = vault
        .expiry_accounting
        .record_fee_incentives_allocated_up_to(
            expiry_market_id,
            math::mul(
                max_expiry_allocation,
                constants::fee_incentive_lifetime_cap_rate!(),
            ),
            requested_allocation,
        );
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

/// Abort before draining LP requests if the frozen mark implies a PLP price or pool
/// NAV outside the executable protocol envelope. `total_supply > 0` is guaranteed by
/// the genesis lock (`lock_capital`) + the `ENotBootstrapped` flush-start gate, so
/// there is no supply==0 bootstrap branch and `total_supply` can never sit in the
/// dust band (`min_bootstrap_liquidity >= min_withdraw_request`).
///
/// The price-bound checks use floor-rounded math (`math::div`, and `mul_div_down`
/// when the drain converts shares↔value) intentionally, so each boundary stays
/// conservative — the floored price is a lower bound on the true price, so passing
/// the lower-bound check guarantees the real price clears it, and the floored
/// upper-bound RHS only tightens the cap. The protocol is never short.
fun assert_plp_price_in_bounds(pool_nav: u64, total_supply: u64) {
    assert!(
        pool_nav >= math::mul(constants::min_withdraw_request!(), constants::min_plp_price!()),
        EPoolNavDust,
    );
    assert!(
        math::div(pool_nav, total_supply) >= constants::min_plp_price!(),
        EPlpPriceBelowCircuitBreaker,
    );
    assert!(
        pool_nav <= math::mul(total_supply, constants::max_plp_price!()),
        EPlpPriceAboveCircuitBreaker,
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

/// Settled-market sweep: deactivate the expiry, return its free cash to idle,
/// materialize its terminal profit, and return unused fee incentives to the pool
/// reserve. Idempotent — a settled market already swept returns zero cash and
/// recognizes no further profit, so a second pass is a no-op.
fun unregister_settled_expiry(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
) {
    let expiry_market_id = market.id();
    let deactivated = vault.expiry_accounting.deactivate_expiry_if_present(expiry_market_id);
    let (returned_cash, settlement_price) = market.release_settled_pool_cash();
    let returned_cash_amount = vault
        .expiry_accounting
        .receive_expiry_cash(expiry_market_id, returned_cash);
    vault.materialize_expiry_profit(config, expiry_market_id);
    let returned_incentives = market.release_fee_incentives();
    let returned_incentive_amount = returned_incentives.value();
    vault.fee_incentive_reserve.join(returned_incentives);

    if (deactivated || returned_cash_amount > 0) {
        vault.emit_expiry_cash_received(market, returned_cash_amount, settlement_price);
    };
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
    let protocol_profit = math::mul(profit, config.protocol_reserve_profit_share());
    let lp_profit = profit - protocol_profit;
    let realized = vault.expiry_accounting.realize_protocol_profit(protocol_profit);
    vault.protocol_reserve_balance.join(realized);
    vault_events::emit_expiry_profit_materialized(
        vault.id(),
        expiry_market_id,
        lp_profit,
        protocol_profit,
        vault.expiry_accounting.idle_balance(),
        vault.protocol_reserve_balance.value(),
        vault.expiry_accounting.profit_basis_debits(),
        vault.expiry_accounting.pending_protocol_profit(),
    );
}

fun emit_expiry_cash_received(
    vault: &PoolVault,
    market: &ExpiryMarket,
    amount: u64,
    settlement_price: u64,
) {
    let expiry_market_id = market.id();
    let (sent_to_expiry_after, received_from_expiry_after) = vault
        .expiry_accounting
        .expiry_flow_amounts(expiry_market_id);
    vault_events::emit_expiry_cash_received(
        vault.id(),
        expiry_market_id,
        settlement_price,
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
        vault.protocol_reserve_balance.value(),
        vault.expiry_accounting.pending_protocol_profit(),
    );
}

/// Engage the valuation lock and snapshot the active expiry set. Shared by both
/// cap-gated flush entrypoints. Gated on a bootstrapped pool so `finish_flush` never
/// reaches `assert_plp_price_in_bounds` with `total_supply == 0`.
fun start_pool_valuation_internal(config: &mut ProtocolConfig, vault: &PoolVault): PoolValuation {
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
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
