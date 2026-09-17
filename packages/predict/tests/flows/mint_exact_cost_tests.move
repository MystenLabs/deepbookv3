// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sizing coverage for the all-in-budget mint request (`mint_exact_cost` and
/// `quote_mint_exact_cost_for_account`): the flow mints the largest lot-rounded
/// quantity whose ALL-IN cost — premium plus trader-paid trading fee, builder fee,
/// congestion surcharge and inventory-impact charge — fits the budget, never
/// debits past it, and leaves less than one more lot's all-in cost unspent.
///
/// Budgets and expected debits are read from a quantity quote at the size in
/// question rather than hardcoded: a budget threshold IS the next lot's all-in
/// cost. `quote_mint_tests` owns whether that quote's composition is itself
/// right, and each fee component here is additionally pinned against its
/// independent value (the fixture's 0.005 minimum fee is `quantity / 200` for a
/// single finite leg, the builder cut is a tenth of it, the subsidy a fifth).
#[test_only]
module deepbook_predict::mint_exact_cost_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_market::{Self, MintQuote},
    flow_test_helpers as helpers,
    order,
    protocol_config,
    strike_exposure,
    strike_exposure_config,
    test_constants
};
use std::unit_test::assert_eq;
use usdc::usdc::USDC;

/// 10_000 lots of 10_000 raw units, and the next lot up.
const TEN_THOUSAND_LOTS: u64 = 100_000_000;
const NEXT_LOT_QUANTITY: u64 = 100_010_000;
/// Lot-cap saturation quantity: max_quantity_lots (u32 max = 4_294_967_295) *
/// lot 10_000.
const LOT_CAP_QUANTITY: u64 = 42_949_672_950_000;
/// A balance that can pay for the lot cap outright, so only the lot cap itself
/// bounds the search.
const LOT_CAP_DEPOSIT: u64 = 100_000_000_000_000;

/// The fixture floors base_fee to 1 and fixes min_fee at 0.005, so at a far
/// expiry (no fee ramp) a single-finite-leg range pays exactly `quantity / 200`.
const MIN_FEE_DIVISOR: u64 = 200;
/// Builder cut of the trading fee: builder_fee_multiplier (0.1), which binds
/// below max_builder_fee_rate (0.005) * quantity at these sizes.
const BUILDER_FEE_DIVISOR: u64 = 10;
/// Sponsor share of the trading fee: fee_incentive_subsidy_rate (0.2).
const SUBSIDY_DIVISOR: u64 = 5;

/// Quantity whose trading fee is large enough that the 0.2 subsidy rate exceeds
/// the sponsored balance, so the subsidy binds at the cap mid-search.
const SUBSIDY_CAP_QUANTITY: u64 = 20_000_000_000;
const SUBSIDY_CAP_NEXT_LOT: u64 = 20_000_010_000;

/// Congestion-surcharge fixture, mirroring `quote_mint_tests`.
const VARIANCE_SEED_QUANTITY: u64 = 100_000_000;
const GAS_SEED: u64 = 2_000;
const GAS_SPIKE: u64 = 3_000;
const SPIKE_MS: u64 = 121_000;
const SPIKE_SOURCE_TS: u64 = 120_000;

/// Inventory-impact fixture, mirroring `inventory_impact_flow_tests`.
const IMPACT_SCALE: u64 = 10_000_000_000;
const IMPACT_MAX_RATE: u64 = 200_000_000; // 20%
const BACKING_BUFFER_LAMBDA: u64 = 500_000_000; // 50%
/// Pre-existing position on the complementary range, so the candidate range's
/// own payout peak is zero while the book's point max is not.
const DISJOINT_BOOK_QUANTITY: u64 = 10_000_000_000;
/// Pre-existing position on the SAME range as the candidate, sized at the impact
/// scale so the liability starts at the curve's kink.
const SAME_RANGE_BOOK_QUANTITY: u64 = 10_000_000_000;
/// Impact charge for a `TEN_THOUSAND_LOTS` mint on an empty book, from the
/// quadratic arm `r_max * L^2 / (2B)` at L = 1e8, B = 1e10, r_max = 0.2.
const BELOW_KINK_IMPACT_CHARGE: u64 = 100_000;
/// Constant term of the capped-rate arm, `2 * phi(B) - phi(B) = r_max * B / 2`:
/// past the kink the charge is `quantity / 5 - 1e9`.
const CAPPED_RATE_INTERCEPT: u64 = 1_000_000_000;

