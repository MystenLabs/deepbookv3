// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault accounting.
///
/// PoolVault owns idle DUSDC and the PLP treasury cap. Expiry markets own
/// active trading cash and risk state. This module coordinates full-pool sync,
/// PLP supply/withdrawal, expiry funding, live expiry cash rebalancing,
/// rebate-reserve release, profit materialization, and settled-expiry cash
/// receipt.
/// It does not own expiry-local strike, oracle, or position state.
module deepbook_predict::plp;

use deepbook::math;
use deepbook_predict::{
    admin::AdminCap,
    constants,
    expiry_market::ExpiryMarket,
    incentive::{Self, IncentiveState},
    market_oracle::MarketOracle,
    pool_accounting::{Self, Ledger},
    predict_manager::PredictManager,
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    vault_events
};
use dusdc::dusdc::DUSDC;
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Self, Coin, TreasuryCap},
    coin_registry,
    sui::SUI,
    vec_set::{Self, VecSet}
};
use token::deep::DEEP;

const EExpiryMarketNotActive: u64 = 0;
const EInsufficientIdleBalance: u64 = 1;
const EWrongPoolVault: u64 = 2;
const EExpiryMarketAlreadySynced: u64 = 3;
const EMissingExpirySync: u64 = 4;
const EZeroSupply: u64 = 5;
const EZeroWithdraw: u64 = 6;
const EInvalidInitialSupply: u64 = 7;
const EZeroShares: u64 = 8;
const EZeroPoolValue: u64 = 9;
const EPackageVersionDisabled: u64 = 10;
const ENoPlpHolders: u64 = 11;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Pool-level capital and PLP accounting state.
public struct PoolVault has key {
    id: UID,
    /// Idle LP-owned DUSDC available for withdrawals and expiry funding.
    idle_balance: Balance<DUSDC>,
    /// Protocol-owned DUSDC excluded from PLP redemption.
    protocol_reserve_balance: Balance<DUSDC>,
    /// Pooled DEEP staked by all managers for trading benefits. Per-manager
    /// active/inactive amounts are mirrored on each `PredictManager`.
    staked_deep: Balance<DEEP>,
    treasury_cap: TreasuryCap<PLP>,
    /// Active expiry IDs, pool cash-flow rows, profit basis, and per-expiry funding caps.
    expiry_accounting: Ledger,
    /// Admin-deposited LP-owned incentive in SUI: valued into pool NAV (released
    /// portion, via `pyth_source::value_in_dusdc`) and paid out pro-rata in-kind
    /// on withdrawal.
    incentive_sui: IncentiveState<SUI>,
    /// Admin-deposited LP-owned incentive in DEEP. Distinct from `staked_deep`
    /// (manager custody, not redeemable): this balance is LP-owned and redeemed
    /// in-kind on withdrawal.
    incentive_deep: IncentiveState<DEEP>,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
}

/// Transaction-local pool sync hot potato.
///
/// The sync flow snapshots active expiries, processes each one exactly once,
/// coordinates cash movement, and accumulates active expiry NAV for share pricing.
public struct PoolSync {
    pool_vault_id: ID,
    expected_expiry_markets: vector<ID>,
    synced_expiry_markets: vector<ID>,
    active_expiry_value: u64,
}

// === Private Functions ===

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

/// Return idle DUSDC held by the pool.
public fun idle_balance(vault: &PoolVault): u64 {
    vault.idle_balance.value()
}

/// Return DEEP staked by managers and held in custody by the pool.
public fun staked_deep(vault: &PoolVault): u64 {
    vault.staked_deep.value()
}

/// Return protocol-owned DUSDC excluded from PLP redemption.
public fun protocol_reserve_balance(vault: &PoolVault): u64 {
    vault.protocol_reserve_balance.value()
}

/// Return active expiry market IDs tracked by the pool.
public fun active_expiry_markets(vault: &PoolVault): &vector<ID> {
    vault.expiry_accounting.active_expiry_markets()
}

/// Return total PLP supply.
public fun total_supply(vault: &PoolVault): u64 {
    vault.treasury_cap.total_supply()
}

/// Return the vested (claimable) SUI incentive balance — the portion folded into
/// NAV and paid out in-kind; the still-vesting remainder is `incentive_sui_locked`.
public fun incentive_sui_balance(vault: &PoolVault): u64 {
    vault.incentive_sui.released_value()
}

