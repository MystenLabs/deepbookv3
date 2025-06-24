// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all lending pools.
module margin_trading::margin_registry;

use std::type_name::{Self, TypeName};
use sui::{bag::{Self, Bag}, dynamic_field as df, vec_set::{Self, VecSet}};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::remove as UID.remove;

// === Errors ===
const EPairAlreadyAllowed: u64 = 1;
const EPairNotAllowed: u64 = 2;
const ELendingPoolAlreadyExists: u64 = 3;
const ELendingPoolDoesNotExists: u64 = 4;

public struct MARGIN_REGISTRY has drop {}

// === Structs ===
public struct LendingAdminCap has key, store {
    id: UID,
}

public struct RiskParams has drop, store {
    min_transfer_risk_ratio: u64, // 9 decimals, minimum risk ratio to allow transfer
    min_borrow_risk_ratio: u64, // 9 decimals, minimum risk ratio to allow borrow
    liquidation_risk_ratio: u64, // 9 decimals, risk ratio below which liquidation is allowed
}

public struct MarginRegistry has key, store {
    id: UID,
    allowed_margin_pairs: VecSet<MarginPair>,
    lending_pools: Bag,
    risk_params: RiskParams, // determines when transfer, borrow, and trade are allowed
}

public struct MarginPair has copy, drop, store {
    base: TypeName,
    quote: TypeName,
}

public struct ConfigKey<phantom Config> has copy, drop, store {}

fun init(_: MARGIN_REGISTRY, ctx: &mut TxContext) {
    let registry = MarginRegistry {
        id: object::new(ctx),
        allowed_margin_pairs: vec_set::empty(),
        lending_pools: bag::new(ctx),
        risk_params: new_risk_params(
            2_000_000_000,
            1_250_000_000,
            1_100_000_000,
        ), // Default risk params
    };
    transfer::share_object(registry);
    let lending_admin_cap = LendingAdminCap { id: object::new(ctx) };
    transfer::public_transfer(lending_admin_cap, ctx.sender())
}

public fun new_risk_params(
    min_transfer_risk_ratio: u64,
    min_borrow_risk_ratio: u64,
    liquidation_risk_ratio: u64,
): RiskParams {
    RiskParams {
        min_transfer_risk_ratio,
        min_borrow_risk_ratio,
        liquidation_risk_ratio,
    }
}

/// Updates risk params for the lending pool as the admin.
/// TODO: maybe liquidation risk ratio shouldn't be updated?
public fun update_risk_params(
    registry: &mut MarginRegistry,
    risk_params: RiskParams,
    _cap: &LendingAdminCap,
) {
    registry.risk_params = risk_params;
}

public(package) fun can_transfer(self: &MarginRegistry, risk_ratio: u64): bool {
    risk_ratio >= self.risk_params.min_transfer_risk_ratio
}

public(package) fun can_borrow(self: &MarginRegistry, risk_ratio: u64): bool {
    risk_ratio >= self.risk_params.min_borrow_risk_ratio
}

public(package) fun can_liquidate(self: &MarginRegistry, risk_ratio: u64): bool {
    risk_ratio < self.risk_params.liquidation_risk_ratio
}

// Allow a margin trading pair
public fun add_margin_pair<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _cap: &LendingAdminCap,
) {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };
    assert!(!self.allowed_margin_pairs.contains(&pair), EPairAlreadyAllowed);
    self.allowed_margin_pairs.insert(pair);
}

// Disallow a margin trading pair
public fun remove_margin_pair<BaseAsset, QuoteAsset>(
    self: &mut MarginRegistry,
    _cap: &LendingAdminCap,
) {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };
    assert!(self.allowed_margin_pairs.contains(&pair), EPairNotAllowed);
    self.allowed_margin_pairs.remove(&pair);
}

public fun is_margin_pair_allowed<BaseAsset, QuoteAsset>(self: &MarginRegistry): bool {
    let pair = MarginPair {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };
    self.allowed_margin_pairs.contains(&pair)
}

// Register a new lending pool. If a same asset pool already exists, abort.
public(package) fun register_lending_pool<Asset>(self: &mut MarginRegistry, pool_id: ID) {
    let key = type_name::get<Asset>();
    assert!(!self.lending_pools.contains(key), ELendingPoolAlreadyExists);
    self.lending_pools.add(key, pool_id);
}

// Get the lending pool id for the given asset.
public(package) fun get_lending_pool_id<Asset>(self: &MarginRegistry): ID {
    let key = type_name::get<Asset>();
    assert!(self.lending_pools.contains(key), ELendingPoolDoesNotExists);

    *self.lending_pools.borrow<TypeName, ID>(key)
}

public fun add_config<Config: store + drop>(
    _cap: &LendingAdminCap,
    self: &mut MarginRegistry,
    config: Config,
) {
    self.id.add(ConfigKey<Config> {}, config);
}

public fun remove_config<Config: store + drop>(
    _cap: &LendingAdminCap,
    self: &mut MarginRegistry,
): Config {
    self.id.remove(ConfigKey<Config> {})
}

public(package) fun get_config<Config: store + drop>(self: &MarginRegistry): &Config {
    self.id.borrow(ConfigKey<Config> {})
}
