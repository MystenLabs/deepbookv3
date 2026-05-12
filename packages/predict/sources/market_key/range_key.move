// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Range key module - identifies a vertical range position by oracle and the
/// two strikes that define the band.
///
/// The canonical instrument is the band `(oracle, lower, higher)`.
/// Bull-call and bear-put ranges with the same strikes are vault-identical and
/// share the same RangeKey row.
module deepbook_predict::range_key;

use deepbook_predict::constants;

const EInvalidStrikes: u64 = 0;

/// Key for a vertical range position used by managers and expiry markets.
public struct RangeKey has copy, drop, store {
    oracle_id: ID,
    lower_strike: u64,
    higher_strike: u64,
}

// === Public Functions ===

/// Create a new RangeKey. Aborts if `lower_strike >= higher_strike` or the
/// range spans both sentinel endpoints.
public fun new(oracle_id: ID, lower_strike: u64, higher_strike: u64): RangeKey {
    assert!(lower_strike < higher_strike, EInvalidStrikes);
    assert!(
        !(lower_strike == constants::neg_inf!() && higher_strike == constants::pos_inf!()),
        EInvalidStrikes,
    );
    RangeKey { oracle_id, lower_strike, higher_strike }
}

/// Get the oracle_id from a RangeKey.
public fun oracle_id(key: &RangeKey): ID {
    key.oracle_id
}

/// Get the lower strike from a RangeKey.
public fun lower_strike(key: &RangeKey): u64 {
    key.lower_strike
}

/// Get the higher strike from a RangeKey.
public fun higher_strike(key: &RangeKey): u64 {
    key.higher_strike
}

/// Return `(min, max)` expanded to include this key's finite strike boundaries.
public(package) fun extend_strike_range(
    key: &RangeKey,
    min_strike: u64,
    max_strike: u64,
): (u64, u64) {
    let mut min_strike = min_strike;
    let mut max_strike = max_strike;
    if (min_strike == 0 && max_strike == 0) {
        if (key.lower_strike == constants::neg_inf!()) {
            return (key.higher_strike, key.higher_strike)
        };
        if (key.higher_strike == constants::pos_inf!()) {
            return (key.lower_strike, key.lower_strike)
        };
        return (key.lower_strike, key.higher_strike)
    };

    if (key.lower_strike != constants::neg_inf!()) {
        min_strike = min_strike.min(key.lower_strike);
        max_strike = max_strike.max(key.lower_strike);
    };
    if (key.higher_strike != constants::pos_inf!()) {
        min_strike = min_strike.min(key.higher_strike);
        max_strike = max_strike.max(key.higher_strike);
    };

    (min_strike, max_strike)
}
