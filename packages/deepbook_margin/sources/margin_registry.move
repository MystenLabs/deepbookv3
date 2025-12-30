// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all margin pools.
module deepbook_margin::margin_registry;

use deepbook::{constants, math, pool::Pool};
use deepbook_margin::margin_constants;
use std::{string::String, type_name::{Self, TypeName}};
use sui::{
    clock::Clock,
    dynamic_field as df,
    event,
    table::{Self, Table},
    vec_map::{Self, VecMap},
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
const EVersionNotEnabled: u64 = 12;
const EMaxMarginManagersReached: u64 = 13;
const EPauseCapNotValid: u64 = 14;
const EMarginManagerNotRegistered: u64 = 15;

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
    margin_managers: Table<address, VecSet<ID>>,
    allowed_maintainers: VecSet<ID>,
    allowed_pause_caps: VecSet<ID>,
}

public struct PoolConfig has copy, drop, store {
    base_margin_pool_id: ID,
    quote_margin_pool_id: ID,
    risk_ratios: RiskRatios,
    user_liquidation_reward: u64, // fractional reward for liquidating a position, in 9 decimals
    pool_liquidation_reward: u64, // fractional reward for the pool, in 9 decimals
    enabled: bool, // whether the pool is enabled for margin trading
    extra_fields: VecMap<String, u64>,
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

public struct MarginPauseCap has key, store {
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

public struct PauseCapUpdated has copy, drop {
    pause_cap_id: ID,
    allowed: bool,
    timestamp: u64,
}

public struct DeepbookPoolRegistered has copy, drop {
    pool_id: ID,
    config: PoolConfig,
    timestamp: u64,
}

public struct DeepbookPoolUpdated has copy, drop {
    pool_id: ID,
    enabled: bool,
    timestamp: u64,
}

public struct DeepbookPoolConfigUpdated has copy, drop {
    pool_id: ID,
    config: PoolConfig,
    timestamp: u64,
}

fun init(_: MARGIN_REGISTRY, ctx: &mut TxContext) {
    let id = object::new(ctx);
    let margin_registry_inner = MarginRegistryInner {
        registry_id: id.to_inner(),
        allowed_versions: vec_set::singleton(margin_constants::margin_version()),
        pool_registry: table::new(ctx),
        margin_pools: table::new(ctx),
        margin_managers: table::new(ctx),
        allowed_maintainers: vec_set::empty(),
        allowed_pause_caps: vec_set::empty(),
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
/// This function does not have version restrictions
public fun mint_maintainer_cap(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
): MaintainerCap {
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
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
/// This function does not have version restrictions
public fun revoke_maintainer_cap(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
    maintainer_cap_id: ID,
    clock: &Clock,
) {
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
    assert!(self.allowed_maintainers.contains(&maintainer_cap_id), EMaintainerCapNotValid);
    self.allowed_maintainers.remove(&maintainer_cap_id);

    event::emit(MaintainerCapUpdated {
        maintainer_cap_id,
        allowed: false,
        timestamp: clock.timestamp_ms(),
    });
}

/// Register a margin pool for margin trading with existing margin pools
public fun register_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
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
        config: pool_config,
        timestamp: clock.timestamp_ms(),
    });
}

/// Enables a deepbook pool for margin trading.
public fun enable_deepbook_pool<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
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
    _admin_cap: &MarginAdminCap,
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

/// Updates risk params for a deepbook pool as the admin.
public fun update_risk_params<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
    pool: &Pool<BaseAsset, QuoteAsset>,
    pool_config: PoolConfig,
    clock: &Clock,
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

