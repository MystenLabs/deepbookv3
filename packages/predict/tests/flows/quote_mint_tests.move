// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the public mint quote surface: a quote's `all_in_cost` is
/// the exact account debit of a same-state mint (quotes and settlement consume
/// one shared computation) — pinned with every fee component at zero AND with
/// each component nonzero (sponsor subsidy, EWMA congestion penalty); a builder
/// fee the trade names adds exactly `quantity * fee`, capped at the builder fee
/// cap, and a code attached to the account adds nothing; the account-aware quote
/// diverges from the anonymous quote in the right direction per component;
/// quotes share the mint path's
/// gates, admission aborts, and maximum-payout bound; and the settlement readers
/// answer without aborting on a live market.
#[test_only]
module deepbook_predict::quote_mint_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    order,
    test_constants
};
use std::unit_test::assert_eq;
use usdc::usdc::USDC;

/// Independent fee components for the at-the-money `mint_quantity()` (1e9)
/// mint. The premium is read from the quote rather than written down as a
/// literal — the exact integer a Cody rational approximation lands on cannot be
/// derived independently, and a hand-written one encoded a rounding artifact as
/// protocol economics until 1e18 variance exposed it (`Φ(0) = 0.5` was 6,310
/// units from true). Each test therefore does BOTH: pins the quoted probability
/// against the generated true-math digital within its documented budget
/// (`assert_atm_entry_probability`), then asserts the fee composition and the
/// account debit around it exactly. Neither half is sufficient alone — without
/// the first, a wrong price would satisfy every assertion below it.
///
/// The fixture floors base_fee to 1, so the fee binds at min_fee (0.005) *
/// quantity = 5_000_000; with no builder code, no fee-incentive balance, and no
/// EWMA variance, every other component is zero.
const MIN_TRADING_FEE: u64 = 5_000_000;
/// At quantity 4e6, the independent ATM probability reference and its full
/// 21-unit approximation budget both floor to premium 1,999,974. The two fee
/// rates below therefore put all-in cost exactly at quantity and one USDC base
/// unit above it, respectively.
const MAX_PAYOUT_BOUNDARY_QUANTITY: u64 = 4_000_000;
const MAX_PAYOUT_BOUNDARY_PREMIUM: u64 = 1_999_974;
const MAX_PAYOUT_BOUNDARY_FEE: u64 = 2_000_026;
const MAX_PAYOUT_BOUNDARY_MIN_FEE_RATE: u64 = 500_006_500;
const ABOVE_MAX_PAYOUT_MIN_FEE_RATE: u64 = 500_006_750;

/// Sponsoring the protocol-minimum incentive (10e6, fully allocated to the
/// market by one live rebalance) leaves the balance far above the rate cap, so
/// the subsidy binds at fee_incentive_subsidy_rate (0.2) * MIN_TRADING_FEE =
/// 1_000_000 and the trader saves exactly that off the all-in cost.
const SUBSIDY_AT_RATE_CAP: u64 = 1_000_000;

