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
const LEVERAGED_QUANTITY: u64 = 2_000_000_000;
const REBATE_AFTER_ONE_MINT: u64 = 2_500_000;
const REBATE_AFTER_DOWN_AND_LEVERAGED_MINTS: u64 = 7_500_000;

const DISJOINT_MAX_LIVE: u64 = QUANTITY;
const DISJOINT_GAP: u64 = QUANTITY;
const OVERLAPPING_RESERVE: u64 = 2 * QUANTITY;

const LEVERAGE_TWO_X: u64 = 2_000_000_000;

/// These tests turn on the market holding an EXACT cash balance at a reserve
/// boundary, so the seed has to be stated relative to what the mints will cost —
/// which is only knowable once the market is live and quotable. Each test
/// therefore creates with zero cash, quotes both mints (pricing does not depend
/// on market cash), pins the quoted probability against the independent
/// reference, and only then seeds the difference. Nothing here restates a price.
const FIRST_ORDER_REQUIRED_CASH: u64 = QUANTITY + REBATE_AFTER_ONE_MINT;
/// A cash level strictly between the buffered reserve and the old summed one —
/// the window the capital-efficiency change opened. The gap is ~750e6 wide, so
/// this sits far from either edge.
const CAPITAL_EFFICIENT_POST_MINT_CASH: u64 = 1_800_000_000;

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

#[test]
fun mint_succeeds_when_cash_between_buffered_reserve_and_old_sum() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_cash(0, option::none());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let down_cost = down_mint_cost(&mut fx, &market);
    let up_cost = leveraged_up_mint_cost(&mut fx, &market);
    let seed = CAPITAL_EFFICIENT_POST_MINT_CASH - down_cost - up_cost;
    fx.seed_market_cash(helpers::market_mut(&mut market), seed);

    let _down = mint_down(&mut fx, &mut market, &mut account);
    assert_eq!(helpers::market(&market).cash_balance(), seed + down_cost);
    let _up = mint_leveraged_up(&mut fx, &mut market, &mut account);

    // Cash is 1.8e9: above new required cash 1.7575e9, below old Σ
    // requirement 2.5075e9. The second mint would have failed under the old
    // summed reserve.
    assert_eq!(helpers::market(&market).cash_balance(), CAPITAL_EFFICIENT_POST_MINT_CASH);
    assert_eq!(
        helpers::market(&market).payout_liability(),
        buffered_reserve(leveraged_live_backing(&mut fx, &market)),
    );
    let leveraged_backing = leveraged_live_backing(&mut fx, &market);
    assert!(
        helpers::market(&market).cash_balance()
            >= buffered_reserve(leveraged_backing) + REBATE_AFTER_DOWN_AND_LEVERAGED_MINTS,
    );
    assert!(
        helpers::market(&market).cash_balance()
            < QUANTITY + leveraged_backing + REBATE_AFTER_DOWN_AND_LEVERAGED_MINTS,
    );

    cleanup(fx, market, account);
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun mint_below_buffered_reserve_aborts() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_cash(0, option::none());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let down_cost = down_mint_cost(&mut fx, &market);
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        FIRST_ORDER_REQUIRED_CASH - down_cost,
    );

    let _down = mint_down(&mut fx, &mut market, &mut account);
    assert_eq!(helpers::market(&market).cash_balance(), FIRST_ORDER_REQUIRED_CASH);

    // The 2x UP mint adds 510e6 cash, leaving 1.5125e9 cash against the
    // 1.7575e9 buffered required cash for the disjoint live orders.
    let _up = mint_leveraged_up(&mut fx, &mut market, &mut account);
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun exact_reserve_full_close_hits_single_number_wall() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_cash(0, option::none());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let required_cash = leveraged_required_cash(&mut fx, &market);
    let down_cost = down_mint_cost(&mut fx, &market);
    let up_cost = leveraged_up_mint_cost(&mut fx, &market);
    fx.seed_market_cash(helpers::market_mut(&mut market), required_cash - down_cost - up_cost);

    let down = mint_down(&mut fx, &mut market, &mut account);
    let _up = mint_leveraged_up(&mut fx, &mut market, &mut account);
    assert_eq!(helpers::market(&market).cash_balance(), required_cash);

    // Closing the DOWN side would pay 495e6 net, but the remaining leveraged
    // UP reserve still needs 1.5e9 plus the higher rebate reserve.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let (_closed, _replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        down,
        QUANTITY,
    );
    abort 999
}