/// Return the unvested (still-streaming) SUI incentive balance.
public fun incentive_sui_locked(vault: &PoolVault): u64 {
    vault.incentive_sui.locked_value()
}

/// Return the vested (claimable) DEEP incentive balance.
public fun incentive_deep_balance(vault: &PoolVault): u64 {
    vault.incentive_deep.released_value()
}

/// Return the unvested (still-streaming) DEEP incentive balance.
public fun incentive_deep_locked(vault: &PoolVault): u64 {
    vault.incentive_deep.locked_value()
}

/// Return the pricing debit side of aggregate expiry profit basis.
public fun profit_basis_debits(vault: &PoolVault): u64 {
    vault.expiry_accounting.profit_basis_debits()
}

/// Return the pricing credit side of aggregate expiry profit basis.
public fun profit_basis_credits(vault: &PoolVault): u64 {
    vault.expiry_accounting.profit_basis_credits()
}

/// Return DUSDC sent to and received from one expiry market.
public fun expiry_flow_amounts(vault: &PoolVault, expiry_market_id: ID): (u64, u64) {
    vault.expiry_accounting.expiry_flow_amounts(expiry_market_id)
}

/// Return the max net DUSDC the pool may have funded into an expiry.
public fun max_expiry_funding(
    vault: &PoolVault,
    config: &ProtocolConfig,
    expiry_market_id: ID,
): u64 {
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    config.expiry_max_funding(expiry_market_id)
}

/// Start a full-pool sync flow for this vault.
public fun start_pool_sync(config: &mut ProtocolConfig, vault: &PoolVault): PoolSync {
    vault.assert_version_allowed();
    config.begin_valuation();
    PoolSync {
        pool_vault_id: vault.id(),
        expected_expiry_markets: *vault.expiry_accounting.active_expiry_markets(),
        synced_expiry_markets: vector[],
        active_expiry_value: 0,
    }
}

/// Sync one snapshotted expiry's cash and active NAV.
///
/// PLP owns the allocation policy: it compares expiry cash against payout
/// liability plus rebate reserve, preserves the fixed expiry cash floor, and
/// records every cash movement in the pool money-out/money-in ledger. Settled
/// markets are deactivated and release all cash above settled backing needs;
/// active markets are rebalanced before producing their current pool NAV.
public fun sync_expiry(
    sync: &mut PoolSync,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
) {
    vault.assert_version_allowed();
    market.assert_version_allowed();
    sync.assert_pool_vault(vault);
    config.assert_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    let expiry_market_id = market.id();
    sync.assert_expiry_ready_to_sync(expiry_market_id);

    if (market_oracle.is_settled()) {
        vault.unregister_settled_expiry(market, config, market_oracle);
        sync.record_expiry_synced(expiry_market_id, 0);
        return
    };

    market.run_liquidation_pass(
        config.pricing_config(),
        market_oracle,
        pyth,
        config.valuation_liquidation_budget(),
        clock,
    );
    vault.rebalance_active_expiry_cash(config, market);
    let expiry_nav = market.pool_nav(config, market_oracle, pyth, clock);
    sync.record_expiry_synced(expiry_market_id, expiry_nav);
}

/// Finish a full-pool sync flow and return the PLP-owned DUSDC-denominated value
/// (idle + active expiry NAV, net of pending protocol profit). Asserts every
/// active expiry was synced. Incentives are valued separately by `supply` (priced
/// into NAV) and paid in-kind by `withdraw`, so the sync flow itself is unaware
/// of them.
public fun finish_pool_sync(vault: &PoolVault, config: &mut ProtocolConfig, sync: PoolSync): u64 {
    vault.assert_version_allowed();
    config.assert_valuation_in_progress();
    sync.assert_pool_vault(vault);
    assert_all_expected_synced(&sync.expected_expiry_markets, &sync.synced_expiry_markets);
    let dusdc_value = vault.synced_pool_value(config, sync.active_expiry_value);
    let PoolSync { .. } = sync;
    config.end_valuation();
    dusdc_value
}

