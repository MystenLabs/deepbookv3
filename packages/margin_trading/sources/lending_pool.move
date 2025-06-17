// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all lending pools.
module margin_trading::lending_pool;

use deepbook::constants;
use margin_trading::margin_registry::{Self, LendingAdminCap, MarginRegistry};
use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::dynamic_field;
use sui::vec_set::{Self, VecSet};
use sui::versioned::{Self, Versioned};

// === Errors ===
// const EPoolAlreadyExists: u64 = 1;
// const EPoolDoesNotExist: u64 = 2;
// const EPackageVersionNotEnabled: u64 = 3;
// const EVersionNotEnabled: u64 = 4;
// const EVersionAlreadyEnabled: u64 = 5;
// const ECannotDisableCurrentVersion: u64 = 6;
// const ECoinAlreadyWhitelisted: u64 = 7;
// const ECoinNotWhitelisted: u64 = 8;

// === Structs ===
public struct StableCoinKey has copy, drop, store {}

public struct LendingPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    base_rate: u64, // 9 decimals
    multiplier: u64, // 9 decimals
    utilization_rate: u64, // 9 decimals
}

public fun create_lending_pool<Asset>(
    registry: &mut MarginRegistry,
    base_rate: u64,
    multiplier: u64,
    _cap: &LendingAdminCap,
    ctx: &mut TxContext,
) {
    let lending_pool = LendingPool<Asset> {
        id: object::new(ctx),
        vault: balance::zero<Asset>(),
        base_rate,
        multiplier,
        utilization_rate: 0,
    };

    let lending_pool_id = object::id(&lending_pool);
    registry.register_lending_pool<Asset>(lending_pool_id);

    transfer::share_object(lending_pool);
}