/// Maximum-payout boundary fixture, mirroring `quote_mint_tests`: at quantity
/// 4e6 these fee rates put all-in cost exactly at quantity, and one raw unit
/// above it.
const MAX_PAYOUT_BOUNDARY_QUANTITY: u64 = 4_000_000;
const MAX_PAYOUT_BOUNDARY_MIN_FEE_RATE: u64 = 500_006_500;
/// A fee rate that puts all-in cost above quantity at EVERY size. The one raw
/// unit above the boundary rate that `quote_mint_tests` uses does not work here:
/// it breaches the bound only at that exact quantity, and a budget search is free
/// to size a smaller lot whose floored premium and fee still fit under its own
/// payout. Only a rate whose total clears 1.0 with room makes the bound
/// unavoidable for whatever the search picks.
const LOSS_MAKING_MIN_FEE_RATE: u64 = 600_000_000;

/// A budget far below the 1 USDC minimum mint premium.
const DUST_BUDGET: u64 = 1_000;

const BUILDER_CODE_INDEX: u64 = 0;

// === Sizing: the fill is the largest whose all-in cost fits ===

#[test]
fun budget_below_the_next_lot_mints_the_largest_fitting_fill() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // One raw unit below the next lot's ALL-IN cost is the largest budget that
    // still sizes 10_000 lots. `min_quantity` equal to the expected fill pins
    // sizing from below; the exact debit pins it from above.
    let fill = atm_quote_checked(&mut fx, &market, TEN_THOUSAND_LOTS);
    let next_lot = atm_quote_checked(&mut fx, &market, NEXT_LOT_QUANTITY);
    assert_eq!(fill.trading_fee(), TEN_THOUSAND_LOTS / MIN_FEE_DIVISOR);
    assert_eq!(fill.all_in_cost(), fill.premium() + fill.trading_fee());
    let budget = next_lot.all_in_cost() - 1;

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
    );

    assert_eq!(order::from_order_id(order_id).quantity(), TEN_THOUSAND_LOTS);
    assert!(helpers::has_position_bundle(&account, expiry_id, order_id));
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - fill.all_in_cost(),
    );
    // Inside the budget, and maximal: one more lot does not fit it.
    assert!(fill.all_in_cost() <= budget);
    assert!(next_lot.all_in_cost() > budget);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun budget_at_the_next_lot_all_in_cost_spends_it_exactly() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // A budget that is exactly one fill's all-in cost leaves no dust at all.
    let next_lot = atm_quote_checked(&mut fx, &market, NEXT_LOT_QUANTITY);
    let budget = next_lot.all_in_cost();

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        NEXT_LOT_QUANTITY,
    );

    assert_eq!(order::from_order_id(order_id).quantity(), NEXT_LOT_QUANTITY);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - budget,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = strike_exposure::EMintQuantityBelowMin)]
fun fill_below_min_quantity_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // The budget sizes exactly 10_000 lots; a floor one lot higher must abort.
    let budget = atm_quote_checked(&mut fx, &market, NEXT_LOT_QUANTITY).all_in_cost() - 1;
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS + constants::position_lot_size!(),
    );

    abort 999
}

#[test]
fun premium_budget_sizing_overspends_the_same_figure() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    // Handed one spend figure, premium sizing buys lots it cannot pay for: its
    // fee lands on top, so the quoted debit exceeds the figure. All-in sizing
    // fits the same figure exactly.
    let budget = atm_quote_checked(&mut fx, &market, TEN_THOUSAND_LOTS).all_in_cost();
    let premium_sized = fx.quote_mint_amount_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        0,
    );
    let cost_sized = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        0,
    );

    assert!(premium_sized.all_in_cost() > budget);
    assert!(premium_sized.quantity() > cost_sized.quantity());
    assert_eq!(cost_sized.quantity(), TEN_THOUSAND_LOTS);
    assert_eq!(cost_sized.all_in_cost(), budget);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === The quote twin ===

