// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault state.
///
/// PoolVault owns idle DUSDC and the PLP treasury cap. Expiry markets own
/// active trading capital and risk state. This module coordinates PLP
/// supply/withdrawal and pool-to-expiry capital allocation.
module deepbook_predict::plp;

use deepbook::math;
use deepbook_predict::{
    config_constants,
    expiry_market::{Self, ExpiryMarket, ExpiryValuation},
    market_oracle::MarketOracle,
    math as predict_math,
    protocol_config::ProtocolConfig,
    risk_config::RiskConfig
};
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, clock::Clock, coin::{Self, Coin, TreasuryCap}, coin_registry};

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

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Pool-level capital and PLP accounting state.
public struct PoolVault has key {
    id: UID,
    idle_balance: Balance<DUSDC>,
    protocol_fee_balance: Balance<DUSDC>,
    insurance_fee_balance: Balance<DUSDC>,
    treasury_cap: TreasuryCap<PLP>,
    active_expiry_markets: vector<ID>,
    total_allocated_capital: u64,
}

/// Transaction-local pool valuation accumulator.
public struct PoolValuation {
    pool_vault_id: ID,
    expected_expiry_markets: vector<ID>,
    valued_expiry_markets: vector<ID>,
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

/// Return idle DUSDC held by the pool.
public fun idle_balance(vault: &PoolVault): u64 {
    vault.idle_balance.value()
}

/// Return protocol fees swept from compacted expiry markets.
public fun protocol_fee_balance(vault: &PoolVault): u64 {
    vault.protocol_fee_balance.value()
}

/// Return insurance fees swept from compacted expiry markets.
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

/// Begin a full-pool valuation.
public fun start_valuation(vault: &PoolVault, config: &mut ProtocolConfig): PoolValuation {
    config.begin_valuation();
    PoolValuation {
        pool_vault_id: vault.id(),
        expected_expiry_markets: *&vault.active_expiry_markets,
        valued_expiry_markets: vector[],
        value: vault.idle_balance.value(),
    }
}

/// Add one expiry valuation to a pool valuation accumulator.
public fun add_expiry_valuation(valuation: &mut PoolValuation, expiry_valuation: ExpiryValuation) {
    let (expiry_market_id, expiry_value) = expiry_market::unpack_valuation(expiry_valuation);
    assert!(valuation.expected_expiry_markets.contains(&expiry_market_id), EExpiryMarketNotActive);
    assert!(
        !valuation.valued_expiry_markets.contains(&expiry_market_id),
        EExpiryMarketAlreadyValued,
    );
    valuation.valued_expiry_markets.push_back(expiry_market_id);
    valuation.value = valuation.value + expiry_value;
}

/// Grow an active expiry's allocation when utilization reaches the high watermark.
public fun grow_expiry_allocation(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
    clock: &Clock,
) {
    config.assert_not_valuation_in_progress();
    assert!(vault.active_expiry_markets.contains(&market.id()), EExpiryMarketNotActive);
    market.assert_market_oracle(market_oracle);
    market_oracle.assert_active(clock);
    let risk_config = config.risk_config();
    let amount = vault.grow_amount(risk_config, market);
    let new_total_allocated = vault.total_allocated_capital + amount;
    let allocation = vault.idle_balance.split(amount);
    vault.total_allocated_capital = new_total_allocated;
    market.receive_allocation(allocation);
}

/// Shrink an active expiry's allocation when utilization reaches the low watermark.
public fun shrink_expiry_allocation(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
    clock: &Clock,
) {
    config.assert_not_valuation_in_progress();
    assert!(vault.active_expiry_markets.contains(&market.id()), EExpiryMarketNotActive);
    market.assert_market_oracle(market_oracle);
    market_oracle.assert_active(clock);
    let amount = shrink_amount(config.risk_config(), market);
    assert!(vault.total_allocated_capital >= amount, EInsufficientTotalAllocatedCapital);
    let allocation = market.return_allocation(amount);
    vault.total_allocated_capital = vault.total_allocated_capital - amount;
    vault.idle_balance.join(allocation);
}

/// Compact a settled expiry market and return all surplus LP cash to the pool.
public fun compact_expiry_market(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
) {
    config.assert_not_valuation_in_progress();
    assert!(vault.active_expiry_markets.contains(&market.id()), EExpiryMarketNotActive);
    let allocated_reduction = market.allocated_capital();
    assert!(
        vault.total_allocated_capital >= allocated_reduction,
        EInsufficientTotalAllocatedCapital,
    );
    let (returned_cash, protocol_fees, insurance_fees) = market.compact_settled(market_oracle);
    vault.total_allocated_capital = vault.total_allocated_capital - allocated_reduction;
    vault.idle_balance.join(returned_cash);
    vault.protocol_fee_balance.join(protocol_fees);
    vault.insurance_fee_balance.join(insurance_fees);
    vault.unregister_expiry_market(market.id());
}

/// Supply DUSDC into the pool vault and receive PLP shares.
public fun supply(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    valuation: PoolValuation,
    payment: Coin<DUSDC>,
    ctx: &mut TxContext,
): Coin<PLP> {
    let pool_value = vault.consume_valuation(config, valuation);
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

    vault.idle_balance.join(payment.into_balance());
    coin::mint(&mut vault.treasury_cap, shares, ctx)
}

/// Withdraw DUSDC from the pool vault by burning PLP shares.
public fun withdraw(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    valuation: PoolValuation,
    lp_coin: Coin<PLP>,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    let pool_value = vault.consume_valuation(config, valuation);
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

    vault.treasury_cap.burn(lp_coin);
    vault.idle_balance.split(withdraw_amount).into_coin(ctx)
}

// === Public-Package Functions ===

/// Create an empty pool vault from the PLP treasury cap.
public(package) fun new(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): PoolVault {
    PoolVault {
        id: object::new(ctx),
        idle_balance: balance::zero(),
        protocol_fee_balance: balance::zero(),
        insurance_fee_balance: balance::zero(),
        treasury_cap,
        active_expiry_markets: vector[],
        total_allocated_capital: 0,
    }
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

/// Register an expiry market as active for pool accounting.
public(package) fun register_expiry_market(vault: &mut PoolVault, expiry_market_id: ID) {
    assert!(!vault.active_expiry_markets.contains(&expiry_market_id), EExpiryMarketAlreadyActive);
    vault.active_expiry_markets.push_back(expiry_market_id);
}

/// Remove an expiry market from active pool accounting.
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
    assert!(
        vault.active_expiry_markets.length() == expected_expiry_markets.length(),
        EActiveExpirySetChanged,
    );
    let mut i = 0;
    while (i < expected_expiry_markets.length()) {
        assert!(
            vault.active_expiry_markets.contains(&expected_expiry_markets[i]),
            EActiveExpirySetChanged,
        );
        i = i + 1;
    };
}

fun assert_all_expected_valued(
    expected_expiry_markets: &vector<ID>,
    valued_expiry_markets: &vector<ID>,
) {
    assert!(
        expected_expiry_markets.length() == valued_expiry_markets.length(),
        EMissingExpiryValuation,
    );
    let mut i = 0;
    while (i < expected_expiry_markets.length()) {
        assert!(
            valued_expiry_markets.contains(&expected_expiry_markets[i]),
            EMissingExpiryValuation,
        );
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
    let utilization = market.utilization();
    assert!(
        utilization >= risk_config.grow_utilization_threshold(),
        EGrowUtilizationBelowThreshold,
    );

    let current_allocation = market.allocated_capital();
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
    let utilization = market.utilization();
    assert!(
        utilization <= risk_config.shrink_utilization_threshold(),
        EShrinkUtilizationAboveThreshold,
    );

    let current_allocation = market.allocated_capital();
    let target_allocation = math::mul(current_allocation, risk_config.shrink_factor())
        .max(risk_config.expiry_allocation())
        .max(market.max_payout());
    let amount = if (target_allocation < current_allocation) {
        current_allocation - target_allocation
    } else {
        0
    }.min(market.returnable_capital());
    assert!(amount > 0, ENoAllocationResize);
    amount
}

fun consume_valuation(
    vault: &PoolVault,
    config: &mut ProtocolConfig,
    valuation: PoolValuation,
): u64 {
    config.assert_valuation_in_progress();
    let PoolValuation {
        pool_vault_id,
        expected_expiry_markets,
        valued_expiry_markets,
        value,
    } = valuation;
    assert!(pool_vault_id == vault.id(), EWrongPoolVault);
    assert_active_set_unchanged(vault, &expected_expiry_markets);
    assert_all_expected_valued(&expected_expiry_markets, &valued_expiry_markets);
    config.end_valuation();
    value
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext) {
    init(PLP {}, ctx);
}