/// Resolve one manager's settled trading-loss rebate and return residual reserve to the pool.
public fun claim_trading_loss_rebate(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    ctx: &mut TxContext,
) {
    vault.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);

    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    let residual_cash = market.claim_trading_loss_rebate(manager, config, market_oracle, ctx);
    let returned_cash_amount = vault.receive_expiry_cash(expiry_market_id, residual_cash);
    vault.materialize_expiry_profit(config, expiry_market_id);
    if (returned_cash_amount > 0) {
        vault.emit_expiry_cash_received(
            expiry_market_id,
            market_oracle,
            returned_cash_amount,
        );
    };
}

/// Supply DUSDC into the pool vault against a complete full-pool sync.
///
/// Values both incentive assets from their fresh feeds, finishes the sync to get
/// the DUSDC NAV, then prices shares against the total (DUSDC + incentive value)
/// and mints PLP. Pricing against total NAV means a new depositor pays the
/// incentives' fair value and cannot dilute existing holders' in-kind claim on
/// them. `sui_source`/`deep_source` are the bound incentive feeds; an empty
/// incentive ignores its source.
public fun supply(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    sync: PoolSync,
    payment: Coin<DUSDC>,
    sui_source: &PythSource,
    deep_source: &PythSource,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<PLP> {
    vault.assert_version_allowed();
    // Value incentives while the valuation window is still open (before the
    // finisher ends it), then finish for the DUSDC NAV.
    let incentive_value = vault.value_incentives(config, sui_source, deep_source, clock);
    let dusdc_value = vault.finish_pool_sync(config, sync);
    let pool_value = dusdc_value + incentive_value;
    let payment_amount = payment.value();
    assert!(payment_amount > 0, EZeroSupply);

    let total_supply = vault.treasury_cap.total_supply();
    let shares = shares_for_supply(total_supply, dusdc_value, pool_value, payment_amount);

    vault.idle_balance.join(payment.into_balance());
    let plp = coin::mint(&mut vault.treasury_cap, shares, ctx);
    vault_events::emit_supply_executed(
        vault.id(),
        payment_amount,
        shares,
        pool_value,
        incentive_value,
        vault.treasury_cap.total_supply(),
        vault.idle_balance.value(),
    );
    plp
}

/// Pure share pricing for a supply: bootstrap mints 1:1, otherwise prices the
/// payment against the pool's share ratio. No custody, NAV, event, or storage
/// effects.
fun shares_for_supply(
    total_supply: u64,
    dusdc_value: u64,
    pool_value: u64,
    payment_amount: u64,
): u64 {
    if (total_supply == 0) {
        // Bootstrap mints 1:1; only the DUSDC side must be empty (incentives
        // can't exist before the first supply — see deposit guards).
        assert!(dusdc_value == 0, EInvalidInitialSupply);
        payment_amount
    } else {
        assert!(pool_value > 0, EZeroPoolValue);
        let share_fraction = math::div(total_supply, pool_value);
        let shares = math::mul(payment_amount, share_fraction);
        assert!(shares > 0, EZeroShares);
        shares
    }
}

/// Withdraw from the pool vault against a complete full-pool sync.
///
/// Pays the DUSDC-denominated pro-rata share plus the pro-rata in-kind share of
/// each incentive asset (SUI, DEEP), all in one call. Each incentive is vested up
/// to the withdrawal time, then `lp_amount * released / total_supply` (supply
/// snapshotted before the burn) is split from its released balance, rounding
/// down: the holder's slice covers every unit vested while they still held
/// shares, and the locked remainder stays for those who remain. Incentives need
/// no oracle here — an in-kind slice is fair by construction — so a stale feed
/// can never block an exit.
public fun withdraw(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    sync: PoolSync,
    lp_coin: Coin<PLP>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<DUSDC>, Coin<SUI>, Coin<DEEP>) {
    vault.assert_version_allowed();
    // Only the DUSDC-denominated value backs the DUSDC payout; incentives are
    // paid in-kind below from their live released balances (no oracle).
    let dusdc_value = vault.finish_pool_sync(config, sync);
    let lp_amount = lp_coin.value();
    assert!(lp_amount > 0, EZeroWithdraw);

    let total_supply = vault.treasury_cap.total_supply();
    let withdraw_amount = dusdc_for_withdraw(
        lp_amount,
        total_supply,
        dusdc_value,
        vault.idle_balance.value(),
    );

    vault.treasury_cap.burn(lp_coin);
    let payout = vault.idle_balance.split(withdraw_amount).into_coin(ctx);
    let now_ms = clock.timestamp_ms();
    let sui = vault.incentive_sui.claim(lp_amount, total_supply, now_ms, ctx);
    let deep = vault.incentive_deep.claim(lp_amount, total_supply, now_ms, ctx);
    vault_events::emit_withdraw_executed(
        vault.id(),
        lp_amount,
        withdraw_amount,
        dusdc_value,
        vault.treasury_cap.total_supply(),
        vault.idle_balance.value(),
    );
    (payout, sui, deep)
}

/// DUSDC payout owed for burning `lp_amount` shares: `dusdc_value * lp_amount /
/// total_supply` (div then mul, round down). Inverse mirror of
/// `shares_for_supply`; pure, so it stays out of the custody/event flow.
fun dusdc_for_withdraw(
    lp_amount: u64,
    total_supply: u64,
    dusdc_value: u64,
    idle_balance: u64,
): u64 {
    let withdraw_fraction = math::div(lp_amount, total_supply);
    let withdraw_amount = math::mul(dusdc_value, withdraw_fraction);
    assert!(withdraw_amount > 0, EZeroWithdraw);
    assert!(idle_balance >= withdraw_amount, EInsufficientIdleBalance);
    withdraw_amount
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

// === Public-Package Functions ===

/// Abort if the running package version is not allowed for this vault.
fun assert_version_allowed(vault: &PoolVault) {
    assert!(
        vault.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Create an empty pool vault from the PLP treasury cap.
public(package) fun new(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): PoolVault {
    PoolVault {
        id: object::new(ctx),
        idle_balance: balance::zero(),
        protocol_reserve_balance: balance::zero(),
        staked_deep: balance::zero(),
        treasury_cap,
        expiry_accounting: pool_accounting::new(ctx),
        incentive_sui: incentive::empty(),
        incentive_deep: incentive::empty(),
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

/// Register an expiry market for pool accounting and active valuation.
public(package) fun register_expiry_market(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    expiry_market_id: ID,
) {
    vault.assert_version_allowed();
    config.register_expiry_runtime_config(expiry_market_id);
    vault.expiry_accounting.register_expiry(expiry_market_id);
}

/// Take custody of an admin SUI incentive deposit, caching its oracle binding and
/// arming a linear vesting schedule over `duration_ms`.
///
/// Mints no PLP. The deposit lands in the locked balance and vests into the
/// released balance over `[now, now + duration_ms]`; released value accrues to
/// existing holders via share price and is paid back in-kind on withdrawal.
/// Requires existing PLP holders so the first future supplier can't capture the
/// whole deposit. A deposit onto a still-vesting schedule first vests the prior
/// schedule to now (locking in its released portion), then re-stretches the
/// unvested remainder plus the new deposit over a fresh window. The authorizing
/// `AdminCap` and feed-config checks live in `registry::deposit_sui_incentive`,
/// which supplies the binding read from the registry.
public(package) fun receive_sui_incentive(
    vault: &mut PoolVault,
    deposit: Coin<SUI>,
    decimals: u8,
    feed_id: u32,
    duration_ms: u64,
    clock: &Clock,
) {
    vault.assert_version_allowed();
    assert!(vault.treasury_cap.total_supply() > 0, ENoPlpHolders);
    vault.incentive_sui.fund(deposit, decimals, feed_id, duration_ms, clock);
}

/// Take custody of an admin DEEP incentive deposit. See `receive_sui_incentive`.
public(package) fun receive_deep_incentive(
    vault: &mut PoolVault,
    deposit: Coin<DEEP>,
    decimals: u8,
    feed_id: u32,
    duration_ms: u64,
    clock: &Clock,
) {
    vault.assert_version_allowed();
    assert!(vault.treasury_cap.total_supply() > 0, ENoPlpHolders);
    vault.incentive_deep.fund(deposit, decimals, feed_id, duration_ms, clock);
}

/// Set the max net DUSDC the pool may have funded into one expiry.
public fun set_max_expiry_funding(
    vault: &mut PoolVault,
    _admin_cap: &AdminCap,
    config: &mut ProtocolConfig,
    expiry_market_id: ID,
    funding: u64,
) {
    vault.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    let net_funding = vault.expiry_accounting.assert_net_funding_at_most(expiry_market_id, funding);
    config.set_expiry_max_funding(expiry_market_id, funding);
    vault_events::emit_expiry_max_funding_updated(
        vault.id(),
        expiry_market_id,
        funding,
        net_funding,
    );
}

// === Private Functions ===

fun assert_all_expected_synced(
    expected_expiry_markets: &vector<ID>,
    synced_expiry_markets: &vector<ID>,
) {
    assert_same_id_set(synced_expiry_markets, expected_expiry_markets, EMissingExpirySync);
}

fun assert_same_id_set(actual: &vector<ID>, expected: &vector<ID>, error: u64) {
    assert!(actual.length() == expected.length(), error);
    let mut i = 0;
    while (i < expected.length()) {
        assert!(actual.contains(&expected[i]), error);
        i = i + 1;
    };
}

fun expiry_rebalance_cash_terms(market: &ExpiryMarket): (u64, u64, u64) {
    let required_cash = market.payout_liability() + market.rebate_reserve();
    let target_buffer = math::mul(required_cash, constants::expiry_rebalance_pct!());
    let target_cash = (required_cash + target_buffer).max(constants::expiry_cash_floor!());
    let sweep_threshold_cash = (required_cash + target_buffer + target_buffer).max(
        constants::expiry_cash_floor!(),
    );
    (market.cash_balance(), target_cash, sweep_threshold_cash)
}

/// Total DUSDC-denominated value of both incentive assets for `supply` pricing.
///
/// Vests each non-empty incentive to now and prices its released balance from its
/// bound, fresh feed; an empty incentive contributes 0 and ignores its source.
/// Must be called inside the valuation window (before the finisher ends it) so
/// the oracle reads are gated like the expiry path's.
fun value_incentives(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    sui_source: &PythSource,
    deep_source: &PythSource,
    clock: &Clock,
): u64 {
    let sui_value = if (!vault.incentive_sui.is_empty()) {
        vault.incentive_sui.sync_value(config, sui_source, clock)
    } else 0;
    let deep_value = if (!vault.incentive_deep.is_empty()) {
        vault.incentive_deep.sync_value(config, deep_source, clock)
    } else 0;
    sui_value + deep_value
}

fun synced_pool_value(vault: &PoolVault, config: &ProtocolConfig, active_expiry_value: u64): u64 {
    let gross_pool_value = vault.idle_balance.value() + active_expiry_value;
    // R1 caveat (flagged for audit; not yet guarded): this assumes gross >= the
    // pending protocol-profit exclusion. The exclusion counts active-expiry NAV
    // symmetrically with realized credits, so if active NAV later falls (traders
    // win) after LPs exited at a higher mark, exclusion can exceed gross and this
    // subtraction underflows, blocking supply/withdraw until NAV recovers.
    // Operationally mitigated by a permanent base PLP supply. Revisit with C3
    // (conservative NAV marking); the minimal guard is `.min(gross_pool_value)`.
    gross_pool_value - vault.pending_protocol_profit_exclusion(config, active_expiry_value)
}

fun pending_protocol_profit_exclusion(
    vault: &PoolVault,
    config: &ProtocolConfig,
    active_expiry_value: u64,
): u64 {
    // NAV prices pending protocol profit before it is terminally materialized.
    // Live cash returns update credits, but reserve custody waits for terminal profit.
    let aggregate_credits = vault.expiry_accounting.profit_basis_credits() + active_expiry_value;
    let aggregate_debits = vault.expiry_accounting.profit_basis_debits();
    if (aggregate_credits <= aggregate_debits) {
        return 0
    };
    math::mul(
        aggregate_credits - aggregate_debits,
        config.protocol_reserve_profit_share(),
    )
}

fun assert_pool_vault(sync: &PoolSync, vault: &PoolVault) {
    assert!(sync.pool_vault_id == vault.id(), EWrongPoolVault);
}

fun assert_expiry_ready_to_sync(sync: &PoolSync, expiry_market_id: ID) {
    assert!(sync.expected_expiry_markets.contains(&expiry_market_id), EExpiryMarketNotActive);
    assert!(!sync.synced_expiry_markets.contains(&expiry_market_id), EExpiryMarketAlreadySynced);
}

fun record_expiry_synced(sync: &mut PoolSync, expiry_market_id: ID, expiry_nav: u64) {
    sync.active_expiry_value = sync.active_expiry_value + expiry_nav;
    sync.synced_expiry_markets.push_back(expiry_market_id);
}

fun rebalance_active_expiry_cash(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    market: &mut ExpiryMarket,
) {
    let expiry_market_id = market.id();
    let (cash_balance, target_cash, sweep_threshold_cash) = expiry_rebalance_cash_terms(market);

    if (cash_balance < target_cash) {
        let requested_top_up = target_cash - cash_balance;
        let funding_room = vault
            .expiry_accounting
            .available_expiry_funding(config, expiry_market_id);
        let top_up = requested_top_up.min(vault.idle_balance.value()).min(funding_room);
        if (top_up > 0) {
            vault.send_expiry_cash(config, market, expiry_market_id, top_up);
            vault.emit_expiry_cash_rebalanced(market, expiry_market_id, top_up, true, target_cash);
        };
    } else if (cash_balance > sweep_threshold_cash) {
        let cash_to_return = cash_balance - target_cash;
        let returned_cash = market.release_pool_cash(cash_to_return);
        let returned_cash_amount = vault.receive_expiry_cash(expiry_market_id, returned_cash);
        vault.emit_expiry_cash_rebalanced(
            market,
            expiry_market_id,
            returned_cash_amount,
            false,
            target_cash,
        );
    };
}

fun unregister_settled_expiry(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
) {
    let expiry_market_id = market.id();
    let deactivated = vault.expiry_accounting.deactivate_expiry_if_present(expiry_market_id);
    let returned_cash = market.release_settled_pool_cash(market_oracle);
    let returned_cash_amount = vault.receive_expiry_cash(expiry_market_id, returned_cash);
    vault.materialize_expiry_profit(config, expiry_market_id);

    if (deactivated || returned_cash_amount > 0) {
        vault.emit_expiry_cash_received(
            expiry_market_id,
            market_oracle,
            returned_cash_amount,
        );
    };
}

fun send_expiry_cash(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    market: &mut ExpiryMarket,
    expiry_market_id: ID,
    amount: u64,
) {
    if (amount == 0) return;
    let cash = vault.idle_balance.split(amount);
    market.receive_pool_cash(cash);
    vault.expiry_accounting.record_sent_to_expiry(config, expiry_market_id, amount);
}

fun receive_expiry_cash(vault: &mut PoolVault, expiry_market_id: ID, cash: Balance<DUSDC>): u64 {
    let amount = cash.value();
    if (amount == 0) {
        cash.destroy_zero();
        return 0
    };
    vault.idle_balance.join(cash);
    vault.expiry_accounting.record_received_from_expiry(expiry_market_id, amount);
    amount
}

fun materialize_expiry_profit(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    expiry_market_id: ID,
) {
    let profit = vault.expiry_accounting.materialize_expiry_profit(expiry_market_id);
    if (profit == 0) return;

    // Materialized profit is cash-backed and irreversible: LP profit stays in
    // idle liquidity, while protocol profit leaves PLP NAV.
    let protocol_profit = math::mul(profit, config.protocol_reserve_profit_share());
    let lp_profit = profit - protocol_profit;
    if (protocol_profit > 0) {
        let protocol_profit_balance = vault.idle_balance.split(protocol_profit);
        vault.protocol_reserve_balance.join(protocol_profit_balance);
    };
    let profit_basis_after = vault.expiry_accounting.profit_basis_debits();
    vault_events::emit_expiry_profit_materialized(
        vault.id(),
        expiry_market_id,
        lp_profit,
        protocol_profit,
        vault.idle_balance.value(),
        vault.protocol_reserve_balance.value(),
        profit_basis_after,
    );
}

fun emit_expiry_cash_received(
    vault: &PoolVault,
    expiry_market_id: ID,
    market_oracle: &MarketOracle,
    amount: u64,
) {
    let (sent_to_expiry_after, received_from_expiry_after) = vault
        .expiry_accounting
        .expiry_flow_amounts(expiry_market_id);
    vault_events::emit_expiry_cash_received(
        vault.id(),
        expiry_market_id,
        pricing::settlement_price(market_oracle),
        amount,
        vault.idle_balance.value(),
        sent_to_expiry_after,
        received_from_expiry_after,
    );
}

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
        vault.idle_balance.value(),
        sent_to_expiry_after,
        received_from_expiry_after,
    );
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext) {
    init(PLP {}, ctx);
}