#[test]
fun exact_reserve_partial_close_preserves_live_floor() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_cash(0, option::none());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let required_cash = leveraged_required_cash(&mut fx, &market);
    let down_cost = down_mint_cost(&mut fx, &market);
    let up_cost = leveraged_up_mint_cost(&mut fx, &market);
    fx.seed_market_cash(helpers::market_mut(&mut market), required_cash - down_cost - up_cost);

    let _down = mint_down(&mut fx, &mut market, &mut account);
    let up = mint_leveraged_up(&mut fx, &mut market, &mut account);
    assert_eq!(helpers::market(&market).cash_balance(), required_cash);

    // Closing half of the leveraged UP side pays its live value less the retained
    // fee, and lowers the reserve to the surviving half's backing plus the gap
    // buffer. The payout is measured and cross-checked against expiry cash.
    let balance_before_close = fx.account_balance_bundle<DUSDC>(&account);
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let (_closed, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        up,
        QUANTITY,
    );
    let up_survivor = replacement.destroy_some();
    let partial_net_payout = fx.account_balance_bundle<DUSDC>(&account) - balance_before_close;
    assert_eq!(helpers::market(&market).cash_balance(), required_cash - partial_net_payout);
    // The survivor keeps QUANTITY of the leveraged side; the down order is now the
    // larger live backing, so the reserve is QUANTITY plus lambda times the gap.
    let survivor_backing = QUANTITY - order::from_order_id(up_survivor).floor_shares();
    assert_eq!(
        helpers::market(&market).payout_liability(),
        QUANTITY + math::mul_down(survivor_backing, config_constants::default_backing_buffer_lambda!()),
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, up_survivor));

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
        test_constants::leverage_one_x(),
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
        test_constants::leverage_one_x(),
    )
}

fun mint_leveraged_up(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut helpers::AccountBundle,
): u256 {
    fx.mint_bundle(
        market,
        account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    )
}

/// The leveraged order's live backing: the quantity above the floor it financed.
/// `entry_value = mul_down(p, Q)` and `floor_shares = entry_value - net_premium`,
/// both from terms the quote publishes; the probability is pinned against the
/// independent reference first, so this derives a fixture input from published
/// contract terms rather than restating an expected price.
fun leveraged_live_backing(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): u64 {
    let quote = fx.quote_mint_bundle(
        market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    let entry_value = math::mul_down(quote.entry_probability(), LEVERAGED_QUANTITY);
    LEVERAGED_QUANTITY - (entry_value - quote.net_premium())
}

/// D030 disjoint backing: the larger live backing plus lambda times the gap. The
/// leveraged order backs more than the down order's QUANTITY, so it is the max
/// and QUANTITY is the gap.
fun buffered_reserve(leveraged_backing: u64): u64 {
    leveraged_backing + math::mul_down(QUANTITY, config_constants::default_backing_buffer_lambda!())
}

fun leveraged_required_cash(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): u64 {
    buffered_reserve(leveraged_live_backing(fx, market)) + REBATE_AFTER_DOWN_AND_LEVERAGED_MINTS
}

/// All-in cost of a mint, which is exactly what it adds to expiry cash: the
/// premium plus the trading fee, with no builder, subsidy or penalty component in
/// these fixtures.
fun quoted_mint_cost(
    fx: &mut helpers::Fixture,
    market: &helpers::MarketBundle,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    complement: bool,
): u64 {
    let quote = fx.quote_mint_bundle(market, lower_tick, higher_tick, quantity, leverage);
    if (complement) {
        helpers::assert_atm_complement_entry_probability(quote.entry_probability())
    } else {
        helpers::assert_atm_entry_probability(quote.entry_probability())
    };
    quote.all_in_cost()
}

fun down_mint_cost(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): u64 {
    quoted_mint_cost(
        fx,
        market,
        constants::neg_inf!(),
        helpers::strike_tick(),
        QUANTITY,
        test_constants::leverage_one_x(),
        true,
    )
}

fun leveraged_up_mint_cost(fx: &mut helpers::Fixture, market: &helpers::MarketBundle): u64 {
    quoted_mint_cost(
        fx,
        market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
        false,
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