/// A trade's builder fee of 0.0005 per $1 contract, in FLOAT_SCALING.
const BUILDER_FEE_PER_CONTRACT: u64 = 500_000;
/// A builder fee cap of 0.0002 per contract, below that fee.
const LOW_BUILDER_FEE_CAP: u64 = 200_000;
const BUILDER_CODE_INDEX: u64 = 0;
/// The highest builder fee cap: the whole $1 payout.
const WHOLE_PAYOUT_FEE: u64 = 1_000_000_000;
/// A builder fee also counts toward the maximum-payout bound. At
/// MAX_PAYOUT_BOUNDARY_QUANTITY the default 0.005 trading fee is 4e6 * 0.005 =
/// 20_000, so a builder fee of 4e6 - 1_999_974 - 20_000 = 1_980_026 puts the
/// all-in cost exactly at the payout. That is 4e6 * 0.4950065.
const MAX_PAYOUT_BOUNDARY_TRADING_FEE: u64 = 20_000;
const MAX_PAYOUT_BOUNDARY_BUILDER_FEE: u64 = 1_980_026;
const BUILDER_FEE_AT_MAX_PAYOUT: u64 = 495_006_500;
/// The smallest fee per contract one unit above: floor(4e6 * 0.49500675) =
/// 1_980_027, an all-in cost of 4_000_001. 0.495006749 still floors to 1_980_026.
const BUILDER_FEE_ABOVE_MAX_PAYOUT: u64 = 495_006_750;
/// `u64::MAX` as a named fee per contract.
const MAX_U64_FEE: u64 = 18_446_744_073_709_551_615;
/// Builder fees are quoted on the 4m boundary mint, where a fee amount differs
/// from its fee per contract (at the 1e9 mint the two are equal): 4e6 * 0.0005
/// = 2_000 named, 4e6 * 0.0002 = 800 at LOW_BUILDER_FEE_CAP, and 4e6 * 0.05 =
/// 200_000 at the shipped 5c cap.
const BUILDER_FEE_4M: u64 = 2_000;
const CAPPED_BUILDER_FEE_4M: u64 = 800;
const DEFAULT_CAP_BUILDER_FEE_4M: u64 = 200_000;
/// The 4m mint's all-in cost with no builder fee:
/// MAX_PAYOUT_BOUNDARY_PREMIUM + MAX_PAYOUT_BOUNDARY_TRADING_FEE.
const ALL_IN_COST_4M: u64 = 2_019_974;
/// Exact-cost sizing on 10_000 lots at a budget of ALL_IN_COST_4M. With no
/// builder fee 4m fits exactly, and 4.01m costs floor(p * 4.01m) = 2_004_974
/// plus 20_050 = 2_025_024, over budget. With the 0.0005 fee 4m costs
/// 2_021_974, over budget, so the fill steps down to 3.99m: floor(p * 3.99m) =
/// 1_994_974 across the probability band, a 3.99m * 0.005 = 19_950 trading fee,
/// and a 3.99m * 0.0005 = 1_995 builder fee, 2_016_919 in all.
const STEPPED_DOWN_QUANTITY: u64 = 3_990_000;
const STEPPED_DOWN_PREMIUM: u64 = 1_994_974;
const STEPPED_DOWN_TRADING_FEE: u64 = 19_950;
const STEPPED_DOWN_BUILDER_FEE: u64 = 1_995;
const STEPPED_DOWN_ALL_IN_COST: u64 = 2_016_919;
/// A cap that stops builder fees.
const ZERO_BUILDER_FEE_CAP: u64 = 0;

/// The congestion surcharge is flat once it fires: default_ewma_penalty_rate
/// (0.001) * quantity (1e9) = 1_000_000, independent of the z-score magnitude.
/// Same value as `ewma_tests::EXPECTED_PENALTY`.
const EWMA_PENALTY_FLAT: u64 = 1_000_000;
/// Small first mint whose only job is folding the gas-2000 observation into the
/// market's EWMA. Its cost is measured from the account balance rather than
/// derived, since the flow under test is the spike mint that follows it.
const VARIANCE_SEED_QUANTITY: u64 = 100_000_000;
const GAS_SEED: u64 = 2_000;
const GAS_SPIKE: u64 = 3_000;
/// One second past the fixture's `now_ms()`: a distinct millisecond for the
/// second EWMA fold, still inside the oracle freshness window after re-seeding.
const SPIKE_MS: u64 = 121_000;
const SPIKE_SOURCE_TS: u64 = 120_000;

#[test, expected_failure(abort_code = expiry_market::EMintCostAboveMaxPayout)]
fun quote_above_maximum_payout_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(ABOVE_MAX_PAYOUT_MIN_FEE_RATE);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());

    fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
    );

    abort 999
}

#[test]
fun quote_at_maximum_payout_mints() {
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
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.premium(), MAX_PAYOUT_BOUNDARY_PREMIUM);
    assert_eq!(quote.trading_fee(), MAX_PAYOUT_BOUNDARY_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), 0);
    assert_eq!(quote.builder_fee(), 0);
    assert_eq!(quote.penalty_fee(), 0);
    assert_eq!(quote.inventory_impact_charge(), 0);
    assert_eq!(quote.all_in_cost(), MAX_PAYOUT_BOUNDARY_QUANTITY);

    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - MAX_PAYOUT_BOUNDARY_QUANTITY,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun quote_matches_independent_costs_and_mint_debits_exactly_all_in_cost() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Live market: the settlement readers answer without aborting.
    assert!(!helpers::market(&market).is_settled());
    assert!(helpers::market(&market).try_settlement_price().is_none());

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    // `mint_quantity()` is exactly one contract, so the premium is the entry
    // probability with nothing to round.
    let premium = quote.premium();
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(premium, quote.entry_probability());
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), 0);
    assert_eq!(quote.builder_fee(), 0);
    assert_eq!(quote.penalty_fee(), 0);
    assert_eq!(quote.all_in_cost(), premium + MIN_TRADING_FEE);

    // The quote is the exact debit: minting with max_cost == all_in_cost
    // succeeds and withdraws exactly the independently derived total.
    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - (premium + MIN_TRADING_FEE),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun account_quote_matches_anonymous_without_stake_or_builder() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    let anonymous = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let for_account = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );

    assert_eq!(for_account.entry_probability(), anonymous.entry_probability());
    assert_eq!(for_account.premium(), anonymous.premium());
    assert_eq!(for_account.trading_fee(), anonymous.trading_fee());
    assert_eq!(for_account.fee_incentive_subsidy(), anonymous.fee_incentive_subsidy());
    assert_eq!(for_account.builder_fee(), anonymous.builder_fee());
    helpers::assert_atm_entry_probability(anonymous.entry_probability());
    assert_eq!(for_account.penalty_fee(), anonymous.penalty_fee());
    assert_eq!(for_account.all_in_cost(), anonymous.premium() + MIN_TRADING_FEE);
    assert_eq!(for_account.all_in_cost(), anonymous.all_in_cost());

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun sponsored_subsidy_lowers_quote_and_mint_debits_exactly() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!());
    fx.rebalance_expiry_cash_bundle(&mut market);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    // The expiry still collects the full fee; the sponsor covers the subsidy.
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), SUBSIDY_AT_RATE_CAP);
    let with_subsidy = quote.premium() + MIN_TRADING_FEE - SUBSIDY_AT_RATE_CAP;
    assert_eq!(quote.all_in_cost(), with_subsidy);

    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<USDC>(&account),
        test_constants::mint_deposit() - with_subsidy,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A code attached to the account is not a fee: the production account quote
