// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike exposure store for one oracle.
///
/// This module is the package boundary for expiry exposure accounting. It keeps
/// a dense NAV matrix and sparse payout tree in sync while leaving each index's
/// storage and query logic in its owning module.
module deepbook_predict::strike_exposure;

use deepbook::constants::max_u64;
use deepbook_predict::{
    constants,
    pricing::CurvePoint,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};

/// Exposure book composed from a dense NAV matrix and sparse payout tree.
public struct StrikeExposure has store {
    nav: StrikeNavMatrix,
    payout: StrikePayoutTree,
    minted_min_strike: u64,
    minted_max_strike: u64,
}

/// Create a strike exposure book for the oracle grid.
public(package) fun new(
    ctx: &mut TxContext,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
): StrikeExposure {
    StrikeExposure {
        nav: strike_nav_matrix::new(ctx, tick_size, min_strike, max_strike),
        payout: strike_payout_tree::new(ctx, tick_size, min_strike, max_strike),
        minted_min_strike: max_u64(),
        minted_max_strike: 0,
    }
}

/// Insert interval quantity for `(lower, higher]`.
public(package) fun insert_range(
    exposure: &mut StrikeExposure,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
) {
    exposure.payout.insert_range(lower, higher, qty, fee_basis);
    exposure.nav.insert_range(lower, higher, qty);
    exposure.track_minted_boundaries(lower, higher);
}

/// Remove interval quantity for `(lower, higher]`.
public(package) fun remove_range(
    exposure: &mut StrikeExposure,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
) {
    exposure.payout.remove_range(lower, higher, qty, fee_basis);
    exposure.nav.remove_range(lower, higher, qty);
}

/// Return the exact worst-case settled payout across all settlement prices.
public(package) fun max_payout(exposure: &StrikeExposure): u64 {
    exposure.payout.max_payout()
}

/// Evaluate live option value and conservative maximum losing fee basis.
public(package) fun live_values(exposure: &StrikeExposure, curve: &vector<CurvePoint>): (u64, u64) {
    let (minted_min_strike, minted_max_strike) = exposure.minted_strike_range();
    let option_value = if (minted_min_strike == 0 && minted_max_strike == 0) {
        0
    } else {
        exposure.nav.live_value(curve, minted_min_strike, minted_max_strike)
    };
    (option_value, exposure.payout.conservative_losing_fee_basis())
}

/// Evaluate settled liability and exact losing fee basis.
public(package) fun settled_values(exposure: &StrikeExposure, settlement: u64): (u64, u64) {
    exposure.payout.settled_values(settlement)
}

/// Return the strike grid this book was created with.
public(package) fun strike_grid(exposure: &StrikeExposure): (u64, u64, u64) {
    exposure.nav.strike_grid()
}

/// Return historical minted strike bounds, or `(0, 0)` for an untouched book.
public(package) fun minted_strike_range(exposure: &StrikeExposure): (u64, u64) {
    if (exposure.minted_min_strike > exposure.minted_max_strike) (0, 0) else (
        exposure.minted_min_strike,
        exposure.minted_max_strike,
    )
}

/// Consume the exposure book after settlement and return exact settled liability.
public(package) fun into_settled_liability(exposure: StrikeExposure, settlement: u64): u64 {
    let StrikeExposure {
        nav,
        payout,
        minted_min_strike: _,
        minted_max_strike: _,
    } = exposure;
    nav.destroy();
    payout.into_settled_liability(settlement)
}

fun track_minted_boundaries(exposure: &mut StrikeExposure, lower: u64, higher: u64) {
    if (lower != constants::neg_inf!()) {
        exposure.minted_min_strike = exposure.minted_min_strike.min(lower);
        exposure.minted_max_strike = exposure.minted_max_strike.max(lower);
    };

    if (higher != constants::pos_inf!()) {
        exposure.minted_min_strike = exposure.minted_min_strike.min(higher);
        exposure.minted_max_strike = exposure.minted_max_strike.max(higher);
    };
}
