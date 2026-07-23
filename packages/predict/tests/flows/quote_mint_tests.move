// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the public mint quote surface: a quote's `all_in_cost` is
/// the exact account debit of a same-state mint (quotes and settlement consume
/// one shared computation) — pinned with every fee component at zero AND with
/// each component nonzero (sponsor subsidy, builder fee, stake discount, EWMA
/// congestion penalty); the account-aware quote diverges from the anonymous
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

/// Independent fixture costs for the at-the-money `mint_quantity()` (1e9) 1x
/// mint, same derivation as `mint_redeem_guard_tests::ALL_IN_MINT_COST`: entry
/// probability is the at-the-money digital Φ(0) = 0.5 exactly, and a 1x order
/// fronts its full premium, so net_premium = floor(0.5 * 1e9) = 500_000_000;
/// the fixture floors base_fee to 1, so the fee binds at min_fee (0.005) *
/// quantity = 5_000_000; no builder code, no fee-incentive balance, and no EWMA
/// variance exist here, so those components are zero. Total = 505_000_000.
const ENTRY_PROBABILITY_ATM: u64 = 500_000_000;
const NET_PREMIUM_ATM: u64 = 500_000_000;
const MIN_TRADING_FEE: u64 = 5_000_000;
const ALL_IN_MINT_COST: u64 = 505_000_000;

/// Sponsoring the protocol-minimum incentive (10e6, fully allocated to the
/// market by one live rebalance) leaves the balance far above the rate cap, so
/// the subsidy binds at fee_incentive_subsidy_rate (0.2) * MIN_TRADING_FEE =
/// 1_000_000 and the trader saves exactly that off the all-in cost.
const SUBSIDY_AT_RATE_CAP: u64 = 1_000_000;
const ALL_IN_WITH_SUBSIDY: u64 = 504_000_000;

/// Builder fee for the ATM mint: min(builder_fee_multiplier (0.1) *
/// MIN_TRADING_FEE, max_builder_fee_rate (0.005) * quantity (1e9)) =
/// min(500_000, 5_000_000) = 500_000, paid on top of the anonymous cost.
const BUILDER_FEE_ATM: u64 = 500_000;
const ALL_IN_WITH_BUILDER: u64 = 505_500_000;
const BUILDER_CODE_INDEX: u64 = 0;
const ROUND_UP_MIN_FEE: u64 = 5_000_009;
const ROUND_UP_QUANTITY: u64 = 1_000_010_000;
const ROUND_UP_NET_PREMIUM: u64 = 500_005_000;
const ROUND_UP_TRADING_FEE: u64 = 5_000_060;
const ROUND_UP_BUILDER_FEE: u64 = 500_006;
const ROUND_UP_ALL_IN_WITH_BUILDER: u64 = 505_505_066;

/// Full-benefit stake (>= upper_benefit_power) earns the max fee discount:
/// benefit_ratio = 1.0, discount_fraction = max_fee_discount (0.5), so the fee
/// halves to 2_500_000 and the all-in cost drops by the same 2_500_000.
const DISCOUNTED_TRADING_FEE: u64 = 2_500_000;
const ALL_IN_WITH_FULL_STAKE_DISCOUNT: u64 = 502_500_000;

