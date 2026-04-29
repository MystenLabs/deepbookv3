// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Range key module - identifies a vertical range position by oracle, expiry,
/// and the two strikes that define the band.
///
/// The canonical instrument is the band `(oracle, expiry, lower, higher)`.
/// Bull-call and bear-put ranges with the same strikes are vault-identical and
/// share the same RangeKey row.
module deepbook_predict::range_key;

use deepbook_predict::constants;

const EInvalidStrikes: u64 = 0;

/// Key for a vertical range position used in PredictManager and Vault.
public struct RangeKey has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    lower_strike: u64,
    higher_strike: u64,
}

// === Public Functions ===

/// Create a new RangeKey. Aborts if `lower_strike >= higher_strike` or the
/// range spans both sentinel endpoints.
public fun new(oracle_id: ID, expiry: u64, lower_strike: u64, higher_strike: u64): RangeKey {
    assert!(lower_strike < higher_strike, EInvalidStrikes);
    assert!(
        !(lower_strike == constants::neg_inf!() && higher_strike == constants::pos_inf!()),
        EInvalidStrikes,
    );
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

/// Return `(min, max)` expanded to include this key's finite strike boundaries.
public(package) fun extend_strike_range(
    key: &RangeKey,
    min_strike: u64,
    max_strike: u64,
): (u64, u64) {
    let mut min_strike = min_strike;
    let mut max_strike = max_strike;
    if (key.lower_strike != constants::neg_inf!()) {
        (min_strike, max_strike) =
            include_strike_bound(
                min_strike,
                max_strike,
                key.lower_strike,
            );
    };
    if (key.higher_strike != constants::pos_inf!()) {
        (min_strike, max_strike) =
            include_strike_bound(
                min_strike,
                max_strike,
                key.higher_strike,
            );
    };

    (min_strike, max_strike)
}

/// Return this key's settled payout at a concrete settlement price.
public(package) fun settled_payout(key: &RangeKey, settlement: u64, quantity: u64): u64 {
    settled_range_payout(settlement, key.lower_strike, key.higher_strike, quantity)
}

/// Return settled payout for `(lower, higher]` with sentinel endpoints.
fun settled_range_payout(settlement: u64, lower: u64, higher: u64, quantity: u64): u64 {
    let above_lower = lower == constants::neg_inf!() || settlement > lower;
    let at_or_below_higher = higher == constants::pos_inf!() || settlement <= higher;
    if (above_lower && at_or_below_higher) {
        quantity
    } else {
        0
    }
}

fun include_strike_bound(min_strike: u64, max_strike: u64, strike: u64): (u64, u64) {
    if (min_strike == 0 && max_strike == 0) {
        (strike, strike)
    } else {
        (min_strike.min(strike), max_strike.max(strike))
    }
}
