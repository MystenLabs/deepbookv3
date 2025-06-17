// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all lending pools.
module margin_trading::lending_pool;

use margin_trading::constants;
use margin_trading::margin_math;
use margin_trading::margin_registry::{Self, LendingAdminCap, MarginRegistry};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;

// === Constants ===
const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;

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
    interest_index: u64, // 9 decimals
    last_index_update_timestamp: u64,
    base_rate: u64, // 9 decimals
    multiplier: u64, // 9 decimals
    utilization_rate: u64, // 9 decimals
}

public fun create_lending_pool<Asset>(
    registry: &mut MarginRegistry,
    base_rate: u64,
    multiplier: u64,
    _cap: &LendingAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let lending_pool = LendingPool<Asset> {
        id: object::new(ctx),
        vault: balance::zero<Asset>(),
        interest_index: 1_000_000_000, // start at 1.0
        last_index_update_timestamp: clock.timestamp_ms(),
        base_rate,
        multiplier,
        utilization_rate: 0,
    };

    let lending_pool_id = object::id(&lending_pool);
    registry.register_lending_pool<Asset>(lending_pool_id);

    transfer::share_object(lending_pool);
}

// Only admin can fund lending pool for MVP
// Should we just lock the funds in here?
public fun fund_lending_pool<Asset>(
    pool: &mut LendingPool<Asset>,
    coin: Coin<Asset>,
    _cap: &LendingAdminCap,
) {
    let balance = coin.into_balance();
    pool.vault.join(balance);
}

// Only admin can withdraw from lending pool for MVP
public fun withdraw_from_lending_pool<Asset>(
    pool: &mut LendingPool<Asset>,
    amount: u64,
    _cap: &LendingAdminCap,
    ctx: &mut TxContext,
): Coin<Asset> {
    // TODO: perform checks to make sure withdrawal is possible without error
    pool.vault.split(amount).into_coin(ctx)
}

public(package) fun update_interest_index<Asset>(self: &mut LendingPool<Asset>, clock: &Clock) {
    let current_time = clock.timestamp_ms();
    let ms_elapsed = current_time - self.last_index_update_timestamp;
    let interest_rate = self.base_rate; // TODO: more complex interest rate model
    let new_index =
        self.interest_index * (constants::float_scaling() + margin_math::div(margin_math::mul(ms_elapsed, interest_rate),YEAR_MS));
    self.interest_index = new_index;
    self.last_index_update_timestamp = current_time;
}

/// Get the ID of the pool given the asset types.
public fun get_lending_pool_id_by_asset<Asset>(registry: &MarginRegistry): ID {
    registry.get_lending_pool_id<Asset>()
}
