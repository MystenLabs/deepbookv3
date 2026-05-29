// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault accounting.
///
/// PoolVault owns idle DUSDC and the PLP treasury cap. Expiry markets own
/// active trading capital and risk state. This module coordinates full-pool
/// valuation, PLP supply/withdrawal, allocation resize, and settled-expiry
/// surplus sweeping. It does not own expiry-local strike, oracle, or position state.
module deepbook_predict::plp;

use deepbook::math;
use deepbook_predict::{
    config_constants,
    constants,
    expiry_market::{ExpiryMarket, ExpiryValuation},
    market_oracle::MarketOracle,
    math as predict_math,
    predict_manager::PredictManager,
    pricing,
    protocol_config::ProtocolConfig,
    risk_config::RiskConfig,
    vault_events
};
use dusdc::dusdc::DUSDC;
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Self, Coin, TreasuryCap},
    coin_registry,
    vec_set::{Self, VecSet}
};
use token::deep::DEEP;

const EExpiryMarketAlreadyActive: u64 = 0;
const EExpiryMarketNotActive: u64 = 1;
const EInsufficientIdleBalance: u64 = 3;
const EMaxTotalExposureExceeded: u64 = 4;
const EWrongPoolVault: u64 = 6;
const EExpiryMarketAlreadyValued: u64 = 7;
const EMissingExpiryValuation: u64 = 8;
const EActiveExpirySetChanged: u64 = 9;
const EGrowUtilizationBelowThreshold: u64 = 12;
const EShrinkUtilizationAboveThreshold: u64 = 13;
const ENoAllocationResize: u64 = 14;
const EInsufficientTotalAllocatedCapital: u64 = 15;
const EZeroSupply: u64 = 16;
const EZeroWithdraw: u64 = 17;
const EInvalidInitialSupply: u64 = 18;
const EZeroShares: u64 = 19;
const EZeroPoolValue: u64 = 20;
const EPackageVersionDisabled: u64 = 21;
const EZeroAllocatedCapital: u64 = 22;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Pool-level capital and PLP accounting state.
public struct PoolVault has key {
    id: UID,
    /// Idle LP-owned DUSDC available for withdrawals and new allocations.
    idle_balance: Balance<DUSDC>,
    /// Protocol revenue swept from settled expiry fee surplus.
    protocol_fee_balance: Balance<DUSDC>,
    /// Insurance fees swept from settled expiry fee surplus.
    insurance_fee_balance: Balance<DUSDC>,
    /// Pooled DEEP staked by all managers for trading benefits. Per-manager
    /// active/inactive amounts are mirrored on each `PredictManager`.
    staked_deep: Balance<DEEP>,
    treasury_cap: TreasuryCap<PLP>,
    /// Expiry markets that still contribute active pool valuation/risk.
    active_expiry_markets: vector<ID>,
    /// Sum of active expiry risk budgets allocated out of the pool.
    total_allocated_capital: u64,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
}

