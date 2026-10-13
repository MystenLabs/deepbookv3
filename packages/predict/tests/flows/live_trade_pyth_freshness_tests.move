// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the live-trade Pyth freshness requirement. While
/// `use_pyth_spot_for_forward` is set, a pricer that fell back to the Block
/// Scholes forward because the Pyth spot was stale or unavailable is refused by
/// all three mint entrypoints, all three mint quotes, and `redeem_live`, while
/// `current_nav` and the pool flush still price on that fallback. Pins the window
/// boundary in both directions for mints and live redeems, both unavailable
/// states (no observation, a print that does not normalize), that the guard fires
/// before the trading pause, that it reads the configured window rather than the
/// compiled default in both directions, that deselecting Pyth lifts it (including
/// on a feed with no observation), and that a new Pyth push restores live trading.
#[test_only]
module deepbook_predict::live_trade_pyth_freshness_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers::{Self as helpers, AccountBundle, Fixture, MarketBundle, Trader},
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
/// The `Pricer`'s Pyth source timestamp when the feed holds no usable observation.
const NO_PYTH_OBSERVATION_MS: u64 = 0;
/// +10% on the seeded level: a Block Scholes move the stale Pyth spot does not
/// follow, so the fallback forward and a Pyth-anchored one disagree.
const MOVED_BLOCK_SCHOLES_PRICE: u64 = 110_000_000_000;
/// Idle seed large enough to bootstrap PLP supply and fund one market.
const IDLE_SEED: u64 = 1_200_000_000_000;

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

/// Mint the standard ATM up position.
fun mint_position(fx: &mut Fixture, market: &mut MarketBundle, account: &mut AccountBundle): u256 {
    fx.mint_bundle(
        market,
        account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    )
}

/// Open the standard position in its own transaction while every input is fresh,
/// so a later transaction's close is the only trade the state under test can
/// refuse.
fun open_position(fx: &mut Fixture, expiry_id: ID, trader: &Trader): u256 {
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(trader);
    let order = mint_position(fx, &mut market, &mut account);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    order
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

// === Gate order ===

/// Pins the order of the mint gates: the Pyth requirement sits in the gate every
/// live flow shares, which runs before the mint-only trading-pause check, so a
/// mint while trading is paused and the Pyth spot is stale aborts on Pyth, not
/// `protocol_config::ETradingPaused`. Paired with
/// `expiry_market_gate_tests::mint_while_trading_paused_aborts`, where Pyth is
/// fresh and the pause fires.
#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun stale_pyth_aborts_a_mint_before_the_trading_pause() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_trading_paused_bundle(&mut market, true);
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

// === Live redeems refuse the same fallback ===

/// The close-side twin of `mint_exact_quantity_one_ms_past_the_window_aborts`:
/// the position opened while Pyth was fresh, and only the Pyth age has moved
/// since. Paired with `redeem_live_exactly_at_the_window_succeeds`.
#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun redeem_live_one_ms_past_the_window_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let order = open_position(&mut fx, expiry_id, &trader);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.redeem_live_bundle(&mut market, &mut account, order, QUANTITY);

    abort 999
}

#[test]
fun redeem_live_exactly_at_the_window_succeeds() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let order = open_position(&mut fx, expiry_id, &trader);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    // Age == window: the bound is inclusive, so the load still anchors on the
    // seeded Pyth spot.
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS);
    assert_eq!(
        fx.load_pricer_bundle(&market).pyth_ts(),
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

/// The close-side twin of `mint_without_any_pyth_observation_aborts`: the
/// position opened on the original feed, then the underlying moved to a
/// replacement feed whose first push has not landed. Paired with
/// `deselected_pyth_ignores_an_unseeded_feed`.
#[test, expected_failure(abort_code = pricing::EPythSpotUnavailable)]
fun redeem_live_without_any_pyth_observation_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let order = open_position(&mut fx, expiry_id, &trader);
    let rebound_pyth_id = fx.create_and_rebind_pyth(SECOND_SOURCE_ID);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle_with_pyth(expiry_id, rebound_pyth_id);
    let mut account = fx.take_account_bundle(&trader);
    // Close one millisecond after the open, on a fresh Block Scholes surface.
    fx.advance_block_scholes_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        test_constants::now_ms() + 1,
    );
    fx.redeem_live_bundle(&mut market, &mut account, order, QUANTITY);

    abort 999
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

    assert_eq!(helpers::config(&market).pricing_cfg().pyth_age_ms(), PYTH_WINDOW_MS);
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