/// stays at the no-builder cost. A fee the trade names adds quantity * fee,
/// rounded down.
#[test]
fun a_named_builder_fee_raises_the_quote_and_an_attached_code_does_not() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    let for_account = fx.production_quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
    );
    helpers::assert_atm_entry_probability(for_account.entry_probability());
    assert_eq!(for_account.premium(), MAX_PAYOUT_BOUNDARY_PREMIUM);
    assert_eq!(for_account.trading_fee(), MAX_PAYOUT_BOUNDARY_TRADING_FEE);
    assert_eq!(for_account.builder_fee(), 0);
    assert_eq!(for_account.all_in_cost(), ALL_IN_COST_4M);

    let with_fee = fx.quote_mint_with_builder_fee_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        BUILDER_FEE_PER_CONTRACT,
    );
    helpers::assert_atm_entry_probability(with_fee.entry_probability());
    assert_eq!(with_fee.premium(), MAX_PAYOUT_BOUNDARY_PREMIUM);
    assert_eq!(with_fee.builder_fee(), BUILDER_FEE_4M);
    assert_eq!(with_fee.all_in_cost(), ALL_IN_COST_4M + BUILDER_FEE_4M);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A named fee above the cap is quoted at the cap per contract.
#[test]
fun a_named_builder_fee_above_the_cap_is_quoted_at_the_cap() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.set_builder_fee_cap_bundle(&mut market, LOW_BUILDER_FEE_CAP);
    let account = fx.take_account_bundle(&trader);

    let with_fee = fx.quote_mint_with_builder_fee_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        BUILDER_FEE_PER_CONTRACT,
    );
    helpers::assert_atm_entry_probability(with_fee.entry_probability());
    assert_eq!(with_fee.premium(), MAX_PAYOUT_BOUNDARY_PREMIUM);
    assert_eq!(with_fee.builder_fee(), CAPPED_BUILDER_FEE_4M);
    assert_eq!(with_fee.all_in_cost(), ALL_IN_COST_4M + CAPPED_BUILDER_FEE_4M);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A builder fee that brings the all-in cost to exactly the 4m payout quotes.
#[test]
fun a_builder_fee_at_the_maximum_payout_quotes() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.set_builder_fee_cap_bundle(&mut market, WHOLE_PAYOUT_FEE);
    let account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_with_builder_fee_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        BUILDER_FEE_AT_MAX_PAYOUT,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.premium(), MAX_PAYOUT_BOUNDARY_PREMIUM);
    assert_eq!(quote.trading_fee(), MAX_PAYOUT_BOUNDARY_TRADING_FEE);
    assert_eq!(quote.builder_fee(), MAX_PAYOUT_BOUNDARY_BUILDER_FEE);
    assert_eq!(quote.all_in_cost(), MAX_PAYOUT_BOUNDARY_QUANTITY);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// One fee step more puts the all-in cost one unit above the payout, so the
/// quote refuses the mint as admission would.
#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_builder_fee_one_unit_past_the_maximum_payout_aborts_the_quote() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.set_builder_fee_cap_bundle(&mut market, WHOLE_PAYOUT_FEE);
    let account = fx.take_account_bundle(&trader);

    fx.quote_mint_with_builder_fee_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        BUILDER_FEE_ABOVE_MAX_PAYOUT,
    );

    abort 999
}

