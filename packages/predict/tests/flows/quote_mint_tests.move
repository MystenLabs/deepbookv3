// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the public mint quote surface: a quote's `all_in_cost` is
/// the exact account debit of a same-state mint (quotes and settlement consume
/// one shared computation) — pinned with every fee component at zero AND with
/// each component nonzero (sponsor subsidy, builder fee, EWMA congestion
/// penalty); the account-aware quote diverges from the anonymous
/// quote in the right direction per component; quotes share the mint path's
/// gates and admission aborts; and the settlement readers answer without
/// aborting on a live market.
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
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

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

/// Sponsoring the protocol-minimum incentive (10e6, fully allocated to the
/// market by one live rebalance) leaves the balance far above the rate cap, so
/// the subsidy binds at fee_incentive_subsidy_rate (0.2) * MIN_TRADING_FEE =
/// 1_000_000 and the trader saves exactly that off the all-in cost.
const SUBSIDY_AT_RATE_CAP: u64 = 1_000_000;

/// Builder fee for the ATM mint: min(builder_fee_multiplier (0.1) *
/// MIN_TRADING_FEE, max_builder_fee_rate (0.005) * quantity (1e9)) =
/// min(500_000, 5_000_000) = 500_000, paid on top of the anonymous cost.
const BUILDER_FEE_ATM: u64 = 500_000;
const BUILDER_CODE_INDEX: u64 = 0;

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
        fx.account_balance_bundle<DUSDC>(&account),
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
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - with_subsidy,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun builder_code_raises_account_quote_and_mint_debits_exactly() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // The builder fee is account attribution: the anonymous quote stays at the
    // no-builder cost, the account quote is higher by exactly the builder fee.
    let anonymous = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    let premium = anonymous.premium();
    helpers::assert_atm_entry_probability(anonymous.entry_probability());
    assert_eq!(anonymous.builder_fee(), 0);
    assert_eq!(anonymous.all_in_cost(), premium + MIN_TRADING_FEE);

    let for_account = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(for_account.builder_fee(), BUILDER_FEE_ATM);
    let with_builder = premium + MIN_TRADING_FEE + BUILDER_FEE_ATM;
    assert_eq!(for_account.all_in_cost(), with_builder);

    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        for_account.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - with_builder,
    );

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
    let balance_after_seed = fx.account_balance_bundle<DUSDC>(&account);
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
    assert_eq!(fx.account_balance_bundle<DUSDC>(&account), balance_after_seed - with_penalty);

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
