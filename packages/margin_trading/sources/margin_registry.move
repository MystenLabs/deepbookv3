// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all margin pools.
module margin_trading::margin_registry;

use std::type_name::TypeName;
use sui::{bag::{Self, Bag}, dynamic_field as df, table::{Self, Table}};

use fun df::borrow as UID.borrow;

public struct MARGIN_REGISTRY has drop {}

// === Structs ===
public struct MarginAdminCap has key, store {
    id: UID,
}

#[allow(unused_field)]
public struct RiskParams has drop, store {
    min_withdraw_risk_ratio: u64, // 9 decimals, minimum risk ratio to allow transfer
    min_borrow_risk_ratio: u64, // 9 decimals, minimum risk ratio to allow borrow
    liquidation_risk_ratio: u64, // 9 decimals, risk ratio below which liquidation is allowed
    target_liquidation_risk_ratio: u64, // 9 decimals, target risk ratio after liquidation
    liquidation_reward_perc: u64, // reward for liquidating a position, in 9 decimals
}

#[allow(unused_field)]
public struct MarginPair has copy, drop, store {
    base: TypeName,
    quote: TypeName,
}

public struct MarginRegistry has key, store {
    id: UID,
    margin_pools: Bag,
    risk_params: Table<MarginPair, RiskParams>, // determines when transfer, borrow, and trade are allowed
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

public(package) fun get_config<Config: store + drop>(self: &MarginRegistry): &Config {
    self.id.borrow(ConfigKey<Config> {})
}
