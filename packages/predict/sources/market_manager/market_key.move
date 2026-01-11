// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market key module - defines the unique identifier for a market position.
///
/// A MarketKey uniquely identifies a binary option position:
/// - oracle_id: which oracle (underlying + expiry)
/// - expiry: expiration timestamp (redundant with oracle, but explicit)
/// - strike: the strike price
/// - direction: UP (0) or DOWN (1)
module deepbook_predict::market_key;

// === Constants ===
const DIRECTION_UP: u8 = 0;
const DIRECTION_DOWN: u8 = 1;

// === Structs ===

/// Key for a market position: (oracle_id, expiry, strike, direction)
/// Used to identify positions in PredictManager and Vault.
public struct MarketKey(ID, u64, u64, u8) has copy, drop, store;

// === Public Functions ===

/// Create a new MarketKey for an UP position.
public fun up(oracle_id: ID, expiry: u64, strike: u64): MarketKey {
    MarketKey(oracle_id, expiry, strike, DIRECTION_UP)
}

/// Create a new MarketKey for a DOWN position.
public fun down(oracle_id: ID, expiry: u64, strike: u64): MarketKey {
    MarketKey(oracle_id, expiry, strike, DIRECTION_DOWN)
}

/// Create a MarketKey from components.
public fun new(oracle_id: ID, expiry: u64, strike: u64, is_up: bool): MarketKey {
    let direction = if (is_up) {
        DIRECTION_UP
    } else {
        DIRECTION_DOWN
    };
    MarketKey(oracle_id, expiry, strike, direction)
}

/// Get the oracle_id from a MarketKey.
public fun oracle_id(key: &MarketKey): ID {
    key.0
}

/// Get the expiry from a MarketKey.
public fun expiry(key: &MarketKey): u64 {
    key.1
}

/// Get the strike from a MarketKey.
public fun strike(key: &MarketKey): u64 {
    key.2
}

/// Get the direction from a MarketKey.
public fun direction(key: &MarketKey): u8 {
    key.3
}

/// Check if a MarketKey is for an UP position.
public fun is_up(key: &MarketKey): bool {
    key.3 == DIRECTION_UP
}

/// Check if a MarketKey is for a DOWN position.
public fun is_down(key: &MarketKey): bool {
    key.3 == DIRECTION_DOWN
}

/// Get the opposite direction key (same oracle + expiry + strike, flipped direction).
public fun opposite(key: &MarketKey): MarketKey {
    let new_direction = if (key.3 == DIRECTION_UP) {
        DIRECTION_DOWN
    } else {
        DIRECTION_UP
    };
    MarketKey(key.0, key.1, key.2, new_direction)
}

public fun up_down_pair(key: &MarketKey): (MarketKey, MarketKey) {
    let up_key = if (key.3 == DIRECTION_UP) {
        *key
    } else {
        MarketKey(key.0, key.1, key.2, DIRECTION_UP)
    };

    (up_key, up_key.opposite())
}
