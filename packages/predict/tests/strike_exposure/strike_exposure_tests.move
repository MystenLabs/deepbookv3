// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::strike_exposure_tests;

use deepbook_predict::{
    admin,
    config_constants,
    constants::{Self, float_scaling as float},
    i64,
    market_oracle,
    order,
    pricing,
    protocol_config,
    pyth_source,
    strike_exposure
};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

// Realistic-shape grid: strikes are 1e9-scaled prices, tick is a multiple of
// oracle_tick_size_unit!() (10_000).
const EXPIRY_MS: u64 = 1_700_000_000_000;
const MIN_STRIKE: u64 = 100_000_000_000; // $100
const TICK_SIZE: u64 = 1_000_000_000; //   $1
const MAX_PREMIUM: u64 = 200_000_000; //   1.0 -> 1.2 over the floor window
const LIQUIDATION_LTV: u64 = 850_000_000;
const FAKE_EXPIRY_ID: address = @0xCAFE;
const NOW_MS: u64 = 1_699_999_900_000;
const ORACLE_SOURCE_TIMESTAMP_MS: u64 = 1_699_999_899_000;
const SPOT_1000: u64 = 1_000_000_000_000;
const FORWARD_1000: u64 = 1_000_000_000_000;
// SVI a=1, b=0 and strike=forward gives d2=-0.5 for an UP order.
// normal_cdf(-0.5) = 0.3085375387259869, rounded to 1e9 scale.
const UP_AT_FORWARD_PROBABILITY: u64 = 308_537_539;
// 308_537_539 * 3_240_000 / 1e9 = 999_661 principal atoms.
const BELOW_MIN_PRINCIPAL_QUANTITY: u64 = 3_240_000;
// 308_537_539 * 3_250_000 / 1e9 = 1_002_747 principal atoms.
const ABOVE_MIN_PRINCIPAL_QUANTITY: u64 = 3_250_000;

// close_and_quote_live_order and live_position_liability need broader manager
// and valuation fixtures. This file covers the constructor, mint admission,
// simple getters, and the settled-liability cache lifecycle.

// === Constructor (grid validation) ===

fun new_exposure(
    expiry_ms: u64,
    min_strike: u64,
    tick_size: u64,
    max_expiry_floor_premium: u64,
    ctx: &mut TxContext,
): strike_exposure::StrikeExposure {
    strike_exposure::new(
        FAKE_EXPIRY_ID.to_id(),
        expiry_ms,
        min_strike,
        tick_size,
        constants::default_expiry_preallocated_ticks!(),
        max_expiry_floor_premium,
        LIQUIDATION_LTV,
        config_constants::default_expiry_fee_window_ms!(),
        constants::float_scaling!(),
        ctx,
    )
}

fun setup_live_mint(
    ctx: &mut TxContext,
): (
    strike_exposure::StrikeExposure,
    protocol_config::ProtocolConfig,
    market_oracle::MarketOracle,
    market_oracle::MarketOracleCap,
    admin::AdminCap,
    pyth_source::PythSource,
    clock::Clock,
) {
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let config = protocol_config::new_for_testing(ctx);
    let mut pyth = pyth_source::new_for_testing(ctx);
    let mut market = market_oracle::create_test_market_oracle_with_pyth(
        &pyth,
        EXPIRY_MS,
        &cap,
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);
    pyth.set_state_for_testing(SPOT_1000, ORACLE_SOURCE_TIMESTAMP_MS, ORACLE_SOURCE_TIMESTAMP_MS);
    market.update_block_scholes_prices(
        &config,
        &pyth,
        &cap,
        SPOT_1000,
        FORWARD_1000,
        ORACLE_SOURCE_TIMESTAMP_MS,
        &clock,
    );
    let svi = market_oracle::new_svi_params(
        constants::float_scaling!(),
        0,
        i64::zero(),
        i64::zero(),
        1,
    );
    market.update_svi(&config, &cap, svi, ORACLE_SOURCE_TIMESTAMP_MS, &clock);
    let exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);

    (exposure, config, market, cap, admin_cap, pyth, clock)
}

fun cleanup_live_mint(
    exposure: strike_exposure::StrikeExposure,
    config: protocol_config::ProtocolConfig,
    market: market_oracle::MarketOracle,
    cap: market_oracle::MarketOracleCap,
    admin_cap: admin::AdminCap,
    pyth: pyth_source::PythSource,
    clock: clock::Clock,
) {
    destroy(exposure);
    destroy(config);
    destroy(market);
    destroy(cap);
    destroy(admin_cap);
    destroy(pyth);
    clock.destroy_for_testing();
}