#[test]
fun account_quote_is_the_exact_debit_of_the_mint_it_sizes() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let budget = atm_quote_checked(&mut fx, &market, NEXT_LOT_QUANTITY).all_in_cost() - 1;
    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        0,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.quantity(), TEN_THOUSAND_LOTS);

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        0,
    );

    assert_eq!(order::from_order_id(order_id).quantity(), quote.quantity());
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - quote.all_in_cost(),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun account_quote_caps_the_budget_to_the_account_balance() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    // A u64-max budget is capped to the deposit: the fill is the largest lot
    // multiple the balance can pay for all-in, and one more lot cannot.
    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        constants::position_lot_size!(),
    );

    assert!(quote.all_in_cost() <= test_constants::mint_deposit());
    let one_more_lot = quote.quantity() + constants::position_lot_size!();
    assert!(
        atm_quote_checked(&mut fx, &market, one_more_lot).all_in_cost()
            > test_constants::mint_deposit(),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun whole_balance_budget_leaves_less_than_one_lot_unspent() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );
    let one_more_lot = atm_quote_checked(
        &mut fx,
        &market,
        quote.quantity() + constants::position_lot_size!(),
    );

    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );

    // What is left is the balance the next lot up could not be bought with.
    let remainder = fx.account_balance_bundle<USDC>(&account);
    assert_eq!(remainder, test_constants::mint_deposit() - quote.all_in_cost());
    assert!(one_more_lot.all_in_cost() > test_constants::mint_deposit());

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Every fee term is sized inside the budget ===

#[test]
fun builder_fee_is_sized_inside_the_budget() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let fill = account_quote_checked(&mut fx, &market, &account, TEN_THOUSAND_LOTS);
    let next_lot = account_quote_checked(&mut fx, &market, &account, NEXT_LOT_QUANTITY);
    let trading_fee = TEN_THOUSAND_LOTS / MIN_FEE_DIVISOR;
    assert_eq!(fill.builder_fee(), trading_fee / BUILDER_FEE_DIVISOR);
    assert_eq!(fill.all_in_cost(), fill.premium() + trading_fee + fill.builder_fee());
    let budget = next_lot.all_in_cost() - 1;

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
    );

    assert_eq!(order::from_order_id(order_id).quantity(), TEN_THOUSAND_LOTS);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - fill.all_in_cost(),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun sponsor_subsidy_is_sized_inside_the_budget() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!());
    fx.rebalance_expiry_cash_bundle(&mut market);

    let fill = atm_quote_checked(&mut fx, &market, TEN_THOUSAND_LOTS);
    let next_lot = atm_quote_checked(&mut fx, &market, NEXT_LOT_QUANTITY);
    let trading_fee = TEN_THOUSAND_LOTS / MIN_FEE_DIVISOR;
    assert_eq!(fill.fee_incentive_subsidy(), trading_fee / SUBSIDY_DIVISOR);
    assert_eq!(
        fill.all_in_cost(),
        fill.premium() + trading_fee - fill.fee_incentive_subsidy(),
    );
    let budget = next_lot.all_in_cost() - 1;

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
    );

    assert_eq!(order::from_order_id(order_id).quantity(), TEN_THOUSAND_LOTS);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - fill.all_in_cost(),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun subsidy_capped_by_the_sponsored_balance_still_sizes_exactly() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!());
    fx.rebalance_expiry_cash_bundle(&mut market);

    // At this size a fifth of the trading fee exceeds the whole sponsored
    // balance, so the subsidy binds at that balance rather than at the rate —
    // the search's one non-linear fee term.
    let fill = atm_quote_checked(&mut fx, &market, SUBSIDY_CAP_QUANTITY);
    let next_lot = atm_quote_checked(&mut fx, &market, SUBSIDY_CAP_NEXT_LOT);
    let trading_fee = SUBSIDY_CAP_QUANTITY / MIN_FEE_DIVISOR;
    assert!(trading_fee / SUBSIDY_DIVISOR > constants::min_fee_incentive_sponsorship!());
    assert_eq!(fill.fee_incentive_subsidy(), constants::min_fee_incentive_sponsorship!());
    let budget = next_lot.all_in_cost() - 1;

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        SUBSIDY_CAP_QUANTITY,
    );

    assert_eq!(order::from_order_id(order_id).quantity(), SUBSIDY_CAP_QUANTITY);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::default_manager_deposit() - fill.all_in_cost(),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun congestion_surcharge_after_the_quote_resizes_instead_of_aborting() {
    let (mut fx, expiry_id, trader) = congested_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        SPIKE_SOURCE_TS,
    );

    // The budget is what a caller saw BEFORE the gas spike: this fill's cost
    // without the surcharge. At execution the surcharge is live, so the fill
    // must come down a lot rather than breach the budget.
    let unsurcharged = atm_quote_checked(&mut fx, &market, TEN_THOUSAND_LOTS);
    assert!(unsurcharged.penalty_fee() > 0);
    let budget = unsurcharged.all_in_cost() - unsurcharged.penalty_fee();
    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        0,
    );
    let one_more_lot = atm_quote_checked(
        &mut fx,
        &market,
        quote.quantity() + constants::position_lot_size!(),
    );
    let balance_before = fx.account_balance_bundle<USDC>(&account);

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        0,
    );

    assert!(quote.penalty_fee() > 0);
    assert!(quote.quantity() < TEN_THOUSAND_LOTS);
    assert_eq!(order::from_order_id(order_id).quantity(), quote.quantity());
    assert!(quote.all_in_cost() <= budget);
    assert!(one_more_lot.all_in_cost() > budget);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        balance_before - quote.all_in_cost(),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EMintCostAboveMax)]
