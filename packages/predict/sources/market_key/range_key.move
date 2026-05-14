// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Range keys identify vertical range positions by oracle and strike band.
///
/// The canonical instrument is the band `(oracle, lower, higher)`.
/// Bull-call and bear-put ranges with the same strikes are payout-identical and
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

/// Return the oracle ID encoded in this range key.
public fun oracle_id(key: &RangeKey): ID {
    key.oracle_id
}

/// Return the lower strike boundary.
public fun lower_strike(key: &RangeKey): u64 {
    key.lower_strike
}

/// Return the higher strike boundary.
public fun higher_strike(key: &RangeKey): u64 {
    key.higher_strike
}

// === Public-Package Functions ===

/// Create a new RangeKey. Aborts if `lower_strike >= higher_strike` or the
/// range spans both sentinel endpoints.
public(package) fun new(oracle_id: ID, lower_strike: u64, higher_strike: u64): RangeKey {
    assert!(lower_strike < higher_strike, EInvalidStrikes);
    assert!(
        !(lower_strike == constants::neg_inf!() && higher_strike == constants::pos_inf!()),
        EInvalidStrikes,
    );
    RangeKey { oracle_id, lower_strike, higher_strike }
}
