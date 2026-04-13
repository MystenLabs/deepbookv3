// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Combo key module - identifies a vertical combo position by oracle, expiry,
/// and the two strikes that define the band.
///
/// The canonical instrument is the band `(oracle, expiry, lower, higher)`.
/// Bull-call and bear-put combos with the same strikes are vault-identical and
/// share the same ComboKey row.
module deepbook_predict::combo_key;

// === Errors ===
const EInvalidStrikes: u64 = 0;

// === Structs ===

/// Key for a vertical combo position used in PredictManager and Vault.
public struct ComboKey has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    lower_strike: u64,
    higher_strike: u64,
}

// === Public Functions ===

/// Create a new ComboKey. Aborts if `lower_strike >= higher_strike`.
public fun new(oracle_id: ID, expiry: u64, lower_strike: u64, higher_strike: u64): ComboKey {
    assert!(lower_strike < higher_strike, EInvalidStrikes);
    ComboKey { oracle_id, expiry, lower_strike, higher_strike }
}

/// Get the oracle_id from a ComboKey.
public fun oracle_id(key: &ComboKey): ID {
    key.oracle_id
}

/// Get the expiry from a ComboKey.
public fun expiry(key: &ComboKey): u64 {
    key.expiry
}

/// Get the lower strike from a ComboKey.
public fun lower_strike(key: &ComboKey): u64 {
    key.lower_strike
}

/// Get the higher strike from a ComboKey.
public fun higher_strike(key: &ComboKey): u64 {
    key.higher_strike
}