/// A named fee of `u64::MAX` is quoted at the shipped 5c cap without
/// overflowing.
#[test]
fun a_builder_fee_of_u64_max_is_quoted_at_the_default_cap() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_with_builder_fee_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        MAX_U64_FEE,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.premium(), MAX_PAYOUT_BOUNDARY_PREMIUM);
    assert_eq!(quote.builder_fee(), DEFAULT_CAP_BUILDER_FEE_4M);
    assert_eq!(quote.all_in_cost(), ALL_IN_COST_4M + DEFAULT_CAP_BUILDER_FEE_4M);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// A zero cap quotes a named fee as nothing.
#[test]
fun a_zero_builder_fee_cap_quotes_no_builder_fee() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.set_builder_fee_cap_bundle(&mut market, ZERO_BUILDER_FEE_CAP);
    let account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_with_builder_fee_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        MAX_PAYOUT_BOUNDARY_QUANTITY,
        BUILDER_FEE_PER_CONTRACT,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.premium(), MAX_PAYOUT_BOUNDARY_PREMIUM);
    assert_eq!(quote.builder_fee(), 0);
    assert_eq!(quote.all_in_cost(), ALL_IN_COST_4M);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The production exact-cost account quote names no builder: with a code
/// attached to the account, a budget of exactly the 4m all-in cost buys 4m and
/// charges no builder fee.
#[test]
fun the_plain_exact_cost_quote_fits_the_budget_with_no_builder_fee() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    let quote = fx.production_quote_mint_exact_cost_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ALL_IN_COST_4M,
        0,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.quantity(), MAX_PAYOUT_BOUNDARY_QUANTITY);
    assert_eq!(quote.premium(), MAX_PAYOUT_BOUNDARY_PREMIUM);
    assert_eq!(quote.trading_fee(), MAX_PAYOUT_BOUNDARY_TRADING_FEE);
    assert_eq!(quote.builder_fee(), 0);
    assert_eq!(quote.all_in_cost(), ALL_IN_COST_4M);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The exact-cost builder quote fits the named fee inside the same budget: 4m
/// no longer fits with its 2_000 fee, so the quote steps down one lot.
#[test]
fun a_builder_exact_cost_quote_steps_down_a_lot_to_fit_its_fee() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_exact_cost_with_builder_fee_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ALL_IN_COST_4M,
        0,
        BUILDER_FEE_PER_CONTRACT,
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.quantity(), STEPPED_DOWN_QUANTITY);
    assert_eq!(quote.premium(), STEPPED_DOWN_PREMIUM);
    assert_eq!(quote.trading_fee(), STEPPED_DOWN_TRADING_FEE);
    assert_eq!(quote.builder_fee(), STEPPED_DOWN_BUILDER_FEE);
    assert_eq!(quote.all_in_cost(), STEPPED_DOWN_ALL_IN_COST);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun ewma_penalty_included_in_quote_and_mint_debits_exactly() {
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

    // Seed one gas observation: a small mint in a gas-2000 transaction pays no
    // penalty itself (variance is zero pre-fold) and then folds 2000 in. With
    // the creation-gas mean m0 anywhere in [0, 1000], the spike z-score below
    // stays above the 1-sigma threshold: z = (3000 - mean') / std' with
    // mean' = 0.99*m0 + 20 and std' = 2000 - m0, so z in [1.49, 1.99].
    let ts = fx.scenario_mut().ctx().epoch_timestamp_ms();
    let seed_ctx = fx.scenario_mut().ctx_builder().set_gas_price(GAS_SEED).set_epoch_timestamp(ts);
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
    let balance_after_seed = fx.account_balance_bundle<USDC>(&account);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    // Spike transaction at gas 3000 in a fresh millisecond: the quote includes
    // the flat surcharge, and the mint in the same transaction charges exactly
    // the quoted pre-fold penalty (charge-then-fold, RP-9).
    fx.set_clock_for_testing(SPIKE_MS);
    let spike_ctx = fx
        .scenario_mut()
        .ctx_builder()
        .set_gas_price(GAS_SPIKE)
        .set_epoch_timestamp(ts);
    fx.scenario_mut().next_with_context(spike_ctx);
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        SPIKE_SOURCE_TS,
    );

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.penalty_fee(), EWMA_PENALTY_FLAT);
    let with_penalty = quote.premium() + MIN_TRADING_FEE + EWMA_PENALTY_FLAT;
    assert_eq!(quote.all_in_cost(), with_penalty);

    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(fx.account_balance_bundle<USDC>(&account), balance_after_seed - with_penalty);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun quote_mint_on_paused_market_aborts() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.set_expiry_mint_paused_bundle(&mut market, true);
    fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );

    abort 999
}

#[test, expected_failure(abort_code = order::EInvalidQuantity)]
fun quote_mint_non_lot_quantity_aborts() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);

    // One above a lot multiple: admission passes, lot validity must still abort
    // in the quote exactly as it does in the mint path's order construction.
    fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity() + 1,
    );

    abort 999
}