// === Valuation keeps the fallback ===

/// With Pyth selected but stale, `current_nav` still prices, on the Block Scholes
/// forward, so it equals the mark with Pyth deselected. The surface moves away
/// from the stale Pyth spot first, so a mark re-anchored on Pyth could not match.
#[test]
fun current_nav_on_a_stale_pyth_spot_still_prices() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    // An open position gives the mark a liability that depends on the forward.
    open_position(&mut fx, expiry_id, &trader);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let stale_at_ms = test_constants::live_source_timestamp_ms() + PYTH_WINDOW_MS + 1;
    fx.advance_block_scholes_bundle_to(&mut market, MOVED_BLOCK_SCHOLES_PRICE, stale_at_ms);
    let nav_with_pyth_selected = fx.current_nav_bundle(&market);
    fx.set_use_pyth_spot_for_forward_bundle(&mut market, false);
    let nav_on_block_scholes = fx.current_nav_bundle(&market);
    assert_eq!(nav_with_pyth_selected, nav_on_block_scholes);

    // Guard against a vacuous match: a fresh Pyth spot at the seeded level
    // re-anchors the forward away from the moved surface and marks differently.
    fx.set_use_pyth_spot_for_forward_bundle(&mut market, true);
    fx.set_pyth_price_for_testing_bundle(
        &mut market,
        test_constants::default_live_price(),
        stale_at_ms,
    );
    assert!(fx.current_nav_bundle(&market) != nav_on_block_scholes);

    helpers::return_market_bundle(market);
    fx.finish();
}

/// The flush snapshot loads each market's pricer on the same fallback, so a gap
/// in Pyth updates does not stall pool valuation: with Pyth selected but stale,
/// the market is snapshotted, valued, and folded into the pool mark at its Block
/// Scholes-forward NAV, the mark it has with Pyth deselected, not the one a fresh
/// Pyth spot would give it.
#[test]
fun flush_on_a_stale_pyth_spot_completes() {
    let mut fx = helpers::setup_market_default();
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    fx.bootstrap_lock(IDLE_SEED);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);
    // An open position gives the mark a liability that depends on the forward.
    open_position(&mut fx, expiry_id, &trader);

    // The state every live trade above refuses to execute in, with the surface
    // moved away from the stale Pyth spot so the two forwards mark differently.
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    let stale_at_ms = test_constants::live_source_timestamp_ms() + PYTH_WINDOW_MS + 1;
    fx.advance_block_scholes_bundle_to(&mut market, MOVED_BLOCK_SCHOLES_PRICE, stale_at_ms);
    // The reference mark reads no Pyth at all.
    fx.set_use_pyth_spot_for_forward_bundle(&mut market, false);
    let nav_on_block_scholes = fx.current_nav_bundle(&market);
    fx.set_use_pyth_spot_for_forward_bundle(&mut market, true);

    // The forward move takes the up position deep into the money, so the market
    // is worth less than the cash the pool sent it and nothing has settled: no
    // protocol profit share is held out, and the pool mark is idle plus the
    // market's NAV.
    let vault = helpers::vault(&market);
    assert!(vault.profit_basis_credits() + nav_on_block_scholes < vault.profit_basis_debits());
    assert_eq!(vault.pending_protocol_profit(), 0);
    let expected_pool_nav = vault.idle_balance() + nav_on_block_scholes;

    fx.start_flush_bundle(&mut market);
    assert!(helpers::market(&market).is_pending_valuation(helpers::config(&market)));
    fx.value_expiry_bundle(&mut market);
    assert_eq!(fx.finish_flush_bundle(&mut market), expected_pool_nav);

    // Guard against a vacuous match: a fresh Pyth spot at the seeded level
    // re-anchors the forward away from the moved surface and marks differently.
    fx.set_pyth_price_for_testing_bundle(
        &mut market,
        test_constants::default_live_price(),
        stale_at_ms,
    );
    assert!(fx.current_nav_bundle(&market) != nav_on_block_scholes);

    helpers::return_market_bundle(market);
    fx.finish();
}