    event::emit(DeepbookPoolConfigUpdated {
        pool_id,
        config: pool_config,
        timestamp: clock.timestamp_ms(),
    });
}

/// Add Pyth Config to the MarginRegistry.
public fun add_config<Config: store + drop>(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
    config: Config,
) {
    self.load_inner();
    self.id.add(ConfigKey<Config> {}, config);
}

/// Remove Pyth Config from the MarginRegistry.
public fun remove_config<Config: store + drop>(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
): Config {
    self.load_inner();
    self.id.remove(ConfigKey<Config> {})
}

/// Enables a package version
/// Only Admin can enable a package version
/// This function does not have version restrictions
public fun enable_version(self: &mut MarginRegistry, version: u64, _admin_cap: &MarginAdminCap) {
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
    assert!(!self.allowed_versions.contains(&version), EVersionAlreadyEnabled);
    self.allowed_versions.insert(version);
}

/// Disables a package version
/// Only Admin can disable a package version
/// This function does not have version restrictions
public fun disable_version(self: &mut MarginRegistry, version: u64, _admin_cap: &MarginAdminCap) {
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
    assert!(self.allowed_versions.contains(&version), EVersionNotEnabled);
    self.allowed_versions.remove(&version);
}

/// Disables a package version
/// Pause Cap must be valid and can disable the version
/// This function does not have version restrictions
public fun disable_version_pause_cap(
    self: &mut MarginRegistry,
    version: u64,
    pause_cap: &MarginPauseCap,
) {
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
    assert!(self.allowed_pause_caps.contains(&pause_cap.id.to_inner()), EPauseCapNotValid);
    assert!(self.allowed_versions.contains(&version), EVersionNotEnabled);
    self.allowed_versions.remove(&version);
}

/// Mint a pause cap
/// Only Admin can mint a pause cap
/// This function does not have version restrictions
public fun mint_pause_cap(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
): MarginPauseCap {
    let id = object::new(ctx);
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
    self.allowed_pause_caps.insert(id.to_inner());

    event::emit(PauseCapUpdated {
        pause_cap_id: id.to_inner(),
        allowed: true,
        timestamp: clock.timestamp_ms(),
    });
    MarginPauseCap { id }
}

/// Revoke a pause cap
/// Only Admin can revoke a pause cap
/// This function does not have version restrictions
public fun revoke_pause_cap(
    self: &mut MarginRegistry,
    _admin_cap: &MarginAdminCap,
    clock: &Clock,
    pause_cap_id: ID,
) {
    let self: &mut MarginRegistryInner = self.inner.load_value_mut();
    assert!(self.allowed_pause_caps.contains(&pause_cap_id), EPauseCapNotValid);
    self.allowed_pause_caps.remove(&pause_cap_id);

    event::emit(PauseCapUpdated {
        pause_cap_id,
        allowed: false,
        timestamp: clock.timestamp_ms(),
    });
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
        extra_fields: vec_map::empty(),
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
    let key = type_name::with_defining_ids<Asset>();
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

/// Get the margin manager IDs for a given owner
public fun get_margin_manager_ids(self: &MarginRegistry, owner: address): VecSet<ID> {
    let inner = self.load_inner();
    if (inner.margin_managers.contains(owner)) {
        *inner.margin_managers.borrow<address, VecSet<ID>>(owner)
    } else {
        vec_set::empty()
    }
}

public fun can_liquidate(self: &MarginRegistry, deepbook_pool_id: ID, risk_ratio: u64): bool {
    let config = self.get_pool_config(deepbook_pool_id);
    risk_ratio < config.risk_ratios.liquidation_risk_ratio
}

public fun base_margin_pool_id(self: &MarginRegistry, deepbook_pool_id: ID): ID {
    let config = self.get_pool_config(deepbook_pool_id);
    config.base_margin_pool_id
}

public fun quote_margin_pool_id(self: &MarginRegistry, deepbook_pool_id: ID): ID {
    let config = self.get_pool_config(deepbook_pool_id);
    config.quote_margin_pool_id
}

public fun min_withdraw_risk_ratio(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.risk_ratios.min_withdraw_risk_ratio
}

public fun min_borrow_risk_ratio(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.risk_ratios.min_borrow_risk_ratio
}

public fun liquidation_risk_ratio(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.risk_ratios.liquidation_risk_ratio
}

public fun target_liquidation_risk_ratio(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.risk_ratios.target_liquidation_risk_ratio
}

public fun user_liquidation_reward(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.user_liquidation_reward
}

public fun pool_liquidation_reward(self: &MarginRegistry, deepbook_pool_id: ID): u64 {
    let config = self.get_pool_config(deepbook_pool_id);
    config.pool_liquidation_reward
}

public fun allowed_maintainers(self: &MarginRegistry): VecSet<ID> {
    let inner = self.load_inner();
    inner.allowed_maintainers
}

public fun allowed_pause_caps(self: &MarginRegistry): VecSet<ID> {
    let inner = self.load_inner();
    inner.allowed_pause_caps
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
    self.assert_maintainer_cap_valid(maintainer_cap);
    let inner = self.load_inner_mut();
    assert!(!inner.margin_pools.contains(key), EMarginPoolAlreadyExists);
    inner.margin_pools.add(key, margin_pool_id);

    let margin_pool_cap = MarginPoolCap {
        id: object::new(ctx),
        margin_pool_id,
    };

    transfer::public_transfer(margin_pool_cap, ctx.sender());
}

public(package) fun add_margin_manager(
    self: &mut MarginRegistry,
    margin_manager_id: ID,
    ctx: &TxContext,
) {
    let owner = ctx.sender();
    let inner = self.load_inner_mut();
    if (!inner.margin_managers.contains(owner)) {
        inner.margin_managers.add(owner, vec_set::empty());
    };
    let margin_manager_ids = inner.margin_managers.borrow_mut(owner);
    margin_manager_ids.insert(margin_manager_id);
    assert!(
        margin_manager_ids.length() <= margin_constants::max_margin_managers(),
        EMaxMarginManagersReached,
    );
}

public(package) fun remove_margin_manager(
    self: &mut MarginRegistry,
    margin_manager_id: ID,
    ctx: &TxContext,
) {
    let owner = ctx.sender();
    let inner = self.load_inner_mut();
    let margin_manager_ids = inner.margin_managers.borrow_mut(owner);
    assert!(margin_manager_ids.contains(&margin_manager_id), EMarginManagerNotRegistered);
    margin_manager_ids.remove(&margin_manager_id);
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
public fun get_pool_config(self: &MarginRegistry, deepbook_pool_id: ID): &PoolConfig {
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

public(package) fun assert_maintainer_cap_valid(
    self: &MarginRegistry,
    maintainer_cap: &MaintainerCap,
) {
    let inner = self.load_inner();
    assert!(
        inner.allowed_maintainers.contains(&maintainer_cap.id.to_inner()),
        EMaintainerCapNotValid,
    );
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
        margin_managers: table::new(ctx),
        allowed_maintainers: vec_set::empty(),
        allowed_pause_caps: vec_set::empty(),
    };

    let registry = MarginRegistry {
        id,
        inner: versioned::create(margin_constants::margin_version(), margin_registry_inner, ctx),
    };
    let margin_admin_cap = MarginAdminCap { id: object::new(ctx) };

    transfer::share_object(registry);

    margin_admin_cap
}
