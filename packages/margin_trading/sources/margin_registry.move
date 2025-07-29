// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all margin pools.
module margin_trading::margin_registry;

use deepbook::{constants, math, pool::Pool};
use margin_trading::{
    margin_constants,
    margin_pool::{Self, MarginPool},
    margin_state::{Self, InterestParams}
};
use std::type_name::{Self, TypeName};
use sui::{clock::Clock, dynamic_field as df, table::{Self, Table}};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::remove as UID.remove;

// === Errors ===
const EInvalidRiskParam: u64 = 1;
const EPoolAlreadyRegistered: u64 = 2;
const EPoolNotRegistered: u64 = 3;
const EPoolNotEnabled: u64 = 4;
const EPoolAlreadyEnabled: u64 = 5;
const EPoolAlreadyDisabled: u64 = 6;
const EMarginPoolAlreadyExists: u64 = 7;
const EMarginPoolDoesNotExists: u64 = 8;
const EInvalidOptimalUtilization: u64 = 9;

public struct MARGIN_REGISTRY has drop {}

// === Structs ===
public struct MarginAdminCap has key, store {
    id: UID,
}

public struct PoolConfig has copy, drop, store {
    base_margin_pool_id: ID,
    quote_margin_pool_id: ID,
    risk_ratios: RiskRatios,
    user_liquidation_reward: u64, // fractional reward for liquidating a position, in 9 decimals
    pool_liquidation_reward: u64, // fractional reward for the pool, in 9 decimals
    max_slippage: u64, // maximum slippage allowed during liquidation, in 9 decimals
    enabled: bool, // whether the pool is enabled for margin trading
}

public struct MarginRegistry has key, store {
    id: UID,
    pool_registry: Table<ID, PoolConfig>,
    margin_pools: Table<TypeName, ID>,
}

public struct ConfigKey<phantom Config> has copy, drop, store {}

public struct RiskRatios has copy, drop, store {
    min_withdraw_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
    target_liquidation_risk_ratio: u64,
}

fun init(_: MARGIN_REGISTRY, ctx: &mut TxContext) {
    let registry = MarginRegistry {
        id: object::new(ctx),
        pool_registry: table::new(ctx),
        margin_pools: table::new(ctx),
    };
    transfer::share_object(registry);
    let margin_admin_cap = MarginAdminCap { id: object::new(ctx) };
    transfer::public_transfer(margin_admin_cap, ctx.sender())
}

// === Public Functions * ADMIN * ===
/// Creates and registers a new margin pool. If a same asset pool already exists, abort.
public fun new_margin_pool<Asset>(
    self: &mut MarginRegistry,
    interest_params: InterestParams,
    supply_cap: u64,
    max_borrow_percentage: u64,
    clock: &Clock,
    _cap: &MarginAdminCap,
    ctx: &mut TxContext,
) {
    let margin_pool_id = margin_pool::create_margin_pool<Asset>(
        interest_params,
        supply_cap,
        max_borrow_percentage,
        clock,
        ctx,
    );

    let key = type_name::get<Asset>();
    assert!(!self.margin_pools.contains(key), EMarginPoolAlreadyExists);
    self.margin_pools.add(key, margin_pool_id);
}

public fun update_supply_cap<Asset>(
    margin_pool: &mut MarginPool<Asset>,
    supply_cap: u64,
    _cap: &MarginAdminCap,
) {
    margin_pool.update_supply_cap<Asset>(supply_cap);
}

public fun update_max_borrow_percentage<Asset>(
    margin_pool: &mut MarginPool<Asset>,
    max_borrow_percentage: u64,
    _cap: &MarginAdminCap,
) {
    assert!(max_borrow_percentage <= 1_000_000_000, EInvalidRiskParam);

    margin_pool.update_max_borrow_percentage<Asset>(max_borrow_percentage);
}

public fun update_interest_params<Asset>(
    margin_pool: &mut MarginPool<Asset>,
    interest_params: InterestParams,
    _cap: &MarginAdminCap,
) {
    margin_pool.update_interest_params<Asset>(interest_params);
}

/// Creates a new InterestParams object with the given parameters.
public fun new_interest_params(
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
): InterestParams {
    assert!(optimal_utilization <= 1_000_000_000, EInvalidOptimalUtilization);

    margin_state::new_interest_params(
        base_rate,
        base_slope,
        optimal_utilization,
        excess_slope,
    )
}