// === Recovery ===

/// With Pyth deselected no Pyth spot feeds the forward, so its age rejects
/// nothing on either side of a trade. This is the admin's way to keep live
/// trading open through a Pyth outage.
#[test]
fun deselecting_pyth_lifts_the_requirement() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let order = open_position(&mut fx, expiry_id, &trader);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    // The state `redeem_live_one_ms_past_the_window_aborts` refuses to close in.
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.set_use_pyth_spot_for_forward_bundle(&mut market, false);

    let remainder = fx.redeem_live_bundle(&mut market, &mut account, order, QUANTITY);
    assert!(remainder.is_none());
    assert!(!helpers::has_position_bundle(&account, expiry_id, order));
    let reopened = mint_position(&mut fx, &mut market, &mut account);
    assert!(helpers::has_position_bundle(&account, expiry_id, reopened));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// With Pyth deselected the requirement passes before reading the Pyth timestamp
/// at all, so a feed with no observation, whose `0` sentinel aborts
/// `redeem_live_without_any_pyth_observation_aborts`, blocks neither side of a
/// trade.
#[test]
fun deselected_pyth_ignores_an_unseeded_feed() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let order = open_position(&mut fx, expiry_id, &trader);
    let rebound_pyth_id = fx.create_and_rebind_pyth(SECOND_SOURCE_ID);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle_with_pyth(expiry_id, rebound_pyth_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_use_pyth_spot_for_forward_bundle(&mut market, false);
    // Close one millisecond after the open, on a fresh Block Scholes surface.
    fx.advance_block_scholes_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        test_constants::now_ms() + 1,
    );
    assert_eq!(fx.load_pricer_bundle(&market).pyth_ts(), NO_PYTH_OBSERVATION_MS);

    let remainder = fx.redeem_live_bundle(&mut market, &mut account, order, QUANTITY);
    assert!(remainder.is_none());
    assert!(!helpers::has_position_bundle(&account, expiry_id, order));
    let reopened = mint_position(&mut fx, &mut market, &mut account);
    assert!(helpers::has_position_bundle(&account, expiry_id, reopened));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// One in-window Pyth push, landed in an earlier transaction, lifts the stale
/// state the abort tests above trade in: a close and a new mint then both price
/// on the pushed spot.
#[test]
fun a_new_pyth_push_restores_live_trading() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let order = open_position(&mut fx, expiry_id, &trader);

    let pushed_at_ms = test_constants::live_source_timestamp_ms() + PYTH_WINDOW_MS + 1;
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    age_pyth_spot(&mut fx, &mut market, PYTH_WINDOW_MS + 1);
    fx.set_pyth_price_for_testing_bundle(
        &mut market,
        test_constants::default_live_price(),
        pushed_at_ms,
    );
    helpers::return_market_bundle(market);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    assert_eq!(fx.load_pricer_bundle(&market).pyth_ts(), pushed_at_ms);

    let remainder = fx.redeem_live_bundle(&mut market, &mut account, order, QUANTITY);
    assert!(remainder.is_none());
    assert!(!helpers::has_position_bundle(&account, expiry_id, order));
    let reopened = mint_position(&mut fx, &mut market, &mut account);
    assert!(helpers::has_position_bundle(&account, expiry_id, reopened));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
