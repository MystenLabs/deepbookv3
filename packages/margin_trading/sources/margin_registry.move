// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all margin pools.
module margin_trading::margin_registry;

use deepbook::{constants, math, pool::Pool};
use margin_trading::margin_constants;
use std::type_name::{Self, TypeName};
use sui::{
    clock::Clock,
    dynamic_field as df,
    event,
    table::{Self, Table},
    vec_set::{Self, VecSet},
    versioned::{Self, Versioned}
};

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
const EMaintainerCapNotValid: u64 = 9;
const EPackageVersionDisabled: u64 = 10;
const EVersionAlreadyEnabled: u64 = 11;
const ECannotDisableCurrentVersion: u64 = 12;
const EVersionNotEnabled: u64 = 13;

public struct MARGIN_REGISTRY has drop {}

// === Structs ===
public struct MarginRegistry has key {
    id: UID,
    inner: Versioned,
}

public struct MarginRegistryInner has store {
    registry_id: ID,
    allowed_versions: VecSet<u64>,
    pool_registry: Table<ID, PoolConfig>,
    margin_pools: Table<TypeName, ID>,
    allowed_maintainers: VecSet<ID>,
}

public struct PoolConfig has copy, drop, store {
    base_margin_pool_id: ID,
    quote_margin_pool_id: ID,
    risk_ratios: RiskRatios,
    user_liquidation_reward: u64, // fractional reward for liquidating a position, in 9 decimals
    pool_liquidation_reward: u64, // fractional reward for the pool, in 9 decimals
    enabled: bool, // whether the pool is enabled for margin trading
}

public struct RiskRatios has copy, drop, store {
    min_withdraw_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
    target_liquidation_risk_ratio: u64,
}

public struct ConfigKey<phantom Config> has copy, drop, store {}

// === Caps ===
public struct MarginAdminCap has key, store {
    id: UID,
}

public struct MaintainerCap has key, store {
    id: UID,
}

public struct MarginPoolCap has key, store {
    id: UID,
    margin_pool_id: ID,
}

// === Events ===
public struct MaintainerCapUpdated has copy, drop {
    maintainer_cap_id: ID,
    allowed: bool,
    timestamp: u64,
}

public struct DeepbookPoolRegistered has copy, drop {
    pool_id: ID,
    timestamp: u64,
}

public struct DeepbookPoolUpdated has copy, drop {
    pool_id: ID,
    enabled: bool,
    timestamp: u64,
}

fun init(_: MARGIN_REGISTRY, ctx: &mut TxContext) {
    let id = object::new(ctx);
    let margin_registry_inner = MarginRegistryInner {
        registry_id: id.to_inner(),
        allowed_versions: vec_set::singleton(margin_constants::margin_version()),
        pool_registry: table::new(ctx),
        margin_pools: table::new(ctx),
        allowed_maintainers: vec_set::empty(),
    };

    let registry = MarginRegistry {
        id,
        inner: versioned::create(margin_constants::margin_version(), margin_registry_inner, ctx),
    };
    let margin_admin_cap = MarginAdminCap { id: object::new(ctx) };
    transfer::share_object(registry);
    transfer::public_transfer(margin_admin_cap, ctx.sender());
}

// === Public Functions * ADMIN * ===
/// Mint a `MaintainerCap`, only admin can mint a `MaintainerCap`.
public fun mint_maintainer_cap(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
): MaintainerCap {
    let self = self.load_inner_mut();
    let id = object::new(ctx);
    self.allowed_maintainers.insert(id.to_inner());

    event::emit(MaintainerCapUpdated {
        maintainer_cap_id: id.to_inner(),
        allowed: true,
        timestamp: clock.timestamp_ms(),
    });

    MaintainerCap {
        id,
    }
}

/// Revoke a `MaintainerCap`. Only the admin can revoke a `MaintainerCap`.
public fun revoke_maintainer_cap(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
    maintainer_cap_id: ID,
    clock: &Clock,
) {
    let self = self.load_inner_mut();
    assert!(self.allowed_maintainers.contains(&maintainer_cap_id), EMaintainerCapNotValid);
    self.allowed_maintainers.remove(&maintainer_cap_id);

    event::emit(MaintainerCapUpdated {
        maintainer_cap_id,
        allowed: false,
        timestamp: clock.timestamp_ms(),
    });
}