/// Register a margin pool for margin trading with existing margin pools
public fun register_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    pool_config: PoolConfig,
    _cap: &MarginAdminCap,
) {
    let pool_id = object::id(pool);
    assert!(!self.pool_registry.contains(pool_id), EPoolAlreadyRegistered);

    self.pool_registry.add(pool_id, pool_config);
}

/// Create a PoolConfig with default risk parameters based on leverage
public fun new_pool_config_with_leverage<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    leverage: u64,
): PoolConfig {
    assert!(leverage > margin_constants::min_leverage(), EInvalidRiskParam);
    assert!(leverage <= margin_constants::max_leverage(), EInvalidRiskParam);

    let factor = math::div(constants::float_scaling(), leverage - constants::float_scaling());
    let risk_ratios = calculate_risk_ratios(factor);

    self.new_pool_config<BaseAsset, QuoteAsset>(
        risk_ratios.min_withdraw_risk_ratio,
        risk_ratios.min_borrow_risk_ratio,
        risk_ratios.liquidation_risk_ratio,
        risk_ratios.target_liquidation_risk_ratio,
        margin_constants::default_user_liquidation_reward(),
        margin_constants::default_pool_liquidation_reward(),
        margin_constants::default_max_slippage(),
    )
}

/// Create a PoolConfig with margin pool IDs and risk parameters
/// Enable is false by default, must be enabled after registration
public fun new_pool_config<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    min_withdraw_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
    target_liquidation_risk_ratio: u64,
    user_liquidation_reward: u64,
    pool_liquidation_reward: u64,
    max_slippage: u64,
): PoolConfig {
    assert!(min_borrow_risk_ratio < min_withdraw_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < min_borrow_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < target_liquidation_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio >= 1_000_000_000, EInvalidRiskParam);
    assert!(user_liquidation_reward <= 1_000_000_000, EInvalidRiskParam);
    assert!(pool_liquidation_reward <= 1_000_000_000, EInvalidRiskParam);
    assert!(user_liquidation_reward + pool_liquidation_reward <= 1_000_000_000, EInvalidRiskParam);
    assert!(
        target_liquidation_risk_ratio > 1_000_000_000 + user_liquidation_reward + pool_liquidation_reward,
        EInvalidRiskParam,
    );
    assert!(max_slippage <= 1_000_000_000, EInvalidRiskParam);

    PoolConfig {
        base_margin_pool_id: self.get_margin_pool_id<BaseAsset>(),
        quote_margin_pool_id: self.get_margin_pool_id<QuoteAsset>(),
        risk_ratios: RiskRatios {
            min_withdraw_risk_ratio,
            min_borrow_risk_ratio,
            liquidation_risk_ratio,
            target_liquidation_risk_ratio,
        },
        user_liquidation_reward,
        pool_liquidation_reward,
        max_slippage,
        enabled: false,
    }
}

/// Updates risk params for a deepbook pool as the admin.
public fun update_risk_params<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    pool_config: PoolConfig,
    _cap: &MarginAdminCap,
) {
    let pool_id = object::id(pool);
    assert!(self.pool_registry.contains(pool_id), EPoolNotRegistered);

    let prev_config = self.pool_registry.remove(pool_id);
    assert!(
        pool_config.risk_ratios.liquidation_risk_ratio <= prev_config.risk_ratios.liquidation_risk_ratio,
        EInvalidRiskParam,
    );
    assert!(prev_config.enabled, EPoolNotEnabled);

    // Validate new risk parameters
    assert!(
        pool_config.risk_ratios.min_borrow_risk_ratio < pool_config.risk_ratios.min_withdraw_risk_ratio,
        EInvalidRiskParam,
    );
    assert!(
        pool_config.risk_ratios.liquidation_risk_ratio < pool_config.risk_ratios.min_borrow_risk_ratio,
        EInvalidRiskParam,
    );
    assert!(
        pool_config.risk_ratios.liquidation_risk_ratio < pool_config.risk_ratios.target_liquidation_risk_ratio,
        EInvalidRiskParam,
    );
    assert!(pool_config.risk_ratios.liquidation_risk_ratio >= 1_000_000_000, EInvalidRiskParam);

    self.pool_registry.add(pool_id, pool_config);
}

/// Disables a deepbook pool from margin trading. Only reduce only orders, cancels, and withdraw settled amounts are allowed.
public fun enable_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    _cap: &MarginAdminCap,
) {
    let pool_id = object::id(pool);
    assert!(self.pool_registry.contains(pool_id), EPoolNotRegistered);

    let config = self.pool_registry.borrow_mut(pool_id);
    assert!(config.enabled == false, EPoolAlreadyEnabled);
    config.enabled = true;
}

