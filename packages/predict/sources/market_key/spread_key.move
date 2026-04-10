// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Spread key module - identifies a vertical spread position by oracle, expiry,
/// and the two strikes that define the band.
///
/// The canonical instrument is the band `(oracle, expiry, lower, higher)`.
/// Bull-call and bear-put spreads with the same strikes are vault-identical and
/// share the same SpreadKey row.
module deepbook_predict::spread_key;

// === Errors ===
const EInvalidStrikes: u64 = 0;

// === Structs ===

/// Key for a vertical spread position used in PredictManager and Vault.
public struct SpreadKey has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    lower_strike: u64,
    higher_strike: u64,
}

// === Public Functions ===

/// Create a new SpreadKey. Aborts if `lower_strike >= higher_strike`.
public fun new(oracle_id: ID, expiry: u64, lower_strike: u64, higher_strike: u64): SpreadKey {
    assert!(lower_strike < higher_strike, EInvalidStrikes);
    SpreadKey { oracle_id, expiry, lower_strike, higher_strike }
}

/// Get the oracle_id from a SpreadKey.
public fun oracle_id(key: &SpreadKey): ID {
    key.oracle_id
}

/// Get the expiry from a SpreadKey.
public fun expiry(key: &SpreadKey): u64 {
    key.expiry
}

/// Get the lower strike from a SpreadKey.
public fun lower_strike(key: &SpreadKey): u64 {
    key.lower_strike
}

/// Get the higher strike from a SpreadKey.
public fun higher_strike(key: &SpreadKey): u64 {
    key.higher_strike
}