fun premium_budget_mint_aborts_when_the_surcharge_lands_after_the_quote() {
    let (mut fx, expiry_id, trader) = congested_market();
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        SPIKE_SOURCE_TS,
    );

    // The same pre-spike budget through premium sizing: the fill is chosen on
    // premium alone, and the surcharge on top breaches the all-in cap. This is
    // the abort the padding in a quote-then-send flow exists to avoid.
    let unsurcharged = atm_quote_checked(&mut fx, &market, TEN_THOUSAND_LOTS);
    let budget = unsurcharged.all_in_cost() - unsurcharged.penalty_fee();
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        unsurcharged.premium(),
        0,
        budget,
    );

    abort 999
}

// === Inventory impact, the book-dependent term ===

#[test]
fun inventory_impact_is_sized_inside_the_budget() {
    let (mut fx, expiry_id, trader) = impact_market(test_constants::default_manager_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let fill = impact_quote(&mut fx, &market, TEN_THOUSAND_LOTS);
    let next_lot = impact_quote(&mut fx, &market, NEXT_LOT_QUANTITY);
    // On an empty book the mint's own payout is the whole liability, which sits
    // below the scale B = 1e10, so the quadratic arm applies:
    // phi(L) = r_max * L^2 / (2B) = 0.2 * 1e8^2 / 2e10 = 100_000.
    assert_eq!(fill.inventory_impact_charge(), BELOW_KINK_IMPACT_CHARGE);
    let budget = next_lot.all_in_cost() - 1;
    let balance_before = fx.account_balance_bundle<USDC>(&account);

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        budget,
        TEN_THOUSAND_LOTS,
    );

    assert_eq!(order::from_order_id(order_id).quantity(), TEN_THOUSAND_LOTS);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        balance_before - fill.all_in_cost(),
    );
    assert_eq!(
        helpers::market(&market).inventory_impact_reserve(),
        fill.inventory_impact_charge(),
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun impact_above_the_curve_kink_still_sizes_exactly() {
    let (mut fx, expiry_id, trader) = impact_market(test_constants::default_manager_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Spending the whole balance drives liability past the impact scale, where
    // the marginal rate caps and the curve turns linear: the search crosses the
    // kink and must still land on the largest fitting lot.
    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );
    let one_more_lot = impact_quote(
        &mut fx,
        &market,
        quote.quantity() + constants::position_lot_size!(),
    );
    let balance_before = fx.account_balance_bundle<USDC>(&account);

    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );

    // Past the kink the liability is the mint's own payout and the marginal rate
    // is capped, so the charge is the linear arm:
    // phi(q) - phi(0) = phi(B) + r_max * (q - B) = 1e9 + 0.2q - 2e9 = q/5 - 1e9.
    assert!(quote.quantity() > IMPACT_SCALE);
    assert_eq!(
        quote.inventory_impact_charge(),
        quote.quantity() / 5 - CAPPED_RATE_INTERCEPT,
    );
    assert!(quote.all_in_cost() <= balance_before);
    assert!(one_more_lot.all_in_cost() > balance_before);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        balance_before - quote.all_in_cost(),
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun impact_over_a_disjoint_book_sizes_exactly() {
    let (mut fx, expiry_id, trader) = impact_market(test_constants::default_manager_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // A position on the complementary range leaves this range's own payout peak
    // at zero while the book's point max is not, so the prospective liability
    // switches from gap-driven to max-driven partway through the search.
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        DISJOINT_BOOK_QUANTITY,
        std::u64::max_value!(),
        std::u64::max_value!(),
    );

    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );
    let one_more_lot = impact_quote(
        &mut fx,
        &market,
        quote.quantity() + constants::position_lot_size!(),
    );
    let balance_before = fx.account_balance_bundle<USDC>(&account);

    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );

    // The complementary position makes the book's point max 1e10 and its total
    // 1e10, so before the mint the gap is zero and phi(1e10) = phi(B) = 1e9.
    // Once the candidate passes that point max it drives the max itself, leaving
    // a constant 1e10 gap: L = q + 0.5 * 1e10, and the linear arm gives
    // phi(L) - phi(B) = 0.2 * (q + 5e9 - 1e10) = q/5 - 1e9. Same closed form as
    // the empty-book case, reached through the max-driven branch instead.
    assert!(quote.quantity() > DISJOINT_BOOK_QUANTITY);
    assert_eq!(
        quote.inventory_impact_charge(),
        quote.quantity() / 5 - CAPPED_RATE_INTERCEPT,
    );
    assert!(one_more_lot.all_in_cost() > balance_before);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        balance_before - quote.all_in_cost(),
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun impact_on_a_range_that_already_holds_exposure_sizes_exactly() {
    let (mut fx, expiry_id, trader) = impact_market(test_constants::default_manager_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Adding to a range that already holds payout: the candidate stacks onto
    // that range's own peak, so the prospective point max carries it and the
    // book's gap stays closed. Sizing against a stale peak would misprice every
    // probe.
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        SAME_RANGE_BOOK_QUANTITY,
        std::u64::max_value!(),
        std::u64::max_value!(),
    );

    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );
    let one_more_lot = impact_quote(
        &mut fx,
        &market,
        quote.quantity() + constants::position_lot_size!(),
    );
    let balance_before = fx.account_balance_bundle<USDC>(&account);

    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );

    // Liability runs from B = 1e10 to 1e10 + q with no gap on either side, so
    // the capped arm charges r_max * q = q/5 with no intercept.
    assert_eq!(quote.inventory_impact_charge(), quote.quantity() / 5);
    assert!(one_more_lot.all_in_cost() > balance_before);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        balance_before - quote.all_in_cost(),
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Budget edges ===