/// Updates risk params for a deepbook pool as the admin.
public fun update_risk_params<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    pool_config: PoolConfig,
    _cap: &MarginAdminCap,
) {
    let inner = self.load_inner_mut();
    let pool_id = pool.id();
    assert!(inner.pool_registry.contains(pool_id), EPoolNotRegistered);

    let prev_config = inner.pool_registry.remove(pool_id);
    assert!(
        pool_config.risk_ratios.liquidation_risk_ratio <= prev_config
            .risk_ratios
            .liquidation_risk_ratio,
        EInvalidRiskParam,
    );
    assert!(prev_config.enabled, EPoolNotEnabled);

    // Validate new risk parameters
    assert!(
        pool_config.risk_ratios.min_borrow_risk_ratio < pool_config
            .risk_ratios
            .min_withdraw_risk_ratio,
        EInvalidRiskParam,
    );
    assert!(
        pool_config.risk_ratios.liquidation_risk_ratio < pool_config
            .risk_ratios
            .min_borrow_risk_ratio,
        EInvalidRiskParam,
    );
    assert!(
        pool_config.risk_ratios.liquidation_risk_ratio < pool_config
            .risk_ratios
            .target_liquidation_risk_ratio,
        EInvalidRiskParam,
    );
    assert!(
        pool_config.risk_ratios.liquidation_risk_ratio >= constants::float_scaling(),
        EInvalidRiskParam,
    );

    inner.pool_registry.add(pool_id, pool_config);
}

/// Register a margin pool for margin trading with existing margin pools
public fun register_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
    pool: &Pool<BaseAsset, QuoteAsset>,
    pool_config: PoolConfig,
    clock: &Clock,
) {
    let inner = self.load_inner_mut();
    let pool_id = pool.id();
    assert!(!inner.pool_registry.contains(pool_id), EPoolAlreadyRegistered);

    inner.pool_registry.add(pool_id, pool_config);

    event::emit(DeepbookPoolRegistered {
        pool_id,
        timestamp: clock.timestamp_ms(),
    });
}

/// Enables a deepbook pool for margin trading.
public fun enable_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
) {
    let inner = self.load_inner_mut();
    let pool_id = pool.id();
    assert!(inner.pool_registry.contains(pool_id), EPoolNotRegistered);

    let config = inner.pool_registry.borrow_mut(pool_id);
    assert!(config.enabled == false, EPoolAlreadyEnabled);
    config.enabled = true;

    event::emit(DeepbookPoolUpdated {
        pool_id,
        enabled: true,
        timestamp: clock.timestamp_ms(),
    });
}

/// Disables a deepbook pool from margin trading. Only reduce only orders, cancels, and withdraw settled amounts are allowed.
public fun disable_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
) {
    let inner = self.load_inner_mut();
    let pool_id = pool.id();
    assert!(inner.pool_registry.contains(pool_id), EPoolNotRegistered);

    let config = inner.pool_registry.borrow_mut(pool_id);
    assert!(config.enabled == true, EPoolAlreadyDisabled);
    config.enabled = false;

    event::emit(DeepbookPoolUpdated {
        pool_id,
        enabled: false,
        timestamp: clock.timestamp_ms(),
    });
}

/// Add Pyth Config to the MarginRegistry.
public fun add_config<Config: store + drop>(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
    config: Config,
) {
    self.load_inner();
    self.id.add(ConfigKey<Config> {}, config);
}

/// Remove Pyth Config from the MarginRegistry.
public fun remove_config<Config: store + drop>(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
): Config {
    self.load_inner();
    self.id.remove(ConfigKey<Config> {})
}

/// Enables a package version
/// Only Admin can enable a package version
/// This function does not have version restrictions
public fun enable_version(self: &mut MarginRegistry, version: u64, _cap: &MarginAdminCap) {
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
    assert!(!self.allowed_versions.contains(&version), EVersionAlreadyEnabled);
    self.allowed_versions.insert(version);
}

/// Disables a package version
/// Only Admin can disable a package version
/// This function does not have version restrictions
public fun disable_version(self: &mut MarginRegistry, version: u64, _cap: &MarginAdminCap) {
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
    assert!(version != margin_constants::margin_version(), ECannotDisableCurrentVersion);
    assert!(self.allowed_versions.contains(&version), EVersionNotEnabled);
    self.allowed_versions.remove(&version);
}

// === Public Helper Functions ===
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
): PoolConfig {
    assert!(min_borrow_risk_ratio < min_withdraw_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < min_borrow_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < target_liquidation_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio >= constants::float_scaling(), EInvalidRiskParam);
    assert!(user_liquidation_reward <= constants::float_scaling(), EInvalidRiskParam);
    assert!(pool_liquidation_reward <= constants::float_scaling(), EInvalidRiskParam);
    assert!(
        user_liquidation_reward + pool_liquidation_reward <= constants::float_scaling(),
        EInvalidRiskParam,
    );
    assert!(
        target_liquidation_risk_ratio >
        constants::float_scaling() + user_liquidation_reward + pool_liquidation_reward,
        EInvalidRiskParam,
    );

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
        enabled: false,
    }
}