#[test]
fun new_returns_book_with_constructor_values() {
    let ctx = &mut tx_context::dummy();
    let exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);

    assert_eq!(exposure.max_expiry_floor_premium(), MAX_PREMIUM);
    // Empty exposure book has zero outstanding payout liability.
    assert_eq!(exposure.payout_liability(), 0);
    destroy(exposure);
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidTickSize)]
fun new_zero_tick_size_aborts() {
    let ctx = &mut tx_context::dummy();
    destroy(new_exposure(EXPIRY_MS, MIN_STRIKE, 0, MAX_PREMIUM, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidTickSize)]
fun new_tick_size_not_multiple_of_unit_aborts() {
    // tick_size must be a multiple of oracle_tick_size_unit!() = 10_000.
    let ctx = &mut tx_context::dummy();
    destroy(new_exposure(EXPIRY_MS, MIN_STRIKE, 999_999, MAX_PREMIUM, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidStrikeGrid)]
fun new_zero_min_strike_aborts() {
    let ctx = &mut tx_context::dummy();
    destroy(new_exposure(EXPIRY_MS, 0, TICK_SIZE, MAX_PREMIUM, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidStrikeGrid)]
fun new_min_strike_not_multiple_of_tick_aborts() {
    let ctx = &mut tx_context::dummy();
    // tick=1e9, min_strike=1e9+1 -> not a multiple.
    destroy(new_exposure(EXPIRY_MS, TICK_SIZE + 1, TICK_SIZE, MAX_PREMIUM, ctx));
    abort 999
}

// === Settled-liability cache lifecycle ===

#[test]
fun materialize_on_empty_exposure_returns_zero() {
    let ctx = &mut tx_context::dummy();
    let mut exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
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
    let mut exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
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
    let mut exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
    // No materialize_settled_liability call beforehand.
    exposure.decrease_materialized_settled_liability(0);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure::ESettledLiabilityUnderflow)]
fun decrease_more_than_materialized_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
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
    let mut exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
    exposure.destroy_live_indexes();
    abort 999
}

#[test]
fun destroy_live_indexes_after_materialize_succeeds() {
    let ctx = &mut tx_context::dummy();
    let mut exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, MAX_PREMIUM, ctx);
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
    let exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, 0, ctx);
    assert_eq!(exposure.max_expiry_floor_premium(), 0);
    destroy(exposure);
}

#[test]
fun max_expiry_floor_premium_round_trips_at_float_scaling() {
    // Boundary: 1.0 in FLOAT_SCALING — extreme but constructor does not bound.
    let ctx = &mut tx_context::dummy();
    let exposure = new_exposure(EXPIRY_MS, MIN_STRIKE, TICK_SIZE, float!(), ctx);
    assert_eq!(exposure.max_expiry_floor_premium(), float!());
    destroy(exposure);
}

// === Mint admission ===

#[test, expected_failure(abort_code = strike_exposure::EOrderPrincipalBelowMinimum)]
fun allocate_mint_order_below_min_principal_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut exposure, config, market, _cap, _admin_cap, pyth, clock) = setup_live_mint(ctx);
    let live_context = pricing::live_context(config.pricing_config(), &market, &pyth, &clock);

    exposure.allocate_mint_order(
        config.pricing_config(),
        &live_context,
        FORWARD_1000,
        constants::pos_inf!(),
        BELOW_MIN_PRINCIPAL_QUANTITY,
        order::leverage_one_x(),
    );
    abort 999
}

#[test]
fun allocate_mint_order_above_min_principal_succeeds() {
    let ctx = &mut tx_context::dummy();
    let (mut exposure, config, market, cap, admin_cap, pyth, clock) = setup_live_mint(ctx);
    let live_context = pricing::live_context(config.pricing_config(), &market, &pyth, &clock);

    let (minted_order, _fee_amount) = exposure.allocate_mint_order(
        config.pricing_config(),
        &live_context,
        FORWARD_1000,
        constants::pos_inf!(),
        ABOVE_MIN_PRINCIPAL_QUANTITY,
        order::leverage_one_x(),
    );

    assert_eq!(minted_order.entry_probability(), UP_AT_FORWARD_PROBABILITY);
    assert_eq!(minted_order.quantity(), ABOVE_MIN_PRINCIPAL_QUANTITY);
    assert_eq!(exposure.payout_liability(), ABOVE_MIN_PRINCIPAL_QUANTITY);

    cleanup_live_mint(exposure, config, market, cap, admin_cap, pyth, clock);
}