#[test, expected_failure(abort_code = strike_exposure_config::EPremiumBelowMinimum)]
fun dust_budget_below_the_minimum_premium_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        DUST_BUDGET,
        0,
    );

    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EPremiumBelowMinimum)]
fun zero_budget_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Zero is a budget that buys nothing, not a disabled cap: sizing lands on
    // zero and admission rejects it.
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        0,
        0,
    );

    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EPremiumBelowMinimum)]
fun empty_balance_caps_the_budget_to_zero() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(0);
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // An unfunded account sizes to zero against any budget, so the flow rejects
    // on admission rather than underflowing the account withdrawal.
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );

    abort 999
}

#[test]
fun oversized_budget_and_balance_saturate_at_the_lot_cap() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(LOT_CAP_DEPOSIT);
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    // A balance that can afford more than the lot cap: the search domain, not
    // the budget, is what binds, and no probe overflows on the way there.
    let quote = fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        std::u64::max_value!(),
        0,
    );

    assert_eq!(quote.quantity(), LOT_CAP_QUANTITY);
    assert!(quote.all_in_cost() < LOT_CAP_DEPOSIT);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Maximum-payout boundary ===

#[test]
fun fill_whose_cost_equals_its_maximum_payout_mints() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(MAX_PAYOUT_BOUNDARY_MIN_FEE_RATE);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // At these rates the all-in cost of this fill is exactly its quantity, the
    // most a winner can ever be paid — admitted, and the passing side of the
    // bound the next test pins from above.
    let fill = atm_quote_checked(&mut fx, &market, MAX_PAYOUT_BOUNDARY_QUANTITY);
    assert_eq!(fill.all_in_cost(), MAX_PAYOUT_BOUNDARY_QUANTITY);

    let order_id = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        MAX_PAYOUT_BOUNDARY_QUANTITY,
    );

    assert_eq!(order::from_order_id(order_id).quantity(), MAX_PAYOUT_BOUNDARY_QUANTITY);
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - MAX_PAYOUT_BOUNDARY_QUANTITY,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EMintCostAboveMaxPayout)]
fun sized_fill_above_its_maximum_payout_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(LOSS_MAKING_MIN_FEE_RATE);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // At a rate this high every fill costs more than it can ever pay out:
    // fitting the budget does not exempt the sized fill from that bound.
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        0,
    );

    abort 999
}

