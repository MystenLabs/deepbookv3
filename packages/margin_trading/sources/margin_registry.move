// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all lending pools.
module margin_trading::margin_registry;

use deepbook::constants;
use margin_trading::lending_pool;
use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::dynamic_field;
use sui::vec_set::{Self, VecSet};
use sui::versioned::{Self, Versioned};

// === Errors ===
const EPairAlreadyAllowed: u64 = 1;
const EPairNotAllowed: u64 = 2;
const ELendingPoolAlreadyExists: u64 = 3;
// const EVersionNotEnabled: u64 = 4;
// const EVersionAlreadyEnabled: u64 = 5;
// const ECannotDisableCurrentVersion: u64 = 6;
// const ECoinAlreadyWhitelisted: u64 = 7;
// const ECoinNotWhitelisted: u64 = 8;

public struct MARGIN_REGISTRY has drop {}

// === Structs ===
public struct LendingAdminCap has key, store {
    id: UID,
}

public struct MarginRegistry has key, store {
    id: UID,
    allowed_margin_pairs: VecSet<MarginPair>,
    lending_pools: Bag,
}

public struct MarginPair has copy, drop, store {
    base: TypeName,
    quote: TypeName,
}

fun init(_: MARGIN_REGISTRY, ctx: &mut TxContext) {
    let registry = MarginRegistry {
        id: object::new(ctx),
        allowed_margin_pairs: vec_set::empty(),
        lending_pools: bag::new(ctx),
    };
    transfer::share_object(registry);
    let lending_admin_cap = LendingAdminCap { id: object::new(ctx) };
    transfer::public_transfer(lending_admin_cap, ctx.sender())
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
