// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market key module - identifies a binary position (UP/DOWN) by oracle,
/// expiry, and strike price.
module deepbook_predict::market_key;

use deepbook_predict::range_key::{Self, RangeKey};
use deepbook_predict::{constants, oracle::{Self, OracleSVI}};

const EOracleMismatch: u64 = 0;

/// Key for a binary position (UP or DOWN) used in PredictManager and Vault.
public struct MarketKey has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    strike: u64,
    is_up: bool,
}

/// Key for a paired collateral position (1 UP + 1 DOWN) at a specific strike.
/// Neutralizes vault exposure; represented as a single lock record in manager.
public struct CollateralKey has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    strike: u64,
}

// === Public Functions ===

/// Create a new MarketKey.
public fun new(oracle_id: ID, expiry: u64, strike: u64, is_up: bool): MarketKey {
    MarketKey { oracle_id, expiry, strike, is_up }
}

/// Create a new CollateralKey.
public fun new_collateral(oracle_id: ID, expiry: u64, strike: u64): CollateralKey {
    CollateralKey { oracle_id, expiry, strike }
}

/// Create a CollateralKey from a MarketKey.
public fun to_collateral(key: &MarketKey): CollateralKey {
    CollateralKey {
        oracle_id: key.oracle_id,
        expiry: key.expiry,
        strike: key.strike,
    }
}

/// Convert a MarketKey to a canonical RangeKey.
/// UP instrument is (strike, pos_inf]; DOWN is (neg_inf, strike].
public fun to_range(key: &MarketKey): RangeKey {
    if (key.is_up) {
        range_key::new(key.oracle_id, key.expiry, key.strike, constants::pos_inf!())
    } else {
        range_key::new(key.oracle_id, key.expiry, constants::neg_inf!(), key.strike)
    }
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

/// Get the direction from a MarketKey.
public fun is_up(key: &MarketKey): bool {
    key.is_up
}

/// Get the oracle_id from a CollateralKey.
public fun c_oracle_id(key: &CollateralKey): ID {
    key.oracle_id
}

/// Get the expiry from a CollateralKey.
public fun c_expiry(key: &CollateralKey): u64 {
    key.expiry
}

/// Get the strike from a CollateralKey.
public fun c_strike(key: &CollateralKey): u64 {
    key.strike
}

/// Assert that the key's oracle and expiry match the provided oracle object.
public fun assert_matches_oracle(key: &MarketKey, oracle: &OracleSVI) {
    assert!(key.oracle_id == oracle::id(oracle), EOracleMismatch);
    assert!(key.expiry == oracle::expiry(oracle), EOracleMismatch);
}

/// Assert that the collateral key's oracle and expiry match the provided oracle object.
public fun assert_matches_oracle_collateral(key: &CollateralKey, oracle: &OracleSVI) {
    assert!(key.oracle_id == oracle::id(oracle), EOracleMismatch);
    assert!(key.expiry == oracle::expiry(oracle), EOracleMismatch);
}
