// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Position module - defines markets and position coins for binary options.
///
/// Each market has two types:
/// - `PositionCoin<Asset>` - unique marker type for the market (oracle + strike + direction)
/// - `Market<Asset>` - shared object holding the TreasuryCap for minting/burning
///
/// Users hold `Coin<PositionCoin<Asset>>` representing their positions:
/// - Coin balance = number of contracts
/// - Each contract pays $1 if the market settles in their favor
/// - Coins from different markets cannot be mixed (enforced by TreasuryCap)
///
/// Market lifecycle:
/// 1. Created via create_market() - initializes PositionCoin and Market with TreasuryCap
/// 2. Users mint position coins by paying the ask price
/// 3. Users redeem position coins for bid price (pre-expiry) or settlement value (post-expiry)
/// 4. Position coins are burned on redemption
module deepbook_predict::position;

use sui::{coin::{Coin, TreasuryCap}, coin_registry::{Self, CoinRegistry, MetadataCap}};

// === Errors ===
const EInvalidDirection: u64 = 0;

// === Constants ===
const DIRECTION_UP: u8 = 0;
const DIRECTION_DOWN: u8 = 1;

// === Structs ===

/// Unique marker type for a specific market's position coins.
/// Each market (oracle + strike + direction) gets its own PositionCoin type.
public struct PositionCoin<phantom Asset> has key {
    id: UID,
    /// Oracle ID this market is based on
    oracle_id: ID,
    /// Strike price for this market
    strike: u64,
    /// Direction: 0 = UP (wins if price > strike), 1 = DOWN (wins if price <= strike)
    direction: u8,
}

/// Shared object holding the TreasuryCap for a market.
/// Used to mint/burn position coins for this specific market.
public struct Market<phantom Asset, phantom PositionCoin> has store {
    /// TreasuryCap for minting/burning position coins
    treasury_cap: TreasuryCap<PositionCoin>,
    /// MetadataCap for the position coin (from coin_registry)
    metadata_cap: MetadataCap<PositionCoin>,
}

// === Public Functions ===

/// Get the oracle ID for this market.
public fun oracle_id<Asset>(position: &PositionCoin<Asset>): ID {
    position.oracle_id
}

/// Get the strike price for this market.
public fun strike<Asset>(position: &PositionCoin<Asset>): u64 {
    position.strike
}

/// Get the direction for this market.
public fun direction<Asset>(position: &PositionCoin<Asset>): u8 {
    position.direction
}

/// Check if this is an UP market (wins if price > strike).
public fun is_up<Asset>(position: &PositionCoin<Asset>): bool {
    position.direction == DIRECTION_UP
}

/// Check if this is a DOWN market (wins if price <= strike).
public fun is_down<Asset>(position: &PositionCoin<Asset>): bool {
    position.direction == DIRECTION_DOWN
}

// === Public-Package Functions ===

/// Create a new market. Called when admin activates a market.
/// Creates PositionCoin (shared) and returns Market with TreasuryCap.
/// Returns (position_coin_id, Market).
public(package) fun create_market<Asset>(
    registry: &mut CoinRegistry,
    oracle_id: ID,
    strike: u64,
    direction: u8,
    ctx: &mut TxContext,
): (ID, Market<Asset, PositionCoin<Asset>>) {
    assert!(direction == DIRECTION_UP || direction == DIRECTION_DOWN, EInvalidDirection);

    // Create the PositionCoin type object (shared, represents this market's coin type)
    let position_coin = PositionCoin<Asset> {
        id: object::new(ctx),
        oracle_id,
        strike,
        direction,
    };
    let position_coin_id = object::id(&position_coin);

    // Register the new currency with coin_registry
    let (initializer, treasury_cap) = coin_registry::new_currency<PositionCoin<Asset>>(
        registry,
        6, // decimals (same as USDC)
        b"POS".to_string(),
        b"Position".to_string(),
        b"Binary option position coin".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);

    // Share the PositionCoin (must be done in this module)
    transfer::share_object(position_coin);

    // Return the Market
    let market = Market<Asset, PositionCoin<Asset>> {
        treasury_cap,
        metadata_cap,
    };

    (position_coin_id, market)
}

/// Mint position coins for this market.
public(package) fun mint<Asset, PositionCoin>(
    market: &mut Market<Asset, PositionCoin>,
    quantity: u64,
    ctx: &mut TxContext,
): Coin<PositionCoin> {
    market.treasury_cap.mint(quantity, ctx)
}

/// Burn position coins for this market.
public(package) fun burn<Asset, PositionCoin>(
    market: &mut Market<Asset, PositionCoin>,
    coin: Coin<PositionCoin>,
): u64 {
    market.treasury_cap.burn(coin)
}

/// Get the total supply of position coins for this market.
public(package) fun total_supply<Asset, PositionCoin>(market: &Market<Asset, PositionCoin>): u64 {
    market.treasury_cap.total_supply()
}

// === Private Functions ===
