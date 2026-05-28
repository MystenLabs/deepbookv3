// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::strike_exposure_tests;

use deepbook_predict::{constants::float_scaling as float, strike_exposure};
use std::unit_test::{assert_eq, destroy};

// Realistic-shape grid: strikes are 1e9-scaled prices, tick is a multiple of
// oracle_tick_size_unit!() (10_000).
const EXPIRY_MS: u64 = 1_700_000_000_000;
const MIN_STRIKE: u64 = 100_000_000_000; // $100
const TICK_SIZE: u64 = 1_000_000_000; //   $1
const MAX_PREMIUM: u64 = 200_000_000; //   1.0 -> 1.2 over the floor window

// Pricing-dependent flows (allocate_mint_order, close_and_quote_live_order,
// close_settled_order, live_position_liability) need a full MarketOracle +
// PythSource fixture; those are covered in a later PR. This file covers the
// constructor, simple getters, and the settled-liability cache lifecycle.

// === Constructor (grid validation) ===

#[test]
fun new_returns_book_with_constructor_values() {
    let ctx = &mut tx_context::dummy();
    let exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);

    assert_eq!(exposure.max_expiry_floor_premium(), MAX_PREMIUM);
    // Empty exposure book has zero outstanding payout liability.
    assert_eq!(exposure.payout_liability(), 0);
    destroy(exposure);
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidTickSize)]
fun new_zero_tick_size_aborts() {
    let ctx = &mut tx_context::dummy();
    destroy(strike_exposure::new(EXPIRY_MS, MIN_STRIKE, 0, MAX_PREMIUM, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidTickSize)]
fun new_tick_size_not_multiple_of_unit_aborts() {
    // tick_size must be a multiple of oracle_tick_size_unit!() = 10_000.
    let ctx = &mut tx_context::dummy();
    destroy(strike_exposure::new(EXPIRY_MS, MIN_STRIKE, 999_999, MAX_PREMIUM, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidStrikeGrid)]
fun new_zero_min_strike_aborts() {
    let ctx = &mut tx_context::dummy();
    destroy(strike_exposure::new(EXPIRY_MS, 0, TICK_SIZE, MAX_PREMIUM, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidStrikeGrid)]
fun new_min_strike_not_multiple_of_tick_aborts() {
    let ctx = &mut tx_context::dummy();
    // tick=1e9, min_strike=1e9+1 -> not a multiple.
    destroy(strike_exposure::new(EXPIRY_MS, TICK_SIZE + 1, TICK_SIZE, MAX_PREMIUM, ctx));
    abort 999
}

// === Settled-liability cache lifecycle ===

#[test]
fun materialize_on_empty_exposure_returns_zero() {
    let ctx = &mut tx_context::dummy();
    let mut exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
    let liability = exposure.materialize_settled_liability(MIN_STRIKE + 5 * TICK_SIZE);
    assert_eq!(liability, 0);
    // payout_liability switches over to the cached settled value once
    // materialized.
    assert_eq!(exposure.payout_liability(), 0);
    destroy(exposure);
}

#[test]
fun materialize_is_idempotent() {
    // The second call must return the cached value without recomputing from
    // the live payout tree.
    let ctx = &mut tx_context::dummy();
    let mut exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
    let first = exposure.materialize_settled_liability(MIN_STRIKE + 5 * TICK_SIZE);
    let second = exposure.materialize_settled_liability(MIN_STRIKE + 10 * TICK_SIZE);
    assert_eq!(first, 0);
    // Idempotent: even a different settlement price returns the cached value.
    assert_eq!(second, 0);
    destroy(exposure);
}

#[test, expected_failure(abort_code = strike_exposure::ESettledLiabilityNotMaterialized)]
fun decrease_before_materialize_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
    // No materialize_settled_liability call beforehand.
    exposure.decrease_materialized_settled_liability(0);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::ESettledLiabilityUnderflow)]
fun decrease_more_than_materialized_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
    let _ = exposure.materialize_settled_liability(MIN_STRIKE + 5 * TICK_SIZE);
    // Empty exposure -> cached liability is 0; decreasing by any positive
    // amount underflows.
    exposure.decrease_materialized_settled_liability(1);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::ESettledLiabilityNotMaterialized)]
fun destroy_live_indexes_before_materialize_aborts() {
    // destroy_live_indexes is gated behind the materialize step so settled
    // liability is preserved before live indexes are released.
    let ctx = &mut tx_context::dummy();
    let mut exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
    exposure.destroy_live_indexes();
    abort 999
}

#[test]
fun destroy_live_indexes_after_materialize_succeeds() {
    let ctx = &mut tx_context::dummy();
    let mut exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
    let _ = exposure.materialize_settled_liability(MIN_STRIKE + 5 * TICK_SIZE);
    exposure.destroy_live_indexes();
    // Cached settled value still readable via payout_liability after live
    // indexes are gone.
    assert_eq!(exposure.payout_liability(), 0);
    destroy(exposure);
}

// === max_expiry_floor_premium getter ===

#[test]
fun max_expiry_floor_premium_round_trips_zero() {
    // Boundary: zero premium is allowed and means no floor growth.
    let ctx = &mut tx_context::dummy();
    let exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, 0, ctx);
    assert_eq!(exposure.max_expiry_floor_premium(), 0);
    destroy(exposure);
}

#[test]
fun max_expiry_floor_premium_round_trips_at_float_scaling() {
    // Boundary: 1.0 in FLOAT_SCALING — extreme but constructor does not bound.
    let ctx = &mut tx_context::dummy();
    let exposure = strike_exposure::new(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, float!(), ctx);
    assert_eq!(exposure.max_expiry_floor_premium(), float!());
    destroy(exposure);
}