/// Transaction-local pool valuation accumulator.
public struct PoolValuation {
    /// PoolVault ID this valuation is bound to.
    pool_vault_id: ID,
    /// Active expiry set snapshotted when valuation starts.
    expected_expiry_markets: vector<ID>,
    /// Expiry IDs whose valuation witnesses have been consumed.
    valued_expiry_markets: vector<ID>,
    /// Running pool value, starting from idle DUSDC and adding each expiry NAV.
    value: u64,
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

/// Return protocol revenue swept from settled expiry fee surplus.
public fun protocol_fee_balance(vault: &PoolVault): u64 {
    vault.protocol_fee_balance.value()
}

/// Return insurance fees swept from settled expiry fee surplus.
public fun insurance_fee_balance(vault: &PoolVault): u64 {
    vault.insurance_fee_balance.value()
}

/// Return active expiry market IDs tracked by the pool.
public fun active_expiry_markets(vault: &PoolVault): &vector<ID> {
    &vault.active_expiry_markets
}

/// Return total PLP supply.
public fun total_supply(vault: &PoolVault): u64 {
    vault.treasury_cap.total_supply()
}

/// Return total DUSDC allocated as expiry risk budget.
public fun total_allocated_capital(vault: &PoolVault): u64 {
    vault.total_allocated_capital
}

/// Begin a full-pool valuation and lock protocol valuation-sensitive flows.
///
/// The accumulator snapshots the active expiry set and starts with idle DUSDC.
/// Callers must add one valuation witness for each active expiry before
/// supplying or withdrawing.
public fun start_valuation(config: &mut ProtocolConfig, vault: &PoolVault): PoolValuation {
    vault.assert_version_allowed();
    config.begin_valuation();
    PoolValuation {
        pool_vault_id: vault.id(),
        expected_expiry_markets: *&vault.active_expiry_markets,
        valued_expiry_markets: vector[],
        value: vault.idle_balance.value(),
    }
}

/// Add one active expiry valuation witness to the pool accumulator.
///
/// Aborts if the witness is not for the snapshotted active set or if the same
/// expiry is added twice.
public fun add_expiry_valuation(valuation: &mut PoolValuation, expiry_valuation: ExpiryValuation) {
    let (expiry_market_id, expiry_value) = expiry_valuation.unpack();
    assert!(valuation.expected_expiry_markets.contains(&expiry_market_id), EExpiryMarketNotActive);
    assert!(
        !valuation.valued_expiry_markets.contains(&expiry_market_id),
        EExpiryMarketAlreadyValued,
    );
    valuation.valued_expiry_markets.push_back(expiry_market_id);
    valuation.value = valuation.value + expiry_value;
}

/// Grow an active live expiry allocation when utilization reaches the high watermark.
///
/// Moves idle DUSDC from the pool into the expiry while respecting global pool
/// allocation capacity and the upgrade-required per-expiry hard cap.
public fun grow_expiry_allocation(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    clock: &Clock,
) {
    vault.assert_version_allowed();
    config.assert_trading_allowed();
    assert!(vault.active_expiry_markets.contains(&market.id()), EExpiryMarketNotActive);
    market.assert_market_oracle(market_oracle);
    market_oracle.assert_active(clock);
    let risk_config = config.risk_config();
    let amount = vault.grow_amount(risk_config, market);
    let new_total_allocated = vault.total_allocated_capital + amount;
    let allocation = vault.idle_balance.split(amount);
    vault.total_allocated_capital = new_total_allocated;
    market.receive_allocation(allocation);

    vault_events::emit_expiry_allocation_changed(
        vault.id(),
        market.id(),
        amount,
        true,
        market.allocated_capital(),
        vault.idle_balance.value(),
    );
}

/// Shrink an active live expiry allocation when utilization reaches the low watermark.
///
/// Moves only returnable free cash back to the pool; expiry payout backing stays
/// inside the expiry market.
public fun shrink_expiry_allocation(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    clock: &Clock,
) {
    vault.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    assert!(vault.active_expiry_markets.contains(&market.id()), EExpiryMarketNotActive);
    market.assert_market_oracle(market_oracle);
    market_oracle.assert_active(clock);
    let amount = shrink_amount(config.risk_config(), market);
    assert!(vault.total_allocated_capital >= amount, EInsufficientTotalAllocatedCapital);
    let allocation = market.return_allocation(amount);
    vault.total_allocated_capital = vault.total_allocated_capital - amount;
    vault.idle_balance.join(allocation);

    vault_events::emit_expiry_allocation_changed(
        vault.id(),
        market.id(),
        amount,
        false,
        market.allocated_capital(),
        vault.idle_balance.value(),
    );
}

/// Sweep settled expiry surplus into the pool.
///
/// This no-ops before settlement. Once settled, it caches terminal payout
/// liability if needed, retires active allocation on the first sweep, and
/// distributes fee surplus not reserved for unresolved rebates.
public fun sweep_settled_expiry_surplus(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
) {
    vault.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    if (!market_oracle.is_settled()) return;

    let allocated_reduction = market.allocated_capital();
    if (allocated_reduction > 0) {
        assert!(vault.active_expiry_markets.contains(&market.id()), EExpiryMarketNotActive);
        assert!(
            vault.total_allocated_capital >= allocated_reduction,
            EInsufficientTotalAllocatedCapital,
        );
    };

    let (returned_cash, returned_fee_surplus) = market.release_settled_surplus(market_oracle);
    let returned_cash_amount = returned_cash.value();
    if (allocated_reduction > 0) {
        vault.total_allocated_capital = vault.total_allocated_capital - allocated_reduction;
        vault.unregister_expiry_market(market.id());
    };
    vault.idle_balance.join(returned_cash);
    let (protocol_fee, insurance_fee, lp_fee) = vault.distribute_fee_surplus(
        config,
        returned_fee_surplus,
    );

    if (
        allocated_reduction > 0 || returned_cash_amount > 0 || protocol_fee > 0 || insurance_fee > 0 || lp_fee > 0
    ) {
        vault_events::emit_expiry_surplus_swept(
            vault.id(),
            market.id(),
            pricing::settlement_price(market_oracle),
            allocated_reduction,
            returned_cash_amount,
            vault.idle_balance.value(),
            vault.total_allocated_capital,
            protocol_fee,
            insurance_fee,
            lp_fee,
        );
    };
}

/// Supply DUSDC into the pool vault against a complete full-pool valuation.
///
/// Completes the valuation after flow preconditions pass and mints PLP shares
/// at the computed pool value.
public fun supply(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    valuation: PoolValuation,
    payment: Coin<DUSDC>,
    ctx: &mut TxContext,
): Coin<PLP> {
    vault.assert_version_allowed();
    let pool_value = vault.validated_pool_value(config, &valuation);
    let payment_amount = payment.value();
    assert!(payment_amount > 0, EZeroSupply);

    let total_supply = vault.treasury_cap.total_supply();
    let shares = if (total_supply == 0) {
        assert!(pool_value == 0, EInvalidInitialSupply);
        payment_amount
    } else {
        assert!(pool_value > 0, EZeroPoolValue);
        let shares = predict_math::mul_div_round_down(payment_amount, total_supply, pool_value);
        assert!(shares > 0, EZeroShares);
        shares
    };

    finish_valuation(config, valuation);
    vault.idle_balance.join(payment.into_balance());
    let plp = coin::mint(&mut vault.treasury_cap, shares, ctx);
    vault_events::emit_supply_executed(
        vault.id(),
        payment_amount,
        shares,
        pool_value,
        vault.treasury_cap.total_supply(),
        vault.idle_balance.value(),
        vault.total_allocated_capital,
    );
    plp
}

/// Withdraw DUSDC from the pool vault against a complete full-pool valuation.
///
/// Completes the valuation after flow preconditions pass, burns PLP, and
/// enforces the pool-level allocated-capital limit after withdrawal.
public fun withdraw(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    valuation: PoolValuation,
    lp_coin: Coin<PLP>,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    vault.assert_version_allowed();
    let pool_value = vault.validated_pool_value(config, &valuation);
    let lp_amount = lp_coin.value();
    assert!(lp_amount > 0, EZeroWithdraw);

    let total_supply = vault.treasury_cap.total_supply();
    let withdraw_amount = predict_math::mul_div_round_down(lp_amount, pool_value, total_supply);
    assert!(withdraw_amount > 0, EZeroWithdraw);
    let idle_balance = vault.idle_balance.value();
    assert!(idle_balance >= withdraw_amount, EInsufficientIdleBalance);
    let pool_capital_after_withdraw =
        idle_balance - withdraw_amount + vault.total_allocated_capital;
    let max_allocated = math::mul(
        pool_capital_after_withdraw,
        config.risk_config().max_total_exposure_pct(),
    );
    assert!(vault.total_allocated_capital <= max_allocated, EMaxTotalExposureExceeded);

    finish_valuation(config, valuation);
    vault.treasury_cap.burn(lp_coin);
    let payout = vault.idle_balance.split(withdraw_amount).into_coin(ctx);
    vault_events::emit_withdraw_executed(
        vault.id(),
        lp_amount,
        withdraw_amount,
        pool_value,
        vault.treasury_cap.total_supply(),
        vault.idle_balance.value(),
        vault.total_allocated_capital,
    );
    payout
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
    manager.add_inactive_stake(deep.value());
    vault.staked_deep.join(deep.into_balance());
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
    vault.staked_deep.split(amount).into_coin(ctx)
}

// === Public-Package Functions ===

/// Overwrite this vault's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_pool_vault_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(vault: &mut PoolVault, allowed_versions: VecSet<u64>) {
    vault.allowed_versions = allowed_versions;
}

