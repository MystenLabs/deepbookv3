// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the mint-only Pyth freshness requirement. While
/// `use_pyth_spot_for_forward` is set, a pricer that fell back to the Block
/// Scholes forward because the Pyth spot was stale or unavailable is refused by
/// all three mint entrypoints and all three mint quotes, while `redeem_live` still
/// closes on that fallback. Pins the window boundary in both directions, both
/// unavailable states (no observation, a print that does not normalize), that the
/// guard reads the configured window rather than the compiled default in both
/// directions, that deselecting Pyth lifts it, and that a new Pyth push restores
/// minting.
#[test_only]
module deepbook_predict::mint_pyth_freshness_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle},
    pricing,
    test_constants
};
use std::unit_test::assert_eq;

/// Lot-aligned position size, matching the other flow suites.
const QUANTITY: u64 = 840_000_000;
/// Compiled default Pyth window, asserted as a literal
/// (`mint_exactly_at_the_window_succeeds`) so a retune has to edit this file
/// consciously.
const PYTH_WINDOW_MS: u64 = 2_000;
/// A window the admin could tighten to, below the default.
const TIGHT_PYTH_WINDOW_MS: u64 = 1_000;
/// A window the admin could widen to, above the default.
const WIDE_PYTH_WINDOW_MS: u64 = 5_000;
/// A Pyth age between the two windows: fresh under the default, stale under the
/// tightened one.
const BETWEEN_WINDOWS_AGE_MS: u64 = 1_500;
/// Propbook source id for a replacement Pyth feed that has no observation yet.
const SECOND_SOURCE_ID: u32 = 2;
/// A Pyth print that does not normalize to a positive spot.
const NON_POSITIVE_PYTH_SPOT: u64 = 0;
/// Accept any fill the budget buys; the gate aborts before sizing either way.
const NO_MIN_QUANTITY: u64 = 0;

/// Leave the Pyth spot at its seed (`live_source_timestamp_ms`) and move the
/// clock and the Block Scholes surface `age_ms` past it. Every other input stays
/// fresh, so only the Pyth age separates the cases below.
fun age_pyth_spot(fx: &mut Fixture, market: &mut MarketBundle, age_ms: u64) {
    fx.advance_block_scholes_bundle_to(
        market,
        test_constants::default_live_price(),
        test_constants::live_source_timestamp_ms() + age_ms,
    );
}

// === Every mint and mint quote refuses a stale Pyth spot ===

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun mint_exact_quantity_one_ms_past_the_window_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Age == window + 1: the first millisecond the load falls back to the Block
    // Scholes forward. Paired with `mint_exactly_at_the_window_succeeds`.
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun mint_exact_amount_on_a_stale_pyth_spot_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_deposit(),
        NO_MIN_QUANTITY,
        std::u64::max_value!(),
    );

    abort 999
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun mint_exact_cost_on_a_stale_pyth_spot_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_deposit(),
        NO_MIN_QUANTITY,
    );

    abort 999
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun quote_mint_on_a_stale_pyth_spot_aborts() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);

    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.quote_mint_bundle(&market, helpers::strike_tick(), constants::pos_inf_tick!(), QUANTITY);

    abort 999
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun quote_mint_for_account_on_a_stale_pyth_spot_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun quote_mint_exact_cost_for_account_on_a_stale_pyth_spot_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_deposit(),
        NO_MIN_QUANTITY,
    );

    abort 999
}

// === A feed with no usable spot is unavailable, not stale ===

/// A replacement Pyth feed has no observation until its first push, so the pricer
/// snapshots a zero Pyth timestamp and prices off the Block Scholes forward.
#[test, expected_failure(abort_code = pricing::EPythSpotUnavailable)]
fun mint_without_any_pyth_observation_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let rebound_pyth_id = fx.create_and_rebind_pyth(SECOND_SOURCE_ID);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle_with_pyth(expiry_id, rebound_pyth_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

/// A print landed inside the window, so age is not the problem: it does not
/// normalize to a positive spot, and the pricer snapshots the same zero timestamp.
#[test, expected_failure(abort_code = pricing::EPythSpotUnavailable)]
fun mint_on_a_non_positive_pyth_print_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_pyth_price_for_testing_bundle(
        &mut market,
        NON_POSITIVE_PYTH_SPOT,
        test_constants::now_ms(),
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

// === The requirement is mint-only: exits keep the fallback ===

#[test]
fun redeem_live_on_a_stale_pyth_spot_still_closes() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Open while Pyth is fresh, then let it age past the window: the state
    // `mint_exact_quantity_one_ms_past_the_window_aborts` refuses to mint in.
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    assert_eq!(
        fx.load_pricer_bundle(&market).pyth_spot_source_timestamp_ms(),
        test_constants::live_source_timestamp_ms(),
    );

    let remainder = fx.redeem_live_bundle(&mut market, &mut account, order, QUANTITY);
    assert!(remainder.is_none());
    assert!(!helpers::has_position_bundle(&account, expiry_id, order));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Boundary ===

#[test]
fun mint_exactly_at_the_window_succeeds() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    assert_eq!(helpers::config(&market).pricing_config().pyth_spot_freshness_ms(), PYTH_WINDOW_MS);
    // Age == window: the bound is inclusive, so the load still anchors on Pyth.
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS);
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === The guard reads the configured window, not the default ===

/// Paired with `a_tightened_window_rejects_the_same_spot`: same market, same
/// Pyth age, opposite outcome.
#[test]
fun the_default_window_admits_a_spot_between_the_windows() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    age_pyth_spot(&mut fx, &mut market, BETWEEN_WINDOWS_AGE_MS);
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun a_tightened_window_rejects_the_same_spot() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_pyth_spot_freshness_bundle(&mut market, TIGHT_PYTH_WINDOW_MS);
    age_pyth_spot(&mut fx, &mut market, BETWEEN_WINDOWS_AGE_MS);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

/// Paired with `mint_exact_quantity_one_ms_past_the_window_aborts`: the same Pyth
/// age mints once the admin widens the window past it.
#[test]
fun a_widened_window_admits_a_spot_past_the_default() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_pyth_spot_freshness_bundle(&mut market, WIDE_PYTH_WINDOW_MS);
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Recovery ===

/// With Pyth deselected no Pyth spot feeds the forward, so its age rejects
/// nothing. This is the admin's way to keep minting through a Pyth outage.
#[test]
fun deselecting_pyth_lifts_the_requirement() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_use_pyth_spot_for_forward_bundle(&mut market, false);
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun a_new_pyth_push_restores_minting() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // The state the abort tests above mint in, then one Pyth push at the clock.
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    let pushed_at_ms = test_constants::live_source_timestamp_ms() + PYTH_WINDOW_MS + 1;
    fx.set_pyth_price_for_testing_bundle(
        &mut market,
        test_constants::default_live_price(),
        pushed_at_ms,
    );
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(fx.load_pricer_bundle(&market).pyth_spot_source_timestamp_ms(), pushed_at_ms);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