// === Flow gates ===

#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun mint_exact_cost_on_a_paused_market_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_expiry_mint_paused_bundle(&mut market, true);
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_deposit(),
        0,
    );

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun mint_exact_cost_while_trading_paused_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_trading_paused_bundle(&mut market, true);
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_deposit(),
        0,
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun cost_quote_on_a_paused_market_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    fx.set_expiry_mint_paused_bundle(&mut market, true);
    fx.quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_deposit(),
        0,
    );

    abort 999
}

// === Fixtures ===

/// The anonymous quantity quote at the fixture's at-the-money strike, the
/// reference every budget threshold and expected debit is read from.
fun atm_quote(fx: &mut helpers::Fixture, market: &helpers::MarketBundle, quantity: u64): MintQuote {
    fx.quote_mint_bundle(
        market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        quantity,
    )
}

/// `atm_quote` with its probability pinned against the independent reference, so
/// the budgets derived from it are anchored to a verified price.
fun atm_quote_checked(
    fx: &mut helpers::Fixture,
    market: &helpers::MarketBundle,
    quantity: u64,
): MintQuote {
    let quote = atm_quote(fx, market, quantity);
    helpers::assert_atm_entry_probability(quote.entry_probability());
    quote
}

/// The account-aware quantity quote, for fixtures whose cost depends on account
/// attribution (a builder code).
fun account_quote_checked(
    fx: &mut helpers::Fixture,
    market: &helpers::MarketBundle,
    account: &helpers::AccountBundle,
    quantity: u64,
): MintQuote {
    let quote = fx.quote_mint_for_account_bundle(
        market,
        account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        quantity,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    quote
}

/// The quantity quote for the short-expiry inventory-impact fixture, whose
/// horizon rolls the digital further down than the far-expiry reference.
fun impact_quote(
    fx: &mut helpers::Fixture,
    market: &helpers::MarketBundle,
    quantity: u64,
): MintQuote {
    let quote = atm_quote(fx, market, quantity);
    helpers::assert_atm_entry_probability_short_expiry(quote.entry_probability());
    quote
}

/// A live market with the inventory-impact curve enabled, mirroring
/// `inventory_impact_flow_tests`, with the trader positioned to mint.
fun impact_market(deposit: u64): (helpers::Fixture, ID, helpers::Trader) {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(BACKING_BUFFER_LAMBDA);
    fx.set_template_inventory_impact_max_rate(IMPACT_MAX_RATE);
    fx.set_default_cadence_allocation(IMPACT_SCALE, test_constants::default_initial_expiry_cash());
    let expiry_id = fx.create_expiry(test_constants::short_expiry_ms());
    let trader = fx.create_funded_manager(deposit);
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::alice());
    (fx, expiry_id, trader)
}

/// A live market whose EWMA has one gas observation folded in, left in a
/// gas-spike transaction so the congestion surcharge is live. Mirrors the
/// `quote_mint_tests` fixture.
fun congested_market(): (helpers::Fixture, ID, helpers::Trader) {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.set_ewma_penalty_bundle(
        &mut market,
        config_constants::default_ewma_alpha!(),
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::default_ewma_penalty_rate!(),
    );
    helpers::return_market_bundle(market);

    let epoch_timestamp_ms = fx.scenario_mut().ctx().epoch_timestamp_ms();
    let seed_ctx = fx
        .scenario_mut()
        .ctx_builder()
        .set_gas_price(GAS_SEED)
        .set_epoch_timestamp(epoch_timestamp_ms);
    fx.scenario_mut().next_with_context(seed_ctx);
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        VARIANCE_SEED_QUANTITY,
        std::u64::max_value!(),
        std::u64::max_value!(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.set_clock_for_testing(SPIKE_MS);
    let spike_ctx = fx
        .scenario_mut()
        .ctx_builder()
        .set_gas_price(GAS_SPIKE)
        .set_epoch_timestamp(epoch_timestamp_ms);
    fx.scenario_mut().next_with_context(spike_ctx);
    (fx, expiry_id, trader)
}
