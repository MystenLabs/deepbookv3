// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market manager module - manages markets and position coins for binary options.
///
/// Core structs:
/// - `PositionCoin<Asset>` - unique marker type for a market (oracle + strike + direction)
/// - `Market<Asset, PositionCoin>` - holds TreasuryCap for minting/burning position coins
/// - `Markets<Asset>` - table of all markets, stored in the main Predict object
///
/// Users hold `Coin<PositionCoin<Asset>>` representing their positions:
/// - Coin balance = number of contracts
/// - Each contract pays $1 if the market settles in their favor
/// - Coins from different markets cannot be mixed (enforced by TreasuryCap)
module deepbook_predict::market_manager;

use deepbook_predict::oracle::Oracle;
use sui::{
    coin::{Coin, TreasuryCap},
    coin_registry::{Self, CoinRegistry, MetadataCap},
    table::{Self, Table}
};

// === Errors ===
const EMarketAlreadyExists: u64 = 0;
const EOracleNotActive: u64 = 1;
const EStrikeNotFound: u64 = 2;

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

/// Holds the TreasuryCap for a market.
/// Used to mint/burn position coins for this specific market.
public struct Market<phantom Asset, phantom PositionCoin> has store {
    treasury_cap: TreasuryCap<PositionCoin>,
    metadata_cap: MetadataCap<PositionCoin>,
}

/// Table of all markets. Stored in the main Predict object.
public struct Markets<phantom Asset> has store {
    /// PositionCoin ID -> Market
    markets: Table<ID, Market<Asset, PositionCoin<Asset>>>,
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

/// Check if a market exists for a given PositionCoin ID.
public fun has_market<Asset>(markets: &Markets<Asset>, position_coin_id: ID): bool {
    markets.markets.contains(position_coin_id)
}

// === Public-Package Functions ===

/// Create a new Markets table.
public(package) fun new<Asset>(ctx: &mut TxContext): Markets<Asset> {
    Markets { markets: table::new(ctx) }
}

/// Add UP and DOWN markets for a given oracle and strike.
/// Validates that the oracle is active and the strike exists.
/// Returns (up_position_coin_id, down_position_coin_id).
public(package) fun add_market<Asset>(
    markets: &mut Markets<Asset>,
    registry: &mut CoinRegistry,
    oracle: &Oracle<Asset>,
    strike: u64,
    ctx: &mut TxContext,
): (ID, ID) {
    assert!(oracle.is_active(), EOracleNotActive);
    assert!(oracle.has_strike(strike), EStrikeNotFound);

    let (up_id, up_market, down_id, down_market) = create_market_pair<Asset>(
        registry,
        oracle.id(),
        strike,
        ctx,
    );

    assert!(!markets.markets.contains(up_id), EMarketAlreadyExists);
    assert!(!markets.markets.contains(down_id), EMarketAlreadyExists);

    markets.markets.add(up_id, up_market);
    markets.markets.add(down_id, down_market);

    (up_id, down_id)
}

/// Mint position coins for a market.
public(package) fun mint<Asset, PositionCoin>(
    market: &mut Market<Asset, PositionCoin>,
    quantity: u64,
    ctx: &mut TxContext,
): Coin<PositionCoin> {
    market.treasury_cap.mint(quantity, ctx)
}

/// Burn position coins for a market.
public(package) fun burn<Asset, PositionCoin>(
    market: &mut Market<Asset, PositionCoin>,
    coin: Coin<PositionCoin>,
): u64 {
    market.treasury_cap.burn(coin)
}

/// Get the total supply of position coins for a market.
public(package) fun total_supply<Asset, PositionCoin>(market: &Market<Asset, PositionCoin>): u64 {
    market.treasury_cap.total_supply()
}

// === Private Functions ===

/// Create both UP and DOWN markets for a given oracle and strike.
fun create_market_pair<Asset>(
    registry: &mut CoinRegistry,
    oracle_id: ID,
    strike: u64,
    ctx: &mut TxContext,
): (ID, Market<Asset, PositionCoin<Asset>>, ID, Market<Asset, PositionCoin<Asset>>) {
    let (up_id, up_market) = create_single_market<Asset>(
        registry,
        oracle_id,
        strike,
        DIRECTION_UP,
        ctx,
    );

    let (down_id, down_market) = create_single_market<Asset>(
        registry,
        oracle_id,
        strike,
        DIRECTION_DOWN,
        ctx,
    );

    (up_id, up_market, down_id, down_market)
}

/// Create a single market (UP or DOWN) for a given oracle and strike.
fun create_single_market<Asset>(
    registry: &mut CoinRegistry,
    oracle_id: ID,
    strike: u64,
    direction: u8,
    ctx: &mut TxContext,
): (ID, Market<Asset, PositionCoin<Asset>>) {
    let position_coin = PositionCoin<Asset> {
        id: object::new(ctx),
        oracle_id,
        strike,
        direction,
    };
    let position_coin_id = object::id(&position_coin);

    let (initializer, treasury_cap) = coin_registry::new_currency<PositionCoin<Asset>>(
        registry,
        6,
        b"POS".to_string(),
        b"Position".to_string(),
        b"Binary option position coin".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);

    // Share the PositionCoin (must be done in this module)
    transfer::share_object(position_coin);

    let market = Market<Asset, PositionCoin<Asset>> {
        treasury_cap,
        metadata_cap,
    };

    (position_coin_id, market)
}