/// Create an empty pool vault from the PLP treasury cap.
public(package) fun new(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): PoolVault {
    PoolVault {
        id: object::new(ctx),
        idle_balance: balance::zero(),
        protocol_fee_balance: balance::zero(),
        insurance_fee_balance: balance::zero(),
        staked_deep: balance::zero(),
        treasury_cap,
        active_expiry_markets: vector[],
        total_allocated_capital: 0,
        allowed_versions: vec_set::singleton(constants::current_version!()),
    }
}

/// Abort if the running package version is not allowed for this vault.
public(package) fun assert_version_allowed(vault: &PoolVault) {
    assert!(
        vault.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Create and share an empty pool vault from the PLP treasury cap.
public(package) fun create_and_share(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): ID {
    let vault = new(treasury_cap, ctx);
    let id = vault.id();
    transfer::share_object(vault);
    id
}

/// Allocate idle DUSDC into a newly created expiry market.
///
/// This is intentionally unusable on a freshly published package until the LP
/// funding path is implemented; the pool must already hold enough idle DUSDC.
public(package) fun allocate_to_new_expiry(
    vault: &mut PoolVault,
    risk_config: &RiskConfig,
): Balance<DUSDC> {
    let amount = risk_config.expiry_allocation();
    let idle_balance = vault.idle_balance.value();
    assert!(idle_balance >= amount, EInsufficientIdleBalance);

    let pool_capital = idle_balance + vault.total_allocated_capital;
    let new_total_allocated = vault.total_allocated_capital + amount;
    let max_allocated = math::mul(pool_capital, risk_config.max_total_exposure_pct());
    assert!(new_total_allocated <= max_allocated, EMaxTotalExposureExceeded);

    vault.total_allocated_capital = new_total_allocated;
    vault.idle_balance.split(amount)
}

/// Register an expiry market as active for valuation and pool allocation accounting.
public(package) fun register_expiry_market(vault: &mut PoolVault, expiry_market_id: ID) {
    assert!(!vault.active_expiry_markets.contains(&expiry_market_id), EExpiryMarketAlreadyActive);
    vault.active_expiry_markets.push_back(expiry_market_id);
}

/// Remove an expiry market from active valuation and pool allocation accounting.
public(package) fun unregister_expiry_market(vault: &mut PoolVault, expiry_market_id: ID) {
    let mut i = 0;
    let len = vault.active_expiry_markets.length();
    while (i < len && vault.active_expiry_markets[i] != expiry_market_id) {
        i = i + 1;
    };
    assert!(i < len, EExpiryMarketNotActive);
    vault.active_expiry_markets.swap_remove(i);
}

// === Private Functions ===

fun assert_active_set_unchanged(vault: &PoolVault, expected_expiry_markets: &vector<ID>) {
    assert_same_id_set(
        &vault.active_expiry_markets,
        expected_expiry_markets,
        EActiveExpirySetChanged,
    );
}

fun assert_all_expected_valued(
    expected_expiry_markets: &vector<ID>,
    valued_expiry_markets: &vector<ID>,
) {
    assert_same_id_set(valued_expiry_markets, expected_expiry_markets, EMissingExpiryValuation);
}

fun assert_same_id_set(actual: &vector<ID>, expected: &vector<ID>, error: u64) {
    assert!(actual.length() == expected.length(), error);
    let mut i = 0;
    while (i < expected.length()) {
        assert!(actual.contains(&expected[i]), error);
        i = i + 1;
    };
}

fun remaining_global_allocation_capacity(vault: &PoolVault, risk_config: &RiskConfig): u64 {
    let idle_balance = vault.idle_balance.value();
    let max_total_allocation = math::mul(
        idle_balance + vault.total_allocated_capital,
        risk_config.max_total_exposure_pct(),
    );
    if (max_total_allocation > vault.total_allocated_capital) {
        max_total_allocation - vault.total_allocated_capital
    } else {
        0
    }
}

fun grow_amount(vault: &PoolVault, risk_config: &RiskConfig, market: &ExpiryMarket): u64 {
    let current_allocation = market.allocated_capital();
    let utilization = allocation_utilization(market.payout_liability(), current_allocation);
    assert!(
        utilization >= risk_config.grow_utilization_threshold(),
        EGrowUtilizationBelowThreshold,
    );

    let desired_target = math::mul(current_allocation, risk_config.grow_factor()).min(
        config_constants::max_allocation!(),
    );
    assert!(desired_target > current_allocation, ENoAllocationResize);
    let desired_growth = desired_target - current_allocation;
    let amount = desired_growth
        .min(vault.remaining_global_allocation_capacity(risk_config))
        .min(vault.idle_balance.value());
    assert!(amount > 0, ENoAllocationResize);
    amount
}

fun shrink_amount(risk_config: &RiskConfig, market: &ExpiryMarket): u64 {
    let current_allocation = market.allocated_capital();
    let utilization = allocation_utilization(market.payout_liability(), current_allocation);
    assert!(
        utilization <= risk_config.shrink_utilization_threshold(),
        EShrinkUtilizationAboveThreshold,
    );

    let target_allocation = math::mul(
        current_allocation,
        risk_config.shrink_factor(),
    ).max(risk_config.expiry_allocation());
    // returnable_capital caps the shrink so allocation and cash remain above payout liability.
    let amount = if (target_allocation < current_allocation) {
        current_allocation - target_allocation
    } else {
        0
    }.min(market.returnable_capital());
    assert!(amount > 0, ENoAllocationResize);
    amount
}

fun allocation_utilization(payout_liability: u64, allocated_capital: u64): u64 {
    assert!(allocated_capital > 0, EZeroAllocatedCapital);
    math::div(payout_liability, allocated_capital)
}

/// Split fee surplus to protocol, insurance, and LP, returning the three amounts.
fun distribute_fee_surplus(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    fee_surplus: Balance<DUSDC>,
): (u64, u64, u64) {
    let total_fee = fee_surplus.value();
    let protocol_fee = math::mul(total_fee, config.fee_config().protocol_fee_share());
    let insurance_fee = math::mul(total_fee, config.fee_config().insurance_fee_share());
    let mut lp_fee = fee_surplus;
    let protocol_fee_balance = lp_fee.split(protocol_fee);
    let insurance_fee_balance = lp_fee.split(insurance_fee);
    let lp_fee_amount = lp_fee.value();
    vault.idle_balance.join(lp_fee);
    vault.protocol_fee_balance.join(protocol_fee_balance);
    vault.insurance_fee_balance.join(insurance_fee_balance);
    (protocol_fee, insurance_fee, lp_fee_amount)
}

fun validated_pool_value(
    vault: &PoolVault,
    config: &ProtocolConfig,
    valuation: &PoolValuation,
): u64 {
    config.assert_valuation_in_progress();
    assert!(valuation.pool_vault_id == vault.id(), EWrongPoolVault);
    assert_active_set_unchanged(vault, &valuation.expected_expiry_markets);
    assert_all_expected_valued(
        &valuation.expected_expiry_markets,
        &valuation.valued_expiry_markets,
    );
    valuation.value
}

fun finish_valuation(config: &mut ProtocolConfig, valuation: PoolValuation) {
    let PoolValuation {
        pool_vault_id: _,
        expected_expiry_markets: _,
        valued_expiry_markets: _,
        value: _,
    } = valuation;
    config.end_valuation();
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext) {
    init(PLP {}, ctx);
}
