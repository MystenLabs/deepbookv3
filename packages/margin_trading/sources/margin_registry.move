// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all margin pools.
module margin_trading::margin_registry;

use deepbook::{constants, math, pool::Pool};
use margin_trading::margin_pool::{MarginPool};
use sui::{dynamic_field as df, table::{Self, Table}};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::remove as UID.remove;

// === Errors ===
const EInvalidRiskParam: u64 = 5;
const EPoolAlreadyRegistered: u64 = 6;
const EPoolNotRegistered: u64 = 7;

// === Constants ===
const DEFAULT_LIQUIDATION_REWARD: u64 = 50_000_000; // 5%
const MIN_LEVERAGE: u64 = 1_000_000_000; // 1x
const MAX_LEVERAGE: u64 = 20_000_000_000; // 20x

public struct MARGIN_REGISTRY has drop {}

// === Structs ===
public struct MarginAdminCap has key, store {
    id: UID,
}

public struct PoolConfig has copy, drop, store {
    base_margin_pool_id: ID,
    quote_margin_pool_id: ID,
    // Risk parameters
    min_withdraw_risk_ratio: u64, // 9 decimals, minimum risk ratio to allow transfer
    min_borrow_risk_ratio: u64, // 9 decimals, minimum risk ratio to allow borrow
    liquidation_risk_ratio: u64, // 9 decimals, risk ratio below which liquidation is allowed
    target_liquidation_risk_ratio: u64, // 9 decimals, target risk ratio after liquidation
    liquidation_reward: u64, // fractional reward for liquidating a position, in 9 decimals
}

public struct MarginRegistry has key, store {
    id: UID,
    pool_registry: Table<ID, PoolConfig>, 
}

public struct ConfigKey<phantom Config> has copy, drop, store {}

public struct RiskRatios has drop {
    min_withdraw_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
    target_liquidation_risk_ratio: u64,
}

fun init(_: MARGIN_REGISTRY, ctx: &mut TxContext) {
    let registry = MarginRegistry {
        id: object::new(ctx),
        pool_registry: table::new(ctx),
    };
    transfer::share_object(registry);
    let margin_admin_cap = MarginAdminCap { id: object::new(ctx) };
    transfer::public_transfer(margin_admin_cap, ctx.sender())
}

// === Public Functions * ADMIN * ===
/// Create a PoolConfig with margin pool IDs and risk parameters
public fun new_pool_config<BaseAsset, QuoteAsset>(
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    min_withdraw_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
    target_liquidation_risk_ratio: u64,
    liquidation_reward: u64,
): PoolConfig {
    assert!(min_borrow_risk_ratio < min_withdraw_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < min_borrow_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < target_liquidation_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio >= 1_000_000_000, EInvalidRiskParam);
    assert!(liquidation_reward <= 1_000_000_000, EInvalidRiskParam);

    PoolConfig {
        base_margin_pool_id: object::id(base_margin_pool),
        quote_margin_pool_id: object::id(quote_margin_pool),
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        liquidation_reward,
    }
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

/// Create a PoolConfig with default risk parameters based on leverage
public fun new_pool_config_with_leverage<BaseAsset, QuoteAsset>(
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    leverage: u64,
): PoolConfig {
    assert!(leverage > MIN_LEVERAGE, EInvalidRiskParam);
    assert!(leverage <= MAX_LEVERAGE, EInvalidRiskParam); 

    let factor = math::div(constants::float_scaling(), leverage - constants::float_scaling());
    let risk_ratios = calculate_risk_ratios(factor);
    
    new_pool_config(
        base_margin_pool,
        quote_margin_pool,
        risk_ratios.min_withdraw_risk_ratio,
        risk_ratios.min_borrow_risk_ratio,
        risk_ratios.liquidation_risk_ratio,
        risk_ratios.target_liquidation_risk_ratio,
        DEFAULT_LIQUIDATION_REWARD
    )
}

/// Updates risk params for a deepbook pool as the admin.
public fun update_risk_params<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    min_withdraw_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
    target_liquidation_risk_ratio: u64,
    liquidation_reward: u64,
    _cap: &MarginAdminCap,
) {
    let pool_id = object::id(pool);
    assert!(self.pool_registry.contains(pool_id), EPoolNotRegistered);

    let prev_config = self.pool_registry.remove(pool_id);
    assert!(
        liquidation_risk_ratio <= prev_config.liquidation_risk_ratio,
        EInvalidRiskParam,
    );

    // Validate new risk parameters
    assert!(min_borrow_risk_ratio < min_withdraw_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < min_borrow_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < target_liquidation_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio >= 1_000_000_000, EInvalidRiskParam);
    assert!(liquidation_reward <= 1_000_000_000, EInvalidRiskParam);

    let updated_config = PoolConfig {
        base_margin_pool_id: prev_config.base_margin_pool_id,
        quote_margin_pool_id: prev_config.quote_margin_pool_id,
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        liquidation_reward,
    };
    self.pool_registry.add(pool_id, updated_config);
}

/// Register a margin pool for margin trading with existing margin pools
public fun register_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    min_withdraw_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
    target_liquidation_risk_ratio: u64,
    liquidation_reward: u64,
    _cap: &MarginAdminCap,
) {
    let pool_id = object::id(pool);
    assert!(!self.pool_registry.contains(pool_id), EPoolAlreadyRegistered);
    
    let config = new_pool_config(
        base_margin_pool,
        quote_margin_pool,
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        liquidation_reward,
    );
    self.pool_registry.add(pool_id, config);
}

// TODO: Account for open orders before allowing unregister
/// Unregister a deepbook pool from margin trading
public fun unregister_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    _cap: &MarginAdminCap,
) {
    let pool_id = object::id(pool);
    assert!(self.pool_registry.contains(pool_id), EPoolNotRegistered);
    
    self.pool_registry.remove(pool_id);
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
public fun pool_registered<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
): bool {
    let pool_id = object::id(pool);
    self.pool_registry.contains(pool_id)
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
public(package) fun get_pool_config(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
): &PoolConfig {
    assert!(self.pool_registry.contains(deepbook_pool_id), EPoolNotRegistered);
    self.pool_registry.borrow(deepbook_pool_id)
}

/// Get the base margin pool ID for a deepbook pool
public(package) fun get_base_margin_pool_id(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
): ID {
    let config = self.get_pool_config(deepbook_pool_id);
    config.base_margin_pool_id
}

/// Get the quote margin pool ID for a deepbook pool
public(package) fun get_quote_margin_pool_id(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
): ID {
    let config = self.get_pool_config(deepbook_pool_id);
    config.quote_margin_pool_id
}

public(package) fun can_withdraw(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
    risk_ratio: u64,
): bool {
    let config = self.get_pool_config(deepbook_pool_id);
    risk_ratio >= config.min_withdraw_risk_ratio
}

public(package) fun can_borrow(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
    risk_ratio: u64,
): bool {
    let config = self.get_pool_config(deepbook_pool_id);
    risk_ratio >= config.min_borrow_risk_ratio
}

public(package) fun can_liquidate(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
    risk_ratio: u64,
): bool {
    let config = self.get_pool_config(deepbook_pool_id);
    risk_ratio < config.liquidation_risk_ratio
}

public(package) fun target_liquidation_risk_ratio(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.target_liquidation_risk_ratio
}

public(package) fun liquidation_reward(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.liquidation_reward
}

public(package) fun get_config<Config: store + drop>(self: &MarginRegistry): &Config {
    self.id.borrow(ConfigKey<Config> {})
}