/// The congestion surcharge is flat once it fires: default_ewma_penalty_rate
/// (0.001) * quantity (1e9) = 1_000_000, independent of the z-score magnitude.
/// Same value as `ewma_tests::EXPECTED_PENALTY`.
const EWMA_PENALTY_FLAT: u64 = 1_000_000;
const ALL_IN_WITH_PENALTY: u64 = 506_000_000;
/// Small first mint whose only job is folding the gas-2000 observation into the
/// market's EWMA: premium 0.5 * 1e8 = 50_000_000 plus min fee 0.005 * 1e8 =
/// 500_000.
const VARIANCE_SEED_QUANTITY: u64 = 100_000_000;
const VARIANCE_SEED_COST: u64 = 50_500_000;
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
        test_constants::leverage_one_x(),
    );
    assert_eq!(quote.entry_probability(), ENTRY_PROBABILITY_ATM);
    assert_eq!(quote.net_premium(), NET_PREMIUM_ATM);
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), 0);
    assert_eq!(quote.builder_fee(), 0);
    assert_eq!(quote.penalty_fee(), 0);
    assert_eq!(quote.all_in_cost(), ALL_IN_MINT_COST);

    // The quote is the exact debit: minting with max_cost == all_in_cost
    // succeeds and withdraws exactly the independently derived total.
    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - ALL_IN_MINT_COST,
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
        test_constants::leverage_one_x(),
    );
    let for_account = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    assert_eq!(for_account.entry_probability(), anonymous.entry_probability());
    assert_eq!(for_account.net_premium(), anonymous.net_premium());
    assert_eq!(for_account.trading_fee(), anonymous.trading_fee());
    assert_eq!(for_account.fee_incentive_subsidy(), anonymous.fee_incentive_subsidy());
    assert_eq!(for_account.builder_fee(), anonymous.builder_fee());
    assert_eq!(for_account.penalty_fee(), anonymous.penalty_fee());
    assert_eq!(for_account.all_in_cost(), ALL_IN_MINT_COST);

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
        test_constants::leverage_one_x(),
    );
    // The expiry still collects the full fee; the sponsor covers the subsidy.
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), SUBSIDY_AT_RATE_CAP);
    assert_eq!(quote.all_in_cost(), ALL_IN_WITH_SUBSIDY);

    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - ALL_IN_WITH_SUBSIDY,
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
        test_constants::leverage_one_x(),
    );
    assert_eq!(anonymous.builder_fee(), 0);
    assert_eq!(anonymous.all_in_cost(), ALL_IN_MINT_COST);

    let for_account = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(for_account.builder_fee(), BUILDER_FEE_ATM);
    assert_eq!(for_account.all_in_cost(), ALL_IN_WITH_BUILDER);

    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        for_account.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - ALL_IN_WITH_BUILDER,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun rounded_trading_fee_can_advance_derived_builder_fee_by_one_atom() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_min_fee(ROUND_UP_MIN_FEE);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    helpers::return_market_bundle(market);
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let quote = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ROUND_UP_QUANTITY,
        test_constants::leverage_one_x(),
    );

    // The pre-change floors were 5_000_059 for trading and 500_005 for the
    // derived builder fee. Rounding the first component upward lands exactly on
    // the builder's next 10% integer threshold, so the all-in delta is two atoms.
    assert_eq!(quote.entry_probability(), ENTRY_PROBABILITY_ATM);
    assert_eq!(quote.net_premium(), ROUND_UP_NET_PREMIUM);
    assert_eq!(quote.trading_fee(), ROUND_UP_TRADING_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), 0);
    assert_eq!(quote.builder_fee(), ROUND_UP_BUILDER_FEE);
    assert_eq!(quote.penalty_fee(), 0);
    assert_eq!(quote.all_in_cost(), ROUND_UP_ALL_IN_WITH_BUILDER);

    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ROUND_UP_QUANTITY,
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - ROUND_UP_ALL_IN_WITH_BUILDER,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun stale_stake_quote_overstates_and_rolled_quote_matches_discounted_debit() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.fund_deep_bundle(&mut account, config_constants::default_upper_benefit_power!());
    fx.stake_deep_bundle(
        &mut market,
        &mut account,
        config_constants::default_upper_benefit_power!(),
    );

    // Same-epoch stake is inactive; the as-is quote stays undiscounted.
    let same_epoch = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(same_epoch.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(same_epoch.all_in_cost(), ALL_IN_MINT_COST);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_epoch(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // The stake is now rollable but un-rolled; the quote reads active_stake
    // as-is, so it still shows the full cost — it can only overstate.
    let stale = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(stale.all_in_cost(), ALL_IN_MINT_COST);

    // The mint rolls the stake first, so the stale quote as max_cost cannot
    // abort and the actual debit is the discounted total.
    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        stale.all_in_cost(),
        std::u64::max_value!(),
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - ALL_IN_WITH_FULL_STAKE_DISCOUNT,
    );

    // Post-roll, the account quote reads the active stake and matches the
    // discounted charge exactly, now below the anonymous quote.
    let rolled = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(rolled.trading_fee(), DISCOUNTED_TRADING_FEE);
    assert_eq!(rolled.all_in_cost(), ALL_IN_WITH_FULL_STAKE_DISCOUNT);

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
        test_constants::leverage_one_x(),
        std::u64::max_value!(),
        std::u64::max_value!(),
    );
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
        test_constants::leverage_one_x(),
    );
    assert_eq!(quote.penalty_fee(), EWMA_PENALTY_FLAT);
    assert_eq!(quote.all_in_cost(), ALL_IN_WITH_PENALTY);

    let order = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        test_constants::mint_deposit() - VARIANCE_SEED_COST - ALL_IN_WITH_PENALTY,
    );

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
        test_constants::leverage_one_x(),
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
        test_constants::leverage_one_x(),
    );

    abort 999
}
