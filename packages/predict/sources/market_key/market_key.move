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

use deepbook_predict::oracle::OracleSVI;

// === Errors ===
const EOracleMismatch: u64 = 1;
const EExpiryMismatch: u64 = 2;

// === Constants ===
const DIRECTION_UP: u8 = 0;
const DIRECTION_DOWN: u8 = 1;

// === Structs ===

/// Key for a market position used to identify positions in PredictManager and Vault.
public struct MarketKey has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    strike: u64,
    direction: u8,
}

// === Public Functions ===

/// Create a new MarketKey for an UP position.
public fun up(oracle_id: ID, expiry: u64, strike: u64): MarketKey {
    MarketKey { oracle_id, expiry, strike, direction: DIRECTION_UP }
}

/// Create a new MarketKey for a DOWN position.
public fun down(oracle_id: ID, expiry: u64, strike: u64): MarketKey {
    MarketKey { oracle_id, expiry, strike, direction: DIRECTION_DOWN }
}

/// Create a MarketKey from components.
public fun new(oracle_id: ID, expiry: u64, strike: u64, is_up: bool): MarketKey {
    let direction = if (is_up) { DIRECTION_UP } else { DIRECTION_DOWN };
    MarketKey { oracle_id, expiry, strike, direction }
}

/// Assert that this key's oracle_id and expiry match the given oracle.
public fun assert_matches_oracle(key: &MarketKey, oracle: &OracleSVI) {
    assert!(key.oracle_id == oracle.id(), EOracleMismatch);
    assert!(key.expiry == oracle.expiry(), EExpiryMismatch);
}

/// Get the oracle_id from a MarketKey.
public fun oracle_id(key: &MarketKey): ID {
    key.oracle_id
}

/// Get the expiry from a MarketKey.
public fun expiry(key: &MarketKey): u64 {
    key.expiry
}

/// Get the strike from a MarketKey.
public fun strike(key: &MarketKey): u64 {
    key.strike
}

/// Check if a MarketKey is for an UP position.
public fun is_up(key: &MarketKey): bool {
    key.direction == DIRECTION_UP
}

/// Check if a MarketKey is for a DOWN position.
public fun is_down(key: &MarketKey): bool {
    key.direction == DIRECTION_DOWN
}
