// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Position key module - defines the unique identifier for a position.
///
/// A PositionKey uniquely identifies a binary option position:
/// - oracle_id: which oracle (underlying + expiry)
/// - expiry: expiration timestamp (redundant with oracle, but explicit)
/// - strike: the strike price
/// - direction: UP (0) or DOWN (1)
module deepbook_predict::position_key;

// === Constants ===
const DIRECTION_UP: u8 = 0;
const DIRECTION_DOWN: u8 = 1;

// === Structs ===

/// Key for a position: (oracle_id, expiry, strike, direction)
/// Used to identify positions in PredictManager and Vault.
public struct PositionKey(ID, u64, u64, u8) has copy, drop, store;

// === Public Functions ===

/// Create a new PositionKey for an UP position.
public fun up(oracle_id: ID, expiry: u64, strike: u64): PositionKey {
    PositionKey(oracle_id, expiry, strike, DIRECTION_UP)
}

/// Create a new PositionKey for a DOWN position.
public fun down(oracle_id: ID, expiry: u64, strike: u64): PositionKey {
    PositionKey(oracle_id, expiry, strike, DIRECTION_DOWN)
}

/// Create a PositionKey from components.
public fun new(oracle_id: ID, expiry: u64, strike: u64, is_up: bool): PositionKey {
    let direction = if (is_up) { DIRECTION_UP } else { DIRECTION_DOWN };
    PositionKey(oracle_id, expiry, strike, direction)
}

/// Get the oracle_id from a PositionKey.
public fun oracle_id(key: &PositionKey): ID {
    key.0
}

/// Get the expiry from a PositionKey.
public fun expiry(key: &PositionKey): u64 {
    key.1
}

/// Get the strike from a PositionKey.
public fun strike(key: &PositionKey): u64 {
    key.2
}

/// Get the direction from a PositionKey.
public fun direction(key: &PositionKey): u8 {
    key.3
}

/// Check if a PositionKey is for an UP position.
public fun is_up(key: &PositionKey): bool {
    key.3 == DIRECTION_UP
}

/// Check if a PositionKey is for a DOWN position.
public fun is_down(key: &PositionKey): bool {
    key.3 == DIRECTION_DOWN
}

/// Get the opposite direction key (same oracle + expiry + strike, flipped direction).
public fun opposite(key: &PositionKey): PositionKey {
    let new_direction = if (key.3 == DIRECTION_UP) { DIRECTION_DOWN } else { DIRECTION_UP };
    PositionKey(key.0, key.1, key.2, new_direction)
}
