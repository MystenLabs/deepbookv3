// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Range key module - identifies a vertical range position by oracle, expiry,
/// and the two strikes that define the band.
///
/// The canonical instrument is the band `(oracle, expiry, lower, higher)`.
/// Bull-call and bear-put ranges with the same strikes are vault-identical and
/// share the same RangeKey row.
module deepbook_predict::range_key;

// === Errors ===
const EInvalidStrikes: u64 = 0;

// === Structs ===

/// Key for a vertical range position used in PredictManager and Vault.
public struct RangeKey has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    lower_strike: u64,
    higher_strike: u64,
}

// === Public Functions ===

/// Create a new RangeKey. Aborts if `lower_strike >= higher_strike`.
public fun new(oracle_id: ID, expiry: u64, lower_strike: u64, higher_strike: u64): RangeKey {
    assert!(lower_strike < higher_strike, EInvalidStrikes);
    RangeKey { oracle_id, expiry, lower_strike, higher_strike }
}

/// Get the oracle_id from a RangeKey.
public fun oracle_id(key: &RangeKey): ID {
    key.oracle_id
}

/// Get the expiry from a RangeKey.
public fun expiry(key: &RangeKey): u64 {
    key.expiry
}

/// Get the lower strike from a RangeKey.
public fun lower_strike(key: &RangeKey): u64 {
    key.lower_strike
}

/// Get the higher strike from a RangeKey.
public fun higher_strike(key: &RangeKey): u64 {
    key.higher_strike
}
