// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Backing-buffer reserve pins for the minimal floor + gap-scaled buffer design.
///
/// These tests use production mint/redeem flows and hand-derived reserve values:
/// disjoint one-lot books have M = 1e9, Σ = 2e9, gap = 1e9, so the default
/// reserve is 1.31e9; overlapping books have gap = 0, so reserve = M = Σ. The
/// settled-redeem legs are covered in `settlement_flow_tests`, so this file keeps
/// the live reserve boundary focused.
#[test_only]
module deepbook_predict::backing_buffer_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_cash,
    flow_test_helpers as helpers,
    test_constants
};
use fixed_math::math::{Self, float_scaling as float};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 1_000_000_000;
const DISJOINT_GAP: u64 = QUANTITY;
const DEFAULT_DISJOINT_BUFFER: u64 = 310_000_000;
const DEFAULT_DISJOINT_RESERVE: u64 = 1_310_000_000;
const OVERLAPPING_RESERVE: u64 = 2 * QUANTITY;
/// Headroom over the buffered reserve, chosen to clear any rebate basis these
/// fixtures can accrue while staying well under the close-side deficit.
const CASH_CUSHION: u64 = QUANTITY / 50;

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

    // M = 1e9, Σ = 2e9, λ(default) * gap = 310e6, reserve = 1.31e9.
    assert_eq!(
        math::mul_down(config_constants::default_backing_buffer_lambda!(), DISJOINT_GAP),
        DEFAULT_DISJOINT_BUFFER,
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

/// The reserve for a single order is its full quantity, but the premium the mint
/// brings in is only `p * quantity` — about half of that for an at-the-money
/// range. A market therefore cannot back its own first order out of what that
/// order pays: the pool allocation has to already be there. This pins the mint
/// side of `expiry_market::assert_cash_backing`, which no flow test reached
/// after the leveraged fixtures that used to cover it were removed.
#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun mint_without_pool_backing_aborts() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_cash(0, option::none());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    assert_eq!(helpers::market(&market).cash_balance(), 0);

    let _down = mint_down(&mut fx, &mut market, &mut account);
    abort 999
}

/// Closing one side of a disjoint book destroys more cash than it frees.
///
/// Two disjoint one-lot orders reserve `M + λ*gap` = 1.31e9. Closing the DOWN
/// side pays out its live value (~0.5e9 at the money) while the reserve only
/// falls to the surviving UP order's own backing, 1e9 — so a market holding the
/// legal minimum ends the close about 0.19e9 short and must refuse it. The seed
/// targets a cash level a little above the minimum, which keeps the fixture
/// independent of the exact rebate basis while staying inside the 0.19e9
/// deficit; the pre-close assertion pins that the market really was backed.
#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun full_close_below_remaining_reserve_aborts() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_cash(0, option::none());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let down_cost = down_mint_cost(&mut fx, &market);
    let up_cost = up_mint_cost(&mut fx, &market);
    let target_cash = disjoint_buffered_reserve() + CASH_CUSHION;
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        target_cash - down_cost - up_cost,
    );

    let down = mint_down(&mut fx, &mut market, &mut account);
    let _up = mint_up(&mut fx, &mut market, &mut account);

    // The market is legally backed before the close, and the cushion is far
    // smaller than the deficit the close will open.
    assert_eq!(helpers::market(&market).cash_balance(), target_cash);
    assert!(helpers::market(&market).cash_balance() >= required_cash(&market));
    assert!(CASH_CUSHION < DISJOINT_GAP / 4);

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let _replacement = fx.redeem_live_bundle(&mut market, &mut account, down, QUANTITY);
    abort 999
}

fun required_cash(market: &helpers::MarketBundle): u64 {
    let market = helpers::market(market);
    market.payout_liability() + market.skew_reserve()
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

/// All-in cost of a mint, which is exactly what it adds to expiry cash: the
/// premium plus the trading fee, with no builder, subsidy or penalty component
/// in these fixtures. The quoted probability is pinned against the independent
/// reference first, so the seed derives from published contract terms rather
/// than restating an expected price.
fun down_mint_cost(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): u64 {
    let quote = fx.quote_mint_bundle(
        market,
        constants::neg_inf!(),
        helpers::strike_tick(),
        QUANTITY,
    );
    helpers::assert_atm_complement_entry_probability(quote.entry_probability());
    quote.all_in_cost()
}

fun up_mint_cost(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): u64 {
    let quote = fx.quote_mint_bundle(
        market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    quote.all_in_cost()
}

fun disjoint_buffered_reserve(): u64 {
    // Independent of the production reserve formula: the configured default makes
    // the 1e9 disjoint gap buffer 310e6. Reserve = max-live + buffer.
    DEFAULT_DISJOINT_RESERVE
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
