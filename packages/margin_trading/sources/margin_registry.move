// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all margin pools.
module margin_trading::margin_registry;

use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::dynamic_field as df;
use sui::table::{Self, Table};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::remove as UID.remove;

// === Errors ===
const EPairAlreadyAllowed: u64 = 1;
const EPairNotAllowed: u64 = 2;
const EMarginPoolAlreadyExists: u64 = 3;
const EMarginPoolDoesNotExists: u64 = 4;
const EInvalidRiskParam: u64 = 5;

public struct MARGIN_REGISTRY has drop {}

// === Structs ===
public struct MarginAdminCap has key, store {
    id: UID,
}

public struct RiskParams has drop, store {
    min_withdraw_risk_ratio: u64, // 9 decimals, minimum risk ratio to allow transfer
    min_borrow_risk_ratio: u64, // 9 decimals, minimum risk ratio to allow borrow
    liquidation_risk_ratio: u64, // 9 decimals, risk ratio below which liquidation is allowed
    target_liquidation_risk_ratio: u64, // 9 decimals, target risk ratio after liquidation
    liquidation_reward: u64, // fractional reward for liquidating a position, in 9 decimals
}

public struct MarginPair has copy, drop, store {
    base: TypeName,
    quote: TypeName,
}

public struct MarginRegistry has key, store {
    id: UID,
    margin_pools: Bag,
    risk_params: Table<
        MarginPair,
        RiskParams,
    >, // determines when transfer, borrow, and trade are allowed
}

public struct ConfigKey<phantom Config> has copy, drop, store {}

fun init(_: MARGIN_REGISTRY, ctx: &mut TxContext) {
    let registry = MarginRegistry {
        id: object::new(ctx),
        margin_pools: bag::new(ctx),
        risk_params: table::new(ctx), // Default risk params
    };
    transfer::share_object(registry);
    let margin_admin_cap = MarginAdminCap { id: object::new(ctx) };
    transfer::public_transfer(margin_admin_cap, ctx.sender())
}

// === Public Functions * ADMIN * ===
public fun new_risk_params(
    min_withdraw_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
    target_liquidation_risk_ratio: u64,
    liquidation_reward: u64,
): RiskParams {
    assert!(min_borrow_risk_ratio < min_withdraw_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < min_borrow_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio < target_liquidation_risk_ratio, EInvalidRiskParam);
    assert!(liquidation_risk_ratio >= 1_000_000_000, EInvalidRiskParam);
    assert!(liquidation_reward <= 1_000_000_000, EInvalidRiskParam);

    RiskParams {
        min_withdraw_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
        target_liquidation_risk_ratio,
        liquidation_reward,
    }
}

/// Updates risk params for the margin pool as the admin.
/// TODO: maybe liquidation risk ratio can only decrease?
public fun update_risk_params<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    risk_params: RiskParams,
    _cap: &MarginAdminCap,
) {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };
    assert!(self.risk_params.contains(pair), EPairNotAllowed);
    self.risk_params.remove(pair);
    self.risk_params.add(pair, risk_params);
}

/// Allow a margin trading pair
public fun add_margin_pair<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    risk_params: RiskParams,
    _cap: &MarginAdminCap,
) {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };
    assert!(!self.risk_params.contains(pair), EPairAlreadyAllowed);
    self.risk_params.add(pair, risk_params);
}

/// Disallow a margin trading pair
public fun remove_margin_pair<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _cap: &MarginAdminCap,
) {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };
    assert!(self.risk_params.contains(pair), EPairNotAllowed);
    self.risk_params.remove(pair);
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
/// Check if a margin trading pair is allowed
public fun margin_pair_allowed<BaseAsset, QuoteAsset>(self: &MarginRegistry): bool {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };

    self.risk_params.contains(pair)
}

/// Get the ID of the pool given the asset types.
public fun get_margin_pool_id_by_asset<Asset>(registry: &MarginRegistry): ID {
    registry.get_margin_pool_id<Asset>()
}

// === Public-Package Functions ===
/// Register a new margin pool. If a same asset pool already exists, abort.
public(package) fun register_margin_pool<Asset>(self: &mut MarginRegistry, pool_id: ID) {
    let key = type_name::get<Asset>();
    assert!(!self.margin_pools.contains(key), EMarginPoolAlreadyExists);
    self.margin_pools.add(key, pool_id);
}

/// Get the margin pool id for the given asset.
public(package) fun get_margin_pool_id<Asset>(self: &MarginRegistry): ID {
    let key = type_name::get<Asset>();
    assert!(self.margin_pools.contains(key), EMarginPoolDoesNotExists);

    *self.margin_pools.borrow<TypeName, ID>(key)
}

public(package) fun can_withdraw<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    risk_ratio: u64,
): bool {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };

    risk_ratio >= self.risk_params.borrow(pair).min_withdraw_risk_ratio
}

public(package) fun can_borrow<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    risk_ratio: u64,
): bool {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };

    risk_ratio >= self.risk_params.borrow(pair).min_borrow_risk_ratio
}

public(package) fun can_liquidate<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
    risk_ratio: u64,
): bool {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };

    risk_ratio < self.risk_params.borrow(pair).liquidation_risk_ratio
}

public(package) fun target_liquidation_risk_ratio<BaseAsset, QuoteAsset>(
    self: &MarginRegistry,
): u64 {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };

    self.risk_params.borrow(pair).target_liquidation_risk_ratio
}

public(package) fun liquidation_reward<BaseAsset, QuoteAsset>(self: &MarginRegistry): u64 {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };

    self.risk_params.borrow(pair).liquidation_reward
}

public(package) fun get_config<Config: store + drop>(self: &MarginRegistry): &Config {
    self.id.borrow(ConfigKey<Config> {})
}