/// Disables a deepbook pool from margin trading. Only reduce only orders, cancels, and withdraw settled amounts are allowed.
public fun disable_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    _cap: &MarginAdminCap,
) {
    let pool_id = object::id(pool);
    assert!(self.pool_registry.contains(pool_id), EPoolNotRegistered);

    let config = self.pool_registry.borrow_mut(pool_id);
    assert!(config.enabled == true, EPoolAlreadyDisabled);
    config.enabled = false;
}

/// Add Pyth Config to the MarginRegistry.
public fun add_config<Config: store + drop>(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
    config: Config,
) {
    self.id.add(ConfigKey<Config> {}, config);
}

/// Remove Pyth Config from the MarginRegistry.
public fun remove_config<Config: store + drop>(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
): Config {
    self.id.remove(ConfigKey<Config> {})
}

// === Public Helper Functions ===
/// Check if a deepbook pool is registered for margin trading
public fun pool_enabled<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
): bool {
    let pool_id = object::id(pool);
    if (self.pool_registry.contains(pool_id)) {
        let config = self.pool_registry.borrow(pool_id);

        config.enabled
    } else {
        false
    }
}

/// Get the margin pool id for the given asset.
public fun get_margin_pool_id<Asset>(self: &MarginRegistry): ID {
    let key = type_name::get<Asset>();
    assert!(self.margin_pools.contains(key), EMarginPoolDoesNotExists);

    *self.margin_pools.borrow<TypeName, ID>(key)
}

/// Get the margin pool IDs for a deepbook pool
public fun get_deepbook_pool_margin_pool_ids(
    registry: &MarginRegistry,
    deepbook_pool_id: ID,
): (ID, ID) {
    let config = registry.get_pool_config(deepbook_pool_id);
    (config.base_margin_pool_id, config.quote_margin_pool_id)
}

// === Public-Package Functions ===
/// Get the pool configuration for a deepbook pool
public(package) fun get_pool_config(self: &MarginRegistry, deepbook_pool_id: ID): &PoolConfig {
    assert!(self.pool_registry.contains(deepbook_pool_id), EPoolNotRegistered);
    self.pool_registry.borrow(deepbook_pool_id)
}

/// Get the base margin pool ID for a deepbook pool
public(package) fun get_base_margin_pool_id(self: &MarginRegistry, deepbook_pool_id: ID): ID {
    let config = self.get_pool_config(deepbook_pool_id);
    config.base_margin_pool_id
}

/// Get the quote margin pool ID for a deepbook pool
public(package) fun get_quote_margin_pool_id(self: &MarginRegistry, deepbook_pool_id: ID): ID {
    let config = self.get_pool_config(deepbook_pool_id);
    config.quote_margin_pool_id
}

public(package) fun can_withdraw(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
    risk_ratio: u64,
): bool {
    let config = self.get_pool_config(deepbook_pool_id);
    risk_ratio >= config.risk_ratios.min_withdraw_risk_ratio
}

public(package) fun can_borrow(self: &MarginRegistry, deepbook_pool_id: ID, risk_ratio: u64): bool {
    let config = self.get_pool_config(deepbook_pool_id);
    risk_ratio >= config.risk_ratios.min_borrow_risk_ratio
}

public(package) fun can_liquidate(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
    risk_ratio: u64,
): bool {
    let config = self.get_pool_config(deepbook_pool_id);
    risk_ratio < config.risk_ratios.liquidation_risk_ratio
}

public(package) fun target_liquidation_risk_ratio(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.risk_ratios.target_liquidation_risk_ratio
}

public(package) fun user_liquidation_reward(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.user_liquidation_reward
}

public(package) fun pool_liquidation_reward(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.pool_liquidation_reward
}

public(package) fun max_slippage(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.max_slippage
}

public(package) fun get_config<Config: store + drop>(self: &MarginRegistry): &Config {
    self.id.borrow(ConfigKey<Config> {})
}

/// Calculate risk parameters based on leverage factor
fun calculate_risk_ratios(leverage_factor: u64): RiskRatios {
    RiskRatios {
        min_withdraw_risk_ratio: constants::float_scaling() + 4 * leverage_factor, // 1 + 1 = 2x
        min_borrow_risk_ratio: constants::float_scaling() + leverage_factor, // 1 + 0.25 = 1.25x
        liquidation_risk_ratio: constants::float_scaling() + leverage_factor / 2, // 1 + 0.125 = 1.125x
        target_liquidation_risk_ratio: constants::float_scaling() + leverage_factor, // 1 + 0.25 = 1.25x
    }
}