/// Create a PoolConfig with default risk parameters based on leverage
public fun new_pool_config_with_leverage<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    leverage: u64,
): PoolConfig {
    self.load_inner();
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
    )
}

// === Public-View Functions ===
/// Check if a deepbook pool is registered for margin trading
public fun pool_enabled<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
): bool {
    let inner = self.load_inner();
    let pool_id = pool.id();
    if (inner.pool_registry.contains(pool_id)) {
        let config = inner.pool_registry.borrow(pool_id);

        config.enabled
    } else {
        false
    }
}

/// Get the margin pool id for the given asset.
public fun get_margin_pool_id<Asset>(self: &MarginRegistry): ID {
    let inner = self.load_inner();
    let key = type_name::get<Asset>();
    assert!(inner.margin_pools.contains(key), EMarginPoolDoesNotExists);

    *inner.margin_pools.borrow<TypeName, ID>(key)
}

/// Get the margin pool IDs for a deepbook pool
public fun get_deepbook_pool_margin_pool_ids(
    self: &MarginRegistry,
    deepbook_pool_id: ID,
): (ID, ID) {
    self.load_inner();
    let config = self.get_pool_config(deepbook_pool_id);
    (config.base_margin_pool_id, config.quote_margin_pool_id)
}

// === Public-Package Functions ===
#[allow(lint(self_transfer))]
public(package) fun register_margin_pool(
    self: &mut MarginRegistry,
    key: TypeName,
    margin_pool_id: ID,
    maintainer_cap: &MaintainerCap,
    ctx: &mut TxContext,
) {
    let inner = self.load_inner_mut();
    assert!(
        inner.allowed_maintainers.contains(&maintainer_cap.id.to_inner()),
        EMaintainerCapNotValid,
    );
    assert!(!inner.margin_pools.contains(key), EMarginPoolAlreadyExists);
    inner.margin_pools.add(key, margin_pool_id);

    let margin_pool_cap = MarginPoolCap {
        id: object::new(ctx),
        margin_pool_id,
    };

    transfer::public_transfer(margin_pool_cap, ctx.sender());
}

public(package) fun load_inner_mut(self: &mut MarginRegistry): &mut MarginRegistryInner {
    let inner: &mut MarginRegistryInner = self.inner.load_value_mut();
    let package_version = margin_constants::margin_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);

    inner
}

public(package) fun load_inner(self: &MarginRegistry): &MarginRegistryInner {
    let inner: &MarginRegistryInner = self.inner.load_value();
    let package_version = margin_constants::margin_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);

    inner
}

/// Get the pool configuration for a deepbook pool
public(package) fun get_pool_config(self: &MarginRegistry, deepbook_pool_id: ID): &PoolConfig {
    let inner = self.load_inner();
    assert!(inner.pool_registry.contains(deepbook_pool_id), EPoolNotRegistered);
    inner.pool_registry.borrow(deepbook_pool_id)
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

public(package) fun get_config<Config: store + drop>(self: &MarginRegistry): &Config {
    self.id.borrow(ConfigKey<Config> {})
}

public(package) fun margin_pool_id(margin_pool_cap: &MarginPoolCap): ID {
    margin_pool_cap.margin_pool_id
}

public(package) fun pool_cap_id(margin_pool_cap: &MarginPoolCap): ID {
    margin_pool_cap.id.to_inner()
}

public(package) fun maintainer_cap_id(maintainer_cap: &MaintainerCap): ID {
    maintainer_cap.id.to_inner()
}

/// Calculate risk parameters based on leverage factor
fun calculate_risk_ratios(leverage_factor: u64): RiskRatios {
    RiskRatios {
        min_withdraw_risk_ratio: constants::float_scaling() + 4 * leverage_factor, // 1 + 1 = 2x
        min_borrow_risk_ratio: constants::float_scaling() + leverage_factor, // 1 + 0.25 = 1.25x
        liquidation_risk_ratio: constants::float_scaling() +
        leverage_factor / 2, // 1 + 0.125 = 1.125x
        target_liquidation_risk_ratio: constants::float_scaling() +
        leverage_factor, // 1 + 0.25 = 1.25x
    }
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): MarginAdminCap {
    let id = object::new(ctx);
    let margin_registry_inner = MarginRegistryInner {
        registry_id: id.to_inner(),
        allowed_versions: vec_set::singleton(margin_constants::margin_version()),
        pool_registry: table::new(ctx),
        margin_pools: table::new(ctx),
        allowed_maintainers: vec_set::empty(),
    };

    let registry = MarginRegistry {
        id,
        inner: versioned::create(margin_constants::margin_version(), margin_registry_inner, ctx),
    };
    let margin_admin_cap = MarginAdminCap { id: object::new(ctx) };

    transfer::share_object(registry);

    margin_admin_cap
}
