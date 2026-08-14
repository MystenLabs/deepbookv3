// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Backing-buffer reserve pins for the minimal floor + gap-scaled buffer design.
///
/// These tests use production mint/redeem flows and hand-derived reserve values:
/// disjoint one-lot books have M = 1e9, Σ = 2e9, gap = 1e9, so the default
/// reserve is 1.25e9; overlapping books have gap = 0, so reserve = M = Σ. The
/// settled-redeem legs are covered in `settlement_flow_tests`, so this file keeps
/// the live reserve boundary focused.
#[test_only]
module deepbook_predict::backing_buffer_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_cash,
    flow_test_helpers as helpers,
    order,
    test_constants
};
use dusdc::dusdc::DUSDC;
use fixed_math::math::{Self, float_scaling as float};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 1_000_000_000;
const DISJOINT_MAX_LIVE: u64 = QUANTITY;
const DISJOINT_GAP: u64 = QUANTITY;
const OVERLAPPING_RESERVE: u64 = 2 * QUANTITY;

/// These tests turn on the market holding an EXACT cash balance at a reserve
/// boundary, so the seed has to be stated relative to what the mints will cost —
/// which is only knowable once the market is live and quotable. Each test
/// therefore creates with zero cash, quotes both mints (pricing does not depend
/// on market cash), pins the quoted probability against the independent
/// reference, and only then seeds the difference. Nothing here restates a price.
/// A cash level strictly between the buffered reserve and the old summed one —
/// the window the capital-efficiency change opened. The gap is ~750e6 wide, so
/// this sits far from either edge.

#[test]
fun disjoint_range_book_uses_default_gap_buffer() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let _down = mint_down(&mut fx, &mut market, &mut account);
    let _up = mint_up(&mut fx, &mut market, &mut account);

    // M = 1e9, Σ = 2e9, λ(default) * gap = 250e6, reserve = 1.25e9.
    assert_eq!(
        math::mul_down(config_constants::default_backing_buffer_lambda!(), DISJOINT_GAP),
        QUANTITY / 4,
    );
    assert_eq!(helpers::market(&market).payout_liability(), disjoint_buffered_reserve());

    cleanup(fx, market, account);
}

#[test]
fun overlapping_range_book_has_zero_gap() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let _first = mint_down(&mut fx, &mut market, &mut account);
    let _second = mint_down(&mut fx, &mut market, &mut account);

    // Both orders win at the same settlement points: M = Σ = 2e9, gap = 0.
    assert_eq!(math::mul_down(config_constants::default_backing_buffer_lambda!(), 0), 0);
    assert_eq!(helpers::market(&market).payout_liability(), OVERLAPPING_RESERVE);

    cleanup(fx, market, account);
}

#[test]
fun lambda_one_is_summed_backing_identity() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_cash(
        test_constants::default_seeded_expiry_cash(),
        option::some(float!()),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let _down = mint_down(&mut fx, &mut market, &mut account);
    let _up = mint_up(&mut fx, &mut market, &mut account);

    // λ = 1e9 makes mul(λ, gap) exactly gap under the fixed-point identity.
    assert_eq!(helpers::market(&market).backing_buffer_lambda(), float!());
    assert_eq!(math::mul_down(float!(), DISJOINT_GAP), DISJOINT_GAP);
    assert_eq!(helpers::market(&market).payout_liability(), 2 * QUANTITY);

    cleanup(fx, market, account);
}

fun mint_down(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut helpers::AccountBundle,
): u256 {
    fx.mint_bundle(
        market,
        account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        QUANTITY,
    )
}

fun mint_up(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut helpers::AccountBundle,
): u256 {
    fx.mint_bundle(
        market,
        account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    )
}

fun disjoint_buffered_reserve(): u64 {
    // Independent of the production reserve formula: λ_default = 0.25, so the gap
    // buffer is DISJOINT_GAP / 4 (line-72 assert separately pins math::mul_down(λ, gap)
    // == QUANTITY / 4). Reserve = max-live + buffer.
    DISJOINT_MAX_LIVE + DISJOINT_GAP / 4
}

fun setup_live_market_with_cash(
    seed_cash: u64,
    backing_buffer_lambda: Option<u64>,
): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    backing_buffer_lambda.do!(|value| fx.set_template_backing_buffer_lambda(value));
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(helpers::market_mut(&mut market), seed_cash);
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::admin());
    (fx, expiry_id, trader)
}

fun cleanup(fx: helpers::Fixture, market: helpers::MarketBundle, account: helpers::AccountBundle) {
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
