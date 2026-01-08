// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - holds LP funds and acts as counterparty to all trades.
///
/// Core structs:
/// - `Vault` shared object containing:
///   - USDC balance (LP deposits)
///   - Markets table (PositionCoin ID -> Market)
///   - Total shares outstanding
///   - Pause flags
///
/// - `VaultShare` owned object representing LP position:
///   - Number of shares owned
///   - Deposit timestamp (for 24h lockup enforcement)
///
/// Share value calculation:
///   share_value = vault_usdc_balance / total_shares
///   As vault profits from spreads, share_value increases automatically.
///
/// The Vault is created once during package initialization.
module deepbook_predict::vault;

use deepbook_predict::position::{Self, PositionCoin, Market};
use sui::{balance::Balance, coin::Coin, coin_registry::CoinRegistry, table::{Self, Table}};

// === Errors ===
const EMarketAlreadyExists: u64 = 0;
const EMarketNotFound: u64 = 1;
const ETradingPaused: u64 = 2;
const EWithdrawalsPaused: u64 = 3;
const EInsufficientBalance: u64 = 4;
const ELockupNotExpired: u64 = 5;

// === Structs ===

/// Shared object holding LP funds and markets.
public struct Vault<phantom Asset> has key {
    id: UID,
    /// USDC balance from LP deposits
    balance: Balance<Asset>,
    /// Markets table: PositionCoin ID -> Market
    markets: Table<ID, Market<Asset, PositionCoin<Asset>>>,
    /// Total LP shares outstanding
    total_shares: u64,
    /// Whether trading is paused
    trading_paused: bool,
    /// Whether withdrawals are paused
    withdrawals_paused: bool,
}

/// Owned object representing LP position
public struct VaultShare<phantom Asset> has key, store {
    id: UID,
    /// Number of shares owned
    shares: u64,
    /// Deposit timestamp for lockup enforcement
    deposit_timestamp: u64,
}

// === Public Functions ===

/// Get total balance in the vault
public fun balance<Asset>(vault: &Vault<Asset>): u64 {
    vault.balance.value()
}

/// Get total shares outstanding
public fun total_shares<Asset>(vault: &Vault<Asset>): u64 {
    vault.total_shares
}

/// Check if trading is paused
public fun trading_paused<Asset>(vault: &Vault<Asset>): bool {
    vault.trading_paused
}

/// Check if withdrawals are paused
public fun withdrawals_paused<Asset>(vault: &Vault<Asset>): bool {
    vault.withdrawals_paused
}

/// Get shares in a VaultShare
public fun shares<Asset>(share: &VaultShare<Asset>): u64 {
    share.shares
}

/// Get deposit timestamp of a VaultShare
public fun deposit_timestamp<Asset>(share: &VaultShare<Asset>): u64 {
    share.deposit_timestamp
}

/// Check if a market exists for a given PositionCoin
public fun has_market<Asset>(vault: &Vault<Asset>, position_coin_id: ID): bool {
    vault.markets.contains(position_coin_id)
}

// === Public-Package Functions ===

/// Create a new vault. Called during package initialization.
public(package) fun create_vault<Asset>(ctx: &mut TxContext): Vault<Asset> {
    Vault {
        id: object::new(ctx),
        balance: sui::balance::zero(),
        markets: table::new(ctx),
        total_shares: 0,
        trading_paused: false,
        withdrawals_paused: false,
    }
}

/// Add a new market to the vault.
/// Creates PositionCoin and Market, stores Market in vault, shares PositionCoin.
public(package) fun add_market<Asset>(
    vault: &mut Vault<Asset>,
    registry: &mut CoinRegistry,
    oracle_id: ID,
    strike: u64,
    direction: u8,
    ctx: &mut TxContext,
): ID {
    let (position_coin_id, market) = position::create_market<Asset>(
        registry,
        oracle_id,
        strike,
        direction,
        ctx,
    );

    assert!(!vault.markets.contains(position_coin_id), EMarketAlreadyExists);

    vault.markets.add(position_coin_id, market);

    position_coin_id
}

/// Mint position coins for a market.
public(package) fun mint_position<Asset>(
    vault: &mut Vault<Asset>,
    position_coin: &PositionCoin<Asset>,
    quantity: u64,
    ctx: &mut TxContext,
): Coin<PositionCoin<Asset>> {
    assert!(!vault.trading_paused, ETradingPaused);

    let position_coin_id = object::id(position_coin);
    assert!(vault.markets.contains(position_coin_id), EMarketNotFound);

    let market = vault.markets.borrow_mut(position_coin_id);
    position::mint(market, quantity, ctx)
}

/// Burn position coins for a market.
public(package) fun burn_position<Asset>(
    vault: &mut Vault<Asset>,
    position_coin: &PositionCoin<Asset>,
    coin: Coin<PositionCoin<Asset>>,
): u64 {
    let position_coin_id = object::id(position_coin);
    assert!(vault.markets.contains(position_coin_id), EMarketNotFound);

    let market = vault.markets.borrow_mut(position_coin_id);
    position::burn(market, coin)
}

/// Deposit USDC and receive vault shares.
public(package) fun deposit<Asset>(
    vault: &mut Vault<Asset>,
    coin: Coin<Asset>,
    timestamp: u64,
    ctx: &mut TxContext,
): VaultShare<Asset> {
    let amount = coin.value();

    // Calculate shares to mint
    let shares = if (vault.total_shares == 0) {
        amount
    } else {
        (amount * vault.total_shares) / vault.balance.value()
    };

    vault.balance.join(coin.into_balance());
    vault.total_shares = vault.total_shares + shares;

    VaultShare {
        id: object::new(ctx),
        shares,
        deposit_timestamp: timestamp,
    }
}

/// Withdraw USDC by burning vault shares.
public(package) fun withdraw<Asset>(
    vault: &mut Vault<Asset>,
    share: VaultShare<Asset>,
    current_timestamp: u64,
    lockup_duration: u64,
    ctx: &mut TxContext,
): Coin<Asset> {
    assert!(!vault.withdrawals_paused, EWithdrawalsPaused);

    let VaultShare { id, shares, deposit_timestamp } = share;
    id.delete();

    // Check lockup period
    assert!(current_timestamp >= deposit_timestamp + lockup_duration, ELockupNotExpired);

    // Calculate USDC to return
    let amount = (shares * vault.balance.value()) / vault.total_shares;
    vault.total_shares = vault.total_shares - shares;

    vault.balance.split(amount).into_coin(ctx)
}

/// Pause trading
public(package) fun pause_trading<Asset>(vault: &mut Vault<Asset>) {
    vault.trading_paused = true;
}

/// Unpause trading
public(package) fun unpause_trading<Asset>(vault: &mut Vault<Asset>) {
    vault.trading_paused = false;
}

/// Pause withdrawals
public(package) fun pause_withdrawals<Asset>(vault: &mut Vault<Asset>) {
    vault.withdrawals_paused = true;
}

/// Unpause withdrawals
public(package) fun unpause_withdrawals<Asset>(vault: &mut Vault<Asset>) {
    vault.withdrawals_paused = false;
}

// === Private Functions ===
