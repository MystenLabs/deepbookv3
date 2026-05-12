// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP pool vault and capital allocator state.
///
/// PoolVault owns idle DUSDC and the PLP treasury cap. Expiry markets own
/// active trading capital and risk state. This module will coordinate PLP
/// supply/withdrawal and pool-to-expiry capital allocation.
module deepbook_predict::pool_vault;

use deepbook_predict::plp::PLP;
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, clock::Clock, coin::{Self, Coin, TreasuryCap}};

const EExpiryMarketAlreadyActive: u64 = 0;
const EExpiryMarketNotActive: u64 = 1;
const ENotImplemented: u64 = 2;

/// Pool-level capital and PLP accounting state.
public struct PoolVault has key {
    id: UID,
    idle_balance: Balance<DUSDC>,
    treasury_cap: TreasuryCap<PLP>,
    active_expiry_markets: vector<ID>,
}

// === Public Functions ===

/// Return the pool vault object ID.
public fun id(vault: &PoolVault): ID {
    object::id(vault)
}

/// Return idle DUSDC held by the pool.
public fun idle_balance(vault: &PoolVault): u64 {
    vault.idle_balance.value()
}

/// Return active expiry market IDs tracked by the pool.
public fun active_expiry_markets(vault: &PoolVault): &vector<ID> {
    &vault.active_expiry_markets
}

/// Return total PLP supply.
public fun total_supply(vault: &PoolVault): u64 {
    vault.treasury_cap.total_supply()
}

/// Return whether an expiry market is currently active in the pool.
public fun contains_expiry_market(vault: &PoolVault, expiry_market_id: ID): bool {
    let mut i = 0;
    while (i < vault.active_expiry_markets.length()) {
        if (vault.active_expiry_markets[i] == expiry_market_id) return true;
        i = i + 1;
    };
    false
}

/// Supply DUSDC into the pool vault and receive PLP shares.
public fun supply(
    vault: &mut PoolVault,
    payment: Coin<DUSDC>,
    _clock: &Clock,
    ctx: &mut TxContext,
): Coin<PLP> {
    assert!(false, ENotImplemented);
    vault.idle_balance.join(payment.into_balance());
    coin::mint(&mut vault.treasury_cap, 0, ctx)
}

/// Withdraw DUSDC from the pool vault by burning PLP shares.
public fun withdraw(
    vault: &mut PoolVault,
    lp_coin: Coin<PLP>,
    _clock: &Clock,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    assert!(false, ENotImplemented);
    vault.treasury_cap.burn(lp_coin);
    balance::zero<DUSDC>().into_coin(ctx)
}

// === Public-Package Functions ===

/// Create an empty pool vault from the PLP treasury cap.
public(package) fun new(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): PoolVault {
    PoolVault {
        id: object::new(ctx),
        idle_balance: balance::zero(),
        treasury_cap,
        active_expiry_markets: vector[],
    }
}

/// Create and share an empty pool vault from the PLP treasury cap.
public(package) fun create_and_share(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): ID {
    let vault = new(treasury_cap, ctx);
    let id = object::id(&vault);
    transfer::share_object(vault);
    id
}

/// Register an expiry market as active for pool accounting.
public(package) fun register_expiry_market(vault: &mut PoolVault, expiry_market_id: ID) {
    assert!(!vault.contains_expiry_market(expiry_market_id), EExpiryMarketAlreadyActive);
    vault.active_expiry_markets.push_back(expiry_market_id);
}

/// Remove an expiry market from active pool accounting.
public(package) fun unregister_expiry_market(vault: &mut PoolVault, expiry_market_id: ID) {
    let mut i = 0;
    let len = vault.active_expiry_markets.length();
    while (i < len && vault.active_expiry_markets[i] != expiry_market_id) {
        i = i + 1;
    };
    assert!(i < len, EExpiryMarketNotActive);
    vault.active_expiry_markets.swap_remove(i);
}
